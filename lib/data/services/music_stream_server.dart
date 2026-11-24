import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/music_track.dart';
import 'nas_service.dart';

/// The MIME type of a music file by its extension.
String musicContentType(String extension) => switch (extension) {
      '.mp3' || '.mp2' => 'audio/mpeg',
      '.m4a' || '.m4b' || '.mp4' || '.alac' => 'audio/mp4',
      '.aac' => 'audio/aac',
      '.flac' => 'audio/flac',
      '.wav' => 'audio/wav',
      '.ogg' || '.oga' => 'audio/ogg',
      '.opus' => 'audio/ogg; codecs=opus',
      '.mka' => 'audio/x-matroska',
      '.aif' || '.aiff' => 'audio/aiff',
      '.wma' => 'audio/x-ms-wma',
      '.ac3' => 'audio/ac3',
      _ => 'application/octet-stream',
    };

/// A "Range: bytes=..." header against a file of [size] bytes: the first
/// and the last byte (inclusive). Null for no/unusable range (the whole
/// file); start > end when it lies beyond the file (416).
({int start, int end})? parseByteRange(String? header, int size) {
  if (header == null) return null;
  final m = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$').firstMatch(header);
  if (m == null) return null;
  final a = m.group(1)!, b = m.group(2)!;
  if (a.isEmpty && b.isEmpty) return null;
  if (a.isEmpty) {
    // The last n bytes.
    final n = int.parse(b);
    if (n <= 0) return null;
    return (start: (size - n).clamp(0, size), end: size - 1);
  }
  final start = int.parse(a);
  final end = b.isEmpty ? size - 1 : int.parse(b).clamp(0, size - 1);
  if (start >= size) return (start: size, end: size - 1);
  if (end < start) return null;
  return (start: start, end: end);
}

/// Reads [length] bytes from [offset] of a NAS file into memory (for tags
/// and covers - small parts).
Future<Uint8List> readNasRange(NasClient client, String path, int offset, int length) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in client.openRead(path, offset: offset, length: length)) {
    builder.add(chunk);
    if (builder.length >= length) break;
  }
  final bytes = builder.takeBytes();
  return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
}

/// Plays NAS files through a little HTTP server on this device
/// (127.0.0.1): the player (ExoPlayer, libmpv) gets a plain http URL with
/// range requests (seeking, MP4s with their index at the end), each served
/// as a stream from the NAS ([NasClient.openRead] - WebDAV Range, FTP
/// REST, SMB offset reads). Nothing is held in memory or on disk: the
/// bytes go to the player as fast as it takes them (backpressure through
/// the socket). The same for every protocol - also for WebDAV, so the
/// login never reaches the player and self-signed https works.
///
/// [MusicStreamServer.isolated] runs it on an isolate of its own with its
/// own NAS client: every byte of the music passes through it, and the
/// player fills its buffer in bursts (several MB of FLAC/WAV at every
/// track change and when it loads the next track) - on the UI isolate that
/// made the picture stutter. The server keeps no state: the file's path
/// and size are in the address.
class MusicStreamServer {
  /// On its own isolate, reaching the NAS through a client of [config].
  MusicStreamServer.isolated(NasConfig config)
      : _config = config,
        _local = null;

  /// On this isolate with [client] (tests).
  MusicStreamServer.local(NasClient client)
      : _local = client,
        _config = null;

  final NasConfig? _config;
  final NasClient? _local;
  Future<int>? _port;
  HttpServer? _localServer;
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _exits;

  Future<int> _ensure() => _port ??= _start().catchError((Object e) {
        _port = null;
        throw e;
      });

  Future<int> _start() async {
    final local = _local;
    if (local != null) {
      final handler = _StreamHandler(local);
      final server = _localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(handler.serve, onError: (Object e) => debugPrint('music server: $e'));
      return server.port;
    }
    final ready = ReceivePort();
    final exits = _exits = ReceivePort();
    // Gone (crashed): started anew with the next track.
    exits.listen((_) {
      _port = null;
      _isolate = null;
      _commands = null;
    });
    _isolate = await Isolate.spawn(
      _serverMain,
      (ready.sendPort, _config!),
      onExit: exits.sendPort,
      debugName: 'music stream server',
    );
    final (port, commands) = await ready.first as (int, SendPort);
    ready.close();
    _commands = commands;
    return port;
  }

  /// The address the player opens for [track].
  Future<Uri> uriFor(MusicTrack track) async => musicStreamUri(await _ensure(), track);

  Future<void> close() async {
    _port = null;
    _commands?.send('close');
    _commands = null;
    final isolate = _isolate;
    _isolate = null;
    if (isolate != null) {
      // In case it doesn't close by itself.
      Future<void>.delayed(const Duration(seconds: 2), () => isolate.kill(priority: Isolate.immediate));
    }
    _exits?.close();
    _exits = null;
    await _localServer?.close(force: true);
    _localServer = null;
    _local?.close();
  }
}

/// The server's address of [track]: path (base64url) and size in it.
Uri musicStreamUri(int port, MusicTrack track) {
  final path = base64Url.encode(utf8.encode(track.path)).replaceAll('=', '');
  return Uri.parse('http://127.0.0.1:$port/t/$path/${track.size ?? '-'}/track${track.extension}');
}

/// The track of a server address made by [musicStreamUri] (null if none).
MusicTrack? musicStreamTrack(Uri uri) {
  final s = uri.pathSegments;
  if (s.length < 3 || s[0] != 't') return null;
  try {
    final encoded = s[1];
    final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
    return MusicTrack(utf8.decode(base64Url.decode(padded)), size: int.tryParse(s[2]));
  } catch (_) {
    return null;
  }
}

/// The server isolate: binds, reports its port and a port for "close".
Future<void> _serverMain((SendPort, NasConfig) args) async {
  final (reply, config) = args;
  final client = config.createClient();
  final handler = _StreamHandler(client);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler.serve, onError: (Object e) => debugPrint('music server: $e'));
  final commands = ReceivePort();
  reply.send((server.port, commands.sendPort));
  await for (final message in commands) {
    if (message == 'close') {
      commands.close();
      await server.close(force: true);
      client.close();
      Isolate.exit();
    }
  }
}

/// Answers the player's requests from the NAS.
class _StreamHandler {
  _StreamHandler(this._client);

  final NasClient _client;
  final _sizes = <String, int>{};

  Future<int?> _sizeOf(MusicTrack track) async {
    final known = track.size ?? _sizes[track.path];
    if (known != null) return known;
    final size = await _client.size(track.path);
    if (size != null) _sizes[track.path] = size;
    return size;
  }

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    final track = musicStreamTrack(request.uri);
    if (track == null || (request.method != 'GET' && request.method != 'HEAD')) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    StreamIterator<List<int>>? data;
    try {
      int? size;
      try {
        size = await _sizeOf(track);
      } on NasException {
        size = null;
      }
      response.headers.set(HttpHeaders.contentTypeHeader, musicContentType(track.extension));
      var offset = 0;
      int? length;
      if (size != null) {
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        final range = parseByteRange(request.headers.value(HttpHeaders.rangeHeader), size);
        if (range != null && range.start > range.end) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          await response.close();
          return;
        }
        if (range != null) {
          offset = range.start;
          length = range.end - range.start + 1;
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${range.start}-${range.end}/$size');
        } else {
          length = size;
          response.statusCode = HttpStatus.ok;
        }
        response.contentLength = length;
      }
      if (request.method == 'HEAD' || length == 0) {
        await response.close();
        return;
      }
      // The first bytes before the answer goes out - a NAS error can still
      // become an error status then.
      data = StreamIterator(_client.openRead(track.path, offset: offset, length: length));
      if (!await data.moveNext()) {
        await response.close();
        return;
      }
      final iterator = data;
      Stream<List<int>> rest() async* {
        yield iterator.current;
        while (await iterator.moveNext()) {
          yield iterator.current;
        }
      }

      await response.addStream(rest());
      await response.close();
    } catch (e) {
      // The player hung up (seek, next track) - or the NAS failed.
      if (e is NasException) debugPrint('music stream ${track.name}: $e');
      try {
        response.statusCode = e is NasException ? HttpStatus.badGateway : HttpStatus.internalServerError;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    } finally {
      unawaited(data?.cancel());
    }
  }
}
