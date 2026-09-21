import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Thin wrapper around [AudioPlayer] for internet-radio stream playback.
/// DAB+ audio is not routed through here (Phase 4) - the USB adapter's chip
/// decodes and outputs DAB+ audio on its own.
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();
  final _errorController = StreamController<String>.broadcast();
  bool _sessionConfigured = false;
  String? _currentUrl;

  String? get currentUrl => _currentUrl;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<String?> get icyTitleStream => _player.icyMetadataStream
      .map((meta) => meta?.info?.title)
      .distinct();

  /// Human-readable playback errors (e.g. stream unreachable), for the UI to
  /// surface instead of silently sitting on a misleading "paused" state.
  Stream<String> get errorStream => _errorController.stream;

  /// Without an explicitly configured audio session, activating audio focus
  /// on play() can silently fail on some Android (TV) devices, leaving the
  /// player stuck in a non-playing state right after starting playback.
  Future<void> _ensureSessionConfigured() async {
    if (_sessionConfigured) return;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    // just_audio requests audio focus on play() via this same configured
    // session, but doesn't react to *losing* it on its own - without this,
    // starting e.g. Spotify and pressing play there didn't stop our own
    // stream, so both played over each other. Nothing here re-requests
    // focus/resumes when the interruption ends, even a transient one (a
    // notification sound, briefly) - the user switched to something else on
    // purpose, and having the radio suddenly start talking over it again on
    // its own would be more surprising than helpful.
    session.interruptionEventStream.listen((event) {
      if (event.begin) _player.pause();
    });
    _sessionConfigured = true;
  }

  Future<void> playStream(String url) async {
    await _ensureSessionConfigured();
    _currentUrl = url;
    await _player.stop();
    try {
      await _player.setUrl(url);
    } catch (e) {
      _errorController.add('Sender nicht erreichbar: $e');
      return;
    }
    unawaited(
      _player.play().catchError((Object e) {
        _errorController.add('Wiedergabefehler: $e');
      }),
    );
  }

  Future<void> stop() async {
    _currentUrl = null;
    await _player.stop();
  }

  /// Pause/resume in place, unlike [stop] - keeps [_currentUrl] loaded so a
  /// remote's Play/Pause/Stop keys can resume the same station rather than
  /// needing a full re-tune (see HomeScreen's key handling).
  Future<void> pause() => _player.pause();

  Future<void> resume() => _player.play();

  Future<void> dispose() async {
    await _player.dispose();
    await _errorController.close();
  }
}
