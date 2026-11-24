import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/music_providers.dart';
import '../../data/models/music_track.dart';
import 'music_widgets.dart';

/// A small "now playing" note over another screen (e.g. the slideshow): it
/// slides in for a few seconds when music is playing as the screen opens and
/// whenever the track changes, then goes away by itself. Shows nothing
/// without music.
class MusicNowPlayingToast extends ConsumerStatefulWidget {
  const MusicNowPlayingToast({super.key, this.shownFor = const Duration(seconds: 6)});

  final Duration shownFor;

  @override
  ConsumerState<MusicNowPlayingToast> createState() => _MusicNowPlayingToastState();
}

class _MusicNowPlayingToastState extends ConsumerState<MusicNowPlayingToast> {
  bool _visible = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    // Music already playing when the screen opens: say what it is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(musicStateProvider).current != null) _show();
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _show() {
    _hide?.cancel();
    setState(() => _visible = true);
    _hide = Timer(widget.shownFor, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // A new track: show again (its tags arriving a moment later just update
    // what's shown).
    ref.listen<String?>(musicStateProvider.select((s) => s.current?.path), (prev, next) {
      if (next != null && next != prev) _show();
    });
    final state = ref.watch(musicStateProvider);
    final track = state.current;
    final preferTags = ref.watch(musicSettingsProvider.select((s) => s.preferTags));
    final display = track == null ? null : MusicDisplay.of(track, state.tags, preferTags: preferTags);
    return IgnorePointer(
      child: AnimatedSlide(
        offset: _visible && display != null ? Offset.zero : const Offset(0, 0.4),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _visible && display != null ? 1 : 0,
          duration: const Duration(milliseconds: 350),
          child: display == null
              ? const SizedBox.shrink()
              : Container(
                  constraints: const BoxConstraints(maxWidth: 520),
                  padding: const EdgeInsets.fromLTRB(10, 10, 18, 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MusicCover(bytes: state.tags?.cover, size: 52, radius: 8),
                      const SizedBox(width: 14),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(display.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                            if (display.artist != null || display.album != null)
                              Text(display.artist ?? display.album!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white60, fontSize: 14)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(state.playing ? Icons.music_note_rounded : Icons.pause_rounded, color: musicLime, size: 22),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
