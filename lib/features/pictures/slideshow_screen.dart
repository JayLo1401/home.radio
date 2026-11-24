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
import '../../data/services/nas_service.dart';
import '../../data/services/picture_library.dart';
import '../../l10n/l10n.dart';
import '../music/music_now_playing_toast.dart';
import 'slide_loader.dart';

/// A slideshow of [folder] and all its subfolders: starts with the first
/// pictures found while the rest is still being looked for, shows each
/// for the set time with a soft crossfade, and keeps the display on. Radio
/// and music are left alone - they simply play on.
///
/// Remote: ←/→ previous/next, OK or ⏯ pause/go on, ↑/↓ or Info the
/// picture's folder, name and number, the options key the slideshow's
/// settings, Back ends it. Touch: tap left/right third back/next, the
/// middle pause, swipe back/next.
///
/// [startAt]: begins with that picture ("ab hier", or resumed) and goes on
/// in the usual order from there. Where it is, is remembered per folder
/// (SlideshowResumeStore).
class SlideshowScreen extends ConsumerStatefulWidget {
  const SlideshowScreen({super.key, required this.folder, this.startAt});

  /// Absolute NAS path.
  final String folder;

  /// Path of a picture in [folder] or below.
  final String? startAt;

  @override
  ConsumerState<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends ConsumerState<SlideshowScreen> with SingleTickerProviderStateMixin {
  static const _fadeDuration = Duration(milliseconds: 900);

  final _focus = FocusNode(debugLabel: 'slideshow');
  late final _display = ref.read(displayServiceProvider);
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

  @override
  void initState() {
    super.initState();
    // Loads the interval before the first picture's time is counted.
    ref.read(slideshowSettingsProvider);
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
    _fade.dispose();
    _focus.dispose();
    _current?.dispose();
    _previous?.dispose();
    _display.setKeepScreenOn(false);
    super.dispose();
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
    if (_current == null && !_loading) {
      _showCurrent();
    } else if (_waiting) {
      _waiting = false;
      _step(1);
    } else if (_preload == null && _current != null) {
      _preloadNext();
    }
    setState(() {});
  }

  void _onWalkDone() {
    if (!mounted) return;
    _playlist.finish();
    if (_playlist.isEmpty && _current == null) {
      setState(() => _noneFound = true);
      return;
    }
    if (_current == null && !_loading) {
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
    setState(() => _loading = true);
    final slide = await _slideFor(entry);
    if (!mounted || generation != _generation) {
      slide?.dispose();
      return;
    }
    if (slide == null) {
      final more = _playlist.removeCurrent(forward: forward);
      if (more) {
        unawaited(_showCurrent(forward: forward));
      } else {
        setState(() {
          _loading = false;
          _waiting = true;
          _noneFound = _playlist.isEmpty && _playlist.complete && _current == null;
        });
        // Nothing to wait for: shown again in a while (the one shown stays).
        if (_playlist.complete && _current != null) _scheduleNext();
      }
      return;
    }
    _present(slide);
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
    setState(() {
      _previous = _current;
      _current = slide;
      _loading = false;
      _waiting = false;
    });
    // After the frame that no longer shows it.
    if (dropped != null) WidgetsBinding.instance.addPostFrameCallback((_) => dropped.dispose());
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
    final current = _current?.entry;
    if (next == null || next.path == current?.path) return;
    if (_preload?.entry.path == next.path) return;
    _discardPreload();
    _preload = (entry: next, slide: _load(next));
  }

  void _scheduleNext() {
    _timer?.cancel();
    if (_paused || _optionsOpen) return;
    final seconds = ref.read(slideshowSettingsProvider).intervalSeconds;
    _timer = Timer(Duration(seconds: seconds), () => _step(1));
  }

  /// [delta] pictures on (1) or back (-1).
  void _step(int delta) {
    if (_current == null && _loading) return;
    if (!_playlist.move(delta)) {
      if (delta > 0) _waiting = true;
      return;
    }
    if (_playlist.current?.path == _current?.entry.path && !_loading) {
      // Only one picture: it stays.
      _scheduleNext();
      return;
    }
    _showCurrent(forward: delta > 0);
  }

  void _togglePause([bool? pause]) {
    setState(() => _paused = pause ?? !_paused);
    if (_paused) {
      _timer?.cancel();
    } else {
      _scheduleNext();
    }
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
    if (_current == null) return KeyEventResult.ignored;
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
    if (event is KeyDownEvent && trackKeys.contains(key) && ref.read(musicPlayerProvider).handleMediaKey(key)) {
      return KeyEventResult.handled;
    }
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
        key == LogicalKeyboardKey.mediaPlayPause) {
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
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.info ||
        key == LogicalKeyboardKey.guide) {
      _toggleOverlay();
      return KeyEventResult.handled;
    }
    if (ref.read(remoteKeysProvider).matches(RemoteAction.options, key)) {
      _openOptions();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onTapUp(TapUpDetails details) {
    if (_current == null) return;
    final width = MediaQuery.sizeOf(context).width;
    final x = details.localPosition.dx;
    if (x < width / 3) {
      _step(-1);
    } else if (x > width * 2 / 3) {
      _step(1);
    } else {
      _togglePause();
      _toggleOverlay();
    }
  }

  void _onSwipe(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < 200 || _current == null) return;
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
    Widget body;
    if (_error != null && current == null) {
      body = _Message(text: l.picturesLoadError(_error!), action: l.commonRetry, onAction: _start);
    } else if (_noneFound) {
      body = _Message(text: l.picturesNoneFound, action: MaterialLocalizations.of(context).backButtonTooltip,
          onAction: () => Navigator.of(context).maybePop());
    } else if (current == null) {
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
          if (previous != null)
            _SlideView(
              key: ObjectKey(previous),
              slide: previous,
              // An opaque picture (with background) can simply be covered;
              // without, the old one has to fade out, too.
              opacity: _blur && previous.cover != null ? kAlwaysCompleteAnimation : ReverseAnimation(_fade),
            ),
          _SlideView(key: ObjectKey(current), slide: current, opacity: previous == null ? kAlwaysCompleteAnimation : _fade),
          if (_paused) const Positioned(top: 24, right: 24, child: _PauseBadge()),
          if (_loading)
            const Positioned(
              bottom: 24,
              right: 24,
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            ),
          // Music to the pictures: what's playing, for a few seconds at
          // the start and on every new track (above the info bar).
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            left: 32,
            bottom: _overlay ? 130 : 32,
            child: const MusicNowPlayingToast(),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _overlay ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: _InfoBar(
                  folder: pictureFolderLabel(widget.folder, current.entry.path),
                  name: current.entry.name,
                  position: '${_playlist.index + 1} / ${_playlist.length}',
                  searching: !_playlist.complete,
                  hint: l.picturesSlideshowHint(remoteKeyHint(ref.watch(remoteKeysProvider), RemoteAction.options)),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Focus(
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
