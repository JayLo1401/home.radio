import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'icy_metadata_service.dart';

/// Thin wrapper around [AudioPlayer] for internet-radio stream playback.
/// DAB+ audio is not routed through here (Phase 4) - the USB adapter's chip
/// decodes and outputs DAB+ audio on its own.
class AudioPlayerService {
  AudioPlayerService() {
    _player.icyMetadataStream.listen((meta) {
      final title = IcyMetadataService.cleanTitle(meta?.info?.title);
      if (title == null) return;
      _playerProvidesIcy = true;
      _setTitle(title);
    });
    // A stream that drops mid-playback (network gone, server restart)
    // surfaces as an error event here, not as a playStream() failure - same
    // retry as a failed start, see [_scheduleRetry].
    _player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace _) {
      final url = _currentUrl;
      // While _start() is running, a failure is already handled by its own
      // setUrl() catch - don't schedule a second retry for the same error.
      if (url == null || _starting) return;
      _errorController.add('Verbindung zum Sender verloren - versuche erneut…');
      _scheduleRetry(url);
    });
  }

  final AudioPlayer _player = AudioPlayer();
  final _errorController = StreamController<String?>.broadcast();
  final _titleController = StreamController<String?>.broadcast();
  final _icyService = IcyMetadataService();
  bool _sessionConfigured = false;
  String? _currentUrl;

  String? get currentUrl => _currentUrl;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  /// The currently playing song/show ("now playing" - ICY StreamTitle),
  /// null while unknown. Comes from just_audio's own ICY metadata when the
  /// platform player delivers it, otherwise from polling the stream directly
  /// (see [IcyMetadataService]) - many stations' titles never showed up at
  /// all through just_audio alone.
  Stream<String?> get icyTitleStream => _titleController.stream;

  /// Human-readable playback errors (e.g. stream unreachable), for the UI to
  /// surface instead of silently sitting on a misleading "paused" state.
  /// Emits null once a previously reported error has resolved itself (a
  /// retry succeeded).
  Stream<String?> get errorStream => _errorController.stream;

  String? _title;
  bool _playerProvidesIcy = false;
  Timer? _titlePollTimer;

  void _setTitle(String? title) {
    if (title == _title) return;
    _title = title;
    _titleController.add(title);
  }

  static const _titlePollInterval = Duration(seconds: 20);

  /// Polls the stream's ICY title ourselves for as long as just_audio
  /// hasn't delivered one on its own (see [icyTitleStream]).
  void _startTitlePolling(String url) {
    _titlePollTimer?.cancel();
    Future<void> poll() async {
      if (_currentUrl != url || _playerProvidesIcy || !_player.playing) return;
      final title = await _icyService.fetchStreamTitle(url);
      if (_currentUrl != url || _playerProvidesIcy) return;
      if (title != null) _setTitle(title);
    }

    // First poll shortly after start, giving just_audio a chance to deliver
    // ICY metadata itself first.
    Timer(const Duration(seconds: 5), poll);
    _titlePollTimer = Timer.periodic(_titlePollInterval, (_) => poll());
  }

  // Automatic retry for a stream that can't be reached - most commonly on
  // an autostart right after boot, before the network is up, which used to
  // leave the station stuck on "Sender nicht erreichbar" until manually
  // re-selected. Backs off 3s, 6s, 12s, ... up to 30s, and keeps going for
  // as long as that station is still the selected one.
  Timer? _retryTimer;
  int _failedAttempts = 0;

  void _scheduleRetry(String url) {
    _retryTimer?.cancel();
    final delaySeconds = (3 * (1 << _failedAttempts)).clamp(3, 30);
    _failedAttempts = (_failedAttempts + 1).clamp(0, 4);
    _retryTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_currentUrl == url) _start(url);
    });
  }

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
    _retryTimer?.cancel();
    _failedAttempts = 0;
    _currentUrl = url;
    _playerProvidesIcy = false;
    _setTitle(null);
    _startTitlePolling(url);
    await _start(url);
  }

  bool _starting = false;

  Future<void> _start(String url) async {
    await _player.stop();
    if (_currentUrl != url) return;
    _starting = true;
    try {
      await _player.setUrl(url);
    } catch (e) {
      if (_currentUrl != url) return;
      _errorController.add('Sender nicht erreichbar - versuche erneut…');
      _scheduleRetry(url);
      return;
    } finally {
      _starting = false;
    }
    if (_currentUrl != url) return;
    _failedAttempts = 0;
    _errorController.add(null);
    unawaited(
      _player.play().catchError((Object e) {
        _errorController.add('Wiedergabefehler: $e');
      }),
    );
  }

  Future<void> stop() async {
    _currentUrl = null;
    _retryTimer?.cancel();
    _titlePollTimer?.cancel();
    _setTitle(null);
    await _player.stop();
  }

  /// Pause/resume in place, unlike [stop] - keeps [_currentUrl] loaded so a
  /// remote's Play/Pause/Stop keys can resume the same station rather than
  /// needing a full re-tune (see HomeScreen's key handling).
  Future<void> pause() {
    _retryTimer?.cancel();
    return _player.pause();
  }

  Future<void> resume() async {
    final url = _currentUrl;
    // Still in the "unreachable" retry loop (or it was paused while in it) -
    // nothing is loaded to resume, so start the stream again instead.
    if (url != null && _player.processingState == ProcessingState.idle) {
      _failedAttempts = 0;
      await _start(url);
      return;
    }
    await _player.play();
  }

  /// Smoothly changes the playback volume (1.0 = normal) - used to duck the
  /// radio under the "Bitte abholen" bell (see ChimeService).
  Future<void> rampVolume(double target, Duration duration) async {
    const steps = 10;
    final start = _player.volume;
    for (var i = 1; i <= steps; i++) {
      await _player.setVolume(start + (target - start) * i / steps);
      await Future<void>.delayed(duration ~/ steps);
    }
  }

  Future<void> dispose() async {
    _retryTimer?.cancel();
    _titlePollTimer?.cancel();
    await _player.dispose();
    await _errorController.close();
    await _titleController.close();
  }
}
