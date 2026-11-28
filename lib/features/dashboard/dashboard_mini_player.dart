import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/music_providers.dart';
import '../../core/providers.dart';
import '../../core/retrying_network_image.dart';
import '../../core/system_providers.dart';
import '../../core/theme.dart';
import '../../data/models/music_track.dart';
import '../../data/repositories/settings_repository.dart' show DashboardPopupPosition;
import '../../l10n/l10n.dart';
import '../launcher/launcher_providers.dart' show RadioCommand, radioCommandProvider;
import '../music/music_widgets.dart';
import 'dashboard_mini_player_logic.dart';

/// "Unten Mitte" - a popup position for the settings.
String dashboardPopupPositionLabel(AppLocalizations l, DashboardPopupPosition position) => switch (position) {
      DashboardPopupPosition.bottomCenter => l.dashboardPopupBottomCenter,
      DashboardPopupPosition.bottomLeft => l.dashboardPopupBottomLeft,
      DashboardPopupPosition.bottomRight => l.dashboardPopupBottomRight,
      DashboardPopupPosition.topCenter => l.dashboardPopupTopCenter,
      DashboardPopupPosition.topLeft => l.dashboardPopupTopLeft,
      DashboardPopupPosition.topRight => l.dashboardPopupTopRight,
    };

/// The media session's item and state (radio, or Musik while it holds it).
final _sessionItemProvider = StreamProvider.autoDispose<MediaItem?>((ref) async* {
  final handler = await ref.watch(radioAudioHandlerProvider.future);
  yield* handler.mediaItem;
});

final _sessionStateProvider = StreamProvider.autoDispose<PlaybackState>((ref) async* {
  final handler = await ref.watch(radioAudioHandlerProvider.future);
  yield* handler.playbackState;
});

/// What plays now - for the popup and the media keys. Never throws.
MiniPlayerSource currentMiniPlayerSource(WidgetRef ref) {
  try {
    final handler = ref.read(radioAudioHandlerProvider).value;
    final state = handler?.playbackState.value;
    return miniPlayerSourceOf(
      musicLoaded: ref.read(musicPlayerProvider).state.value.active,
      sessionIsGuest: handler?.hasGuest ?? false,
      hasRadioItem: handler?.mediaItem.value != null,
      radioIsBusy: state != null && radioBusy(playing: state.playing, state: state.processingState),
    );
  } catch (e) {
    debugPrint('mini player: $e');
    return MiniPlayerSource.idle;
  }
}

/// Runs a control without letting an error through.
void _safely(String what, FutureOr<void> Function() action) {
  try {
    final result = action();
    if (result is Future<void>) unawaited(result.catchError((Object e) => debugPrint('mini player $what: $e')));
  } catch (e) {
    debugPrint('mini player $what: $e');
  }
}

/// The controls of the popup - also for the media keys over the
/// Haussteuerung. Music goes to Musik's player, the radio to Radio (its
/// screen stays open under everything).
class MiniPlayerControls {
  MiniPlayerControls(this.ref);

  final WidgetRef ref;

  bool get _radioPart => ref.read(systemPartsProvider).radio;

  void playPause() => _safely('play/pause', () {
        switch (currentMiniPlayerSource(ref)) {
          case MiniPlayerSource.music:
            return ref.read(musicPlayerProvider).togglePlayPause();
          case MiniPlayerSource.radio || MiniPlayerSource.idle:
            if (_radioPart) ref.read(radioCommandProvider.notifier).send(RadioCommand.togglePlayPause);
        }
      });

  void stop() => _safely('stop', () {
        switch (currentMiniPlayerSource(ref)) {
          case MiniPlayerSource.music:
            return ref.read(musicPlayerProvider).stop();
          case MiniPlayerSource.radio:
            ref.read(radioCommandProvider.notifier).send(RadioCommand.stop);
          case MiniPlayerSource.idle:
        }
      });

  void next() => _skip(1);

  void previous() => _skip(-1);

  void _skip(int direction) => _safely('skip', () async {
        switch (currentMiniPlayerSource(ref)) {
          case MiniPlayerSource.music:
            final player = ref.read(musicPlayerProvider);
            return direction > 0 ? player.next() : player.previous();
          case MiniPlayerSource.radio:
            // The next/previous station of the list Radio shows (favourites).
            final handler = await ref.read(radioAudioHandlerProvider.future);
            return direction > 0 ? handler.skipToNext() : handler.skipToPrevious();
          case MiniPlayerSource.idle:
        }
      });

  /// The remote's media keys (true = taken): without moving the focus.
  bool handleMediaKey(LogicalKeyboardKey key) {
    final source = currentMiniPlayerSource(ref);
    if (source == MiniPlayerSource.music) {
      // As everywhere else in the app (Stop pauses, the music stays loaded).
      try {
        return ref.read(musicPlayerProvider).handleMediaKey(key);
      } catch (e) {
        debugPrint('mini player key: $e');
        return true;
      }
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      playPause();
    } else if (key == LogicalKeyboardKey.mediaPlay) {
      if (source == MiniPlayerSource.idle) playPause();
    } else if (key == LogicalKeyboardKey.mediaPause || key == LogicalKeyboardKey.mediaStop) {
      stop();
    } else if (key == LogicalKeyboardKey.mediaTrackNext) {
      next();
    } else if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      previous();
    } else {
      return false;
    }
    return true;
  }
}

/// The slim playback popup over the Haussteuerung: a translucent pill with
/// Home, and while radio or music plays the cover/station logo, what plays
/// and previous / play-pause / stop / next. Idle it shrinks to Home and a
/// small play button.
///
/// Remote: [DashboardScreen] puts the focus in ([focusIn]); Left/Right move
/// between the buttons, OK presses, the arrow towards the dashboard
/// ([atTop]: Down, else Up) calls [onExit]. Touch works as usual.
class DashboardMiniPlayer extends ConsumerStatefulWidget {
  const DashboardMiniPlayer({
    super.key,
    required this.atTop,
    required this.onHome,
    required this.onExit,
    this.onFocusChange,
    this.hint,
  });

  final bool atTop;
  final VoidCallback onHome;

  /// The focus goes back to the dashboard.
  final VoidCallback onExit;
  final ValueChanged<bool>? onFocusChange;

  /// A one-time note how the remote reaches the popup, shown next to it.
  final String? hint;

  @override
  ConsumerState<DashboardMiniPlayer> createState() => DashboardMiniPlayerState();
}

class DashboardMiniPlayerState extends ConsumerState<DashboardMiniPlayer> {
  final _group = FocusNode(debugLabel: 'miniPlayer', canRequestFocus: false, skipTraversal: true);
  final _home = FocusNode(debugLabel: 'miniPlayerHome');
  final _previous = FocusNode(debugLabel: 'miniPlayerPrevious');
  final _play = FocusNode(debugLabel: 'miniPlayerPlay');
  final _stop = FocusNode(debugLabel: 'miniPlayerStop');
  final _next = FocusNode(debugLabel: 'miniPlayerNext');
  Timer? _ticker;

  /// The buttons shown, left to right (see [build]).
  List<FocusNode> _order = const [];

  /// Whether a button of the popup has the focus.
  bool get hasFocus => _group.hasFocus;

  /// The focus into the popup: on play/pause, else on Home.
  void focusIn() {
    final target = _order.contains(_play) ? _play : _home;
    target.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    // The music's progress line moves on.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      try {
        if (ref.read(musicStateProvider).playing && (ModalRoute.of(context)?.isCurrent ?? true)) setState(() {});
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final node in [_group, _home, _previous, _play, _stop, _next]) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final back = widget.atTop ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.arrowUp;
    final away = widget.atTop ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.arrowDown;
    if (key == back) {
      widget.onExit();
      return KeyEventResult.handled;
    }
    if (key == away) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      final index = _order.indexWhere((n) => n.hasFocus);
      final next = index + (key == LogicalKeyboardKey.arrowRight ? 1 : -1);
      if (index >= 0 && next >= 0 && next < _order.length) _order[next].requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final controls = MiniPlayerControls(ref);
    // Rebuilds on every change of the session, the music and the favourites.
    final item = ref.watch(_sessionItemProvider).value;
    final session = ref.watch(_sessionStateProvider).value;
    final music = ref.watch(musicStateProvider);
    final handler = ref.watch(radioAudioHandlerProvider).value;
    final radioPart = ref.watch(systemPartsProvider.select((p) => p.radio));
    final source = miniPlayerSourceOf(
      musicLoaded: music.active,
      sessionIsGuest: handler?.hasGuest ?? false,
      hasRadioItem: item != null,
      radioIsBusy: session != null && radioBusy(playing: session.playing, state: session.processingState),
    );

    final Widget? info;
    final bool playing;
    double? progress;
    switch (source) {
      case MiniPlayerSource.music:
        final track = music.current!;
        final preferTags = ref.watch(musicSettingsProvider.select((s) => s.preferTags));
        final display = MusicDisplay.of(track, music.tags, preferTags: preferTags);
        info = _Info(
          art: MusicCover(bytes: music.tags?.cover, size: 36, radius: 8),
          title: display.title,
          subtitle: display.artist ?? display.album ?? l.musicTitle,
        );
        playing = music.playing;
        final duration = music.duration;
        if (duration != null && duration.inMilliseconds > 0) {
          try {
            progress = (ref.read(musicPlayerProvider).position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
          } catch (_) {}
        }
      case MiniPlayerSource.radio:
        final favorites = ref.watch(favoritesStreamProvider).value ?? const [];
        final channel = favorites.where((c) => '${c.programNumber}' == item!.id).firstOrNull;
        final artist = item!.artist?.trim();
        info = _Info(
          art: _StationLogo(
            localPath: channel?.logoLocalPath,
            url: channel?.logoUrl ?? item.artUri?.toString(),
          ),
          title: item.title,
          subtitle: artist == null || artist.isEmpty ? (item.album ?? '') : artist,
        );
        playing = session?.playing ?? false;
      case MiniPlayerSource.idle:
        info = null;
        playing = false;
    }

    final buttons = <(FocusNode, IconData, String, VoidCallback, bool)>[
      (_home, Icons.home_rounded, l.dashboardPopupHome, widget.onHome, false),
      if (info != null) ...[
        (_previous, Icons.skip_previous_rounded, l.dashboardPopupPrevious, controls.previous, false),
        (
          _play,
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          playing ? l.dashboardPopupPause : l.dashboardPopupPlay,
          controls.playPause,
          true,
        ),
        (_stop, Icons.stop_rounded, l.dashboardPopupStop, controls.stop, false),
        (_next, Icons.skip_next_rounded, l.dashboardPopupNext, controls.next, false),
      ] else if (radioPart)
        (_play, Icons.play_arrow_rounded, l.dashboardPopupPlay, controls.playPause, true),
    ];
    _order = [for (final b in buttons) b.$1];
    // A button that went away (idle again) leaves the focus on Home.
    if (_group.hasFocus && !_order.any((n) => n.hasFocus)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _group.hasFocus && !_order.any((n) => n.hasFocus)) _home.requestFocus();
      });
    }
    Widget button((FocusNode, IconData, String, VoidCallback, bool) b) =>
        _PillButton(focusNode: b.$1, icon: b.$2, tooltip: b.$3, onTap: b.$4, accent: b.$5);

    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    button(buttons.first),
                    if (info != null) ...[
                      const SizedBox(width: 6),
                      Flexible(child: info),
                      const SizedBox(width: 6),
                    ],
                    for (final b in buttons.skip(1)) button(b),
                  ],
                ),
              ),
            ),
            if (progress != null)
              Positioned(
                left: 24,
                right: 24,
                bottom: 2,
                child: MusicProgressLine(value: progress, height: 2),
              ),
          ],
        ),
      ),
    );

    final hint = widget.hint;
    return Focus(
      focusNode: _group,
      onKeyEvent: _onKey,
      onFocusChange: widget.onFocusChange,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        verticalDirection: widget.atTop ? VerticalDirection.up : VerticalDirection.down,
        children: [
          if (hint != null) ...[
            _Hint(text: hint),
            const SizedBox(height: 6),
          ],
          AnimatedSize(duration: const Duration(milliseconds: 180), alignment: Alignment.center, child: pill),
        ],
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.art, required this.title, required this.subtitle});

  final Widget art;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        art,
        const SizedBox(width: 10),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, height: 1.2)),
                if (subtitle.isNotEmpty)
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60, fontSize: 12.5, height: 1.2)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StationLogo extends StatelessWidget {
  const _StationLogo({this.localPath, this.url});

  final String? localPath;
  final String? url;

  @override
  Widget build(BuildContext context) {
    const size = 36.0;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
      child: const Icon(Icons.radio, color: Colors.white38, size: 20),
    );
    final Widget image;
    if (localPath case final path?) {
      image = Image.file(File(path),
          width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
    } else if (url case final url? when url.startsWith('http')) {
      image = RetryingNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_) => placeholder,
        errorWidget: (_) => placeholder,
      );
    } else {
      return placeholder;
    }
    return ClipRRect(borderRadius: BorderRadius.circular(8), child: image);
  }
}

/// A round button of the pill with the app's focus frame.
class _PillButton extends StatefulWidget {
  const _PillButton({
    required this.focusNode,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.accent = false,
  });

  final FocusNode focusNode;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Play/pause: a little bigger and in the brand colour.
  final bool accent;

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(22),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            focusNode: widget.focusNode,
            customBorder: const CircleBorder(),
            focusColor: Colors.transparent,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onTap,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(
                widget.icon,
                size: widget.accent ? 28 : 24,
                color: widget.accent ? musicLime : Colors.white70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The one-time remote note next to the pill.
class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 14)),
        ),
      ),
    );
  }
}
