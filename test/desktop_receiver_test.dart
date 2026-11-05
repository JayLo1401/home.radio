// Drives the desktop receiver (hrdab.dll / libhrdab.so) through the same
// DabRtlSdrService API the screens use, against a real rtl_tcp server.
// Skipped unless configured, e.g. on Windows:
//   $env:HRDAB_LIBRARY = "build\windows\x64\runner\Release\hrdab.dll"
//   $env:PATH = "build\windows\x64\runner\Release;$env:PATH"  # libusb-1.0.dll
//   $env:HRDAB_TEST_SERVER = "192.168.100.79:1234"
//   $env:HRDAB_TEST_FM_KHZ = "99900"; $env:HRDAB_TEST_NB_HZ = "118100000"
//   flutter test test/desktop_receiver_test.dart
@TestOn('windows || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/services/dab_rtlsdr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final server = Platform.environment['HRDAB_TEST_SERVER'];
  final skip = server == null || Platform.environment['HRDAB_LIBRARY'] == null
      ? 'set HRDAB_LIBRARY and HRDAB_TEST_SERVER to run'
      : false;
  final host = server?.split(':').first ?? '';
  final port = int.tryParse(server?.split(':').last ?? '') ?? 1234;
  final env = Platform.environment;

  late DabRtlSdrService rx;
  final events = <Map<String, dynamic>>[];

  setUpAll(() {
    if (skip != false) return;
    rx = DabRtlSdrService();
    rx.events.listen((e) {
      events.add(e);
      if (e['type'] != 'nbSpectrum' && e['type'] != 'rsErrors') {
        final s = '$e';
        // ignore: avoid_print
        print(s.length > 300 ? '${s.substring(0, 300)}...' : s);
      }
    });
  });

  Future<Map<String, dynamic>> waitFor(bool Function(Map<String, dynamic>) test, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    var seen = 0;
    while (DateTime.now().isBefore(deadline)) {
      for (; seen < events.length; seen++) {
        if (test(events[seen])) return events[seen];
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('event not seen');
  }

  test('setServer reaches rtl_tcp', () async {
    expect(await rx.setServer(host: host, port: port), isTrue);
  }, skip: skip);

  test('FM: status and RDS', () async {
    final khz = int.parse(env['HRDAB_TEST_FM_KHZ'] ?? '99900');
    events.clear();
    expect(await rx.fmPlay(khz), isTrue);
    final st = await waitFor((e) => e['type'] == 'fmStatus', const Duration(seconds: 10));
    expect(st['levelDb'], isA<double>());
    expect(st['snrDb'], isA<double>());
    final rds = await waitFor((e) => e['type'] == 'fmRds' && e['ps'] != null, const Duration(seconds: 20));
    expect(rds['freqKhz'], khz);
    await rx.fmStop();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('NB: status, activity and spectrum', () async {
    final hz = int.parse(env['HRDAB_TEST_NB_HZ'] ?? '118100000');
    events.clear();
    expect(
      await rx.nbStart(sampleRate: 1024000, centerHz: hz, channelsHz: [hz], freqHz: hz, mode: 'am', squelchDb: 10),
      isTrue,
    );
    final st = await waitFor((e) => e['type'] == 'nbStatus', const Duration(seconds: 10));
    expect(st['mode'], 'am');
    final sp = await waitFor((e) => e['type'] == 'nbSpectrum', const Duration(seconds: 10));
    expect((sp['binsDb'] as List).isNotEmpty, isTrue);
    expect(await rx.nbTune(freqHz: hz, mode: 'auto'), isTrue);
    await rx.nbStop();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('DAB: single-channel scan, then play the first service', () async {
    final khz = int.parse(env['HRDAB_TEST_DAB_KHZ'] ?? '222064');
    events.clear();
    await rx.scanBand3(onlyFreqKhz: khz);
    final done = await waitFor((e) => e['type'] == 'scanFinished', const Duration(seconds: 40));
    final locked = events.where((e) => e['type'] == 'channelLocked').toList();
    expect(done['foundCount'], locked.length);
    final services = locked.isEmpty ? const [] : locked.first['services'] as List;
    if (services.isEmpty || env['HRDAB_TEST_DAB_PLAY'] != '1') return;
    final sid = (services.first as Map)['serviceId'] as int;
    expect(await rx.playService(freqKhz: khz, serviceId: sid), isTrue);
    await Future<void>.delayed(const Duration(seconds: 10));
    await rx.stopPlayback();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
