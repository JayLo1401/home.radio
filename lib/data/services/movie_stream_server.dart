import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'nas_service.dart';

/// Bytes the [MovieStreamServer] hands out - a file on the NAS, several
/// joined (a DVD's VOB parts), or such bytes rewritten on the way.
abstract class MovieByteSource {
  int get length;

  /// The bytes from [start] up to [end] (exclusive). Cancelling the
  /// subscription stops the NAS transfer behind it.
  Stream<List<int>> read(int start, int end);
}

/// A piece of a file on the NAS.
class NasSegment {
  const NasSegment(this.path, this.offset, this.length);

  final String path;
  final int offset;
  final int length;

  @override
  String toString() => 'NasSegment($path @$offset +$length)';
}

/// [segments] one after the other, as one file: a film file (one
/// segment), the VOB parts of a DVD folder, or the VOB files' places
/// inside an ISO image.
class NasSegmentsSource implements MovieByteSource {
  NasSegmentsSource(this.client, this.segments) : length = segments.fold(0, (sum, s) => sum + s.length);

  final NasClient client;
  final List<NasSegment> segments;

  @override
  final int length;

  @override
  Stream<List<int>> read(int start, int end) async* {
    var segmentStart = 0;
    for (final s in segments) {
      final segmentEnd = segmentStart + s.length;
      if (segmentEnd > start && segmentStart < end) {
        final from = max(start, segmentStart) - segmentStart;
        final to = min(end, segmentEnd) - segmentStart;
        yield* client.openRead(s.path, offset: s.offset + from, length: to - from);
      }
      segmentStart = segmentEnd;
      if (segmentStart >= end) break;
    }
  }
}

/// [base] cut into packets of [inSize] bytes, each turned into [outSize]
/// bytes by [map] - always the same size, so every position can be
/// worked out both ways (ranges, seeking):
///
/// * DVD packs (2048 → 2048) rewritten in place (DvdPackFilter);
/// * M2TS (192 → 188): camcorder AVCHD files (.mts) carry 4 bytes of time
///   code before each MPEG-TS packet - ExoPlayer only reads plain 188-byte
///   packets.
///
/// A piece at the end shorter than a packet passes as it is if [inSize]
/// equals [outSize], else it's left out.
class PacketMappedSource implements MovieByteSource {
  PacketMappedSource(this.base, {required this.inSize, required this.outSize, required this.map})
      : length = base.length ~/ inSize * outSize + (inSize == outSize ? base.length % inSize : 0);

  final MovieByteSource base;
  final int inSize;
  final int outSize;

  /// One whole packet in, its [outSize] bytes out (may change it in place).
  Uint8List Function(Uint8List packet) map;

  @override
  final int length;

  @override
  Stream<List<int>> read(int start, int end) async* {
    end = min(end, length);
    if (start >= end) return;
    final firstPacket = start ~/ outSize;
    final lastPacket = (end + outSize - 1) ~/ outSize; // exclusive
    final inStart = firstPacket * inSize;
    final inEnd = min(base.length, lastPacket * inSize);
    final mapper = map;
    var outPosition = firstPacket * outSize; // of the next packet out
    // Copies: [map] may change the packets in place.
    final pending = BytesBuilder();

    Uint8List? emit(Uint8List out) {
      final from = max(start, outPosition) - outPosition;
      final to = min(end, outPosition + out.length) - outPosition;
      outPosition += out.length;
      if (to <= from) return null;
      return from == 0 && to == out.length ? out : Uint8List.sublistView(out, from, to);
    }

    await for (final chunk in base.read(inStart, inEnd)) {
      pending.add(chunk);
      if (pending.length < inSize) continue;
      final bytes = pending.takeBytes();
      final whole = bytes.length - bytes.length % inSize;
      final Uint8List mapped;
      if (inSize == outSize) {
        // Same size (DVD packs): rewritten where they are, no second copy.
        for (var at = 0; at < whole; at += inSize) {
          final packet = Uint8List.sublistView(bytes, at, at + inSize);
          final result = mapper(packet);
          if (!identical(result, packet)) bytes.setRange(at, at + inSize, result);
        }
        mapped = Uint8List.sublistView(bytes, 0, whole);
      } else {
        final out = BytesBuilder(copy: false);
        for (var at = 0; at < whole; at += inSize) {
          out.add(mapper(Uint8List.sublistView(bytes, at, at + inSize)));
        }
        mapped = out.takeBytes();
      }
      if (whole < bytes.length) pending.add(Uint8List.sublistView(bytes, whole));
      final piece = emit(mapped);
      if (piece != null) yield piece;
      if (outPosition >= end) return;
    }
    // The end of the file, shorter than a packet.
    if (pending.isNotEmpty && inSize == outSize) {
      final piece = emit(pending.takeBytes());
      if (piece != null) yield piece;
    }
  }
}

/// The 188-byte MPEG-TS packet of a 192-byte M2TS packet.
Uint8List m2tsToTs(Uint8List packet) => Uint8List.sublistView(packet, 4);

/// Whether [head] (a file's start) is M2TS: sync bytes 4 bytes into
/// every 192-byte packet.
bool looksLikeM2ts(Uint8List head) {
  if (head.length < 192 * 3) return false;
  for (var i = 0; i < 3; i++) {
    if (head[i * 192 + 4] != 0x47) return false;
  }
  return true;
}

/// A byte range of an HTTP request: [start] to [end] (exclusive).
typedef ByteRange = ({int start, int end});

/// The range a "Range: bytes=..." header asks for in a file of [total]
/// bytes: null without (or with an unknown kind of) header - the whole
/// file; a range with start >= end if it can't be served (416). Several
/// ranges: only the first.
ByteRange? parseRangeHeader(String? header, int total) {
  if (header == null) return null;
  final m = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)').firstMatch(header);
  if (m == null) return null;
  final first = m.group(1)!;
  final last = m.group(2)!;
  if (first.isEmpty) {
    // "bytes=-500": the last 500 bytes.
    if (last.isEmpty) return null;
    final suffix = int.parse(last);
    if (suffix == 0) return (start: total, end: total);
    return (start: max(0, total - suffix), end: total);
  }
  final start = int.parse(first);
  if (start >= total) return (start: total, end: total);
  final end = last.isEmpty ? total : min(total, int.parse(last) + 1);
  if (end <= start) return (start: total, end: total);
  return (start: start, end: end);
}

/// The content type of a film file by its extension (lower case, without
/// the dot).
String movieMimeType(String extension) => switch (extension.toLowerCase()) {
      'mp4' || 'm4v' || 'f4v' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      'avi' || 'divx' || 'xvid' => 'video/x-msvideo',
      'mov' || 'qt' => 'video/quicktime',
      '3gp' => 'video/3gpp',
      '3g2' => 'video/3gpp2',
      'mpg' || 'mpeg' || 'mpe' || 'vob' || 'iso' => 'video/mp2p',
      'm1v' || 'm2v' => 'video/mpeg',
      'ts' || 'm2ts' || 'mts' => 'video/mp2t',
      'wmv' => 'video/x-ms-wmv',
      'asf' => 'video/x-ms-asf',
      'flv' => 'video/x-flv',
      'ogm' || 'ogv' => 'video/ogg',
      'rm' || 'rmvb' || 'ra' => 'application/vnd.rn-realmedia',
      'dv' => 'video/dv',
      _ => 'application/octet-stream',
    };

/// A little HTTP server on this device (127.0.0.1) that hands a film from
/// the NAS to the player - with byte ranges (206, Content-Range), so the
/// player can seek and look at the end of the file (its length) at once;
/// every request gets its own NAS transfer, several at a time.
class MovieStreamServer {
  MovieStreamServer._(this._server, this._source, this._name, this._mime);

  final HttpServer _server;
  MovieByteSource _source;
  final String _name;
  final String _mime;
  int _generation = 0;

  /// [name]: the file name in the address, its extension tells the player
  /// the format (".mpg" for a DVD's program stream).
  static Future<MovieStreamServer> start(MovieByteSource source, {required String name, required String mime}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final session = MovieStreamServer._(server, source, name, mime);
    server.listen(session._serve, onError: (Object e) => debugPrint('MovieStreamServer: $e'));
    return session;
  }

  /// What the player opens - a new address after [replaceSource].
  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/$_generation/${Uri.encodeComponent(_name)}');

  int get length => _source.length;

  /// Other bytes from now on (another sound track of a DVD) - the player
  /// opens the new [uri].
  void replaceSource(MovieByteSource source) {
    _source = source;
    _generation++;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final source = _source;
    final total = source.length;
    try {
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, _mime);
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final range = parseRangeHeader(request.headers.value(HttpHeaders.rangeHeader), total);
      if (range != null && range.start >= range.end) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await response.close();
        return;
      }
      final start = range?.start ?? 0;
      final end = range?.end ?? total;
      response
        ..statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent
        ..contentLength = end - start;
      if (range != null) response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/$total');
      if (request.method == 'HEAD' || end == start) {
        await response.close();
        return;
      }
      await response.addStream(source.read(start, end));
      await response.close();
    } catch (e) {
      // The player went away (seeking, closed) - or the NAS failed.
      if (e is NasException) debugPrint('MovieStreamServer: $e');
      try {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {}
    }
  }

  Future<void> close() => _server.close(force: true);
}
