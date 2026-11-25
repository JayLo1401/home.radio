import 'package:flutter/foundation.dart';

/// A programme marked in the guide to be watched: shortly before it begins
/// a note asks to switch to it (see TvReminderDialog).
@immutable
class TvReminder {
  const TvReminder({
    required this.serviceRef,
    required this.channelName,
    required this.title,
    required this.begin,
    required this.end,
  });

  /// The channel (the receiver's service reference).
  final String serviceRef;
  final String channelName;
  final String title;
  final DateTime begin;
  final DateTime end;

  /// One per channel and start - marking the same programme again removes it.
  String get key => '${serviceKeyOf(serviceRef)}|${begin.millisecondsSinceEpoch}';

  Map<String, Object?> toJson() => {
        'ref': serviceRef,
        'channel': channelName,
        'title': title,
        'begin': begin.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
      };

  static TvReminder? fromJson(Object? json) {
    if (json is! Map) return null;
    final ref = json['ref'], channel = json['channel'], title = json['title'];
    final begin = json['begin'], end = json['end'];
    if (ref is! String || channel is! String || title is! String || begin is! int || end is! int) return null;
    return TvReminder(
      serviceRef: ref,
      channelName: channel,
      title: title,
      begin: DateTime.fromMillisecondsSinceEpoch(begin),
      end: DateTime.fromMillisecondsSinceEpoch(end),
    );
  }

  @override
  bool operator ==(Object other) => other is TvReminder && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The same channel in every list (as tv_providers' serviceKey: without
/// trailing colons, upper case).
String serviceKeyOf(String ref) => ref.replaceAll(RegExp(r':+$'), '').toUpperCase();

/// How long after its start a programme is still worth the note (the app
/// was closed, the box asleep).
const tvReminderGrace = Duration(minutes: 5);

/// Reminders worth keeping at [now]: not begun longer than [tvReminderGrace]
/// ago, by start.
List<TvReminder> currentTvReminders(Iterable<TvReminder> reminders, DateTime now) =>
    reminders.where((r) => r.begin.add(tvReminderGrace).isAfter(now)).toList()
      ..sort((a, b) => a.begin.compareTo(b.begin));

/// When the note for [r] shows: [lead] before it begins.
DateTime tvReminderAlarm(TvReminder r, Duration lead) => r.begin.subtract(lead);

/// The reminders due at [now] that weren't shown yet ([shown]: their keys),
/// together: all that begin in the same minute as the first due one. Empty
/// if none is due.
List<TvReminder> dueTvReminders(
  Iterable<TvReminder> reminders,
  DateTime now,
  Duration lead, {
  Set<String> shown = const {},
}) {
  final due = currentTvReminders(reminders, now)
      .where((r) => !shown.contains(r.key) && !tvReminderAlarm(r, lead).isAfter(now))
      .toList();
  if (due.isEmpty) return const [];
  final minute = _minute(due.first.begin);
  return due.where((r) => _minute(r.begin) == minute).toList();
}

/// When the next note is due after [now] (null: none) - for the timer.
DateTime? nextTvReminderAlarm(
  Iterable<TvReminder> reminders,
  DateTime now,
  Duration lead, {
  Set<String> shown = const {},
}) {
  DateTime? next;
  for (final r in currentTvReminders(reminders, now)) {
    if (shown.contains(r.key)) continue;
    final alarm = tvReminderAlarm(r, lead);
    if (next == null || alarm.isBefore(next)) next = alarm;
  }
  return next;
}

int _minute(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;
