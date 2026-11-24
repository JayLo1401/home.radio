import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart';

import '../tv/tv_player.dart' show TvAudioTrack, TvPlayer, audioDetails, audioTrackName;

/// Where the film is and what it does.
@immutable
class MoviePlaybackState {
  const MoviePlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.error,
  });

  final Duration position;

  /// Zero while unknown.
  final Duration duration;
  final bool playing;
  final bool buffering;
  final bool completed;
  final String? error;

  MoviePlaybackState copyWith({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    bool? completed,
    String? error,
  }) =>
      MoviePlaybackState(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        completed: completed ?? this.completed,
        error: error ?? this.error,
      );
}

/// Which player plays a film.
enum MovieEngine {
  /// Android's ExoPlayer (video_player, the copy with the MP2 decoder - same
  /// picture output as TV): the smoothest on weak boxes for MP4/MKV/TS with
  /// H.264/HEVC/MPEG-2.
  exoPlayer,

  /// libmpv (media_kit, FFmpeg inside): plays what ExoPlayer can't - WMV,
  /// FLV, DivX 3, Ogg/Theora, DVD sound in DTS/LPCM ... Always on the PC.
  mpv,
}

/// Film files ExoPlayer can't open (container) or whose usual video it has
/// no decoder for - they go to libmpv straight on Android, without a failed
/// first try: Windows Media (wmv, asf), Flash video (flv, f4v - Sorenson /
/// VP6 picture, F4V brand ExoPlayer doesn't sniff), DivX 3 (.divx), Ogg
/// video (Theora), raw MPEG-1/2 video.
const mpvFirstMovieExtensions = {'wmv', 'asf', 'flv', 'f4v', 'divx', 'ogm', 'ogv', 'm1v', 'm2v'};

/// The player a film starts with: on the PC always libmpv; on Android
/// ExoPlayer - unless the file's [extension] is one of
/// [mpvFirstMovieExtensions] or it's a DVD stream with no sound ExoPlayer
/// can play ([exoPlayableAudio] false: only DTS / LPCM tracks).
MovieEngine firstMovieEngine({required bool android, required String extension, bool exoPlayableAudio = true}) {
  if (!android) return MovieEngine.mpv;
  if (mpvFirstMovieExtensions.contains(extension.toLowerCase())) return MovieEngine.mpv;
  if (!exoPlayableAudio) return MovieEngine.mpv;
  return MovieEngine.exoPlayer;
}

/// Whether a film [engine] couldn't open or play goes on with libmpv: from
/// ExoPlayer always (unknown container, no decoder for the picture, no
/// picture at all, timeout, an error while playing) - libmpv (FFmpeg)
/// plays far more, like VLC. libmpv itself has nothing after it.
bool movieFallsBackToMpv(MovieEngine engine) => engine == MovieEngine.exoPlayer;

/// A player couldn't show the film (ExoPlayer: no picture; libmpv: an
/// error while opening).
class MovieEngineException implements Exception {
  const MovieEngineException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The films' player - TV's players ([TvPlayer]) with what a film needs on
/// top: pause, seeking, position. [MovieEngine] says which one runs; the
/// screen treats both alike.
abstract class MoviePlayer {
  factory MoviePlayer(Uri uri, {MovieEngine engine = MovieEngine.mpv}) {
    if (engine == MovieEngine.exoPlayer) return _ExoMoviePlayer(uri);
    // On the PC main() did it already; on Android the first film with
    // libmpv loads it.
    mk.MediaKit.ensureInitialized();
    return _MpvMoviePlayer(uri);
  }

  /// Android - ExoPlayer is there (see [firstMovieEngine]).
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  MovieEngine get engine;

  /// Opens the film at [start] and plays; throws if it doesn't open within
  /// [timeout] - or [MovieEngineException] if the player can't show it.
  Future<void> open({Duration start = Duration.zero, Duration timeout = const Duration(seconds: 45)});

  Widget view();

  ValueListenable<MoviePlaybackState> get state;

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(Duration position);

  /// The film's own sound tracks (not a DVD's - those come by the stream).
  Future<List<TvAudioTrack>> audioTracks();

  Future<void> selectAudio(String id);

  Future<void> dispose();
}

class _ExoMoviePlayer implements MoviePlayer {
  _ExoMoviePlayer(Uri uri)
      : _controller = VideoPlayerController.networkUrl(
          uri,
          // As TV (see _ExoTvPlayer): a SurfaceView from Android 10 on, the
          // texture on older ones (Fire TV Stick).
          viewType: TvPlayer.androidSdk >= 29 ? VideoViewType.platformView : VideoViewType.textureView,
        );

  final VideoPlayerController _controller;
  final _state = ValueNotifier(const MoviePlaybackState());
  bool _disposed = false;

  @override
  MovieEngine get engine => MovieEngine.exoPlayer;

  @override
  ValueListenable<MoviePlaybackState> get state => _state;

  @override
  Future<void> open({Duration start = Duration.zero, Duration timeout = const Duration(seconds: 45)}) async {
    // A video no decoder here takes comes as an error (see
    // packages/video_player_android/HOME_MEDIA.md) - initialize throws.
    await _controller.initialize().timeout(timeout);
    await _waitForPicture();
    if (start > Duration.zero) await _controller.seekTo(start);
    await _controller.play();
    _controller.addListener(_publish);
    _publish();
  }

  /// Size 0x0: no video format - the file has no picture ExoPlayer shows.
  /// (The texture output may report the size a moment later - a short
  /// wait first.)
  Future<void> _waitForPicture() async {
    if (!_controller.value.size.isEmpty) return;
    final sized = Completer<void>();
    void listener() {
      if (!_controller.value.size.isEmpty && !sized.isCompleted) sized.complete();
    }

    _controller.addListener(listener);
    try {
      await sized.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      throw const MovieEngineException('ExoPlayer: no picture');
    } finally {
      _controller.removeListener(listener);
    }
  }

  void _publish() {
    if (_disposed) return;
    final v = _controller.value;
    _state.value = MoviePlaybackState(
      position: v.position,
      duration: v.duration,
      playing: v.isPlaying,
      buffering: v.isBuffering,
      completed: v.isCompleted,
      error: v.hasError ? (v.errorDescription ?? 'error') : null,
    );
  }

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seekTo(Duration position) => _controller.seekTo(position);

  @override
  Future<List<TvAudioTrack>> audioTracks() async {
    if (_disposed || !_controller.isAudioTrackSupportAvailable()) return const [];
    try {
      final tracks = await _controller.getAudioTracks();
      return [
        for (final (i, t) in tracks.indexed)
          TvAudioTrack(
            id: t.id,
            label: audioTrackName(t.language, t.label, i),
            details: audioDetails(t.codec, t.channelCount),
            selected: t.isSelected,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> selectAudio(String id) => _controller.selectAudioTrack(id);

  @override
  Widget view() => Center(
        child: AspectRatio(aspectRatio: _controller.value.aspectRatio, child: VideoPlayer(_controller)),
      );

  @override
  Future<void> dispose() async {
    _disposed = true;
    _controller.removeListener(_publish);
    _state.dispose();
    await _controller.dispose();
  }
}

class _MpvMoviePlayer implements MoviePlayer {
  _MpvMoviePlayer(this._uri);

  final Uri _uri;
  final _player = mk.Player(
    configuration: mk.PlayerConfiguration(
      title: 'Film',
      // Android boxes have 1-2 GB: a smaller cache ahead (the film comes
      // from the NAS through this device's own server, quick to refill).
      bufferSize: MoviePlayer.isAndroid ? _androidCacheBytes : 32 << 20,
    ),
  );
  // Android: libmpv's defaults through media_kit_video - picture output
  // "gpu" (OpenGL ES), hardware decoding "auto-safe" (MediaCodec for H.264,
  // HEVC, MPEG-2/4, VP8/9, AV1); the old codecs (WMV, DivX 3, FLV ...) are
  // decoded by FFmpeg in software.
  late final _video = mkv.VideoController(_player);
  final _state = ValueNotifier(const MoviePlaybackState());
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _disposed = false;

  static const _androidCacheBytes = 24 << 20;

  mk.NativePlayer? get _native => _player.platform is mk.NativePlayer ? _player.platform as mk.NativePlayer : null;

  @override
  MovieEngine get engine => MovieEngine.mpv;

  @override
  ValueListenable<MoviePlaybackState> get state => _state;

  void _set(MoviePlaybackState Function(MoviePlaybackState s) change) {
    if (!_disposed) _state.value = change(_state.value);
  }

  @override
  Future<void> open({Duration start = Duration.zero, Duration timeout = const Duration(seconds: 45)}) async {
    final s = _player.stream;
    // Open: the first picture - or, for a file without picture, its sound.
    // An error before that (no format, no decoder) ends it after a moment
    // (libmpv reports some it gets over).
    final ready = Completer<void>();
    Timer? failing;
    void done([Object? error]) {
      failing?.cancel();
      if (ready.isCompleted) return;
      error == null ? ready.complete() : ready.completeError(error);
    }

    _subscriptions
      ..add(s.position.listen((v) => _set((x) => x.copyWith(position: v))))
      ..add(s.duration.listen((v) => _set((x) => x.copyWith(duration: v))))
      ..add(s.playing.listen((v) => _set((x) => x.copyWith(playing: v))))
      ..add(s.buffering.listen((v) => _set((x) => x.copyWith(buffering: v))))
      ..add(s.completed.listen((v) => _set((x) => x.copyWith(completed: v))))
      ..add(s.tracks.listen((t) {
        bool real(String id) => id != 'auto' && id != 'no';
        if (t.audio.any((a) => real(a.id)) && !t.video.any((v) => real(v.id))) done();
      }))
      ..add(s.error.listen((v) {
        debugPrint('MoviePlayer: $v');
        if (!ready.isCompleted) failing ??= Timer(const Duration(seconds: 4), () => done(MovieEngineException(v)));
      }));
    unawaited(_video.waitUntilFirstFrameRendered.then((_) => done(), onError: (Object _) {}));
    final native = _native;
    if (native != null) {
      try {
        // The film comes from this device's own server - in memory only.
        await native.setProperty('cache-on-disk', 'no');
        // A NAS may take a few seconds to start a transfer (seeking).
        await native.setProperty('network-timeout', '20');
        if (MoviePlayer.isAndroid) {
          // What was played stays in memory a little only.
          await native.setProperty('demuxer-max-back-bytes', '${8 << 20}');
          // Seeking lands on key frames - decoding up to the exact second
          // takes too long on the boxes with software-decoded old codecs.
          await native.setProperty('hr-seek', 'no');
        }
      } catch (e) {
        debugPrint('MoviePlayer: $e');
      }
    }
    await _player.open(mk.Media(_uri.toString(), start: start > Duration.zero ? start : null));
    try {
      await ready.future.timeout(timeout);
    } finally {
      failing?.cancel();
    }
    // DVDs are interlaced: the system's libmpv on Linux has deinterlacers
    // (Windows' and Android's have none - on Android MediaCodec usually
    // deinterlaces MPEG-2 itself).
    if (native != null && Platform.isLinux) {
      try {
        if (await native.getProperty('video-frame-info/interlaced') == 'yes') {
          await native.setProperty('deinterlace', 'yes');
        }
      } catch (_) {}
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seekTo(Duration position) => _player.seek(position);

  @override
  Future<List<TvAudioTrack>> audioTracks() async {
    final selected = _player.state.track.audio.id;
    final tracks = _player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    return [
      for (final (i, t) in tracks.indexed)
        TvAudioTrack(
          id: t.id,
          label: audioTrackName(t.language, t.title, i),
          details: audioDetails(t.codec, t.channelscount),
          selected: t.id == selected,
        ),
    ];
  }

  @override
  Future<void> selectAudio(String id) async {
    final track = _player.state.tracks.audio.where((t) => t.id == id).firstOrNull;
    if (track != null) await _player.setAudioTrack(track);
  }

  @override
  Widget view() => mkv.Video(
        controller: _video,
        controls: mkv.NoVideoControls,
        fill: Colors.black,
        filterQuality: FilterQuality.medium,
        pauseUponEnteringBackgroundMode: false,
      );

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _state.dispose();
    await _player.dispose();
  }
}
