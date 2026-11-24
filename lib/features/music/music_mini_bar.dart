import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/music_providers.dart';
import '../../data/models/music_track.dart';
import '../../l10n/l10n.dart';
import 'music_now_playing_screen.dart';
import 'music_widgets.dart';

/// "Now playing" for other screens (Home): cover, title, artist, a
/// progress line - OK/tap opens the player. Nothing while no music is
/// loaded, so it can simply be placed. Focusable like a tile; Play/Pause
/// on the remote toggles while it has the focus (and generally through
/// MusicPlayer.handleMediaKey).
class MusicMiniBar extends ConsumerStatefulWidget {
  const MusicMiniBar({super.key, this.width, this.focusNode, this.autofocus = false});

  /// null: as wide as the parent allows.
  final double? width;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  ConsumerState<MusicMiniBar> createState() => _MusicMiniBarState();
}

class _MusicMiniBarState extends ConsumerState<MusicMiniBar> {
  Timer? _ticker;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(musicStateProvider).playing && (ModalRoute.of(context)?.isCurrent ?? true)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(musicStateProvider);
    final track = state.current;
    if (track == null) return const SizedBox.shrink();
    final preferTags = ref.watch(musicSettingsProvider.select((s) => s.preferTags));
    final display = MusicDisplay.of(track, state.tags, preferTags: preferTags);
    final player = ref.read(musicPlayerProvider);
    final duration = state.duration;
    final progress = duration == null || duration.inMilliseconds == 0
        ? 0.0
        : player.position.inMilliseconds / duration.inMilliseconds;
    return SizedBox(
      width: widget.width,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _focused ? Theme.of(context).focusColor : Colors.white12, width: _focused ? 3 : 1),
          boxShadow: _focused ? [BoxShadow(color: musicGreen.withValues(alpha: 0.45), blurRadius: 16)] : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            borderRadius: BorderRadius.circular(14),
            focusColor: Colors.transparent,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: () => openMusicNowPlaying(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 14, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      MusicCover(bytes: state.tags?.cover, size: 52, radius: 8),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(display.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                            Text(display.artist ?? display.album ?? context.l10n.musicTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white60, fontSize: 14)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: state.playing ? context.l10n.musicPause : context.l10n.musicPlay,
                        onPressed: player.togglePlayPause,
                        icon: Icon(state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: musicLime),
                      ),
                      IconButton(
                        tooltip: context.l10n.musicNext,
                        onPressed: player.next,
                        icon: const Icon(Icons.skip_next_rounded, color: Colors.white70),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  MusicProgressLine(value: progress, height: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
