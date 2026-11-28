import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/services/enigma2_recordings.dart';
import '../../data/services/enigma2_service.dart';
import '../../l10n/l10n.dart';
import 'tv_recording_providers.dart';
import 'tv_reminder_providers.dart';
import 'tv_widgets.dart';

/// The red of a recording (dot in the guide, the record entries).
const tvRecordRed = Color(0xFFE53935);

/// The small red dot of a programme the receiver records.
class TvRecordDot extends StatelessWidget {
  const TvRecordDot({super.key, this.size = 12});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(color: tvRecordRed, shape: BoxShape.circle),
      );
}

/// "Sa 28.11. 20:15 – 21:45".
String tvProgrammeWhen(BuildContext context, DateTime begin, DateTime end) {
  final l = context.l10n;
  final day = DateFormat('E ${l.tvDayMonthPattern}', l.localeName).format(begin);
  return '$day  ${hhmm(begin)} – ${hhmm(end)}';
}

/// The receiver's timers as they are now (null: not to be had).
Future<List<E2Timer>?> _timers(WidgetRef ref) async {
  try {
    return await ref.read(enigma2RecordingsProvider)?.timers();
  } catch (_) {
    return null;
  }
}

void _say(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
}

/// OK on a programme (long OK in the guide, OK in a channel's list): remind
/// of it, record it (by the receiver), or take either back.
Future<void> showTvProgrammeActions(
  BuildContext context,
  WidgetRef ref, {
  required E2Channel channel,
  required E2Event event,
}) async {
  final l = context.l10n;
  final running = event.runsAt(DateTime.now());
  final reminded = ref.read(tvRemindersProvider.notifier).isSet(channel.ref, event.begin);
  final timers = await _timers(ref);
  if (!context.mounted) return;
  final timer = timers == null ? null : timerForEvent(timers, channel.ref, event);
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      backgroundColor: const Color(0xFF111A16),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(event.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text('${channel.name}  ·  ${tvProgrammeWhen(context, event.begin, event.end)}',
              style: const TextStyle(color: brandGreen, fontSize: 15)),
        ],
      ),
      children: [
        if (!running)
          TvRow(
            autofocus: true,
            onTap: () => Navigator.of(context).pop('remind'),
            child: ListTile(
              leading: Icon(reminded ? Icons.notifications_off_outlined : Icons.notifications_active, color: brandGreen),
              title: Text(reminded ? l.tvRecReminderOff : l.tvRecReminderOn),
            ),
          ),
        TvRow(
          autofocus: running,
          onTap: () => Navigator.of(context).pop(timer == null ? 'record' : 'unrecord'),
          child: ListTile(
            leading: Icon(timer == null ? Icons.fiber_manual_record : Icons.delete_outline, color: tvRecordRed),
            title: Text(timer == null ? (running ? l.tvRecRecordRest : l.tvRecRecord) : l.tvRecDeleteTimer),
            subtitle: timer != null && timer.running ? Text(l.tvRecRunningNow) : null,
          ),
        ),
        TvRow(
          onTap: () => Navigator.of(context).pop(),
          child: ListTile(leading: const Icon(Icons.close), title: Text(l.commonCancel)),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return;
  switch (choice) {
    case 'remind':
      final notifier = ref.read(tvRemindersProvider.notifier);
      if (!await notifier.toggle(event, channel)) {
        if (context.mounted) _say(context, l.tvReminderAlreadyRunning);
        return;
      }
      if (context.mounted) {
        _say(context, reminded ? l.tvReminderRemoved(event.title) : l.tvReminderSet(event.title, hhmm(event.begin), channel.name));
      }
    case 'record':
      await recordTvProgramme(context, ref, channel: channel, event: event);
    case 'unrecord':
      if (timer != null) await deleteTvTimer(context, ref, timer, ask: false);
  }
}

/// The record key on a programme: record it - or, if it's being recorded,
/// ask whether to delete the timer.
Future<void> toggleTvRecording(
  BuildContext context,
  WidgetRef ref, {
  required E2Channel channel,
  required E2Event event,
}) async {
  final timers = await _timers(ref);
  if (!context.mounted) return;
  final timer = timers == null ? null : timerForEvent(timers, channel.ref, event);
  if (timer != null) return deleteTvTimer(context, ref, timer, ask: true);
  await recordTvProgramme(context, ref, channel: channel, event: event);
}

/// A timer on the receiver for [event] - its answer as a note, a refusal
/// (a conflict: one cable, the tuner taken) in a dialog with the timers in
/// the way.
Future<void> recordTvProgramme(
  BuildContext context,
  WidgetRef ref, {
  required E2Channel channel,
  required E2Event event,
}) async {
  final l = context.l10n;
  final api = ref.read(enigma2RecordingsProvider);
  if (api == null) return _say(context, l.tvErrorNoReceiver);
  if (!event.end.isAfter(DateTime.now())) return _say(context, l.tvRecEnded);
  final E2TimerResult result;
  try {
    result = await api.record(channel.ref, event);
  } catch (e) {
    if (context.mounted) _say(context, l.tvRecFailed('$e'));
    return;
  }
  ref.invalidate(tvTimersProvider);
  if (!context.mounted) return;
  if (result.ok) {
    return _say(context, l.tvRecSet(event.title, hhmm(event.begin), channel.name));
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF111A16),
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amber),
          const SizedBox(width: 10),
          Expanded(child: Text(result.conflicts.isEmpty ? l.tvRecRefused : l.tvRecConflict)),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (result.message.isNotEmpty)
              Text(l.tvRecReceiverSays(result.message), style: const TextStyle(color: Colors.white70, fontSize: 16)),
            if (result.conflicts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l.tvRecConflictsWith, style: const TextStyle(color: Colors.white60, fontSize: 15)),
              const SizedBox(height: 6),
              for (final t in result.conflicts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      const TvRecordDot(size: 10),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${t.name}  ·  ${t.serviceName}  ·  ${tvProgrammeWhen(context, t.begin, t.end)}',
                          style: const TextStyle(color: Colors.white, fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text(l.tvRecConflictHint, style: const TextStyle(color: Colors.white54, fontSize: 14)),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(l.commonOk)),
      ],
    ),
  );
}

/// Deletes [timer] on the receiver ([ask]: after asking).
Future<void> deleteTvTimer(BuildContext context, WidgetRef ref, E2Timer timer, {required bool ask}) async {
  final l = context.l10n;
  final api = ref.read(enigma2RecordingsProvider);
  if (api == null) return _say(context, l.tvErrorNoReceiver);
  if (ask) {
    final ok = await confirmTvRecordingAction(
      context,
      title: l.tvRecDeleteTimerQuestion,
      text: '${timer.name}\n${timer.serviceName}  ·  ${tvProgrammeWhen(context, timer.begin, timer.end)}',
      confirm: l.tvRecDeleteTimer,
    );
    if (!ok || !context.mounted) return;
  }
  try {
    final result = await api.deleteTimer(timer);
    ref.invalidate(tvTimersProvider);
    if (!context.mounted) return;
    _say(context, result.ok ? l.tvRecTimerDeleted(timer.name) : l.tvRecFailed(result.message));
  } catch (e) {
    if (context.mounted) _say(context, l.tvRecFailed('$e'));
  }
}

/// "Wirklich ...?" - true on yes. The safe answer has the focus.
Future<bool> confirmTvRecordingAction(
  BuildContext context, {
  required String title,
  required String text,
  required String confirm,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111A16),
        title: Text(title),
        content: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 17)),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: tvRecordRed),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    ) ??
    false;
