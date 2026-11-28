import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/music_providers.dart';
import '../../core/pictures_providers.dart';
import '../../core/providers.dart';
import '../../core/retrying_network_image.dart';
import '../../core/theme.dart';
import '../../data/models/favorite_channel.dart';
import '../../data/models/music_track.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/radio_audio_handler.dart';
import '../../l10n/l10n.dart';
import '../music/music_widgets.dart';

/// What the slideshow's popup controls: the music, the radio, or nothing.
enum SlideshowPopupSource { music, radio, none }

/// Which player the popup shows: the music while it holds the media
/// session (or plays), else the radio when it has a station, else none.
SlideshowPopupSource slideshowPopupSource({
  required bool musicActive,
  required bool musicPlaying,
  required bool radioHasStation,
  required bool musicHoldsSession,
}) {
  if (musicActive && (musicHoldsSession || musicPlaying || !radioHasStation)) return SlideshowPopupSource.music;
  if (radioHasStation) return SlideshowPopupSource.radio;
  return SlideshowPopupSource.none;
}

/// The slim popup over the running slideshow (OK, ↑ or ↓): what's playing -
/// music with cover, title, artist and progress, the radio with logo,
/// station and stream title - its controls (previous / play-pause / next:
/// the track, or for the radio the station), and how long each picture is
/// shown. ← → move between the controls, OK presses, Back ([onClose], via
/// the slideshow) or a few seconds without a key close it.
class SlideshowPopup extends ConsumerStatefulWidget {
  const SlideshowPopup({super.key, required this.onClose, this.idleTimeout = const Duration(seconds: 8)});

  final VoidCallback onClose;
  final Duration idleTimeout;

  @override
  ConsumerState<SlideshowPopup> createState() => _SlideshowPopupState();
}

class _SlideshowPopupState extends ConsumerState<SlideshowPopup> {
  final _scope = FocusScopeNode(debugLabel: 'slideshow popup');
  final _playNode = FocusNode(debugLabel: 'popup play');
  final _durationNode = FocusNode(debugLabel: 'popup duration');
  Timer? _idle;

  /// The music's position, read twice a second while shown.
  Timer? _ticker;
  bool _durationFocused = false;

  @override
  void initState() {
    super.initState();
    _durationNode.addListener(() {
      if (mounted && _durationFocused != _durationNode.hasFocus) {
        setState(() => _durationFocused = _durationNode.hasFocus);
      }
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && ref.read(musicStateProvider).active) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controls = _source() != SlideshowPopupSource.none;
      (controls ? _playNode : _durationNode).requestFocus();
    });
    _restartIdle();
  }

  @override
  void dispose() {
    _idle?.cancel();
    _ticker?.cancel();
    _scope.dispose();
    _playNode.dispose();
    _durationNode.dispose();
    super.dispose();
  }

  void _restartIdle() {
    _idle?.cancel();
    _idle = Timer(widget.idleTimeout, () {
      if (mounted) widget.onClose();
    });
  }

  RadioAudioHandler? get _handler {
    try {
      return ref.read(radioAudioHandlerProvider).value;
    } catch (_) {
      return null;
    }
  }

  SlideshowPopupSource _source() {
    final music = ref.read(musicStateProvider);
    final handler = _handler;
    return slideshowPopupSource(
      musicActive: music.active,
      musicPlaying: music.playing,
      radioHasStation: handler?.mediaItem.value != null,
      musicHoldsSession: handler?.hasGuest ?? false,
    );
  }

  /// A control: never throws (at worst nothing happens).
  Future<void> _run(Future<void> Function() action) async {
    _restartIdle();
    try {
      await action();
    } catch (e) {
      debugPrint('slideshow popup: $e');
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    _restartIdle();
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    // One row: ↑/↓ have nowhere to go (and mustn't leave the popup).
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // Rebuilt by the music's and the radio's changes.
    final music = ref.watch(musicStateProvider);
    final handler = ref.watch(radioAudioHandlerProvider).value;
    final interval = ref.watch(slideshowSettingsProvider.select((s) => s.intervalSeconds));
    return StreamBuilder<MediaItem?>(
      stream: handler?.mediaItem,
      initialData: handler?.mediaItem.value,
      builder: (context, itemSnapshot) => StreamBuilder<PlaybackState>(
        stream: handler?.playbackState,
        initialData: handler?.playbackState.value,
        builder: (context, stateSnapshot) {
          final item = itemSnapshot.data;
          final source = slideshowPopupSource(
            musicActive: music.active,
            musicPlaying: music.playing,
            radioHasStation: item != null,
            musicHoldsSession: handler?.hasGuest ?? false,
          );
          final radioPlaying = stateSnapshot.data?.playing ?? false;
          return FocusScope(
            node: _scope,
            onKeyEvent: _onKey,
            onFocusChange: (focused) {
              // The duration's list is open (its own route): no closing
              // meanwhile.
              if (focused) {
                _restartIdle();
              } else {
                _idle?.cancel();
              }
            },
            child: Container(
              constraints: const BoxConstraints(maxWidth: 760),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
              decoration: BoxDecoration(
                color: const Color(0xEE101416),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  switch (source) {
                    SlideshowPopupSource.music => _MusicInfo(position: _musicPosition()),
                    SlideshowPopupSource.radio => _RadioInfo(item: item!),
                    SlideshowPopupSource.none => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.music_off_outlined, color: Colors.white38, size: 36),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(l.picturesNothingPlaying,
                                  style: const TextStyle(color: Colors.white70, fontSize: 16)),
                            ),
                          ],
                        ),
                      ),
                  },
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      if (source != SlideshowPopupSource.none) ...[
                        MusicControlButton(
                          icon: Icons.skip_previous_rounded,
                          size: 48,
                          tooltip: source == SlideshowPopupSource.music ? l.musicPrevious : l.picturesPreviousStation,
                          onPressed: () => _run(() async {
                            if (source == SlideshowPopupSource.music) {
                              await ref.read(musicPlayerProvider).previous();
                            } else {
                              await handler?.skipToPrevious();
                            }
                          }),
                        ),
                        const SizedBox(width: 12),
                        MusicControlButton(
                          focusNode: _playNode,
                          primary: true,
                          size: 56,
                          icon: (source == SlideshowPopupSource.music ? music.playing : radioPlaying)
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          tooltip: (source == SlideshowPopupSource.music ? music.playing : radioPlaying)
                              ? l.musicPause
                              : l.musicPlay,
                          onPressed: () => _run(() async {
                            if (source == SlideshowPopupSource.music) {
                              await ref.read(musicPlayerProvider).togglePlayPause();
                            } else if (radioPlaying) {
                              await handler?.pause();
                            } else {
                              await handler?.play();
                            }
                          }),
                        ),
                        const SizedBox(width: 12),
                        MusicControlButton(
                          icon: Icons.skip_next_rounded,
                          size: 48,
                          tooltip: source == SlideshowPopupSource.music ? l.musicNext : l.picturesNextStation,
                          onPressed: () => _run(() async {
                            if (source == SlideshowPopupSource.music) {
                              await ref.read(musicPlayerProvider).next();
                            } else {
                              await handler?.skipToNext();
                            }
                          }),
                        ),
                      ],
                      const Spacer(),
                      Text(l.picturesDisplayDuration, style: const TextStyle(color: Colors.white60, fontSize: 15)),
                      const SizedBox(width: 10),
                      TvFocusHighlight(
                        focused: _durationFocused,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              focusNode: _durationNode,
                              value: SettingsRepository.slideshowIntervals.contains(interval)
                                  ? interval
                                  : SettingsRepository.defaultSlideshowInterval,
                              focusColor: Colors.transparent,
                              dropdownColor: const Color(0xFF1C2124),
                              borderRadius: BorderRadius.circular(10),
                              iconEnabledColor: brandGreen,
                              style: const TextStyle(color: Colors.white, fontSize: 17),
                              onTap: () => _idle?.cancel(),
                              items: [
                                for (final s in SettingsRepository.slideshowIntervals)
                                  DropdownMenuItem(value: s, child: Text(l.picturesIntervalSeconds(s))),
                              ],
                              onChanged: (v) {
                                _restartIdle();
                                if (v == null) return;
                                final notifier = ref.read(slideshowSettingsProvider.notifier);
                                final s = ref.read(slideshowSettingsProvider);
                                notifier.set(s.copyWith(intervalSeconds: v)).catchError(
                                      (Object e) => debugPrint('slideshow interval: $e'),
                                    );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(l.picturesPopupHint, style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Duration _musicPosition() {
    try {
      return ref.read(musicPlayerProvider).position;
    } catch (_) {
      return Duration.zero;
    }
  }
}

class _MusicInfo extends ConsumerWidget {
  const _MusicInfo({required this.position});

  final Duration position;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(musicStateProvider);
    final track = s.current;
    if (track == null) return const SizedBox.shrink();
    final preferTags = ref.watch(musicSettingsProvider.select((x) => x.preferTags));
    final display = MusicDisplay.of(track, s.tags, preferTags: preferTags);
    final duration = s.duration;
    final fraction =
        duration == null || duration <= Duration.zero ? 0.0 : position.inMilliseconds / duration.inMilliseconds;
    return Row(
      children: [
        MusicCover(bytes: s.tags?.cover, size: 72, radius: 10),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(display.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
              if (display.artist != null || display.album != null)
                Text(display.artist ?? display.album!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 15)),
              const SizedBox(height: 10),
              MusicProgressLine(value: fraction),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(formatMusicDuration(position), style: const TextStyle(color: Colors.white60, fontSize: 13)),
                  const Spacer(),
                  Text(formatMusicDuration(duration), style: const TextStyle(color: Colors.white60, fontSize: 13)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RadioInfo extends ConsumerWidget {
  const _RadioInfo({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final program = ref.watch(currentProgramNumberProvider);
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    final channel = program == null ? null : favorites.where((c) => c.programNumber == program).firstOrNull;
    final logoUrl = channel?.logoUrl ?? (item.artUri?.scheme.startsWith('http') ?? false ? item.artUri.toString() : null);
    final streamTitle = item.artist?.trim();
    return Row(
      children: [
        _RadioLogo(logoUrl: logoUrl, logoLocalPath: channel?.logoLocalPath),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
              if (streamTitle != null && streamTitle.isNotEmpty)
                Text(streamTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 15))
              else if (item.album != null)
                Text(item.album!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 15)),
            ],
          ),
        ),
      ],
    );
  }
}

class _RadioLogo extends StatelessWidget {
  const _RadioLogo({required this.logoUrl, required this.logoLocalPath});

  final String? logoUrl;
  final String? logoLocalPath;

  @override
  Widget build(BuildContext context) {
    const size = 72.0;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
      child: const Icon(Icons.radio, color: Colors.white38, size: 34),
    );
    final local = logoLocalPath;
    final url = logoUrl;
    Widget? image;
    if (local != null) {
      image = Image.file(File(local), width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
    } else if (url != null) {
      image = RetryingNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_) => placeholder,
        errorWidget: (_) => placeholder,
      );
    }
    return image == null ? placeholder : ClipRRect(borderRadius: BorderRadius.circular(10), child: image);
  }
}
