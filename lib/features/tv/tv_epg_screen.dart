import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/services/enigma2_service.dart';
import '../../l10n/l10n.dart';
import '../../data/services/tv_reminders.dart' show serviceKeyOf;
import 'tv_providers.dart';
import 'tv_reminder_providers.dart';
import 'tv_widgets.dart';

/// A channel's programme guide (from the receiver's EPG, usually a week):
/// the programmes by day on the left, the focused one's description on the
/// right. Back closes it.
class TvEpgScreen extends ConsumerStatefulWidget {
  const TvEpgScreen({super.key, required this.channel});

  final E2Channel channel;

  @override
  ConsumerState<TvEpgScreen> createState() => _TvEpgScreenState();
}

class _TvEpgScreenState extends ConsumerState<TvEpgScreen> {
  E2Event? _focused;

  /// OK on a coming programme: reminder on/off (see TvReminderDialog).
  Future<void> _toggleReminder(E2Event e) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(tvRemindersProvider.notifier);
    final wasSet = notifier.isSet(widget.channel.ref, e.begin);
    final ok = await notifier.toggle(e, widget.channel);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(!ok
            ? l.tvReminderAlreadyRunning
            : wasSet
                ? l.tvReminderRemoved(e.title)
                : l.tvReminderSet(e.title, hhmm(e.begin), widget.channel.name)),
      ));
  }

  String _day(DateTime t) {
    final l10n = context.l10n;
    final today = DateTime.now();
    final d = DateTime(t.year, t.month, t.day);
    final diff = d.difference(DateTime(today.year, today.month, today.day)).inDays;
    final date = DateFormat(l10n.tvDayMonthPattern, l10n.localeName).format(t);
    return switch (diff) {
      0 => '${l10n.tvToday}, $date',
      1 => '${l10n.tvTomorrow}, $date',
      _ => '${DateFormat.EEEE(l10n.localeName).format(t)}, $date',
    };
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(enigma2ConfigProvider);
    final events = ref.watch(tvChannelEpgProvider(widget.channel.ref));
    final reminders = {for (final r in ref.watch(tvRemindersProvider)) r.key};
    bool reminded(E2Event e) => reminders.contains('${serviceKeyOf(widget.channel.ref)}|${e.begin.millisecondsSinceEpoch}');
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Radio's top bar.
            Container(
              color: Colors.black.withValues(alpha: 0.7),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    if (config != null) Picon(config: config, channel: widget.channel, width: 64, height: 40),
                    const SizedBox(width: 12),
                    Text('${widget.channel.number} · ${widget.channel.name}',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 12),
                    Text(context.l10n.tvSchedule,
                        style: const TextStyle(color: brandGreen, fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    const TvClock(),
                  ],
                ),
              ),
            ),
            Expanded(
              child: events.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: Colors.white70))),
                data: (list) {
                  final upcoming = list.where((e) => e.end.isAfter(now)).toList();
                  if (upcoming.isEmpty) {
                    return Center(
                      child: Text(context.l10n.tvScheduleNoInfo,
                          style: const TextStyle(color: Colors.white70, fontSize: 18)),
                    );
                  }
                  final shown = _focused ?? upcoming.first;
                  final rows = <Widget>[];
                  String? lastDay;
                  for (final (i, e) in upcoming.indexed) {
                    final day = _day(e.begin);
                    if (day != lastDay) {
                      lastDay = day;
                      rows.add(Padding(
                        padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                        child: Text(day, style: const TextStyle(color: brandGreen, fontSize: 16, fontWeight: FontWeight.w600)),
                      ));
                    }
                    final running = e.runsAt(now);
                    rows.add(Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: TvRow(
                        autofocus: i == 0,
                        selected: running,
                        onFocused: () => setState(() => _focused = e),
                        onTap: () {
                          setState(() => _focused = e);
                          if (!running) unawaited(_toggleReminder(e));
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 70,
                                child: Text(hhmm(e.begin), style: const TextStyle(color: Colors.white70, fontSize: 17)),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(e.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                                    if (running) ...[const SizedBox(height: 6), EventProgress(event: e)],
                                  ],
                                ),
                              ),
                              if (reminded(e)) const Icon(Icons.notifications_active, color: brandGreen),
                            ],
                          ),
                        ),
                      ),
                    ));
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 620,
                        child: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: rows),
                      ),
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.fromLTRB(0, 20, 24, 24),
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0E151A),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(shown.title,
                                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                Text(
                                  '${_day(shown.begin)}  ${hhmm(shown.begin)} – ${hhmm(shown.end)}  ·  '
                                  '${context.l10n.tvMinutes(shown.duration.inMinutes)}',
                                  style: const TextStyle(color: brandGreen, fontSize: 16),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  shown.runsAt(now)
                                      ? context.l10n.tvReminderRunningHint
                                      : reminded(shown)
                                          ? context.l10n.tvReminderIsSetHint
                                          : context.l10n.tvReminderSetHint,
                                  style: const TextStyle(color: Colors.white54, fontSize: 15),
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  shown.description.isEmpty ? context.l10n.tvNoDescription : shown.description,
                                  style: const TextStyle(color: Colors.white70, fontSize: 18, height: 1.4),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
