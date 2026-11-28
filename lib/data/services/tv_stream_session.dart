import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'enigma2_service.dart' show StreamScrambling, TsScramblingProbe;

/// [chunk] from its first MPEG-TS packet on: the first sync byte (0x47)
/// followed by two more 188 bytes apart (as far as the chunk goes).
List<int> alignToTsPacket(List<int> chunk) {
  for (var i = 0; i < 188 && i < chunk.length; i++) {
    if (chunk[i] != 0x47) continue;
    if (i + 188 < chunk.length && chunk[i + 188] != 0x47) continue;
    if (i + 376 < chunk.length && chunk[i + 376] != 0x47) continue;
    return i == 0 ? chunk : chunk.sublist(i);
  }
  return chunk;
}

/// One channel's stream from the receiver, passed through a little HTTP
/// server on this device (127.0.0.1) to the player - a single connection to
/// the receiver, looked at on the way:
///
/// * the player only gets the stream from the moment the picture arrives
///   descrambled - nothing scrambled ever reaches its decoder;
/// * [verdict] says right at the start whether the channel comes clear or
///   scrambled (a fraction of a second after the receiver's first data),
///   so the receiver can be switched to an encrypted channel at once;
/// * after switching, [reopen] fetches the stream anew if the running one
///   stays scrambled.
class TvStreamSession {
  TvStreamSession._(this._server, this._upstream, this._headers);

  final HttpServer _server;
  final Uri _upstream;
  final Map<String, String> _headers;
  final _data = StreamController<List<int>>();
  final _tap = StreamController<List<int>>.broadcast();
  final _verdict = Completer<StreamScrambling>();
  final _clear = Completer<void>();
  final _refused = Completer<void>();
  http.Client? _client;
  bool _closed = false;
  bool _reopen = false;
  bool _playerConnected = false;

  static Future<TvStreamSession> open(Uri upstream, Map<String, String> headers) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final session = TvStreamSession._(server, upstream, headers);
    server.listen(session._serve);
    unawaited(session._run());
    return session;
  }

  static final _nullPacket = Uint8List(188)
    ..fillRange(4, 188, 0xFF)
    ..setAll(0, const [0x47, 0x1F, 0xFF, 0x10]);

  /// What the player opens.
  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/stream.ts');

  /// The first look at the stream: clear, scrambled, or unknown (no data).
  Future<StreamScrambling> get verdict => _verdict.future;

  /// Completes when the picture runs descrambled (and flows to the player).
  Future<void> get clear => _clear.future;

  bool get isClear => _clear.isCompleted;

  /// The receiver's data as it comes, for a look on the way (HbbTV's AIT) -
  /// only fed while someone listens.
  Stream<List<int>> get tap => _tap.stream;

  /// The receiver ended a request without sending anything - typically no
  /// tuner free that can get the channel (FBC tuners on one cable only get
  /// the band/polarisation the receiver itself is tuned to). Switching the
  /// receiver to the channel helps; the session keeps trying meanwhile.
  Future<void> get refused => _refused.future;

  /// Drops the running connection and fetches the stream anew - after the
  /// receiver was switched to the channel, if this one stays scrambled.
  void reopen() {
    if (_clear.isCompleted) return;
    _reopen = true;
    _client?.close();
  }

  Future<void> _serve(HttpRequest request) async {
    // One player per session (a second request: the old one gave up).
    if (_playerConnected) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    _playerConnected = true;
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..bufferOutput = false
      ..headers.contentType = ContentType('video', 'mp2t');
    try {
      // The answer at once - the picture may take a moment (an encrypted
      // channel until the receiver descrambles it). dart:io sends the
      // headers only with data: an MPEG-TS null packet (PID 0x1FFF, padding
      // every demuxer drops) gets them out.
      response.add(_nullPacket);
      await response.flush();
      await response.addStream(_data.stream);
      await response.close();
    } catch (_) {
      // The player went away (channel change).
    }
  }

  Future<void> _run() async {
    var failures = 0;
    while (!_closed) {
      _reopen = false;
      final client = _client = http.Client();
      var gotData = false;
      try {
        final request = http.Request('GET', _upstream)..headers.addAll(_headers);
        final response = await client.send(request).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
        final probe = TsScramblingProbe();
        // The receiver sometimes takes a stream on and sends nothing (or
        // stops) - then a new connection, rather than waiting for ever.
        await for (final chunk in response.stream.timeout(const Duration(seconds: 5))) {
          if (_closed) break;
          if (_tap.hasListener) _tap.add(chunk);
          if (_clear.isCompleted) {
            gotData = true;
            _data.add(chunk);
            continue;
          }
          final result = probe.add(chunk);
          // Only a real stream counts - without a free tuner the receiver
          // answers "200 OK" with an error text ("HTTP/1.0 400 Bad Request").
          if (probe.packets > 0) gotData = true;
          if (result == StreamScrambling.clear) {
            if (!_verdict.isCompleted) _verdict.complete(StreamScrambling.clear);
            _clear.complete();
            // From here on everything goes to the player - starting at a
            // packet: a chunk can begin in the middle of one, and ExoPlayer
            // recognises MPEG-TS only by sync bytes every 188 bytes from the
            // start ("None of the available extractors could read the
            // stream").
            _data.add(alignToTsPacket(chunk));
          } else if (result == StreamScrambling.scrambled && !_verdict.isCompleted) {
            _verdict.complete(StreamScrambling.scrambled);
          }
        }
      } catch (e) {
        if (!_closed && !_reopen) debugPrint('TV stream: $e');
      } finally {
        client.close();
      }
      if (_closed) break;
      if (_reopen) continue;
      // The receiver ended the stream, sent nothing or turned the request
      // down - again, a few times in a row; a stream that was flowing just
      // goes on on the new connection (the player bridges the gap).
      failures = gotData ? 0 : failures + 1;
      if (!gotData && !_refused.isCompleted) _refused.complete();
      if (failures >= 8) {
        if (!_verdict.isCompleted) _verdict.complete(StreamScrambling.unknown);
        if (!_clear.isCompleted) _clear.completeError(const SocketException('Der Receiver liefert keinen Stream'));
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client?.close();
    if (!_verdict.isCompleted) _verdict.complete(StreamScrambling.unknown);
    if (!_clear.isCompleted) {
      _clear.future.ignore();
      _clear.completeError(StateError('closed'));
    }
    // Not awaited: with the player gone, nobody takes the end of the data.
    unawaited(_data.close());
    unawaited(_tap.close());
    await _server.close(force: true);
  }
}
