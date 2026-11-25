import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/tv_reminders.dart';
import 'package:home_system/features/tv/tv_reminder_dialog.dart';
import 'package:home_system/l10n/l10n.dart';

TvReminder _r(String channel, String title, DateTime begin) => TvReminder(
      serviceRef: '1:0:19:${channel.hashCode.toRadixString(16)}:0:0:0:0:0:0:',
      channelName: channel,
      title: title,
      begin: begin,
      end: begin.add(const Duration(minutes: 45)),
    );

void main() {
  final at2015 = DateTime(2026, 11, 25, 20, 15);
  final a = _r('ORF 1', 'Sendung A', at2015);
  final b = _r('ZDF', 'Sendung B', at2015);
  final later = _r('ARD', 'Tagesthemen', DateTime(2026, 11, 25, 22, 15));
  const lead = Duration(minutes: 2);

  test('due 2 minutes before; programmes starting together come together', () {
    final list = [later, b, a];
    expect(dueTvReminders(list, DateTime(2026, 11, 25, 20, 12, 59), lead), isEmpty);
    final due = dueTvReminders(list, DateTime(2026, 11, 25, 20, 13), lead);
    expect(due.map((r) => r.title).toSet(), {'Sendung A', 'Sendung B'});
    // Shown once.
    expect(dueTvReminders(list, DateTime(2026, 11, 25, 20, 14), lead, shown: {a.key, b.key}), isEmpty);
    expect(nextTvReminderAlarm(list, DateTime(2026, 11, 25, 19), lead), DateTime(2026, 11, 25, 20, 13));
    expect(nextTvReminderAlarm(list, DateTime(2026, 11, 25, 20, 14), lead, shown: {a.key, b.key}),
        DateTime(2026, 11, 25, 22, 13));
  });

  test('missed (app closed): still shown up to 5 minutes after the start, then dropped', () {
    expect(dueTvReminders([a], DateTime(2026, 11, 25, 20, 19), lead), [a]);
    expect(dueTvReminders([a], DateTime(2026, 11, 25, 20, 21), lead), isEmpty);
    expect(currentTvReminders([a, later], DateTime(2026, 11, 25, 21)), [later]);
  });

  test('the same programme is one reminder; JSON round trip', () {
    final again = _r('ORF 1', 'Sendung A (neu)', at2015);
    expect(again, a);
    final upper = TvReminder(serviceRef: a.serviceRef.toUpperCase(), channelName: '', title: '', begin: at2015, end: at2015);
    expect(upper.key, a.key);
    final back = TvReminder.fromJson(a.toJson())!;
    expect((back.title, back.channelName, back.begin, back.end), (a.title, a.channelName, a.begin, a.end));
    expect(TvReminder.fromJson({'ref': 1}), isNull);
  });

  group('dialog', () {
    Future<TvReminder?> open(WidgetTester tester, List<TvReminder> reminders, Future<void> Function() act) async {
      TvReminder? result;
      var closed = false;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: const [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showTvReminderDialog(context, reminders, countdown: const Duration(seconds: 3));
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      // Not pumpAndSettle: the bar keeps animating (and would run out).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await act();
      expect(closed, isTrue, reason: 'dialog closed');
      return result;
    }

    testWidgets('one reminder: switches by itself when the bar has run', (tester) async {
      final result = await open(tester, [a], () async {
        expect(find.text('Ihre Erinnerungen'), findsOneWidget);
        expect(find.text('Sendung A'), findsOneWidget);
        expect(find.textContaining('ORF 1'), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      });
      expect(result, a);
    });

    testWidgets('one reminder: Abbrechen and Back don\'t switch, "Jetzt umschalten" does', (tester) async {
      expect(
        await open(tester, [a], () async {
          await tester.tap(find.text('Abbrechen'));
          await tester.pumpAndSettle();
        }),
        isNull,
      );
      expect(
        await open(tester, [a], () async {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }),
        isNull,
      );
      expect(
        await open(tester, [a], () async {
          await tester.tap(find.text('Jetzt umschalten'));
          await tester.pumpAndSettle();
        }),
        a,
      );
    });

    testWidgets('several at once: no countdown, OK picks one', (tester) async {
      final result = await open(tester, [a, b], () async {
        expect(find.text('Jetzt umschalten'), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        // No switching by itself.
        await tester.pump(const Duration(seconds: 5));
        expect(find.text('Sendung B'), findsOneWidget);
        await tester.tap(find.text('Sendung B'));
        await tester.pumpAndSettle();
      });
      expect(result, b);
    });
  });
}
