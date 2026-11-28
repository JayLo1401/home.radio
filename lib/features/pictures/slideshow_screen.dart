import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dashboard_providers.dart';
import '../../core/loading_wave.dart';
import '../../core/music_providers.dart';
import '../../core/nas_providers.dart';
import '../../core/pictures_providers.dart';
import '../../core/providers.dart';
import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/music_player.dart';
import '../../data/services/nas_service.dart';
import '../../data/services/picture_library.dart';
import '../../data/services/radio_audio_handler.dart';
import '../../l10n/l10n.dart';
import '../movies/movie_player_screen.dart' show formatMovieTime, movieSeekStep;
import '../music/music_now_playing_toast.dart';
import 'slide_loader.dart';
import 'slide_video.dart';
import 'slideshow_popup.dart';

/// A slideshow of [folder] and all its subfolders: starts with the first
/// pictures found while the rest is still being looked for, shows each
/// for the set time with a soft crossfade, and keeps the display on. Radio
/// and music are left alone - they simply play on, except while a video
/// with sound plays ([media] with videos): a video plays to its end, the
/// music pauses meanwhile and goes on afterwards.
///
/// Remote: ←/→ previous/next, OK or ↑/↓ the popup with what's playing,
/// its controls and the display time (SlideshowPopup), ⏯ pause/go on, Info
/// the picture's folder, name and number, the options key the slideshow's
/// settings, Back ends it (or closes the popup). Touch: tap left/right
/// third back/next, the middle the popup, swipe back/next.
///
/// [startAt]: begins with that picture ("ab hier", or resumed) and goes on
/// in the usual order from there. Where it is, is remembered per folder
/// (SlideshowResumeStore).
class SlideshowScreen extends ConsumerStatefulWidget {
  const SlideshowScreen({super.key, required this.folder, this.startAt, this.media = SlideshowMedia.pictures});

  /// Absolute NAS path.
  final String folder;

  /// Path of a picture (or video) in [folder] or below.
  final String? startAt;

  /// Pictures, videos or both.
  final SlideshowMedia media;

  @override
  ConsumerState<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends ConsumerState<SlideshowScreen> with SingleTickerProviderStateMixin {
  static const _fadeDuration = Duration(milliseconds: 900);

  final _focus = FocusNode(debugLabel: 'slideshow');
  late final _display = ref.read(displayServiceProvider);
  late final MusicPlayer _music = ref.read(musicPlayerProvider);
  late final AnimationController _fade = AnimationController(vsync: this, duration: _fadeDuration)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _dropPrevious();
    });

  NasClient? _client;
  StreamSubscription<List<NasEntry>>? _walk;
  late SlideshowPlaylist<NasEntry> _playlist;

  /// Shown, and the one before it while the crossfade runs.
  SlideImage? _current;
  SlideImage? _previous;

  /// The next picture, loading or loaded ahead of time.
  ({NasEntry entry, Future<SlideImage?> slide})? _preload;

  /// Counts the pictures asked for - a load that was overtaken (the user
  /// pressed on) is thrown away.
  var _generation = 0;
  var _loading = false;

  /// Wants the next picture, but none is known yet (still searching).
  var _waiting = false;
  Timer? _timer;
  Timer? _overlayTimer;
  var _paused = false;
  var _overlay = true;
  var _optionsOpen = false;
  String? _error;
  var _noneFound = false;
  ({int width, int height})? _box;
  var _blur = true;

  /// Where this folder's place is remembered (see SlideshowResumeStore).
  String? _resumeKey;

  /// The NAS - videos get a connection of their own.
  NasConfig? _config;

  /// The video playing instead of a picture.
  SlideVideo? _video;

  /// Seeking in [_video] with ← / → (as in Filme): the presses add up -
  /// faster the more in a row - and the jump happens when they stop.
  SlideVideo? _seekVideo;
  Duration? _seekTarget;
  Timer? _seekTimer;
  int _seekPresses = 0;
  int _seekDirection = 0;
  DateTime _lastSeek = DateTime(0);

  /// The video's position bar shows (while seeking and a moment after).
  var _seekBar = false;
  Timer? _seekBarTimer;

  /// Paused for a video with sound - going on after it.
  var _musicPausedForVideo = false;
  RadioAudioHandler? _radioPausedForVideo;

  /// The popup with what's playing and the display time is shown.
  var _popupOpen = false;

  /// What is shown now: the video, else the picture.
  NasEntry? get _shown => _video?.entry ?? _current?.entry;

  @override
  void initState() {
    super.initState();
    // Loads the interval before the first picture's time is counted.
    ref.read(slideshowSettingsProvider);
    // Read now: dispose may need it to resume the music after a video.
    _music;
    _display.setKeepScreenOn(true);
    _start();
    _grabFocus();
  }

  void _grabFocus() {
    for (final delay in const [Duration.zero, Duration(milliseconds: 400)]) {
      Future<void>.delayed(delay, () {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) _focus.requestFocus();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _box = slideBox(View.of(context).physicalSize);
  }

  @override
  void dispose() {
    _stop();
    _timer?.cancel();
    _overlayTimer?.cancel();
    _seekTimer?.cancel();
    _seekBarTimer?.cancel();
    _fade.dispose();
    _focus.dispose();
    _current?.dispose();
    _previous?.dispose();
    final video = _video;
    _video = null;
    if (video != null) _closeVideo(video);
    _resumeAudioAfterVideo();
    _display.setKeepScreenOn(false);
    super.dispose();
  }

  void _closeVideo(SlideVideo video) {
    video.removeListener(_onVideoChanged);
    unawaited(video.close());
  }

  /// Music or radio playing: paused for a video (its sound would mix in).
  Future<void> _pauseAudioForVideo() async {
    if (_musicPausedForVideo || _radioPausedForVideo != null) return;
    try {
      if (_music.state.value.playing) {
        _musicPausedForVideo = true;
        await _music.pause();
        return;
      }
    } catch (e) {
      debugPrint('slideshow: music not paused ($e)');
    }
    try {
      final handler = ref.read(radioAudioHandlerProvider).value;
      if (handler != null && !handler.hasGuest && handler.playbackState.value.playing) {
        _radioPausedForVideo = handler;
        await handler.pause();
      }
    } catch (e) {
      debugPrint('slideshow: radio not paused ($e)');
    }
  }

  /// What [_pauseAudioForVideo] paused goes on.
  void _resumeAudioAfterVideo() {
    if (_musicPausedForVideo) {
      _musicPausedForVideo = false;
      _music.play().catchError((Object e) => debugPrint('slideshow: music not resumed ($e)'));
    }
    final radio = _radioPausedForVideo;
    _radioPausedForVideo = null;
    if (radio != null) radio.play().catchError((Object e) => debugPrint('slideshow: radio not resumed ($e)'));
  }

  /// Stops looking for pictures and loading them.
  void _stop() {
    _generation++;
    _walk?.cancel();
    _walk = null;
    _discardPreload();
    _client?.close();
    _client = null;
  }

  void _discardPreload() {
    final preload = _preload;
    _preload = null;
    preload?.slide.then((s) => s?.dispose());
  }

  /// (Re)starts: a new connection, the walk through the folders.
  Future<void> _start() async {
    _stop();
    final settings = await ref.read(settingsRepositoryProvider).getSlideshowSettings();
    final nas = await ref.read(nasSettingsProvider.future);
    if (!mounted) return;
    final client = nas.config.createClient();
    _client = client;
    _config = nas.config;
    _blur = settings.blurredBackground;
    _resumeKey = SlideshowResumeStore.keyOf(nas.config.identity, widget.folder);
    final startAt = widget.startAt;
    _playlist = SlideshowPlaylist(
      order: settings.order,
      startWhere: startAt == null ? null : (e) => e.path == startAt,
    );
    setState(() {
      _error = null;
      _noneFound = false;
      _waiting = false;
    });
    _showOverlayBriefly();
    _walk = collectPictures(
      client,
      widget.folder,
      media: widget.media,
      onError: (folder, e) => debugPrint('slideshow: $folder left out ($e)'),
    ).listen(
      _onFound,
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = e is NasException ? e.message : '$e');
      },
      onDone: _onWalkDone,
      cancelOnError: true,
    );
  }

  void _onFound(List<NasEntry> pictures) {
    if (pictures.isEmpty || !mounted) return;
    _playlist.addAll(pictures);
    if (_shown == null && !_loading) {
      _showCurrent();
    } else if (_waiting) {
      _waiting = false;
      _step(1);
    } else if (_preload == null && _shown != null) {
      _preloadNext();
    }
    setState(() {});
  }

  void _onWalkDone() {
    if (!mounted) return;
    _playlist.finish();
    if (_playlist.isEmpty && _shown == null) {
      setState(() => _noneFound = true);
      return;
    }
    if (_shown == null && !_loading) {
      // The picture to start at never came (deleted meanwhile): the first.
      _showCurrent();
    } else if (_waiting) {
      _waiting = false;
      _step(1);
    } else {
      // The last one can now be followed by the first.
      _preloadNext();
    }
    setState(() {});
  }

  /// Loads and shows the playlist's current picture; one that can't be
  /// shown is dropped and the next one in that direction tried.
  Future<void> _showCurrent({bool forward = true}) async {
    final entry = _playlist.current;
    if (entry == null) {
      _waiting = true;
      return;
    }
    final generation = ++_generation;
    _timer?.cancel();
    // A video being left stops at once (its sound mustn't play on while
    // the next one loads).
    unawaited(_video?.pause());
    setState(() => _loading = true);
    if (isPictureVideoName(entry.name)) return _showVideo(entry, generation, forward: forward);
    final slide = await _slideFor(entry);
    if (!mounted || generation != _generation) {
      slide?.dispose();
      return;
    }
    if (slide == null) return _skipUnusable(forward: forward);
    _present(slide);
  }

  /// The current one can't be shown: dropped, the next one in that
  /// direction tried.
  void _skipUnusable({required bool forward}) {
    final more = _playlist.removeCurrent(forward: forward);
    if (more) {
      unawaited(_showCurrent(forward: forward));
      return;
    }
    setState(() {
      _loading = false;
      _waiting = true;
      _noneFound = _playlist.isEmpty && _playlist.complete && _shown == null;
    });
    if (_video == null) _resumeAudioAfterVideo();
    // Nothing to wait for: shown again in a while (the one shown stays).
    if (_playlist.complete && _shown != null) _scheduleNext();
  }

  /// A video: plays whole with sound (the music pauses meanwhile), then the
  /// slideshow goes on ([_onVideoChanged]).
  Future<void> _showVideo(NasEntry entry, int generation, {required bool forward}) async {
    final config = _config;
    final language = Localizations.localeOf(context).languageCode;
    await _pauseAudioForVideo();
    if (!mounted || generation != _generation) return;
    final video = config == null ? null : await SlideVideo.open(config, entry, language: language);
    if (!mounted || generation != _generation) {
      if (video != null) unawaited(video.close());
      return;
    }
    if (video == null) return _skipUnusable(forward: forward);
    if (!await video.hasSound()) _resumeAudioAfterVideo();
    if (!mounted || generation != _generation) {
      unawaited(video.close());
      return;
    }
    final old = _video;
    setState(() {
      _video = video;
      _loading = false;
      _waiting = false;
    });
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => _closeVideo(old));
    video.addListener(_onVideoChanged);
    if (_paused) unawaited(video.pause());
    _timer?.cancel();
    _remember(entry);
    // The picture after it, loaded while it plays.
    _preloadNext();
  }

  /// The video played to its end (or broke off): the next one.
  void _onVideoChanged() {
    final video = _video;
    if (video == null || !video.ended || !mounted) return;
    video.removeListener(_onVideoChanged);
    _step(1);
  }

  Future<SlideImage?> _slideFor(NasEntry entry) {
    final preload = _preload;
    if (preload != null && preload.entry.path == entry.path) {
      _preload = null;
      return preload.slide;
    }
    return _load(entry);
  }

  Future<SlideImage?> _load(NasEntry entry) {
    final client = _client;
    final box = _box;
    if (client == null || box == null) return Future.value();
    return loadSlide(client, entry, box: box, cover: _blur);
  }

  void _present(SlideImage slide) {
    final dropped = _previous;
    final video = _video;
    // After a video the picture comes without a crossfade (from the one
    // before the video).
    final before = video != null ? _current : null;
    setState(() {
      _previous = video != null ? null : _current;
      _current = slide;
      _video = null;
      _loading = false;
      _waiting = false;
    });
    // After the frame that no longer shows it.
    if (dropped != null) WidgetsBinding.instance.addPostFrameCallback((_) => dropped.dispose());
    if (before != null) WidgetsBinding.instance.addPostFrameCallback((_) => before.dispose());
    if (video != null) WidgetsBinding.instance.addPostFrameCallback((_) => _closeVideo(video));
    // Paused for a video (also one that couldn't be played): goes on.
    _resumeAudioAfterVideo();
    _fade.forward(from: 0);
    _scheduleNext();
    _preloadNext();
    _remember(slide.entry);
  }

  /// This folder's place, for "Fortsetzen" next time.
  void _remember(NasEntry entry) {
    final key = _resumeKey;
    if (key == null) return;
    final point = SlideshowResumePoint(path: entry.path, name: entry.name, position: _playlist.index + 1);
    ref.read(slideshowResumeProvider).save(key, point).catchError((Object e) => debugPrint('slideshow resume: $e'));
  }

  void _dropPrevious() {
    final previous = _previous;
    if (previous == null || !mounted) return;
    setState(() => _previous = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  /// Loads the following picture ahead, so it's there when its time comes.
  void _preloadNext() {
    final next = _playlist.peek(1);
    final current = _shown;
    if (next == null || next.path == current?.path || isPictureVideoName(next.name)) return;
    if (_preload?.entry.path == next.path) return;
    _discardPreload();
    _preload = (entry: next, slide: _load(next));
  }

  void _scheduleNext() {
    _timer?.cancel();
    // A video goes on when it has ended.
    if (_paused || _optionsOpen || _video != null) return;
    final seconds = ref.read(slideshowSettingsProvider).intervalSeconds;
    _timer = Timer(Duration(seconds: seconds), () => _step(1));
  }

  /// [delta] pictures on (1) or back (-1).
  void _step(int delta) {
    if (_shown == null && _loading) return;
    if (!_playlist.move(delta)) {
      if (delta > 0) _waiting = true;
      return;
    }
    final shown = _shown;
    if (_playlist.current?.path == shown?.path && !_loading && _video == null) {
      // Only one picture: it stays. (Only one video: it plays again.)
      _scheduleNext();
      return;
    }
    _showCurrent(forward: delta > 0);
  }

  void _togglePause([bool? pause]) {
    setState(() => _paused = pause ?? !_paused);
    final video = _video;
    if (video != null) {
      unawaited(_paused ? video.pause() : video.play());
      return;
    }
    if (_paused) {
      _timer?.cancel();
    } else {
      _scheduleNext();
    }
  }

  /// The popup with what's playing, its controls and the display time; the
  /// info bar shows meanwhile.
  void _openPopup() {
    _overlayTimer?.cancel();
    setState(() {
      _popupOpen = true;
      _overlay = true;
    });
  }

  void _closePopup() {
    if (!_popupOpen || !mounted) return;
    setState(() {
      _popupOpen = false;
      _overlay = false;
    });
    _focus.requestFocus();
  }

  void _toggleOverlay() {
    _overlayTimer?.cancel();
    setState(() => _overlay = !_overlay);
  }

  /// At the start: how it works, for a few seconds.
  void _showOverlayBriefly() {
    _overlayTimer?.cancel();
    setState(() => _overlay = true);
    _overlayTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _overlay = false);
    });
  }

  Future<void> _openOptions() async {
    _optionsOpen = true;
    _timer?.cancel();
    await showSlideshowOptions(context, ref);
    _optionsOpen = false;
    if (!mounted) return;
    // A new background setting applies from the next picture loaded.
    final blur = ref.read(slideshowSettingsProvider).blurredBackground;
    if (blur != _blur) {
      _blur = blur;
      _discardPreload();
      _preloadNext();
    }
    _scheduleNext();
    _grabFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Without a picture (error, nothing found) the buttons take the keys.
    if (_shown == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Music to the pictures: next/previous (and fast-forward/rewind) switch
    // the track - ←/→ step the pictures; OK and the pause key pause the
    // slideshow, not the music.
    final trackKeys = {
      LogicalKeyboardKey.mediaTrackNext,
      LogicalKeyboardKey.mediaTrackPrevious,
      LogicalKeyboardKey.mediaFastForward,
      LogicalKeyboardKey.mediaRewind,
    };
    // A video: ← → (and ⏪ ⏩) seek in it, ⏮ ⏭ and the channel keys go to
    // the previous / next picture or video (the music is paused anyway).
    final video = _video;
    if (video != null && !_popupOpen) {
      final result = _videoKey(video, event);
      if (result != null) return result;
    }
    if (event is KeyDownEvent && trackKeys.contains(key) && ref.read(musicPlayerProvider).handleMediaKey(key)) {
      return KeyEventResult.handled;
    }
    // The popup's controls take the keys (← → move between them).
    if (_popupOpen) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaFastForward) {
      // Held down: not a load per repeat (each would fetch a whole photo).
      if (event is KeyDownEvent) _step(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.mediaRewind) {
      if (event is KeyDownEvent) _step(-1);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _openPopup();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause || key == LogicalKeyboardKey.mediaStop) {
      _togglePause(true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      _togglePause(false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.info || key == LogicalKeyboardKey.guide) {
      _toggleOverlay();
      return KeyEventResult.handled;
    }
    if (ref.read(remoteKeysProvider).matches(RemoteAction.options, key)) {
      _openOptions();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The keys while [video] plays - null for the ones handled as usual.
  KeyEventResult? _videoKey(SlideVideo video, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.mediaFastForward) {
      _seekVideoBy(video, 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.mediaRewind) {
      _seekVideoBy(video, -1);
      return KeyEventResult.handled;
    }
    final next = key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.pageUp;
    final previous = key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.pageDown;
    if (next || previous) {
      if (event is KeyDownEvent) _step(next ? 1 : -1);
      return KeyEventResult.handled;
    }
    return null;
  }

  void _seekVideoBy(SlideVideo video, int direction) {
    final state = video.player.state.value;
    if (!identical(_seekVideo, video)) {
      _seekVideo = video;
      _seekTarget = null;
      _seekPresses = 0;
      _seekDirection = 0;
    }
    final now = DateTime.now();
    final inARow = direction == _seekDirection && now.difference(_lastSeek) < const Duration(milliseconds: 1500);
    _seekPresses = inARow ? _seekPresses + 1 : 0;
    _seekDirection = direction;
    _lastSeek = now;
    var target = (_seekTarget ?? state.position) + movieSeekStep(_seekPresses) * direction;
    if (target < Duration.zero) target = Duration.zero;
    final duration = state.duration;
    if (duration > Duration.zero && target >= duration) {
      // Past the end: on to the next picture or video.
      _seekTimer?.cancel();
      _seekTarget = null;
      _step(1);
      return;
    }
    _seekTimer?.cancel();
    _seekBarTimer?.cancel();
    setState(() {
      _seekTarget = target;
      _seekBar = true;
    });
    _seekTimer = Timer(const Duration(milliseconds: 600), () => unawaited(_applySeek(video)));
  }

  Future<void> _applySeek(SlideVideo video) async {
    final target = _seekTarget;
    if (target == null || !identical(_video, video)) return;
    try {
      await video.player.seekTo(target);
    } catch (e) {
      debugPrint('slideshow video seek: $e');
    }
    if (!mounted || !identical(_video, video)) return;
    setState(() => _seekTarget = null);
    _seekBarTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _seekTarget == null) setState(() => _seekBar = false);
    });
  }

  void _onTapUp(TapUpDetails details) {
    if (_shown == null) return;
    if (_popupOpen) {
      _closePopup();
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final x = details.localPosition.dx;
    if (x < width / 3) {
      _step(-1);
    } else if (x > width * 2 / 3) {
      _step(1);
    } else {
      _openPopup();
    }
  }

  void _onSwipe(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < 200 || _shown == null) return;
    _step(v < 0 ? 1 : -1);
  }

  @override
  Widget build(BuildContext context) {
    // A new interval applies at once.
    ref.listen(slideshowSettingsProvider.select((s) => s.intervalSeconds), (_, _) {
      if (_timer?.isActive ?? false) _scheduleNext();
    });
    final l = context.l10n;
    final current = _current;
    final previous = _previous;
    final video = _video;
    final shown = _shown;
    Widget body;
    if (_error != null && shown == null) {
      body = _Message(text: l.picturesLoadError(_error!), action: l.commonRetry, onAction: _start);
    } else if (_noneFound) {
      body = _Message(
        text: switch (widget.media) {
          SlideshowMedia.pictures => l.picturesNoneFound,
          SlideshowMedia.both => l.picturesNoMediaFound,
          SlideshowMedia.videos => l.picturesNoVideosFound,
        },
        action: MaterialLocalizations.of(context).backButtonTooltip,
        onAction: () => Navigator.of(context).maybePop(),
      );
    } else if (shown == null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LoadingWave(),
            const SizedBox(height: 16),
            Text(l.picturesSearching, style: const TextStyle(color: Colors.white70, fontSize: 18)),
          ],
        ),
      );
    } else {
      body = Stack(
        fit: StackFit.expand,
        children: [
          if (video != null)
            KeyedSubtree(key: ObjectKey(video), child: video.view())
          else ...[
            if (previous != null)
              _SlideView(
                key: ObjectKey(previous),
                slide: previous,
                // An opaque picture (with background) can simply be covered;
                // without, the old one has to fade out, too.
                opacity: _blur && previous.cover != null ? kAlwaysCompleteAnimation : ReverseAnimation(_fade),
              ),
            if (current != null)
              _SlideView(
                key: ObjectKey(current),
                slide: current,
                opacity: previous == null ? kAlwaysCompleteAnimation : _fade,
              ),
          ],
          if (_paused) const Positioned(top: 24, right: 24, child: _PauseBadge()),
          if (video != null && (_seekBar || _overlay) && !_popupOpen)
            Positioned(
              left: 48,
              right: 48,
              bottom: _overlay ? 130 : 32,
              child: IgnorePointer(
                child: _VideoSeekBar(video: video, target: identical(_seekVideo, video) ? _seekTarget : null),
              ),
            ),
          if (_loading)
            const Positioned(
              bottom: 24,
              right: 24,
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            ),
          // Music to the pictures: what's playing, for a few seconds at
          // the start and on every new track (above the info bar).
          if (!_popupOpen)
            AnimatedPositioned(
              // Keyed: kept when a video takes the pictures' place.
              key: const ValueKey('toast'),
              duration: const Duration(milliseconds: 250),
              left: 32,
              bottom: _overlay ? 130 : 32,
              child: const MusicNowPlayingToast(),
            ),
          Positioned(
            key: const ValueKey('info'),
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _overlay ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: _InfoBar(
                  folder: pictureFolderLabel(widget.folder, shown.path),
                  name: shown.name,
                  position: '${_playlist.index + 1} / ${_playlist.length}',
                  searching: !_playlist.complete,
                  hint: video != null
                      ? l.picturesSlideshowVideoHint
                      : l.picturesSlideshowHint(remoteKeyHint(ref.watch(remoteKeysProvider), RemoteAction.options)),
                ),
              ),
            ),
          ),
          if (_popupOpen)
            Positioned(
              key: const ValueKey('popup'),
              left: 0,
              right: 0,
              bottom: 130,
              child: Center(child: SlideshowPopup(onClose: _closePopup)),
            ),
        ],
      );
    }
    return PopScope(
      // Back closes the popup first.
      canPop: !_popupOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePopup();
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onHorizontalDragEnd: _onSwipe,
            child: body,
          ),
        ),
      ),
    );
  }
}

/// One picture: fitted on black, or on its own blurred, darkened copy.
class _SlideView extends StatelessWidget {
  const _SlideView({super.key, required this.slide, required this.opacity});

  final SlideImage slide;
  final Animation<double> opacity;

  @override
  Widget build(BuildContext context) {
    final cover = slide.cover;
    // Opacity straight in the image's paint - no extra layer per frame.
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cover != null)
          RawImage(
            image: cover,
            fit: BoxFit.cover,
            opacity: opacity,
            filterQuality: FilterQuality.medium,
            color: const Color(0xFF5A5A5A),
            colorBlendMode: BlendMode.modulate,
          ),
        RawImage(image: slide.image, fit: BoxFit.contain, opacity: opacity, filterQuality: FilterQuality.medium),
      ],
    );
  }
}

class _PauseBadge extends StatelessWidget {
  const _PauseBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.pause, color: Colors.white, size: 22),
          const SizedBox(width: 6),
          Text(context.l10n.picturesPaused, style: const TextStyle(color: Colors.white, fontSize: 16)),
        ],
      ),
    );
  }
}

class _InfoBar extends StatelessWidget {
  const _InfoBar({
    required this.folder,
    required this.name,
    required this.position,
    required this.searching,
    required this.hint,
  });

  final String folder;
  final String name;
  final String position;
  final bool searching;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xCC000000)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(
                searching ? '$position  ·  ${context.l10n.picturesStillSearching}' : position,
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(hint, style: const TextStyle(color: Colors.white38, fontSize: 13)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.action, required this.onAction});

  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icon/pictures_logo.png', width: 96, height: 96),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, color: Colors.white70)),
            const SizedBox(height: 20),
            FilledButton(autofocus: true, onPressed: onAction, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

/// The slideshow's settings as a small dialog (the options key in the
/// slideshow): OK on a line switches to its next value.
Future<void> showSlideshowOptions(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final l = context.l10n;
        final s = ref.watch(slideshowSettingsProvider);
        final notifier = ref.read(slideshowSettingsProvider.notifier);
        const steps = SettingsRepository.slideshowIntervals;
        final next = steps[(steps.indexOf(s.intervalSeconds) + 1) % steps.length];
        Widget line(String label, String value, VoidCallback onTap, {bool autofocus = false}) => ListTile(
              autofocus: autofocus,
              title: Text(label),
              trailing: Text(value, style: const TextStyle(color: brandGreen, fontSize: 16)),
              onTap: onTap,
            );
        return SimpleDialog(
          title: Text(l.picturesSlideshowHeading),
          children: [
            line(l.picturesInterval, l.picturesIntervalSeconds(s.intervalSeconds),
                () => notifier.set(s.copyWith(intervalSeconds: next)),
                autofocus: true),
            line(
              l.picturesOrder,
              s.order == SlideshowOrder.folders ? l.picturesOrderFolders : l.picturesOrderShuffled,
              () => notifier.set(s.copyWith(
                order: s.order == SlideshowOrder.folders ? SlideshowOrder.shuffled : SlideshowOrder.folders,
              )),
            ),
            line(l.picturesBlur, s.blurredBackground ? '✓' : '–',
                () => notifier.set(s.copyWith(blurredBackground: !s.blurredBackground))),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(l.picturesOrderNextTime, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
          ],
        );
      },
    ),
  );
}

/// A video's position while seeking: time, bar, length.
class _VideoSeekBar extends StatelessWidget {
  const _VideoSeekBar({required this.video, required this.target});

  final SlideVideo video;

  /// Where the presses so far lead (not yet jumped to).
  final Duration? target;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        // A new player when ExoPlayer hands over to libmpv.
        listenable: video,
        builder: (context, _) => ValueListenableBuilder(
          valueListenable: video.player.state,
          builder: (context, state, _) {
            final position = target ?? state.position;
            final duration = state.duration;
            final fraction = duration > Duration.zero
                ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Text(formatMovieTime(position), style: const TextStyle(color: Colors.white, fontSize: 16)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 6,
                        backgroundColor: Colors.white24,
                        color: brandGreen,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    duration > Duration.zero ? formatMovieTime(duration) : '-:--',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
            );
          },
        ),
      );
}
