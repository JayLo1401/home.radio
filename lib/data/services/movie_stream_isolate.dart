import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;

import '../../l10n/l10n.dart';
import 'movie_source.dart';
import 'movie_stream_server.dart';
import 'nas_service.dart';

/// A film's stream for the player: the [MovieStreamServer] with its NAS
/// transfer and the rewriting of the bytes (DVD packs, M2TS).
///
/// It runs in an isolate of its own: reading the NAS (SMB with its
/// signing in Dart), filtering every DVD pack and serving HTTP is steady
/// work for a whole core while the player fills its buffer - on the UI
/// isolate that took turns with drawing, and on the boxes the picture
/// stuttered (DVDs above all). If the isolate can't start, it runs here
/// like before.
abstract class MovieStream {
  /// What the player opens - a new address after [replace].
  Uri get uri;

  /// Other bytes from now on (another sound track of a DVD, the bytes as
  /// they are for libmpv) - the player opens the new [uri].
  Future<void> replace(MovieSourceSpec spec);

  Future<void> close();

  /// Starts the stream of [spec] from the NAS [config] in its own isolate
  /// (its own NAS connection); if that fails, in this isolate through
  /// [client] (not closed here). [locale]: the language for error texts.
  static Future<MovieStream> start(
    MovieSourceSpec spec, {
    required NasConfig config,
    required NasClient client,
    required String name,
    required String mime,
    required String locale,
  }) async {
    try {
      return await _IsolateMovieStream.start(spec, config: config, name: name, mime: mime, locale: locale);
    } catch (e) {
      debugPrint('MovieStream: no isolate of its own ($e) - in the UI isolate');
      final server = await MovieStreamServer.start(spec.build(client), name: name, mime: mime);
      return _LocalMovieStream(server, client);
    }
  }
}

class _LocalMovieStream implements MovieStream {
  _LocalMovieStream(this._server, this._client);

  final MovieStreamServer _server;
  final NasClient _client;

  @override
  Uri get uri => _server.uri;

  @override
  Future<void> replace(MovieSourceSpec spec) async => _server.replaceSource(spec.build(_client));

  @override
  Future<void> close() => _server.close();
}

/// What the isolate gets to start with.
typedef _StartMessage = ({
  SendPort reply,
  NasConfig config,
  MovieSourceSpec spec,
  String name,
  String mime,
  String locale,
});

class _IsolateMovieStream implements MovieStream {
  _IsolateMovieStream._(this._isolate, this._commands, this._uri);

  final Isolate _isolate;
  final SendPort _commands;
  Uri _uri;
  bool _closed = false;

  static const _startTimeout = Duration(seconds: 15);
  static const _answerTimeout = Duration(seconds: 10);

  static Future<_IsolateMovieStream> start(
    MovieSourceSpec spec, {
    required NasConfig config,
    required String name,
    required String mime,
    required String locale,
  }) async {
    final replies = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_StartMessage>(
        _isolateMain,
        (reply: replies.sendPort, config: config, spec: spec, name: name, mime: mime, locale: locale),
        debugName: 'movie stream',
        onExit: replies.sendPort,
      );
      final first = await replies.first.timeout(_startTimeout);
      if (first case (final SendPort commands, final String uri)) {
        return _IsolateMovieStream._(isolate, commands, Uri.parse(uri));
      }
      throw StateError(first is String ? first : 'movie stream isolate ended');
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      replies.close();
    }
  }

  @override
  Uri get uri => _uri;

  @override
  Future<void> replace(MovieSourceSpec spec) async {
    if (_closed) throw StateError('movie stream closed');
    final answer = ReceivePort();
    try {
      _commands.send(('replace', spec, answer.sendPort));
      final uri = await answer.first.timeout(_answerTimeout);
      if (uri is! String) throw StateError('movie stream: $uri');
      _uri = Uri.parse(uri);
    } finally {
      answer.close();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _commands.send('close');
    } catch (_) {}
    // It ends itself after closing the server; this is for one that hangs.
    Timer(const Duration(seconds: 5), () => _isolate.kill(priority: Isolate.immediate));
  }
}

/// The isolate: its own NAS connection and stream server; answers
/// "replace" and ends on "close".
Future<void> _isolateMain(_StartMessage start) async {
  NasClient? client;
  MovieStreamServer? server;
  final commands = ReceivePort();
  try {
    try {
      applyAppLocale(Locale(start.locale));
    } catch (_) {}
    final nas = start.config.createClient();
    client = nas;
    final running = await MovieStreamServer.start(start.spec.build(nas), name: start.name, mime: start.mime);
    server = running;
    start.reply.send((commands.sendPort, running.uri.toString()));
    await for (final message in commands) {
      if (message case ('replace', final MovieSourceSpec spec, final SendPort answer)) {
        try {
          running.replaceSource(spec.build(nas));
          answer.send(running.uri.toString());
        } catch (e) {
          answer.send(('error', '$e'));
        }
      } else if (message == 'close') {
        break;
      }
    }
  } catch (e) {
    debugPrint('MovieStream isolate: $e');
    start.reply.send('$e');
  } finally {
    commands.close();
    try {
      await server?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      client?.close();
    } catch (_) {}
  }
  Isolate.exit();
}
