import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/services/enigma2_service.dart';
import '../settings/tv_settings_screen.dart';
import 'tv_epg_screen.dart';
import 'tv_providers.dart';
import 'tv_widgets.dart';

/// Home TV: live TV from the Enigma2 receiver (GigaBlue etc.), full screen.
/// One of Home Media's parts, opened from the launcher - Back or Home leave
/// it, which stops the picture.
///
/// Remote, as on a TV set: up/down (and channel keys, ⏪/⏩) change the
/// channel, digits pick one by number, OK opens the channel list (left/
/// right there switch the bouquet), ☰ or Info opens the programme guide of
/// the channel, play/pause stops and resumes.
class TvScreen extends ConsumerStatefulWidget {
  const TvScreen({super.key});

  @override
  ConsumerState<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends ConsumerState<TvScreen> {
  final _focus = FocusNode(debugLabel: 'tv');
  VideoPlayerController? _player;
  E2Channel? _current;
  String? _error;
  bool _loading = false;
  bool _stopped = false;
  int _generation = 0;

  bool _infoVisible = false;
  Timer? _infoTimer;
  bool _listVisible = false;

  String _digits = '';
  Timer? _digitTimer;

  /// "Als Nächstes": the programme announced, and which one was already.
  E2Event? _nextUp;
  String? _nextUpShownFor;
  Timer? _nextUpCheck;
  Timer? _nextUpHide;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startLastChannel());
    _nextUpCheck = Timer.periodic(const Duration(seconds: 15), (_) => _checkNextUp());
  }

  @override
  void dispose() {
    _generation++;
    _player?.dispose();
    _infoTimer?.cancel();
    _digitTimer?.cancel();
    _nextUpCheck?.cancel();
    _nextUpHide?.cancel();
    _focus.dispose();
    super.dispose();
  }

  Enigma2Config? get _config => ref.read(enigma2ConfigProvider);

  Future<void> _startLastChannel() async {
    final config = _config;
    if (config == null || !config.configured) return;
    final List<E2Channel> channels;
    try {
      channels = await ref.read(tvChannelsProvider.future);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted || channels.isEmpty) return;
    final repo = ref.read(settingsRepositoryProvider);
    // A fixed start channel (Einstellungen → Home TV), else the last one.
    final fixed = await repo.getTvStartChannel();
    final last = await repo.getTvLastChannel();
    final channel = channels.where((c) => c.ref == fixed).firstOrNull ??
        channels.where((c) => c.ref == last).firstOrNull ??
        channels.first;
    await _tune(channel);
  }

  Future<void> _tune(E2Channel channel) async {
    final config = _config;
    if (config == null) return;
    final generation = ++_generation;
    final old = _player;
    setState(() {
      _current = channel;
      _player = null;
      _loading = true;
      _error = null;
      _stopped = false;
    });
    _showInfo();
    _checkNextUp();
    await old?.dispose();
    unawaited(ref.read(settingsRepositoryProvider).setTvLastChannel(channel.ref));
    final player = VideoPlayerController.networkUrl(config.streamUri(channel.ref), httpHeaders: config.authHeaders);
    try {
      await player.initialize();
      if (!mounted || generation != _generation) {
        await player.dispose();
        return;
      }
      await player.play();
      setState(() {
        _player = player;
        _loading = false;
      });
    } catch (e) {
      await player.dispose();
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Kein Bild von „${channel.name}“ - ist der Receiver an und ein Tuner frei?';
      });
    }
  }

  Future<void> _step(int direction) async {
    final channels = ref.read(tvChannelsProvider).value ?? const [];
    if (channels.isEmpty) return;
    final i = channels.indexWhere((c) => c.ref == _current?.ref);
    await _tune(channels[(i + direction) % channels.length]);
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (_stopped || player == null) {
      final c = _current;
      if (c != null) await _tune(c);
      return;
    }
    _generation++;
    setState(() {
      _player = null;
      _stopped = true;
    });
    await player.dispose();
  }

  /// Shortly before the next programme on this channel starts (Einstellungen
  /// → Home TV → "Als Nächstes"), a note says what's coming - once per
  /// programme, for the set time.
  void _checkNextUp() {
    final settings = ref.read(tvNextUpProvider);
    final channel = _current;
    if (!mounted || !settings.enabled || channel == null) return;
    final epg = ref.read(tvNowNextProvider).value ?? const {};
    final now = DateTime.now();
    final next = nowNextFor(epg, channel, now).next;
    if (next == null) return;
    final key = '${channel.ref}@${next.begin.millisecondsSinceEpoch}';
    final until = next.begin.difference(now);
    if (key == _nextUpShownFor || until.isNegative || until > Duration(minutes: settings.leadMinutes)) return;
    _nextUpShownFor = key;
    _nextUpHide?.cancel();
    setState(() => _nextUp = next);
    _nextUpHide = Timer(Duration(seconds: settings.showSeconds), () {
      if (mounted) setState(() => _nextUp = null);
    });
  }

  void _showInfo() {
    _infoTimer?.cancel();
    setState(() => _infoVisible = true);
    _infoTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _infoVisible = false);
    });
  }

  void _digit(int d) {
    _digitTimer?.cancel();
    setState(() => _digits = '$_digits$d');
    final channels = ref.read(tvChannelsProvider).value ?? const [];
    final number = int.parse(_digits);
    // As soon as no other channel number can start with these digits.
    final done = _digits.length >= channels.length.toString().length;
    void go() {
      final c = channels.where((c) => c.number == number).firstOrNull;
      setState(() => _digits = '');
      if (c != null) _tune(c);
    }

    done ? go() : _digitTimer = Timer(const Duration(milliseconds: 1500), go);
  }

  void _openEpg() {
    final c = _current;
    if (c == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TvEpgScreen(channel: c)));
  }

  static final _digitKeys = {
    for (var i = 0; i <= 9; i++) ...{
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i): i,
      LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + i): i,
    },
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.gameButtonA) {
      setState(() => _listVisible = true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.info || key == LogicalKeyboardKey.guide) {
      _openEpg();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      _showInfo();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause || key == LogicalKeyboardKey.mediaPlay || key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    final d = _digitKeys[key];
    if (d != null) {
      _digit(d);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onBack() {
    if (_listVisible) {
      setState(() => _listVisible = false);
      _focus.requestFocus();
    } else if (_infoVisible) {
      _infoTimer?.cancel();
      setState(() => _infoVisible = false);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Set up (or changed) while Home TV is open: start with it.
    ref.listen(enigma2ConfigProvider, (previous, next) {
      if (next == null || !next.configured) return;
      if (previous?.host != next.host || previous?.webPort != next.webPort || previous?.streamPort != next.streamPort) {
        ref.invalidate(tvBouquetsProvider);
        _current = null;
        _startLastChannel();
      }
    });
    final config = ref.watch(enigma2ConfigProvider);
    final player = _player;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: config == null
            ? const Center(child: CircularProgressIndicator())
            : !config.configured
                ? const _NotSetUp()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Focus(
                        focusNode: _focus,
                        autofocus: true,
                        onKeyEvent: _onKey,
                        child: Center(
                          child: player != null && player.value.isInitialized
                              ? AspectRatio(aspectRatio: player.value.aspectRatio, child: VideoPlayer(player))
                              : const SizedBox.shrink(),
                        ),
                      ),
                      if (_loading) const Center(child: CircularProgressIndicator()),
                      if ((_error != null || _stopped) && !_listVisible)
                        Center(
                          child: _Message(
                            icon: _stopped ? Icons.pause_circle_outline : Icons.signal_wifi_bad,
                            text: _stopped ? 'Angehalten - ⏯ spielt weiter' : _error!,
                          ),
                        ),
                      if (_digits.isNotEmpty)
                        Positioned(
                          top: 32,
                          right: 40,
                          child: Text(_digits,
                              style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 12)])),
                        ),
                      if (_nextUp != null && !_listVisible)
                        Positioned(top: 32, right: 40, child: _NextUpNote(event: _nextUp!)),
                      if ((_infoVisible || _error != null) && _current != null && !_listVisible)
                        Positioned(left: 0, right: 0, bottom: 0, child: _InfoBanner(config: config, channel: _current!)),
                      if (_listVisible)
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: 0,
                          width: 620,
                          child: _ChannelList(
                            config: config,
                            current: _current,
                            onPick: (c) {
                              setState(() => _listVisible = false);
                              _focus.requestFocus();
                              if (c.ref != _current?.ref) _tune(c);
                            },
                            onEpg: (c) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TvEpgScreen(channel: c))),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 36),
          const SizedBox(width: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 20)),
          ),
        ],
      ),
    );
  }
}

/// "Als Nächstes": the next programme, a few minutes before it starts.
class _NextUpNote extends StatelessWidget {
  const _NextUpNote({required this.event});

  final E2Event event;

  @override
  Widget build(BuildContext context) {
    final minutes = event.begin.difference(DateTime.now()).inMinutes;
    final when = minutes <= 0 ? 'gleich' : 'in $minutes Min.';
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.fromLTRB(20, 14, 22, 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(14),
        border: const Border(left: BorderSide(color: brandGreen, width: 5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Als Nächstes · $when', style: const TextStyle(color: brandGreen, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('${hhmm(event.begin)}  ${event.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          if (event.shortDescription.trim().isNotEmpty)
            Text(event.shortDescription.trim(),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 15)),
        ],
      ),
    );
  }
}

/// Without a receiver: what Home TV is and the way to set it up.
class _NotSetUp extends StatelessWidget {
  const _NotSetUp();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset('assets/icon/home_tv_logo.png', width: 140, height: 140),
            ),
            const SizedBox(height: 24),
            const Text('Home TV', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text(
              'Fernsehen vom eigenen Sat-Receiver: Senderlisten, Senderlogos und Programmführer kommen direkt vom '
              'Enigma2-Receiver (z. B. GigaBlue, VU+, Dreambox mit OpenWebif) im Heimnetz.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              autofocus: true,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TvSettingsScreen())),
              icon: const Icon(Icons.settings_input_antenna),
              label: const Text('Receiver einrichten'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Channel, now and next - shown on every channel change, like Home Radio's
/// "now playing" banner at the bottom.
class _InfoBanner extends ConsumerWidget {
  const _InfoBanner({required this.config, required this.channel});

  final Enigma2Config config;
  final E2Channel channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final epg = ref.watch(tvNowNextProvider).value ?? const {};
    final nn = nowNextFor(epg, channel, DateTime.now());
    final now = nn.now, next = nn.next;
    return Container(
      color: Colors.black.withValues(alpha: 0.75),
      padding: const EdgeInsets.fromLTRB(40, 20, 40, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Picon(config: config, channel: channel, width: 150, height: 90),
          const SizedBox(width: 28),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${channel.number} · ${channel.name}',
                    style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                if (now != null) ...[
                  Text('${hhmm(now.begin)} – ${hhmm(now.end)}   ${now.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 20)),
                  const SizedBox(height: 8),
                  EventProgress(event: now, width: 520),
                ] else
                  const Text('Keine Programminformation', style: TextStyle(color: Colors.white54, fontSize: 18)),
                if (next != null) ...[
                  const SizedBox(height: 8),
                  Text('Danach ${hhmm(next.begin)}   ${next.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 17)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const TvClock(style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('OK Senderliste  ·  ☰ Programm', style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The bouquet's channels on the right, as Home Radio's station list: picon,
/// number, name, what's on now. Left/right switch the bouquet, OK tunes,
/// ☰ opens the channel's programme guide.
class _ChannelList extends ConsumerStatefulWidget {
  const _ChannelList({required this.config, required this.current, required this.onPick, required this.onEpg});

  final Enigma2Config config;
  final E2Channel? current;
  final ValueChanged<E2Channel> onPick;
  final ValueChanged<E2Channel> onEpg;

  @override
  ConsumerState<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends ConsumerState<_ChannelList> {
  E2Channel? _focused;

  /// The tuned channel's row - takes the focus when the list opens (the
  /// player had it, so the rows' autofocus wouldn't).
  final _startNode = FocusNode(debugLabel: 'channel list');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusStart());
  }

  @override
  void dispose() {
    _startNode.dispose();
    super.dispose();
  }

  void _focusStart() {
    if (!mounted) return;
    if (_startNode.context != null) {
      _startNode.requestFocus();
    } else {
      // Channels still loading - once they're there.
      Future.delayed(const Duration(milliseconds: 200), _focusStart);
    }
  }

  Future<void> _switchBouquet(int direction) async {
    final bouquets = ref.read(tvBouquetsProvider).value ?? const [];
    final current = ref.read(tvCurrentBouquetProvider).value;
    if (bouquets.length < 2 || current == null) return;
    final i = bouquets.indexWhere((b) => b.ref == current.ref);
    // The focused row goes with the old list - keep the focus in the list.
    _startNode.requestFocus();
    await ref.read(tvBouquetProvider.notifier).set(bouquets[(i + direction) % bouquets.length].ref);
    await ref.read(tvChannelsProvider.future);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusStart());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      _switchBouquet(key == LogicalKeyboardKey.arrowRight ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.info || key == LogicalKeyboardKey.guide) {
      final c = _focused ?? widget.current;
      if (c != null) widget.onEpg(c);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final channels = ref.watch(tvChannelsProvider);
    final bouquet = ref.watch(tvCurrentBouquetProvider).value;
    final epg = ref.watch(tvNowNextProvider).value ?? const {};
    final now = DateTime.now();
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Container(
        color: Colors.black.withValues(alpha: 0.88),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/icon/home_tv_logo.png', width: 36, height: 36),
                ),
                const SizedBox(width: 10),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Home TV', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('Powered by Jay', style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600)),
                  ],
                ),
                const Spacer(),
                const TvClock(),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.chevron_left, color: Colors.white38),
                Expanded(
                  child: Text(
                    bouquet?.name ?? 'Senderliste',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: brandGreen, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white38),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: channels.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: Colors.white70))),
                data: (list) => list.isEmpty
                    ? const Center(child: Text('Keine Sender in dieser Liste', style: TextStyle(color: Colors.white70)))
                    : ListView.builder(
                        itemCount: list.length,
                        padding: const EdgeInsets.only(bottom: 20),
                        itemBuilder: (context, i) {
                          final c = list[i];
                          final event = nowNextFor(epg, c, now).now;
                          final isCurrent = c.ref == widget.current?.ref;
                          final start = isCurrent || (i == 0 && !list.any((x) => x.ref == widget.current?.ref));
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: TvRow(
                              focusNode: start ? _startNode : null,
                              selected: isCurrent,
                              onFocused: () => _focused = c,
                              onTap: () => widget.onPick(c),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 40,
                                      child: Text('${c.number}', style: const TextStyle(color: Colors.white54, fontSize: 16)),
                                    ),
                                    Picon(config: widget.config, channel: c, width: 76, height: 46),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(c.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                                          if (event != null) ...[
                                            const SizedBox(height: 2),
                                            Text('${hhmm(event.begin)}  ${event.title}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(color: Colors.white60, fontSize: 14)),
                                            const SizedBox(height: 5),
                                            EventProgress(event: event),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
