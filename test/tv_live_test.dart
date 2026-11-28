import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/loading_wave.dart';
import 'package:home_system/data/services/enigma2_service.dart';
import 'package:home_system/features/tv/tv_progress_bar.dart';
import 'package:home_system/features/tv/tv_providers.dart' show nowNextRefreshIn;
import 'package:home_system/features/tv/tv_tuning_overlay.dart';

void main() {
  group('programme progress colour', () {
    test('green at the start, yellow halfway, red at the end', () {
      final start = programmeProgressColor(0);
      final half = programmeProgressColor(0.5);
      final end = programmeProgressColor(1);
      expect(start.g, greaterThan(start.r));
      expect(half.r, greaterThan(0.8));
      expect(half.g, greaterThan(0.6));
      expect(end.r, greaterThan(end.g * 2));
    });

    test('runs steadily from green to red', () {
      double redShare(Color c) => c.r / (c.r + c.g);
      var last = -1.0;
      for (var i = 0; i <= 20; i++) {
        final share = redShare(programmeProgressColor(i / 20));
        expect(share, greaterThan(last));
        last = share;
      }
    });

    test('out of range and NaN are clamped', () {
      expect(programmeProgressColor(-1), programmeProgressColor(0));
      expect(programmeProgressColor(3), programmeProgressColor(1));
      expect(programmeProgressColor(double.nan), programmeProgressColor(0));
    });

    testWidgets('the bar fills by the programme gone by', (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: ProgrammeProgressBar(progress: 0.25, width: 200, height: 4)),
      ));
      final fill = tester.getSize(find.byType(FractionallySizedBox));
      expect(fill.width, 50);
      expect(fill.height, 4);
    });
  });

  group('now and next refresh', () {
    final t = DateTime(2026, 11, 28, 20, 0);
    E2Event event(int beginMin, int minutes) => E2Event(
          serviceRef: '1:0:19:1:1:1:C00000:0:0:0:',
          title: 'x',
          begin: t.add(Duration(minutes: beginMin)),
          duration: Duration(minutes: minutes),
        );

    test('shortly after the first running programme ends', () {
      expect(nowNextRefreshIn([event(-30, 31), event(1, 60), event(-10, 60)], t), const Duration(minutes: 1, seconds: 5));
    });

    test('at least 20 s, at most 3 minutes', () {
      final endingNow = E2Event(
        serviceRef: '1:0:19:1:1:1:C00000:0:0:0:',
        title: 'x',
        begin: t.subtract(const Duration(minutes: 30)),
        duration: const Duration(minutes: 30, seconds: 3),
      );
      expect(nowNextRefreshIn([endingNow], t), const Duration(seconds: 20));
      // Already over: doesn't count.
      expect(nowNextRefreshIn([event(-30, 30)], t), const Duration(minutes: 3));
      expect(nowNextRefreshIn([event(-5, 60)], t), const Duration(minutes: 3));
      expect(nowNextRefreshIn(const [], t), const Duration(minutes: 3));
    });
  });

  group('satellite signal', () {
    test('OpenWebif values while the receiver shows a channel', () {
      final s = parseE2Signal({
        'tunertype': 'DVB-S2',
        'tunernumber': 2,
        'snr': 85,
        'snr_db': '13.62',
        'agc': 99,
        'ber': 0,
        'inStandby': 'false',
      })!;
      expect(s.tuner, 2);
      expect(s.snrPercent, 85);
      expect(s.snrDb, closeTo(13.62, 0.001));
      expect(s.agcPercent, 99);
      expect(s.ber, 0);
      expect(s.quality, '13.6 dB · 85 %');
    });

    test('standby (empty fields, even while streaming): none', () {
      expect(
        parseE2Signal({
          'tunertype': '',
          'tunernumber': '',
          'snr': '',
          'snr_db': '',
          'agc': '',
          'ber': '',
          'inStandby': 'true',
        }),
        isNull,
      );
    });

    test('no dB from the tuner: only the percentage', () {
      final s = parseE2Signal({'tunernumber': 0, 'snr': 70, 'snr_db': 70, 'agc': 50, 'ber': 12})!;
      expect(s.snrDb, isNull);
      expect(s.quality, '70 %');
    });

    test("the stream's tuner from /api/about", () {
      final about = {
        'info': {
          'streams': [
            {'ref': '1:0:19:1:1:1:C00000:0:0:0:', 'tuner_number': 3},
            {'ref': '1:0:19:3402:3ED:1:C00000:0:0:0:', 'name': 'oe24.TV HD', 'tuner_number': 0},
          ],
        },
      };
      expect(streamTunerOf(about, '1:0:19:3402:3ED:1:C00000:0:0:0'), 0);
      expect(streamTunerOf(about, '1:0:19:1:1:1:C00000:0:0:0'), 3);
      expect(streamTunerOf(about, '1:0:19:2:2:1:C00000:0:0:0'), isNull);
      expect(streamTunerOf(const {'info': {}}, '1:0:19:1:1:1:C00000:0:0:0'), isNull);
    });
  });

  testWidgets('tuning animation: at once on a switch, faded out and gone at the picture', (tester) async {
    Widget overlay(bool visible) =>
        Directionality(textDirection: TextDirection.ltr, child: TvTuningOverlay(visible: visible));
    await tester.pumpWidget(overlay(false));
    expect(find.byType(LoadingWave), findsNothing);
    await tester.pumpWidget(overlay(true));
    expect(find.byType(LoadingWave), findsOneWidget);
    final fade = tester.widget<FadeTransition>(find.byType(FadeTransition));
    expect(fade.opacity.value, 1);
    await tester.pumpWidget(overlay(false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(LoadingWave), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(LoadingWave), findsNothing);
  });
}
