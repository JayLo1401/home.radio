import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/db/database.dart';
import 'package:home_system/data/models/iptv_channel.dart';
import 'package:home_system/data/repositories/settings_repository.dart';
import 'package:home_system/data/services/backup_areas.dart';
import 'package:home_system/data/services/enigma2_service.dart';
import 'package:home_system/features/tv/tv_channel_info.dart';
import 'package:home_system/features/tv/tv_providers.dart';
import 'package:home_system/l10n/l10n.dart';

void main() {
  group('OK in the channel list', () {
    test('another channel: always switch to it', () {
      for (final withInfo in [true, false]) {
        for (final plays in [true, false]) {
          expect(channelListOk(withInfo: withInfo, isCurrent: false, plays: plays), TvListOk.tune);
        }
      }
    });

    test('the channel on air, list at the side: its info as before', () {
      expect(channelListOk(withInfo: false, isCurrent: true, plays: true), TvListOk.showInfo);
      expect(channelListOk(withInfo: false, isCurrent: true, plays: false), TvListOk.showInfo);
    });

    test('the channel on air, list with info: back to the picture, or tuned again without one', () {
      expect(channelListOk(withInfo: true, isCurrent: true, plays: true), TvListOk.close);
      expect(channelListOk(withInfo: true, isCurrent: true, plays: false), TvListOk.retune);
    });

    test('plays: a picture or on its way - not paused, failed or given up', () {
      expect(tvChannelPlays(hasPlayer: true, loading: false, stopped: false, failed: false), isTrue);
      expect(tvChannelPlays(hasPlayer: false, loading: true, stopped: false, failed: false), isTrue);
      expect(tvChannelPlays(hasPlayer: true, loading: false, stopped: true, failed: false), isFalse);
      // The stream lost / no picture: the error is set.
      expect(tvChannelPlays(hasPlayer: true, loading: false, stopped: false, failed: true), isFalse);
      expect(tvChannelPlays(hasPlayer: false, loading: false, stopped: false, failed: true), isFalse);
      expect(tvChannelPlays(hasPlayer: false, loading: false, stopped: false, failed: false), isFalse);
    });
  });

  group('layout: list in the middle, info right of it', () {
    test('wide screen: the list exactly in the middle', () {
      final at = channelListInfoLayout(1920);
      expect(at.listLeft + at.listWidth / 2, 960);
      expect(at.infoLeft, greaterThan(at.listLeft + at.listWidth));
      expect(at.infoLeft + at.infoWidth, lessThanOrEqualTo(1920));
      expect(at.infoWidth, greaterThanOrEqualTo(300));
    });

    test('smaller screens: the list moves left as far as the info needs', () {
      for (final w in [960.0, 1024.0, 1280.0, 1366.0]) {
        final at = channelListInfoLayout(w);
        expect(at.infoWidth, greaterThanOrEqualTo(300), reason: '$w');
        expect(at.listLeft, greaterThan(0), reason: '$w');
        expect(at.listLeft + at.listWidth / 2, lessThanOrEqualTo(w / 2), reason: '$w');
        expect(at.infoLeft + at.infoWidth, lessThanOrEqualTo(w), reason: '$w');
      }
    });

    test('too narrow for both: the list alone, all of it', () {
      final at = channelListInfoLayout(600);
      expect(at.infoWidth, 0);
      expect(at.listLeft, 0);
      expect(at.listWidth, 600);
    });
  });

  group('setting "Senderliste mit Info rechts"', () {
    test('on by default, kept, in the backup\'s TV area', () async {
      expect(TvViewSettings.defaults.listInfo, isTrue);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = SettingsRepository(db);
      expect((await repo.getTvView()).listInfo, isTrue);
      await repo.setTvView((await repo.getTvView()).copyWith(listInfo: false));
      expect(await db.getSetting('tv_list_info'), 'false');
      final view = await repo.getTvView();
      expect(view.listInfo, isFalse);
      expect(view.listText, TvViewSettings.defaults.listText);
      expect(view, TvViewSettings.defaults.copyWith(listInfo: false));
      await repo.setTvView(view.copyWith(listInfo: true));
      expect((await repo.getTvView()).listInfo, isTrue);
      expect(backupAreaOf('tv_list_info'), BackupArea.tv);
    });
  });

  group('info beside the list', () {
    const config = Enigma2Config(host: 'box');
    final t = DateTime.now();
    E2Channel channel(int n) => E2Channel(ref: '1:0:19:$n:1:1:C00000:0:0:0:', name: 'Sender $n', number: n, hasPicon: false);
    E2Event event(E2Channel c, String title, int fromMin, int minutes, {String desc = ''}) => E2Event(
          serviceRef: c.ref,
          title: title,
          begin: t.add(Duration(minutes: fromMin)),
          duration: Duration(minutes: minutes),
          shortDescription: desc,
        );
    final one = channel(1), two = channel(2), three = channel(3);
    final nowNext = {
      for (final c in [one, two, three])
        serviceKey(c.ref): [
          event(c, 'Jetzt ${c.number}', -10, 40, desc: 'Worum es geht ${c.number}'),
          event(c, 'Danach ${c.number}', 30, 30),
        ],
    };

    Future<void> pump(WidgetTester tester, Widget panel) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [tvNowNextProvider.overrideWith((ref) async => nowNext)],
        child: MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SizedBox(width: 600, height: 700, child: panel)),
        ),
      ));
      await tester.pump();
    }

    testWidgets('now with description and next from the bouquet at once, more once the marking rests',
        (tester) async {
      final asked = <String>[];
      Future<List<E2Event>> load(String ref) async {
        asked.add(ref);
        final c = [one, two, three].firstWhere((c) => c.ref == ref);
        return [
          event(c, 'Gestern', -300, 60),
          event(c, 'Jetzt ${c.number}', -10, 40, desc: 'Worum es geht ${c.number}'),
          event(c, 'Danach ${c.number}', 30, 30),
          event(c, 'Später ${c.number}', 60, 30),
          event(c, 'Nachts ${c.number}', 90, 30),
        ];
      }

      Widget panel(E2Channel c) => TvChannelInfoPanel(
            key: const ValueKey('panel'),
            config: config,
            channel: c,
            isCurrent: c == one,
            currentPlays: true,
            loadEpg: load,
          );

      await pump(tester, panel(one));
      expect(find.text('1 · Sender 1'), findsOneWidget);
      expect(find.text('Jetzt 1'), findsOneWidget);
      expect(find.text('Worum es geht 1'), findsOneWidget);
      expect(find.text('Danach 1'), findsOneWidget);
      expect(find.text('Läuft gerade – OK zurück zum Bild'), findsOneWidget);
      expect(find.text('Später 1'), findsNothing);

      // Scrolling past: nothing asked until the marking rests.
      await pump(tester, panel(two));
      await tester.pump(const Duration(milliseconds: 200));
      await pump(tester, panel(three));
      expect(find.text('Jetzt 3'), findsOneWidget);
      expect(find.text('Läuft gerade – OK zurück zum Bild'), findsNothing);
      expect(asked, isEmpty);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(asked, [three.ref]);
      expect(find.text('Später 3'), findsOneWidget);
      expect(find.text('Nachts 3'), findsOneWidget);
      expect(find.text('Gestern'), findsNothing);

      // Back on it: kept, not asked again.
      await pump(tester, panel(two));
      await pump(tester, panel(three));
      await tester.pump(const Duration(seconds: 1));
      expect(asked, [three.ref]);
    });

    testWidgets('the channel on air without a picture: OK tunes it again; a failed EPG is no problem', (tester) async {
      await pump(
        tester,
        TvChannelInfoPanel(
          config: config,
          channel: one,
          isCurrent: true,
          currentPlays: false,
          loadEpg: (_) async => throw Exception('receiver away'),
        ),
      );
      expect(find.text('Kein Bild – OK startet den Sender neu'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Jetzt 1'), findsOneWidget);
      expect(find.text('Danach 1'), findsOneWidget);
    });

    testWidgets('Internet-TV: what the channel is, no guide', (tester) async {
      const iptv = IptvChannel(
        id: 'Test.at',
        name: 'Testkanal',
        streams: [IptvStream(url: 'http://x/y.m3u8', geoBlocked: true)],
        country: 'AT',
      );
      await pump(
        tester,
        const TvChannelInfoPanel(config: config, iptv: iptv, iptvNumber: 4, isCurrent: false, currentPlays: true),
      );
      expect(find.text('4 · Testkanal'), findsOneWidget);
      expect(find.textContaining('Programmführer'), findsOneWidget);
      expect(find.byType(IptvChannelDetails), findsOneWidget);
    });
  });
}
