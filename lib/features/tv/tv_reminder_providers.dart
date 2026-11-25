import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dashboard_providers.dart' show displayServiceProvider;
import '../../core/music_providers.dart' show musicPlayerProvider;
import '../../core/providers.dart';
import '../../core/system_providers.dart';
import '../../data/services/display_service.dart';
import '../../data/services/enigma2_service.dart';
import '../../data/services/tv_reminders.dart';
import '../launcher/launcher_navigation.dart' show showLauncherWith;
import '../launcher/launcher_providers.dart' show RadioCommand, appNavigatorKey, radioCommandProvider;
import 'tv_reminder_dialog.dart';
import 'tv_screen.dart';

/// The programmes marked in the guide (kept in the settings, past ones
/// dropped).
class TvRemindersNotifier extends Notifier<List<TvReminder>> {
  @override
  List<TvReminder> build() {
    ref.read(settingsRepositoryProvider).getTvReminders().then((v) => state = currentTvReminders(v, DateTime.now()));
    return const [];
  }

  bool isSet(String serviceRef, DateTime begin) {
    final key = TvReminder(serviceRef: serviceRef, channelName: '', title: '', begin: begin, end: begin).key;
    return state.any((r) => r.key == key);
  }

  /// Marks [event] on [channel] - or unmarks it if it was. False for a
  /// programme that has begun already (nothing to remind of).
  Future<bool> toggle(E2Event event, E2Channel channel) async {
    if (!event.begin.isAfter(DateTime.now())) return false;
    final reminder = TvReminder(
      serviceRef: channel.ref,
      channelName: channel.name,
      title: event.title,
      begin: event.begin,
      end: event.end,
    );
    final rest = state.where((r) => r.key != reminder.key).toList();
    final next = rest.length == state.length ? [...rest, reminder] : rest;
    await _save(next);
    return true;
  }

  /// Done (shown) - out of the list.
  Future<void> remove(Iterable<TvReminder> done) async {
    final keys = {for (final r in done) r.key};
    await _save(state.where((r) => !keys.contains(r.key)).toList());
  }

  Future<void> _save(List<TvReminder> list) async {
    state = currentTvReminders(list, DateTime.now());
    await ref.read(settingsRepositoryProvider).setTvReminders(state);
  }
}

final tvRemindersProvider = NotifierProvider<TvRemindersNotifier, List<TvReminder>>(TvRemindersNotifier.new);

/// Minutes before a marked programme the note shows (Einstellungen → TV).
class TvReminderLeadNotifier extends Notifier<int> {
  @override
  int build() {
    ref.read(settingsRepositoryProvider).getTvReminderLead().then((v) => state = v);
    return 2;
  }

  Future<void> set(int minutes) async {
    state = minutes;
    await ref.read(settingsRepositoryProvider).setTvReminderLead(minutes);
  }
}

final tvReminderLeadProvider = NotifierProvider<TvReminderLeadNotifier, int>(TvReminderLeadNotifier.new);

/// "Switch to this channel" for an open TV (from a reminder) - the counter
/// makes the same channel twice still a change.
class TvZapRequestNotifier extends Notifier<(String, int)?> {
  @override
  (String, int)? build() => null;

  void zap(String serviceRef) => state = (serviceRef, (state?.$2 ?? 0) + 1);
}

final tvZapRequestProvider = NotifierProvider<TvZapRequestNotifier, (String, int)?>(TvZapRequestNotifier.new);

/// Whether TV is open (TvScreen sets it) - a reminder then switches there.
class TvOpenNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool open) => state = open;
}

final tvOpenProvider = NotifierProvider<TvOpenNotifier, bool>(TvOpenNotifier.new);

/// Shows the notes of the marked programmes on time (app.dart watches it):
/// a timer to the next one, the note over whatever is open, and the
/// switch to the chosen channel - TV opens if it isn't.
final tvReminderControllerProvider = Provider<void>((ref) {
  final reminders = ref.watch(tvRemindersProvider);
  final lead = Duration(minutes: ref.watch(tvReminderLeadProvider));
  final tvOn = ref.watch(systemPartsProvider.select((p) => p.tv));
  if (!tvOn) return;
  final shown = ref.read(_shownProvider);
  Timer? timer;

  Future<void> fire() async {
    final due = dueTvReminders(ref.read(tvRemindersProvider), DateTime.now(), lead, shown: shown);
    if (due.isEmpty) return;
    shown.addAll(due.map((r) => r.key));
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    // The app behind another one (Netflix ...): to the front first.
    if (DisplayService.supported && WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      await ref.read(displayServiceProvider).bringToFront();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    final dialogContext = appNavigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final chosen = await showTvReminderDialog(dialogContext, due);
    unawaited(ref.read(tvRemindersProvider.notifier).remove(due));
    if (chosen != null) await _switchTo(ref, chosen);
  }

  void schedule() {
    timer?.cancel();
    final next = nextTvReminderAlarm(ref.read(tvRemindersProvider), DateTime.now(), lead, shown: shown);
    if (next == null) return;
    final wait = next.difference(DateTime.now());
    timer = Timer(wait.isNegative ? Duration.zero : wait + const Duration(milliseconds: 200), () async {
      try {
        await fire();
      } catch (e) {
        debugPrint('TV reminders: $e');
      }
      schedule();
    });
  }

  if (reminders.isNotEmpty) schedule();
  ref.onDispose(() => timer?.cancel());
});

/// The keys of the notes shown in this run (not shown twice when the list
/// changes meanwhile).
final _shownProvider = Provider<Set<String>>((ref) => <String>{});

/// To the reminder's channel: an open TV switches, else TV opens over the
/// launcher with it (radio and music pause, as from the TV tile).
Future<void> _switchTo(Ref ref, TvReminder reminder) async {
  if (ref.read(tvOpenProvider)) {
    ref.read(tvZapRequestProvider.notifier).zap(reminder.serviceRef);
    return;
  }
  showLauncherWith(ref.read);
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
  try {
    await ref.read(musicPlayerProvider).pauseForApp();
  } catch (_) {}
  unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => TvScreen(startServiceRef: reminder.serviceRef))));
}
