import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/l10n.dart';
import '../models/music_track.dart';
import '../repositories/nas_settings_repository.dart';
import 'music_cover.dart';
import 'music_index.dart';
import 'music_library.dart';
import 'music_stream_server.dart';
import 'music_tag_reader.dart';
import 'nas_service.dart';
import 'radio_audio_handler.dart';

/// What the Musik player is doing - one snapshot per change (not per
/// position tick: see [MusicPlayer.position]).
@immutable
class MusicState {
  const MusicState({
    this.queue = const [],
    this.index = -1,
    this.playing = false,
    this.buffering = false,
    this.shuffle = false,
    this.repeat = MusicRepeat.off,
    this.tags,
    this.duration,
    this.collecting = false,
    this.label,
    this.error,
    this.version = 0,
  });

  /// In play order (a view - don't keep it, [version] tells changes).
  final List<MusicTrack> queue;
  final int index;
  final bool playing;
  final bool buffering;
  final bool shuffle;
  final MusicRepeat repeat;

  /// The current track's tags once read (null while reading).
  final MusicTags? tags;
  final Duration? duration;

  /// The folders are still being walked - more tracks are coming.
  final bool collecting;

  /// What is playing: a folder's name, "Alles zufällig", a search.
  final String? label;
  final String? error;

  /// Counts every change (the queue list is the same object).
  final int version;

  MusicTrack? get current => index >= 0 && index < queue.length ? queue[index] : null;

  /// Something is loaded (playing or paused).
  bool get active => current != null;

  MusicState copyWith({
    List<MusicTrack>? queue,
    int? index,
    bool? playing,
    bool? buffering,
    bool? shuffle,
    MusicRepeat? repeat,
    MusicTags? Function()? tags,
    Duration? Function()? duration,
    bool? collecting,
    String? Function()? label,
    String? Function()? error,
  }) =>
      MusicState(
        queue: queue ?? this.queue,
        index: index ?? this.index,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        shuffle: shuffle ?? this.shuffle,
        repeat: repeat ?? this.repeat,
        tags: tags != null ? tags() : this.tags,
        duration: duration != null ? duration() : this.duration,
        collecting: collecting ?? this.collecting,
        label: label != null ? label() : this.label,
        error: error != null ? error() : this.error,
        version: version + 1,
      );
}

/// Where the player gets the NAS and the music folder from.
typedef MusicNasSettings = Future<NasSettings> Function();

/// The Musik part's player - app-wide, keeps playing when its screens are
/// left. Plays NAS files through [MusicStreamServer]; the queue is ours
/// ([MusicQueue], up to the whole collection), the platform player only
/// ever holds the current track and the next one (loaded ahead, so the
/// change is gapless as far as the formats allow) - 50,000 items in
/// ExoPlayer's playlist would cost memory and time on a weak box.
///
/// Shares the speakers and the media session with the radio: starting
/// music pauses the radio ([onTakeSpeakers], which sends the radio its
/// "pause for another app"), and the music takes the radio's media session
/// over as a guest ([RadioAudioHandler.attachGuest]) - the notification,
/// Home Assistant and the remote's media keys see and control the music.
/// When the radio starts again, the session goes back and the music
/// pauses ([radioStarted]).
class MusicPlayer implements MediaSessionGuest {
  MusicPlayer({
    required this._nasSettings,
    required this.indexStore,
    required this._onTakeSpeakers,
    required this._handler,
    this._onModesChanged,
    Random? random,
  })  : _random = random ?? Random(),
        _queue = MusicQueue(random: random);

  final MusicNasSettings _nasSettings;
  final MusicIndexStore indexStore;
  final void Function() _onTakeSpeakers;
  final Future<RadioAudioHandler?> Function() _handler;
  final void Function(bool shuffle, MusicRepeat repeat)? _onModesChanged;
  final Random _random;
  final MusicQueue _queue;

  final state = ValueNotifier(const MusicState());

  AudioPlayer? _player;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// The tracks in the platform player: [current, next?].
  List<MusicTrack> _window = const [];
  int _loadGeneration = 0;
  Future<void> _ops = Future.value();

  // One client per job - FTP and SMB clients do one call at a time: the
  // streams (and tag reads), the folder walks, the folder covers.
  String? _identity;
  MusicStreamServer? _server;
  NasClient? _walkClient;
  NasClient? _metaClient;

  MusicWalkToken? _walk;
  int _errorsInRow = 0;

  /// The load whose error was handled (one failure can come both as an
  /// exception and on the event stream).
  int _errorHandledFor = -1;
  bool _sessionHeld = false;
  bool _sessionConfigured = false;
  MusicRepeat _repeat = MusicRepeat.off;

  final _tagCache = <String, MusicTags>{};
  final _coverCache = <String, Uint8List?>{};
  final _tagLoads = <String, Future<MusicTags>>{};

  /// The position in the current track.
  Duration get position => _player?.position ?? Duration.zero;

  /// The position, a few times a second while playing.
  Stream<Duration> get positionStream => _player?.positionStream ?? const Stream.empty();

  /// Android: the player's audio session (for the visualisation's
  /// spectrum), null elsewhere / before the first track.
  int? get androidAudioSessionId => _player?.androidAudioSessionId;
  final _sessionIds = StreamController<int?>.broadcast();
  Stream<int?> get androidAudioSessionIdStream => _sessionIds.stream;

  /// Initial modes from the settings (before the first track).
  void applyModes({required bool shuffle, required MusicRepeat repeat}) {
    _repeat = repeat;
    if (!state.value.active) {
      _queue.setShuffle(shuffle);
      _publish(shuffle: shuffle, repeat: repeat);
    }
  }

  // --- Clients ---

  Future<({NasConfig config, String root})?> _setup() async {
    final settings = await _nasSettings();
    final root = settings.folder(NasFolder.music);
    if (root == null) return null;
    final config = settings.config;
    // The password counts too (identity leaves it out).
    final identity = '${config.identity}|${config.password.hashCode}';
    if (identity != _identity || _server == null) {
      _identity = identity;
      unawaited(_server?.close());
      // On an isolate of its own - the music's bytes don't cross the UI's.
      _server = MusicStreamServer.isolated(config);
      _walkClient?.close();
      _walkClient = config.createClient();
      _metaClient?.close();
      _metaClient = config.createClient();
      _tagCache.clear();
      _coverCache.clear();
    }
    return (config: config, root: root);
  }

  // --- Starting ---

  /// Plays [tracks] (e.g. a folder's), from [start] - with [shuffle] in
  /// random order with [start] first (no [start]: a random one).
  Future<void> playTracks(List<MusicTrack> tracks, {int? start, bool? shuffle, String? label}) async {
    if (tracks.isEmpty) return;
    if (await _setup() == null) return _fail(l10n.musicErrorNoFolder);
    _cancelWalk();
    final shuffled = shuffle ?? _queue.shuffle;
    _queue.replace(tracks, start: start ?? 0, shuffle: shuffled, startRandom: shuffled && start == null);
    _errorsInRow = 0;
    _publish(label: () => label, error: () => null, collecting: false, shuffle: shuffled);
    await _serial(() => _loadCurrent(play: true));
  }

  /// Plays everything in [folder] and its subfolders - starts with the
  /// first tracks found while the walk goes on.
  Future<void> playFolder(String folder, {required bool shuffle, String? label, bool subfolders = true}) async {
    final setup = await _setup();
    if (setup == null) return _fail(l10n.musicErrorNoFolder);
    _cancelWalk();
    final token = _walk = MusicWalkToken();
    _queue.replace(const [], shuffle: shuffle);
    _errorsInRow = 0;
    _publish(label: () => label, error: () => null, collecting: true, shuffle: shuffle);
    final identity = setup.config.identity;
    final first = <MusicTrack>[];
    var started = false;
    final deadline = DateTime.now().add(const Duration(milliseconds: 1500));
    var published = DateTime.now();

    Future<void> start() async {
      started = true;
      _queue.replace(first, shuffle: shuffle, startRandom: shuffle);
      _publish();
      await _serial(() => _loadCurrent(play: true));
    }

    try {
      await for (final batch in walkMusic(
        _walkClient!,
        folder,
        random: shuffle ? _random : null,
        subfolders: subfolders,
        token: token,
        onListed: (f, listing) => indexStore.noteListing(identity, setup.root, f, listing),
      )) {
        if (token.cancelled) return;
        if (started) {
          _queue.addDiscovered(batch);
          // A walk over thousands of folders: the screens hear about it
          // once a second, not per folder.
          final now = DateTime.now();
          if (now.difference(published) > const Duration(seconds: 1)) {
            published = now;
            _publish();
          }
          // Found tracks never land before the next one already loaded -
          // only a player without a next one needs it.
          if (_window.length < 2) unawaited(_serial(_refreshNext));
          continue;
        }
        first.addAll(batch);
        // In order: at once. Shuffled: a few more first, for a real choice.
        if (!shuffle || first.length >= 40 || DateTime.now().isAfter(deadline)) await start();
      }
      if (token.cancelled) return;
      if (!started) {
        if (first.isEmpty) {
          _publish(collecting: false);
          return _fail(l10n.musicErrorNoMusic);
        }
        await start();
      }
      _publish(collecting: false);
    } on NasException catch (e) {
      if (!token.cancelled) {
        _publish(collecting: false);
        _fail(e.message);
      }
    }
  }

  /// The whole collection shuffled: from the index if there is one (all at
  /// once), else by walking the music folder in random order.
  Future<void> playAllShuffled() async {
    final setup = await _setup();
    if (setup == null) return _fail(l10n.musicErrorNoFolder);
    final index = await indexStore.indexFor(setup.config.identity, setup.root);
    if (index != null && index.trackCount > 0) {
      final tracks = await Future(() => index.tracks);
      return playTracks(tracks, shuffle: true, label: l10n.musicAllShuffled);
    }
    return playFolder(setup.root, shuffle: true, label: l10n.musicAllShuffled);
  }

  void _cancelWalk() {
    _walk?.cancel();
    _walk = null;
  }

  void _fail(String message) => _publish(error: () => message);

  // --- The platform player ---

  /// Platform player calls one after the other (playlist changes must not
  /// interleave).
  Future<void> _serial(Future<void> Function() op) {
    final result = _ops.then((_) => op());
    _ops = result.catchError((Object e) => debugPrint('music: $e'));
    return result.catchError((Object e) => debugPrint('music: $e'));
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer(
      // Enough to play on through a short hiccup of the NAS, without
      // holding minutes of a WAV in memory.
      audioLoadConfiguration: const AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: Duration(seconds: 20),
          maxBufferDuration: Duration(seconds: 40),
          bufferForPlaybackDuration: Duration(milliseconds: 1500),
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 3),
        ),
      ),
    );
    _player = player;
    _subscriptions
      ..add(player.currentIndexStream.listen((i) => _serial(() => _onPlayerIndex(i))))
      ..add(player.playerStateStream.listen(_onPlayerState))
      ..add(player.durationStream.listen((d) {
        if (d != state.value.duration) _publish(duration: () => d);
      }))
      ..add(player.androidAudioSessionIdStream.listen(_sessionIds.add))
      ..add(player.playbackEventStream.listen(
        (_) => _publishSession(),
        // After a pending track change - in order with the index events.
        onError: (Object e, StackTrace _) => _serial(() async => _onPlaybackError(e)),
      ));
    return player;
  }

  Future<void> _ensureAudioSession() async {
    if (_sessionConfigured) return;
    _sessionConfigured = true;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      // Another app took the speakers (see AudioPlayerService).
      session.interruptionEventStream.listen((event) {
        if (event.begin) _player?.pause();
      });
    } catch (e) {
      debugPrint('music session: $e');
    }
  }

  Future<AudioSource> _sourceFor(MusicTrack track) async =>
      AudioSource.uri(await _server!.uriFor(track), tag: track.path);

  Future<void> _loadCurrent({required bool play, Duration? position}) async {
    final generation = ++_loadGeneration;
    final current = _queue.current;
    if (current == null || _server == null) return;
    if (play) await _takeSpeakers();
    final player = _ensurePlayer();
    final next = _queue.peekNext(repeat: _repeat);
    final sources = [await _sourceFor(current), if (next != null) await _sourceFor(next)];
    _window = [current, ?next];
    _publish(index: _queue.index, tags: () => _tagCache[current.path], duration: () => null, buffering: true);
    unawaited(_loadTags(current));
    try {
      await player.setLoopMode(_repeat == MusicRepeat.one ? LoopMode.one : LoopMode.off);
      await player.setAudioSources(sources, initialIndex: 0, initialPosition: position);
    } on PlayerInterruptedException {
      return;
    } catch (e) {
      if (generation == _loadGeneration) _onPlaybackError(e);
      return;
    }
    if (generation != _loadGeneration) return;
    if (play) unawaited(player.play().catchError((Object e) => _onPlaybackError(e)));
    if (next != null) unawaited(_loadTags(next));
  }

  /// The platform player moved on to the next track by itself (the end of
  /// the current one): the queue follows, the track before leaves the
  /// player and the one after the new current comes in.
  Future<void> _onPlayerIndex(int? i) async {
    final player = _player;
    if (player == null || i == null || i == 0 || _window.length < 2) return;
    final playing = _window[1];
    // A new track in the player - its errors count on their own.
    _loadGeneration++;
    _queue.next(repeat: _repeat);
    if (_queue.current != playing) {
      final at = _queue.items.indexOf(playing);
      if (at >= 0) _queue.jumpTo(at);
    }
    _errorsInRow = 0;
    _window = [playing];
    _publish(index: _queue.index, tags: () => _tagCache[playing.path], duration: () => player.duration);
    unawaited(_loadTags(playing));
    await player.removeAudioSourceAt(0);
    await _refreshNext();
  }

  /// Makes the player's next track the queue's next (after shuffle, repeat
  /// or the walk adding tracks).
  Future<void> _refreshNext() async {
    final player = _player;
    if (player == null || _window.isEmpty || _queue.current != _window.first) return;
    final want = _queue.peekNext(repeat: _repeat);
    if (_window.length > 1 && _window[1] == want) return;
    if (player.audioSources.length > 1) await player.removeAudioSourceRange(1, player.audioSources.length);
    _window = [_window.first];
    if (want == null) return;
    await player.addAudioSource(await _sourceFor(want));
    _window = [_window.first, want];
    unawaited(_loadTags(want));
    // It had ended waiting for more (a walk still running).
    if (player.processingState == ProcessingState.completed) {
      await player.seek(Duration.zero, index: 1);
      unawaited(player.play());
    }
  }

  void _onPlayerState(PlayerState s) {
    final buffering = s.processingState == ProcessingState.loading || s.processingState == ProcessingState.buffering;
    if (s.processingState == ProcessingState.completed && s.playing && !state.value.collecting) {
      // The end of the queue: back to the start, paused.
      _player?.pause();
      if (_queue.length > 0) {
        _queue.jumpTo(0);
        unawaited(_serial(() => _loadCurrent(play: false)));
      }
      _publish(playing: false, buffering: false);
      return;
    }
    if (s.playing != state.value.playing || buffering != state.value.buffering) {
      _publish(playing: s.playing, buffering: buffering);
    }
    if (s.processingState == ProcessingState.ready && s.playing) _errorsInRow = 0;
  }

  void _onPlaybackError(Object e) {
    if (_errorHandledFor == _loadGeneration) return;
    _errorHandledFor = _loadGeneration;
    final track = _queue.current;
    debugPrint('music: ${track?.name}: $e');
    _errorsInRow++;
    if (_errorsInRow >= 5 || _queue.length <= 1) {
      _publish(playing: false, buffering: false, error: () => l10n.musicErrorUnplayable(track?.name ?? ''));
      return;
    }
    _publish(error: () => l10n.musicErrorUnplayable(track?.name ?? ''));
    // On to the next one.
    if (_queue.next(repeat: _repeat == MusicRepeat.one ? MusicRepeat.all : _repeat)) {
      unawaited(_serial(() => _loadCurrent(play: true)));
    }
  }

  // --- Controls ---

  @override
  Future<void> play() async {
    final player = _player;
    if (!state.value.active) return;
    if (player == null || player.processingState == ProcessingState.idle) {
      return _serial(() => _loadCurrent(play: true, position: player?.position));
    }
    await _takeSpeakers();
    _publish(error: () => null);
    unawaited(player.play());
  }

  @override
  Future<void> pause() async => _player?.pause();

  Future<void> togglePlayPause() => state.value.playing ? pause() : play();

  /// Another app or TV takes the screen and speakers: pause (stays loaded).
  Future<void> pauseForApp() async => pause();

  /// Stops and forgets the queue; the media session goes back to the radio
  /// and the platform player is released (memory on weak boxes).
  @override
  Future<void> stop() async {
    _cancelWalk();
    _loadGeneration++;
    final player = _player;
    _player = null;
    _window = const [];
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    await player?.dispose();
    _queue.clear();
    _publish(playing: false, buffering: false, index: -1, tags: () => null, duration: () => null, label: () => null);
    await _releaseSession();
  }

  @override
  Future<void> skipToNext() => next();

  @override
  Future<void> skipToPrevious() => previous();

  Future<void> next() async {
    if (!_queue.next(repeat: _repeat == MusicRepeat.one ? MusicRepeat.all : _repeat)) return;
    _errorsInRow = 0;
    await _serial(() => _loadCurrent(play: true));
  }

  /// Back to the start of the track - or, at its first seconds, the one
  /// before.
  Future<void> previous() async {
    if (position > const Duration(seconds: 4)) return seek(Duration.zero);
    if (!_queue.previous(repeat: _repeat == MusicRepeat.one ? MusicRepeat.all : _repeat)) {
      return seek(Duration.zero);
    }
    await _serial(() => _loadCurrent(play: true));
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue.jumpTo(index);
    await _serial(() => _loadCurrent(play: true));
  }

  @override
  Future<void> seek(Duration position) async {
    final player = _player;
    if (player == null) return;
    final duration = player.duration;
    var target = position < Duration.zero ? Duration.zero : position;
    if (duration != null && target > duration - const Duration(seconds: 1)) {
      target = duration - const Duration(seconds: 1);
      if (target < Duration.zero) target = Duration.zero;
    }
    await player.seek(target);
  }

  Future<void> seekBy(Duration delta) => seek(position + delta);

  Future<void> setShuffle(bool on) async {
    _queue.setShuffle(on);
    _publish(shuffle: on, index: _queue.index);
    _onModesChanged?.call(on, _repeat);
    await _serial(_refreshNext);
  }

  Future<void> setRepeat(MusicRepeat repeat) async {
    _repeat = repeat;
    _publish(repeat: repeat);
    _onModesChanged?.call(_queue.shuffle, repeat);
    await _player?.setLoopMode(repeat == MusicRepeat.one ? LoopMode.one : LoopMode.off);
    await _serial(_refreshNext);
  }

  Future<void> cycleRepeat() => setRepeat(MusicRepeat.values[(_repeat.index + 1) % MusicRepeat.values.length]);

  /// The remote's media keys while music is loaded (true = taken). For
  /// Home and other screens: they ask this first, before the radio.
  bool handleMediaKey(LogicalKeyboardKey key) {
    if (!state.value.active) return false;
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      togglePlayPause();
    } else if (key == LogicalKeyboardKey.mediaPlay) {
      play();
    } else if (key == LogicalKeyboardKey.mediaPause || key == LogicalKeyboardKey.mediaStop) {
      pause();
    } else if (key == LogicalKeyboardKey.mediaTrackNext || key == LogicalKeyboardKey.mediaFastForward) {
      next();
    } else if (key == LogicalKeyboardKey.mediaTrackPrevious || key == LogicalKeyboardKey.mediaRewind) {
      previous();
    } else {
      return false;
    }
    return true;
  }

  // --- Sharing with the radio ---

  Future<void> _takeSpeakers() async {
    await _ensureAudioSession();
    if (_sessionHeld) return;
    _sessionHeld = true;
    _onTakeSpeakers();
    try {
      (await _handler())?.attachGuest(this);
    } catch (_) {}
    // The session shows the radio until told otherwise: everything anew.
    _sentItem = null;
    _sentKey = null;
    unawaited(_publishSession());
  }

  Future<void> _releaseSession() async {
    if (!_sessionHeld) return;
    _sessionHeld = false;
    try {
      (await _handler())?.detachGuest(this);
    } catch (_) {}
  }

  /// The radio started: pause - the queue stays for later.
  @override
  void radioStarted() {
    _sessionHeld = false;
    _player?.pause();
  }

  String? _artPath;
  Object? _artKey;
  Future<Uri?>? _art;

  /// The cover as a file for the notification (audio_service wants an
  /// address) - written once per track and cover, not per update.
  Future<Uri?> _artUri(MusicTrack track, Uint8List? cover) {
    if (cover == null || kIsWeb || !Platform.isAndroid) return Future.value(null);
    final key = (track.path, identityHashCode(cover));
    if (_artKey == key && _art != null) return _art!;
    _artKey = key;
    return _art = () async {
      try {
        final dir = Directory('${(await getTemporaryDirectory()).path}/music_art');
        await dir.create(recursive: true);
        // A new name per track - the notification caches by address.
        final file = File('${dir.path}/${track.path.hashCode.toUnsigned(32)}.img');
        await file.writeAsBytes(cover, flush: true);
        final old = _artPath;
        if (old != null && old != file.path) unawaited(File(old).delete().then((_) {}, onError: (_) {}));
        _artPath = file.path;
        return Uri.file(file.path);
      } catch (_) {
        return null;
      }
    }();
  }

  // What the media session got last - only changes go out. Each item makes
  // Android load the artwork again, each state rebuilds the notification
  // (with the artwork): sent on every player event (buffering reports come
  // several times a second while a track loads) that cost a weak box
  // seconds right at every track change.
  MediaItem? _sentItem;
  Object? _sentKey;
  Duration _sentPosition = Duration.zero;
  DateTime _sentAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _sendingSession = false;
  bool _sessionDirty = false;

  /// Brings the media session up to date - one update at a time, changes
  /// meanwhile go out together afterwards.
  Future<void> _publishSession() async {
    if (!_sessionHeld) return;
    if (_sendingSession) {
      _sessionDirty = true;
      return;
    }
    _sendingSession = true;
    try {
      do {
        _sessionDirty = false;
        await _sendSession();
      } while (_sessionDirty && _sessionHeld);
    } catch (e) {
      debugPrint('music session: $e');
    } finally {
      _sendingSession = false;
    }
  }

  static bool _sameItem(MediaItem? a, MediaItem? b) =>
      a == null || b == null
          ? a == b
          : a.id == b.id &&
              a.title == b.title &&
              a.artist == b.artist &&
              a.album == b.album &&
              a.duration == b.duration &&
              a.artUri == b.artUri;

  Future<void> _sendSession() async {
    final handler = await _handler().catchError((Object _) => null);
    if (handler == null || !_sessionHeld) return;
    final s = state.value;
    final track = s.current;
    final player = _player;
    MediaItem? item;
    if (track != null) {
      final display = MusicDisplay.of(track, s.tags);
      item = MediaItem(
        id: track.path,
        title: display.title,
        artist: display.artist,
        album: display.album,
        duration: s.duration,
        artUri: await _artUri(track, s.tags?.cover),
      );
    }
    if (!_sameItem(item, _sentItem)) {
      _sentItem = item;
      handler.publishGuestItem(this, item);
    }
    final playing = player?.playing ?? false;
    final processing = switch (player?.processingState) {
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
      _ => AudioProcessingState.idle,
    };
    final key = (playing, processing, s.index, s.shuffle, s.repeat);
    final position = player?.position ?? Duration.zero;
    final now = DateTime.now();
    // Android moves the position on by itself while playing - only a jump
    // (seek, new track) needs telling.
    final expected = _sentPosition + (playing ? now.difference(_sentAt) : Duration.zero);
    final jumped = (position - expected).abs() > const Duration(milliseconds: 1500);
    if (key == _sentKey && !jumped) return;
    _sentKey = key;
    _sentPosition = position;
    _sentAt = now;
    handler.publishGuestState(
      this,
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.stop,
          MediaAction.seek,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        androidCompactActionIndices: const [0, 1, 2],
        playing: playing,
        processingState: processing,
        updatePosition: position,
        bufferedPosition: player?.bufferedPosition ?? Duration.zero,
        queueIndex: s.index < 0 ? null : s.index,
        shuffleMode: s.shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
        repeatMode: switch (s.repeat) {
          MusicRepeat.off => AudioServiceRepeatMode.none,
          MusicRepeat.all => AudioServiceRepeatMode.all,
          MusicRepeat.one => AudioServiceRepeatMode.one,
        },
      ),
    );
  }

  // --- Tags and covers ---

  /// The tags of [track] (cached; the folder's cover when the file has
  /// none). Never throws.
  Future<MusicTags> tagsFor(MusicTrack track) => _loadTags(track);

  Future<MusicTags> _loadTags(MusicTrack track) {
    final cached = _tagCache[track.path];
    if (cached != null) {
      _applyTags(track, cached);
      return Future.value(cached);
    }
    return _tagLoads[track.path] ??= () async {
      var tags = MusicTags.empty;
      try {
        final client = _metaClient;
        if (client != null) {
          var size = track.size;
          try {
            size ??= await client.size(track.path);
          } catch (_) {}
          tags = await readMusicTags(
            (offset, length) => readNasRange(client, track.path, offset, length),
            fileSize: size,
          ).timeout(const Duration(seconds: 20), onTimeout: () => MusicTags.empty);
        }
        if (tags.cover == null) {
          final cover = await _folderCover(track.folder);
          if (cover != null) tags = tags.withCover(cover);
        } else {
          // Embedded covers are often 3000 px and several MB: shown, cached
          // and in the notification only ever small (see shrinkMusicCover).
          tags = tags.withCover(await shrinkMusicCover(tags.cover!));
        }
      } catch (e) {
        debugPrint('music tags ${track.name}: $e');
      }
      _tagCache[track.path] = tags;
      while (_tagCache.length > 16) {
        _tagCache.remove(_tagCache.keys.first);
      }
      _tagLoads.remove(track.path);
      _applyTags(track, tags);
      return tags;
    }();
  }

  void _applyTags(MusicTrack track, MusicTags tags) {
    if (state.value.current == track && !identical(state.value.tags, tags)) {
      _publish(tags: () => tags);
    }
  }

  Future<Uint8List?> _folderCover(String folder) async {
    if (_coverCache.containsKey(folder)) return _coverCache[folder];
    Uint8List? cover;
    final client = _metaClient;
    if (client != null) {
      try {
        final entries = await client.list(folder);
        final name = pickFolderCover([for (final e in entries) if (!e.isDirectory) e.name]);
        if (name != null) {
          final bytes = await client.read(joinNasPath(folder, name), maxBytes: 6 * 1024 * 1024);
          cover = await shrinkMusicCover(bytes);
        }
      } catch (_) {}
    }
    _coverCache[folder] = cover;
    while (_coverCache.length > 8) {
      _coverCache.remove(_coverCache.keys.first);
    }
    return cover;
  }

  // --- State ---

  void _publish({
    int? index,
    bool? playing,
    bool? buffering,
    bool? shuffle,
    MusicRepeat? repeat,
    MusicTags? Function()? tags,
    Duration? Function()? duration,
    bool? collecting,
    String? Function()? label,
    String? Function()? error,
  }) {
    state.value = state.value.copyWith(
      queue: _queue.items,
      index: index ?? _queue.index,
      playing: playing,
      buffering: buffering,
      shuffle: shuffle ?? _queue.shuffle,
      repeat: repeat ?? _repeat,
      tags: tags,
      duration: duration,
      collecting: collecting,
      label: label,
      error: error,
    );
    unawaited(_publishSession());
  }

  Future<void> dispose() async {
    await stop();
    await _server?.close();
    _walkClient?.close();
    _metaClient?.close();
    await _sessionIds.close();
  }
}
