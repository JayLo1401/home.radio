import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/services/movie_library.dart';
import '../../data/services/movie_source.dart';
import '../../data/services/movie_stream_isolate.dart';
import '../../data/services/nas_service.dart';
import '../movies/movie_player.dart';

/// A video in the slideshow: played whole with sound by the films' players
/// (ExoPlayer first on Android, libmpv when it can't), from the NAS through
/// the films' stream server. It never throws: a video that can't be opened
/// gives null from [open], one that breaks off while playing is [ended].
class SlideVideo extends ChangeNotifier {
  SlideVideo._(this.entry, this._client, this._prepared, this._server, this._player, this._language) {
    _player.state.addListener(_onState);
  }

  final NasEntry entry;
  final NasClient _client;
  final PreparedMovie _prepared;
  final MovieStream _server;
  final String _language;
  MoviePlayer _player;
  bool _ended = false;
  bool _switching = false;
  bool _disposed = false;

  /// The player showing it now (a new one after ExoPlayer gave up).
  MoviePlayer get player => _player;

  /// Played to its end - or broken off (no player could go on with it).
  bool get ended => _ended;

  /// Opens [entry] from the NAS [config] and starts playing - null if no
  /// player can show it (unknown format, damaged file, NAS error ...).
  static Future<SlideVideo?> open(NasConfig config, NasEntry entry, {required String language}) async {
    NasClient? client;
    MovieStream? server;
    MoviePlayer? player;
    try {
      client = config.createClient();
      final prepared = await prepareMovie(
        client,
        MovieItem(path: entry.path, title: entry.name, kind: MovieKind.file, size: entry.size),
      );
      var engine = firstMovieEngine(
        android: MoviePlayer.isAndroid,
        extension: fileExtension(entry.name),
        exoPlayableAudio: !prepared.isDvdStream ||
            prepared.dvdAudio.isEmpty ||
            prepared.playableAudio(exoPlayer: true).isNotEmpty,
      );
      final exo = engine == MovieEngine.exoPlayer;
      server = await MovieStream.start(
        prepared.specFor(audio: prepared.defaultAudio(exoPlayer: exo, language: language), exoPlayer: exo),
        config: config,
        client: client,
        name: prepared.name,
        mime: prepared.mime,
        locale: language,
      );
      player = MoviePlayer(server.uri, engine: engine);
      try {
        await player.open(timeout: exo ? const Duration(seconds: 30) : const Duration(seconds: 45));
      } catch (e) {
        if (!movieFallsBackToMpv(engine)) rethrow;
        debugPrint('slideshow video ${entry.path}: ExoPlayer failed ($e) - libmpv');
        final failed = player;
        player = null;
        await failed.dispose();
        engine = MovieEngine.mpv;
        await server.replace(
          prepared.specFor(audio: prepared.defaultAudio(exoPlayer: false, language: language), exoPlayer: false),
        );
        player = MoviePlayer(server.uri, engine: engine);
        await player.open();
      }
      return SlideVideo._(entry, client, prepared, server, player, language);
    } catch (e) {
      debugPrint('slideshow video ${entry.path}: not playable ($e)');
      await _quietly(() => player?.dispose());
      await _quietly(() => server?.close());
      client?.close();
      return null;
    }
  }

  static Future<void> _quietly(Future<void>? Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('slideshow video: $e');
    }
  }

  /// Whether it has sound (then the music pauses meanwhile). When the
  /// player can't say: yes.
  Future<bool> hasSound() async {
    try {
      if (_prepared.isDvdStream) return true;
      return (await _player.audioTracks()).isNotEmpty;
    } catch (_) {
      return true;
    }
  }

  void _onState() {
    if (_disposed || _switching) return;
    final s = _player.state.value;
    if (s.error != null) {
      if (movieFallsBackToMpv(_player.engine)) {
        unawaited(_fallBackToMpv(s.position));
      } else {
        debugPrint('slideshow video ${entry.path}: ${s.error}');
        _end();
      }
      return;
    }
    if (s.completed) _end();
  }

  void _end() {
    if (_ended || _disposed) return;
    _ended = true;
    notifyListeners();
  }

  /// ExoPlayer broke off while playing: libmpv goes on from [position].
  Future<void> _fallBackToMpv(Duration position) async {
    _switching = true;
    final old = _player;
    old.state.removeListener(_onState);
    try {
      await old.dispose();
      if (_disposed) return;
      await _server.replace(
        _prepared.specFor(audio: _prepared.defaultAudio(exoPlayer: false, language: _language), exoPlayer: false),
      );
      final next = MoviePlayer(_server.uri, engine: MovieEngine.mpv);
      _player = next;
      next.state.addListener(_onState);
      if (!_disposed) notifyListeners();
      await next.open(start: position);
    } catch (e) {
      debugPrint('slideshow video ${entry.path}: libmpv failed too ($e)');
      _switching = false;
      _end();
      return;
    }
    _switching = false;
  }

  Future<void> play() async {
    try {
      await _player.play();
    } catch (e) {
      debugPrint('slideshow video: $e');
    }
  }

  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('slideshow video: $e');
    }
  }

  /// The picture, filling the screen (black around it).
  Widget view() => ListenableBuilder(
        listenable: this,
        builder: (context, _) => ColoredBox(color: Colors.black, child: _player.view()),
      );

  /// Stops and frees everything (also the NAS connection).
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _player.state.removeListener(_onState);
    super.dispose();
    await _quietly(() => _player.dispose());
    await _quietly(() => _server.close());
    _client.close();
  }
}
