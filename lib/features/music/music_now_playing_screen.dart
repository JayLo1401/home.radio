import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/music_providers.dart';
import '../../core/remote_keys.dart';
import '../../data/models/music_track.dart';
import '../../data/repositories/music_settings_repository.dart';
import '../../data/services/music_library.dart' show MusicRepeat;
import '../../data/services/music_player.dart';
import '../../l10n/l10n.dart';
import 'music_visualizer_screen.dart';
import 'music_widgets.dart';

/// Opens the now-playing screen.
Future<void> openMusicNowPlaying(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MusicNowPlayingScreen()));

/// The playing track big: cover, title, artist, album, progress, the
/// controls and the queue.
///
/// Remote, PowerAmp style: OK pause/play, ←/→ 10 s back/on (held: faster),
/// ↑ the visualisation, ↓ to the buttons (←/→ move there, ↑ back), ☰ the
/// queue; Back closes. Media keys as everywhere. With the visualisation on
/// "automatic" it comes up by itself after a minute without a key.
class MusicNowPlayingScreen extends ConsumerStatefulWidget {
  const MusicNowPlayingScreen({super.key});

  @override
  ConsumerState<MusicNowPlayingScreen> createState() => _MusicNowPlayingScreenState();
}

class _MusicNowPlayingScreenState extends ConsumerState<MusicNowPlayingScreen> {
  final _root = FocusNode(debugLabel: 'music now playing');
  final _playButton = FocusNode(debugLabel: 'music play');
  final _queueScroll = ScrollController();
  Timer? _ticker;
  Timer? _idle;
  Timer? _seekFlush;
  Duration? _seekTarget;
  int _repeats = 0;
  bool _showQueue = false;

  static const _queueRowHeight = 60.0;
  static const _autoVisualizerAfter = Duration(seconds: 60);

  MusicPlayer get _player => ref.read(musicPlayerProvider);

  @override
  void initState() {
    super.initState();
    // Seek mode or buttons/queue: the hints and what Back does change.
    _root.addListener(_onFocusMoved);
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      // Not while covered (the visualisation): no work for nobody to see.
      if (mounted && _seekTarget == null && (ModalRoute.of(context)?.isCurrent ?? true)) setState(() {});
    });
    _resetIdle();
  }

  void _onFocusMoved() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _root.removeListener(_onFocusMoved);
    _ticker?.cancel();
    _idle?.cancel();
    _seekFlush?.cancel();
    _root.dispose();
    _playButton.dispose();
    _queueScroll.dispose();
    super.dispose();
  }

  void _resetIdle() {
    _idle?.cancel();
    _idle = Timer(_autoVisualizerAfter, () {
      if (!mounted) return;
      final auto = ref.read(musicSettingsProvider).visualizer == MusicVisualizerMode.auto;
      final current = ModalRoute.of(context)?.isCurrent ?? false;
      if (auto && current && ref.read(musicStateProvider).playing) {
        _openVisualizer();
      } else {
        _resetIdle();
      }
    });
  }

  Future<void> _openVisualizer() async {
    _idle?.cancel();
    await Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 700),
      pageBuilder: (_, _, _) => const MusicVisualizerScreen(),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
    if (!mounted) return;
    _root.requestFocus();
    _resetIdle();
  }

  /// ←/→: 10 s, held longer 30 s then 60 s steps - gathered and sent to
  /// the player a few times a second.
  void _seekStep(int direction, {required bool repeat}) {
    _repeats = repeat ? _repeats + 1 : 0;
    final step = _repeats < 6 ? 10 : (_repeats < 20 ? 30 : 60);
    final duration = ref.read(musicStateProvider).duration;
    var target = (_seekTarget ?? _player.position) + Duration(seconds: step * direction);
    if (target < Duration.zero) target = Duration.zero;
    if (duration != null && target > duration) target = duration;
    setState(() => _seekTarget = target);
    _seekFlush ??= Timer(const Duration(milliseconds: 180), _flushSeek);
  }

  Future<void> _flushSeek() async {
    _seekFlush = null;
    final target = _seekTarget;
    if (target == null) return;
    await _player.seek(target);
    // Keep showing the target until the player is there.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted && _seekFlush == null) setState(() => _seekTarget = null);
    });
  }

  bool get _inSeekMode => _root.hasPrimaryFocus;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    _resetIdle();
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if ((key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) && _seekTarget != null) {
        _seekFlush?.cancel();
        _flushSeek();
      }
      return KeyEventResult.ignored;
    }
    final repeat = event is KeyRepeatEvent;
    if (!repeat && _player.handleMediaKey(key)) return KeyEventResult.handled;
    if (!repeat && ref.read(remoteKeysProvider).matches(RemoteAction.options, key)) {
      _toggleQueue();
      return KeyEventResult.handled;
    }
    if (!_inSeekMode) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      _seekStep(key == LogicalKeyboardKey.arrowLeft ? -1 : 1, repeat: repeat);
      return KeyEventResult.handled;
    }
    if (repeat) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _player.togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (ref.read(musicSettingsProvider).visualizer != MusicVisualizerMode.off) _openVisualizer();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _playButton.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// ↑ from the buttons: back to seeking.
  KeyEventResult _onControlsKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _root.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggleQueue() {
    setState(() => _showQueue = !_showQueue);
    if (_showQueue) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollQueueToCurrent());
    } else {
      _root.requestFocus();
    }
  }

  void _scrollQueueToCurrent() {
    if (!_queueScroll.hasClients) return;
    final index = ref.read(musicStateProvider).index;
    final offset = (index - 2).clamp(0, 1 << 30) * _queueRowHeight;
    _queueScroll.jumpTo(offset.clamp(0, _queueScroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(musicStateProvider);
    final settings = ref.watch(musicSettingsProvider);
    final track = state.current;
    final display = track == null ? null : MusicDisplay.of(track, state.tags, preferTags: settings.preferTags);
    final position = _seekTarget ?? _player.position;
    final duration = state.duration;
    final progress = duration == null || duration.inMilliseconds == 0
        ? 0.0
        : position.inMilliseconds / duration.inMilliseconds;

    return PopScope(
      canPop: _inSeekMode && !_showQueue,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showQueue) {
          _toggleQueue();
        } else {
          _root.requestFocus();
          setState(() {});
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _root,
          autofocus: true,
          onKeyEvent: _onKey,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(-0.6, -0.4),
                radius: 1.4,
                colors: [Color(0xFF1C2A1A), musicGraphite, Colors.black],
                stops: [0, 0.45, 1],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(48, 32, 48, 24),
                child: track == null
                    ? Center(
                        child: Text(l10n.musicNothingPlaying,
                            style: const TextStyle(color: Colors.white54, fontSize: 24)),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _nowPlaying(context, state, display!, position, progress)),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            child: _showQueue
                                ? Padding(
                                    padding: const EdgeInsets.only(left: 32),
                                    child: SizedBox(width: 420, child: _queue(context, state, settings.preferTags)),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _nowPlaying(BuildContext context, MusicState state, MusicDisplay display, Duration position, double progress) {
    final l10n = context.l10n;
    final visualizerOn = ref.watch(musicSettingsProvider.select((s) => s.visualizer)) != MusicVisualizerMode.off;
    return LayoutBuilder(builder: (context, c) {
      final coverSize = (c.maxHeight * 0.62).clamp(160.0, c.maxWidth * 0.4);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: visualizerOn ? _openVisualizer : null,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: musicGreen.withValues(alpha: 0.25), blurRadius: 40, spreadRadius: 2)],
                    ),
                    child: MusicCover(bytes: state.tags?.cover, size: coverSize, radius: 16),
                  ),
                ),
                const SizedBox(width: 40),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (state.label != null)
                        Text(
                          state.label!.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: musicLime, fontSize: 15, letterSpacing: 1.6),
                        ),
                      const SizedBox(height: 10),
                      Text(
                        display.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w700, height: 1.15),
                      ),
                      if (display.artist != null) ...[
                        const SizedBox(height: 8),
                        Text(display.artist!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 26)),
                      ],
                      if (display.album != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          [display.album!, if (state.tags?.year != null) '${state.tags!.year}'].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white38, fontSize: 20),
                        ),
                      ],
                      const SizedBox(height: 18),
                      Text(
                        [
                          l10n.musicQueuePosition(state.index + 1, state.queue.length),
                          if (state.collecting) l10n.musicCollecting,
                        ].join(' · '),
                        style: const TextStyle(color: Colors.white38, fontSize: 16),
                      ),
                      if (state.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(state.error!,
                              maxLines: 2, style: const TextStyle(color: Colors.amberAccent, fontSize: 16)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _progress(state, position, progress),
          const SizedBox(height: 18),
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onControlsKey,
            child: FocusTraversalGroup(child: _controls(context, state, visualizerOn)),
          ),
          const SizedBox(height: 12),
          Text(
            _inSeekMode ? l10n.musicNowPlayingHint(remoteKeyHint(ref.watch(remoteKeysProvider), RemoteAction.options)) : l10n.musicControlsHint,
            style: const TextStyle(color: Colors.white30, fontSize: 14),
          ),
        ],
      );
    });
  }

  Widget _progress(MusicState state, Duration position, double progress) {
    final seeking = _seekTarget != null;
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, c) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final duration = state.duration;
              if (duration == null || c.maxWidth <= 0) return;
              _player.seek(duration * (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: MusicProgressLine(value: progress, height: seeking ? 8 : 6),
            ),
          ),
        ),
        Row(
          children: [
            Text(formatMusicDuration(position),
                style: TextStyle(color: seeking ? musicLime : Colors.white70, fontSize: 18)),
            const Spacer(),
            if (state.buffering)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: musicLime)),
              ),
            Text(formatMusicDuration(state.duration), style: const TextStyle(color: Colors.white70, fontSize: 18)),
          ],
        ),
      ],
    );
  }

  Widget _controls(BuildContext context, MusicState state, bool visualizerOn) {
    final l10n = context.l10n;
    final repeatIcon = state.repeat == MusicRepeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        MusicControlButton(
          icon: Icons.shuffle_rounded,
          tooltip: state.shuffle ? l10n.musicShuffleOn : l10n.musicShuffleOff,
          active: state.shuffle,
          onPressed: () => _player.setShuffle(!state.shuffle),
        ),
        const SizedBox(width: 20),
        MusicControlButton(
          icon: Icons.skip_previous_rounded,
          tooltip: l10n.musicPrevious,
          size: 64,
          onPressed: _player.previous,
        ),
        const SizedBox(width: 20),
        MusicControlButton(
          icon: state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: state.playing ? l10n.musicPause : l10n.musicPlay,
          size: 84,
          primary: true,
          focusNode: _playButton,
          onPressed: _player.togglePlayPause,
        ),
        const SizedBox(width: 20),
        MusicControlButton(
          icon: Icons.skip_next_rounded,
          tooltip: l10n.musicNext,
          size: 64,
          onPressed: _player.next,
        ),
        const SizedBox(width: 20),
        MusicControlButton(
          icon: repeatIcon,
          tooltip: switch (state.repeat) {
            MusicRepeat.off => l10n.musicRepeatOff,
            MusicRepeat.all => l10n.musicRepeatAll,
            MusicRepeat.one => l10n.musicRepeatOne,
          },
          active: state.repeat != MusicRepeat.off,
          onPressed: _player.cycleRepeat,
        ),
        const SizedBox(width: 40),
        MusicControlButton(
          icon: Icons.queue_music_rounded,
          tooltip: l10n.musicQueue,
          active: _showQueue,
          onPressed: _toggleQueue,
        ),
        if (visualizerOn) ...[
          const SizedBox(width: 20),
          MusicControlButton(
            icon: Icons.blur_on_rounded,
            tooltip: l10n.musicVisualizer,
            onPressed: _openVisualizer,
          ),
        ],
        const SizedBox(width: 20),
        MusicControlButton(
          icon: Icons.stop_rounded,
          tooltip: l10n.musicStop,
          onPressed: () async {
            await _player.stop();
            if (context.mounted) Navigator.of(context).maybePop();
          },
        ),
      ],
    );
  }

  Widget _queue(BuildContext context, MusicState state, bool preferTags) {
    final l10n = context.l10n;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(l10n.musicQueueTitle(state.queue.length),
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: FocusTraversalGroup(
              child: ListView.builder(
                controller: _queueScroll,
                itemExtent: _queueRowHeight,
                itemCount: state.queue.length,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                itemBuilder: (context, i) {
                  final track = state.queue[i];
                  final current = i == state.index;
                  final guess = preferTags ? track.nameGuess : (artist: null, title: track.baseName);
                  return MusicRow(
                    selected: current,
                    autofocus: current,
                    onTap: () => _player.jumpTo(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 44,
                            child: current
                                ? Icon(state.playing ? Icons.equalizer_rounded : Icons.pause_rounded, color: musicLime)
                                : Text('${i + 1}', style: const TextStyle(color: Colors.white38, fontSize: 14)),
                          ),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(guess.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: current ? musicLime : Colors.white, fontSize: 16)),
                                Text(guess.artist ?? track.folderName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white38, fontSize: 13)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
