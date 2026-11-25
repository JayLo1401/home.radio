import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/services/enigma2_service.dart';
import '../../l10n/l10n.dart';
import 'tv_epg_screen.dart';
import 'tv_providers.dart';
import 'tv_reminder_providers.dart';
import '../../data/services/tv_reminders.dart' show serviceKeyOf;
import 'tv_widgets.dart';

/// TV's programme guide as on a TV set: time across, the channels of
/// the list down - around the one on air -, a box per programme.
///
/// Remote: left/right the previous/next programme, up/down the channel
/// above/below at the same time, channel +/- (page up/down) a page of
/// channels, ⏪/⏩ three hours, OK switches to the channel, the options key
/// lists all programmes of the channel, Back closes. The mouse: a click
/// marks a programme, a second one switches, the wheel moves through the
/// channels.
///
/// Closes with the channel to switch to (or nothing).
class TvGuideScreen extends ConsumerStatefulWidget {
  const TvGuideScreen({super.key, this.start});

  /// The channel the guide starts on.
  final E2Channel? start;

  @override
  ConsumerState<TvGuideScreen> createState() => _TvGuideScreenState();
}

class _TvGuideScreenState extends ConsumerState<TvGuideScreen> {
  /// What's shown across: two and a half hours.
  static const _span = Duration(minutes: 150);
  static const _rowHeight = 72.0;
  static const _channelColumn = 280.0;

  /// Loaded in steps of this much.
  static const _chunk = Duration(hours: 6);

  final _focus = FocusNode(debugLabel: 'guide');

  /// Programmes per channel (serviceKey), by start.
  final _events = <String, List<E2Event>>{};
  DateTime? _loadedUntil;
  bool _loadingMore = false;
  String? _error;

  int _row = 0;
  int _firstRow = 0;
  int _visibleRows = 6;
  late DateTime _cursor = DateTime.now();
  late DateTime _windowStart = _floor30(DateTime.now());
  Timer? _clock;

  static DateTime _floor30(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute < 30 ? 0 : 30);

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _clock?.cancel();
    _focus.dispose();
    super.dispose();
  }

  List<E2Channel> get _channels => ref.read(tvChannelsProvider).value ?? const [];

  Future<void> _start() async {
    final channels = await ref.read(tvChannelsProvider.future);
    if (!mounted) return;
    final i = channels.indexWhere((c) => c.ref == widget.start?.ref);
    setState(() => _row = i < 0 ? 0 : i);
    await _load(_floor30(DateTime.now()));
    // The channel on air in the middle of the rows.
    if (mounted) {
      setState(() {
        _firstRow = _row - _visibleRows ~/ 2;
        _follow();
      });
    }
  }

  /// The programmes of every channel from [from] on, [_chunk] long.
  Future<void> _load(DateTime from) async {
    final service = ref.read(enigma2ServiceProvider);
    final bouquet = await ref.read(tvCurrentBouquetProvider.future);
    if (service == null || bouquet == null) return;
    _loadingMore = true;
    try {
      final events = await service.epgMulti(bouquet.ref, from, _chunk);
      if (!mounted) return;
      setState(() {
        for (final e in events) {
          final list = _events[serviceKey(e.serviceRef)] ??= [];
          if (!list.any((x) => x.begin == e.begin)) list.add(e);
        }
        for (final list in _events.values) {
          list.sort((a, b) => a.begin.compareTo(b.begin));
        }
        _loadedUntil = from.add(_chunk);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _loadingMore = false;
    }
  }

  /// Loads further ahead once the window comes near the end of what's there.
  void _loadAheadIfNeeded() {
    final until = _loadedUntil;
    if (until == null || _loadingMore) return;
    if (_windowStart.add(_span).add(const Duration(hours: 1)).isAfter(until)) unawaited(_load(until));
  }

  List<E2Event> _eventsOf(E2Channel c) => _events[serviceKey(c.ref)] ?? const [];

  /// The programme of [c] at the cursor - else the next one after it, else
  /// the last before.
  E2Event? _eventAt(E2Channel c, DateTime t) {
    final list = _eventsOf(c).where((e) => e.end.isAfter(DateTime.now())).toList();
    return list.where((e) => e.runsAt(t)).firstOrNull ??
        list.where((e) => e.begin.isAfter(t)).firstOrNull ??
        list.lastOrNull;
  }

  E2Event? get _focused {
    final channels = _channels;
    if (_row >= channels.length) return null;
    return _eventAt(channels[_row], _cursor);
  }

  /// Keeps the focused programme and row on screen.
  void _follow() {
    final now = DateTime.now();
    final earliest = _floor30(now);
    final e = _focused;
    final t = e == null ? _cursor : (e.begin.isBefore(now) ? now : e.begin);
    if (t.isBefore(_windowStart)) _windowStart = _floor30(t);
    if (t.isAfter(_windowStart.add(_span - const Duration(minutes: 30)))) {
      _windowStart = _floor30(t).subtract(const Duration(minutes: 30));
    }
    if (_windowStart.isBefore(earliest)) _windowStart = earliest;
    // The focused row not at the very edge.
    if (_row < _firstRow + 1) _firstRow = _row - 1;
    if (_row > _firstRow + _visibleRows - 2) _firstRow = _row - _visibleRows + 2;
    _firstRow = _firstRow.clamp(0, (_channels.length - _visibleRows).clamp(0, 1 << 20));
    _loadAheadIfNeeded();
  }

  void _moveRow(int by) {
    final n = _channels.length;
    if (n == 0) return;
    setState(() {
      _row = (_row + by).clamp(0, n - 1);
      _follow();
    });
  }

  void _moveProgramme(int direction) {
    final channels = _channels;
    if (_row >= channels.length) return;
    final e = _focused;
    final now = DateTime.now();
    final list = _eventsOf(channels[_row]).where((x) => x.end.isAfter(now)).toList();
    setState(() {
      if (e == null) {
        _cursor = _cursor.add(Duration(minutes: 30 * direction));
      } else if (direction > 0) {
        final next = list.where((x) => !x.begin.isBefore(e.end)).firstOrNull;
        if (next != null) _cursor = next.begin;
      } else {
        final prev = list.where((x) => !x.end.isAfter(e.begin)).lastOrNull;
        if (prev != null) _cursor = prev.begin.isBefore(now) ? now : prev.begin;
      }
      if (_cursor.isBefore(now)) _cursor = now;
      _follow();
    });
  }

  void _shiftTime(Duration by) {
    setState(() {
      final now = DateTime.now();
      _cursor = _cursor.add(by);
      if (_cursor.isBefore(now)) _cursor = now;
      _windowStart = _floor30(_cursor);
      _follow();
    });
  }

  void _pick() {
    final channels = _channels;
    if (_row < channels.length) Navigator.of(context).pop(channels[_row]);
  }

  /// Holding OK: reminder for the marked programme on/off (a short press
  /// still switches).
  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };
  static const _hold = Duration(milliseconds: 600);
  DateTime? _okDownAt;

  /// Reminder for [e] on [channel] on/off, with a short note.
  Future<void> _toggleReminder(E2Channel channel, E2Event? e) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
    if (e == null) return;
    final notifier = ref.read(tvRemindersProvider.notifier);
    final wasSet = notifier.isSet(channel.ref, e.begin);
    if (!await notifier.toggle(e, channel)) {
      say(l.tvReminderAlreadyRunning);
      return;
    }
    say(wasSet ? l.tvReminderRemoved(e.title) : l.tvReminderSet(e.title, hhmm(e.begin), channel.name));
  }

  void _toggleFocusedReminder() {
    final channels = _channels;
    if (_row < channels.length) unawaited(_toggleReminder(channels[_row], _focused));
  }

  void _openChannelList() {
    final channels = _channels;
    if (_row >= channels.length) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TvEpgScreen(channel: channels[_row])));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_okKeys.contains(key)) {
      // Decided on release: short = switch, held = reminder.
      if (event is KeyDownEvent) {
        _okDownAt = DateTime.now();
      } else if (event is KeyUpEvent) {
        final down = _okDownAt;
        _okDownAt = null;
        if (down != null) DateTime.now().difference(down) >= _hold ? _toggleFocusedReminder() : _pick();
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = ref.read(remoteKeysProvider);
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveRow(-1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveRow(1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _moveProgramme(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _moveProgramme(1);
    } else if (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.channelUp) {
      _moveRow(-_visibleRows);
    } else if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.channelDown) {
      _moveRow(_visibleRows);
    } else if (key == LogicalKeyboardKey.mediaFastForward || key == LogicalKeyboardKey.mediaTrackNext) {
      _shiftTime(const Duration(hours: 3));
    } else if (key == LogicalKeyboardKey.mediaRewind || key == LogicalKeyboardKey.mediaTrackPrevious) {
      _shiftTime(const Duration(hours: -3));
    } else if (event is KeyDownEvent && keys.matches(RemoteAction.channelList, key)) {
      _pick();
    } else if (event is KeyDownEvent && keys.matches(RemoteAction.options, key)) {
      _openChannelList();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// The mouse: a click marks, a click on the marked programme switches.
  void _tapCell(int row, E2Event? e) {
    final now = DateTime.now();
    final t = e == null ? _cursor : (e.begin.isBefore(now) ? now : e.begin);
    if (row == _row && (e == null || _focused == e)) return _pick();
    setState(() {
      _row = row;
      _cursor = t;
      _follow();
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(enigma2ConfigProvider);
    final channels = ref.watch(tvChannelsProvider).value ?? const <E2Channel>[];
    final bouquet = ref.watch(tvCurrentBouquetProvider).value;
    final reminders = {for (final r in ref.watch(tvRemindersProvider)) r.key};
    bool reminded(E2Channel c, E2Event e) => reminders.contains('${serviceKeyOf(c.ref)}|${e.begin.millisecondsSinceEpoch}');
    final focused = _focused;
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopBar(title: bouquet?.name ?? context.l10n.tvGuide),
              Expanded(
                child: config == null || (_loadedUntil == null && _error == null)
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null && _events.isEmpty
                        ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70, fontSize: 18)))
                        : LayoutBuilder(builder: (context, size) {
                            final rows = ((size.maxHeight - 40) / _rowHeight).floor().clamp(1, 50);
                            if (rows != _visibleRows) {
                              _visibleRows = rows;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) setState(_follow);
                              });
                            }
                            final gridWidth = size.maxWidth - _channelColumn - 24;
                            final perMinute = gridWidth / _span.inMinutes;
                            return Listener(
                              onPointerSignal: (s) {
                                if (s is PointerScrollEvent) _moveRow(s.scrollDelta.dy > 0 ? 1 : -1);
                              },
                              child: Column(
                                children: [
                                  _TimeAxis(start: _windowStart, span: _span, perMinute: perMinute, left: _channelColumn),
                                  Expanded(
                                    child: Stack(
                                      children: [
                                        Column(
                                          children: [
                                            for (var r = _firstRow; r < channels.length && r < _firstRow + rows; r++)
                                              _GuideRow(
                                                config: config,
                                                channel: channels[r],
                                                events: _eventsOf(channels[r]),
                                                windowStart: _windowStart,
                                                span: _span,
                                                perMinute: perMinute,
                                                focusedRow: r == _row,
                                                focusedEvent: r == _row ? focused : null,
                                                onTap: (e) => _tapCell(r, e),
                                                onLongPress: (e) => unawaited(_toggleReminder(channels[r], e)),
                                                reminded: (e) => reminded(channels[r], e),
                                              ),
                                          ],
                                        ),
                                        // Now.
                                        if (DateTime.now().isAfter(_windowStart))
                                          Positioned(
                                            top: 0,
                                            bottom: 0,
                                            left: _channelColumn +
                                                DateTime.now().difference(_windowStart).inSeconds / 60 * perMinute,
                                            child: IgnorePointer(child: Container(width: 2, color: Colors.redAccent)),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
              ),
              _Details(
                event: focused,
                channel: _row < channels.length ? channels[_row] : null,
                reminded: focused != null && _row < channels.length && reminded(channels[_row], focused),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(remoteKeysProvider);
    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/icon/tv_logo.png', width: 36, height: 36),
            ),
            const SizedBox(width: 10),
            Text(context.l10n.tvGuide,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            Text(title, style: const TextStyle(color: brandGreen, fontSize: 16, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(
              // ‹‹ ›› rather than ⏪⏩, which Android draws as coloured emoji.
              context.l10n.tvGuideKeyHint(remoteKeyHint(keys, RemoteAction.options)),
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14),
            ),
            const SizedBox(width: 20),
            const TvClock(),
          ],
        ),
      ),
    );
  }
}

/// The times across the top, every half hour.
class _TimeAxis extends StatelessWidget {
  const _TimeAxis({required this.start, required this.span, required this.perMinute, required this.left});

  final DateTime start;
  final Duration span;
  final double perMinute;
  final double left;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final otherDay = start.day != today.day;
    return SizedBox(
      height: 40,
      child: Stack(
        children: [
          Positioned(
            left: 16,
            top: 10,
            child: Text(
              otherDay
                  ? DateFormat(context.l10n.tvDayMonthPattern, context.l10n.localeName).format(start)
                  : context.l10n.tvToday,
              style: const TextStyle(color: brandGreen, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          for (var m = 0; m < span.inMinutes; m += 30)
            Positioned(
              left: left + m * perMinute,
              top: 10,
              child: Text(hhmm(start.add(Duration(minutes: m))), style: const TextStyle(color: Colors.white70, fontSize: 16)),
            ),
        ],
      ),
    );
  }
}

/// One channel: picon and name, then its programmes as boxes.
class _GuideRow extends StatelessWidget {
  const _GuideRow({
    required this.config,
    required this.channel,
    required this.events,
    required this.windowStart,
    required this.span,
    required this.perMinute,
    required this.focusedRow,
    required this.focusedEvent,
    required this.onTap,
    required this.onLongPress,
    required this.reminded,
  });

  final ValueChanged<E2Event> onLongPress;
  final bool Function(E2Event e) reminded;
  final Enigma2Config config;
  final E2Channel channel;
  final List<E2Event> events;
  final DateTime windowStart;
  final Duration span;
  final double perMinute;
  final bool focusedRow;
  final E2Event? focusedEvent;
  final ValueChanged<E2Event?> onTap;

  @override
  Widget build(BuildContext context) {
    final windowEnd = windowStart.add(span);
    final now = DateTime.now();
    final shown = events.where((e) => e.end.isAfter(windowStart) && e.begin.isBefore(windowEnd)).toList();
    return SizedBox(
      height: _TvGuideScreenState._rowHeight,
      child: Row(
        children: [
          // The channel.
          Container(
            width: _TvGuideScreenState._channelColumn,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            color: focusedRow ? brandGreen.withValues(alpha: 0.18) : Colors.transparent,
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text('${channel.number}', style: const TextStyle(color: Colors.white54, fontSize: 15)),
                ),
                Picon(config: config, channel: channel, width: 72, height: 44),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(channel.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: focusedRow ? FontWeight.bold : FontWeight.normal,
                      )),
                ),
              ],
            ),
          ),
          // Its programmes.
          Expanded(
            child: Stack(
              children: [
                if (shown.isEmpty)
                  Positioned.fill(
                    child: _Cell(
                      title: context.l10n.tvNoProgramInfo,
                      subtitle: null,
                      focused: focusedRow && focusedEvent == null,
                      running: false,
                      onTap: () => onTap(null),
                    ),
                  ),
                for (final e in shown)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: _x(e.begin.isBefore(windowStart) ? windowStart : e.begin),
                    width: _x(e.end.isAfter(windowEnd) ? windowEnd : e.end) -
                        _x(e.begin.isBefore(windowStart) ? windowStart : e.begin),
                    child: _Cell(
                      title: e.title,
                      subtitle: '${hhmm(e.begin)} – ${hhmm(e.end)}',
                      focused: focusedRow && focusedEvent == e,
                      running: e.runsAt(now),
                      reminded: reminded(e),
                      onTap: () => onTap(e),
                      onLongPress: () => onLongPress(e),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 24),
        ],
      ),
    );
  }

  double _x(DateTime t) => t.difference(windowStart).inSeconds / 60 * perMinute;
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.title,
    required this.subtitle,
    required this.focused,
    required this.running,
    required this.onTap,
    this.reminded = false,
    this.onLongPress,
  });

  final bool reminded;
  final VoidCallback? onLongPress;
  final String title;
  final String? subtitle;
  final bool focused;
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: focused
              ? brandGreen.withValues(alpha: 0.85)
              : running
                  ? const Color(0xFF22313A)
                  : const Color(0xFF151D23),
          borderRadius: BorderRadius.circular(8),
          border: focused ? Border.all(color: Colors.white, width: 2) : null,
        ),
        child: ClipRect(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  if (reminded) ...[
                    Icon(Icons.notifications_active, size: 16, color: focused ? Colors.black : brandGreen),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          color: focused ? Colors.black : Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        )),
                  ),
                ],
              ),
              if (subtitle != null)
                Text(subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: TextStyle(color: focused ? Colors.black87 : Colors.white54, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The marked programme: title, time, what it's about.
class _Details extends StatelessWidget {
  const _Details({required this.event, required this.channel, this.reminded = false});

  final E2Event? event;
  final E2Channel? channel;
  final bool reminded;

  @override
  Widget build(BuildContext context) {
    final e = event;
    return Container(
      height: 150,
      color: Colors.black.withValues(alpha: 0.7),
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
      child: e == null
          ? Text(channel?.name ?? '', style: const TextStyle(color: Colors.white70, fontSize: 20))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (reminded) ...[
                      const Icon(Icons.notifications_active, color: brandGreen),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                    ),
                    Text(
                      '${channel?.name ?? ''}  ·  ${hhmm(e.begin)} – ${hhmm(e.end)}  ·  '
                      '${context.l10n.tvMinutes(e.duration.inMinutes)}',
                      style: const TextStyle(color: brandGreen, fontSize: 16),
                    ),
                  ],
                ),
                if (e.runsAt(DateTime.now())) ...[
                  const SizedBox(height: 6),
                  EventProgress(event: e, width: 400),
                ],
                const SizedBox(height: 8),
                Expanded(
                  child: Text(
                    e.description.isEmpty ? context.l10n.tvNoDescription : e.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.35),
                  ),
                ),
              ],
            ),
    );
  }
}
