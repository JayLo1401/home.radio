import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dashboard_providers.dart' show displayServiceProvider;
import '../../core/music_providers.dart';
import '../../data/models/music_track.dart';
import '../../data/services/music_spectrum.dart';
import '../../l10n/l10n.dart';
import 'music_visualizer.dart';
import 'music_widgets.dart';

/// The visualisation full screen, over the now-playing screen. The cover
/// and title fade in on every new track and on opening.
///
/// Remote: OK pause/play, ←/→ track back/on, ↑ the next visualisation,
/// Back (or ↓) closes; the media keys work as everywhere.
///
/// A track change must not disturb the picture: the view and its
/// renderer live on, this screen only rebuilds for the few values it shows
/// (not for every player event), and the spectrum stays attached unless
/// the player's audio session really changes.
class MusicVisualizerScreen extends ConsumerStatefulWidget {
  const MusicVisualizerScreen({super.key});

  @override
  ConsumerState<MusicVisualizerScreen> createState() => _MusicVisualizerScreenState();
}

class _MusicVisualizerScreenState extends ConsumerState<MusicVisualizerScreen> {
  final _focus = FocusNode(debugLabel: 'music visualizer');
  final _pulse = MusicPulse(math.Random().nextInt(1 << 20));
  final _follower = MusicLevelFollower();
  final _controller = MusicVisualizerController();
  late final _display = ref.read(displayServiceProvider);

  StreamSubscription<List<double>>? _bands;
  StreamSubscription<int?>? _sessionIds;
  MusicLevels _real = MusicLevels.silent;
  DateTime _realAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _overlay = true;
  Timer? _overlayTimer;

  /// Shows "simulated" in the corner while the picture doesn't follow the
  /// real music (no permission, option off, or no spectrum coming in).
  final _simulated = ValueNotifier(false);
  final _openedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _display.setKeepScreenOn(true);
    _showOverlay();
    _startSpectrum();
  }

  @override
  void dispose() {
    _display.setKeepScreenOn(false);
    _overlayTimer?.cancel();
    _bands?.cancel();
    _sessionIds?.cancel();
    _focus.dispose();
    _simulated.dispose();
    super.dispose();
  }

  /// The real spectrum when wanted and allowed - else the generated pulse.
  Future<void> _startSpectrum() async {
    final settings = ref.read(musicSettingsProvider);
    if (!settings.audioReactive || !MusicSpectrum.supported) return;
    final spectrum = ref.read(musicSpectrumProvider);
    if (!await spectrum.hasPermission() || !mounted) return;
    final player = ref.read(musicPlayerProvider);
    int? attached;
    void listen(int? id) {
      // A track change can report no session for a moment - keep the one
      // attached; a new Visualizer only for a really new session.
      if (id == null || id <= 0 || (id == attached && _bands != null)) return;
      attached = id;
      _bands?.cancel();
      _bands = spectrum.bands(id).listen((b) {
        _real = _follower.add(b);
        _realAt = DateTime.now();
      }, onError: (Object _) => _bands = null);
    }

    listen(player.androidAudioSessionId);
    _sessionIds = player.androidAudioSessionIdStream.listen(listen);
  }

  MusicLevels _levels(double t) {
    final playing = ref.read(musicStateProvider).playing;
    final now = DateTime.now();
    final fresh = now.difference(_realAt) < const Duration(milliseconds: 400);
    // Simulated: no spectrum attached at all, or none coming in for a while
    // although the music plays (paused, it simply has nothing to show).
    _simulated.value = _bands == null ||
        (playing &&
            now.difference(_realAt) > const Duration(seconds: 2) &&
            now.difference(_openedAt) > const Duration(seconds: 2));
    if (fresh) return _real;
    return _pulse.at(t, playing: playing);
  }

  void _showOverlay() {
    _overlayTimer?.cancel();
    if (mounted) setState(() => _overlay = true);
    _overlayTimer = Timer(const Duration(seconds: 7), () {
      if (mounted) setState(() => _overlay = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final player = ref.read(musicPlayerProvider);
    if (player.handleMediaKey(key)) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      player.togglePlayPause();
      _showOverlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      player.next();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      player.previous();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _controller.nextScene();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final quality = ref.watch(musicSettingsProvider.select((s) => s.quality));
    final interval = ref.watch(musicSettingsProvider.select((s) => s.visualizerInterval));
    ref.listen(musicStateProvider.select((s) => s.current), (_, _) => _showOverlay());
    // Only what is shown - not every buffering/position event.
    final track = ref.watch(musicStateProvider.select((s) => s.current));
    final tags = ref.watch(musicStateProvider.select((s) => s.tags));
    final playing = ref.watch(musicStateProvider.select((s) => s.playing));
    final display = track == null
        ? null
        : MusicDisplay.of(track, tags, preferTags: ref.watch(musicSettingsProvider.select((s) => s.preferTags)));
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          onTap: () => Navigator.of(context).maybePop(),
          onDoubleTap: () => ref.read(musicPlayerProvider).togglePlayPause(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              MusicVisualizerView(
                profile: MusicVisualizerProfile.of(quality),
                levels: _levels,
                interval: interval,
                controller: _controller,
              ),
              // In the corner: this is not the music's real spectrum.
              Positioned(
                top: 28,
                right: 36,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _simulated,
                  builder: (context, simulated, _) => AnimatedOpacity(
                    opacity: simulated ? 1 : 0,
                    duration: const Duration(milliseconds: 600),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.l10n.musicVisualizerSimulated,
                            style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            context.l10n.musicVisualizerSimulatedHint,
                            style: const TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 48,
                bottom: 40,
                right: 48,
                child: RepaintBoundary(
                  child: AnimatedOpacity(
                    opacity: _overlay || !playing ? 1 : 0,
                    duration: const Duration(milliseconds: 900),
                    child: display == null
                        ? const SizedBox.shrink()
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [BoxShadow(color: musicGreen.withValues(alpha: 0.35), blurRadius: 30)],
                                ),
                                child: MusicCover(bytes: tags?.cover, size: 120),
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!playing)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: Text(
                                          context.l10n.musicPaused,
                                          style: const TextStyle(color: musicLime, fontSize: 18),
                                        ),
                                      ),
                                    Text(
                                      display.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 34,
                                        fontWeight: FontWeight.w700,
                                        shadows: [Shadow(blurRadius: 12)],
                                      ),
                                    ),
                                    if (display.artist != null)
                                      Text(
                                        display.artist!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 24,
                                          shadows: [Shadow(blurRadius: 10)],
                                        ),
                                      ),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        context.l10n.musicVisualizerHint,
                                        style: const TextStyle(color: Colors.white38, fontSize: 14),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
