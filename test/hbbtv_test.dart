import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:home_system/data/services/hbbtv_ait.dart';
import 'package:home_system/data/services/hbbtv_service.dart';

/// TS packets (PAT, PMT, AIT PIDs only) recorded from the receiver's stream
/// (Astra 19.2° E, November 2026), one packet per line as hex.
List<Uint8List> _packets(String name) => File('test/fixtures/hbbtv/$name.hex')
    .readAsLinesSync()
    .where((l) => l.trim().isNotEmpty)
    .map((l) => Uint8List.fromList([for (var i = 0; i < l.length; i += 2) int.parse(l.substring(i, i + 2), radix: 16)]))
    .toList();

Uint8List _join(List<Uint8List> packets) => Uint8List.fromList([for (final p in packets) ...p]);

void main() {
  group('DvbTriplet', () {
    test('from a service reference', () {
      final t = DvbTriplet.fromServiceRef('1:0:19:283D:3FB:1:C00000:0:0:0:')!;
      expect(t.sid, 0x283D);
      expect(t.tsid, 0x3FB);
      expect(t.onid, 1);
      expect(DvbTriplet.fromServiceRef('4097:0:1:0:0:0:0:0:0:0:http%3a//x'), isNull);
    });
  });

  group('AitScanner', () {
    test('Das Erste HD: AIT over several packets, ARD start app', () {
      final scanner = AitScanner(serviceId: 0x283D);
      expect(scanner.add(_join(_packets('daserste_psi'))), AitScanState.found);
      expect(scanner.apps.length, greaterThan(3));
      final start = pickStartApp(scanner.apps)!;
      expect(start.autostart, isTrue);
      expect(start.url, 'http://itv.ard.de/ardstart/index.html');
      expect(start.name, 'HBBTV-Start-DSMCC+Web');
      expect(start.dvbId, '13.1');
      expect(scanner.apps.map((a) => a.url), contains('http://tv.ardmediathek.de/index.html'));
    });

    test('ORF1 HD (encrypted channel - PSI comes clear)', () {
      final scanner = AitScanner(serviceId: 0x132F);
      expect(scanner.add(_join(_packets('orf1_psi'))), AitScanState.found);
      expect(pickStartApp(scanner.apps)!.url, 'http://orfhbbtv.orf.at/orf/redbutton/index.html');
    });

    test('ZDF HD: the autostart app, not the first PRESENT one', () {
      final scanner = AitScanner(serviceId: 0x2B66);
      expect(scanner.add(_join(_packets('zdf_psi'))), AitScanState.found);
      expect(pickStartApp(scanner.apps)!.url, 'http://hbbtv.zdf.de/zdfstart/index.php');
    });

    test('fed in odd-sized chunks', () {
      final bytes = _join(_packets('daserste_psi'));
      final scanner = AitScanner(serviceId: 0x283D);
      var state = AitScanState.searching;
      for (var i = 0; i < bytes.length && state == AitScanState.searching; i += 77) {
        state = scanner.add(bytes.sublist(i, (i + 77).clamp(0, bytes.length)));
      }
      expect(state, AitScanState.found);
    });

    test('a broken AIT packet is ignored (CRC)', () {
      final packets = _packets('orf1_psi');
      // The AIT packet: PID 0x1C8E.
      final ait = packets.indexWhere((p) => ((p[1] & 0x1F) << 8 | p[2]) == 0x1C8E);
      packets[ait][40] ^= 0xFF;
      final scanner = AitScanner(serviceId: 0x132F);
      expect(scanner.add(_join(packets)), AitScanState.searching);
    });

    test('a channel whose PMT has no AIT', () {
      // Das Erste's packets, the AIT PID's stream type changed in the PMT
      // would break its CRC - so: a PMT made up here.
      final scanner = AitScanner(serviceId: 1);
      final pat = _section([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE1, 0x00]);
      final pmt = _section([
        0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0, 0x00, //
        0x1B, 0xE1, 0x01, 0xF0, 0x00, // video
      ]);
      scanner.add(_packet(0, pat));
      expect(scanner.add(_packet(0x100, pmt)), AitScanState.none);
    });
  });

  group('parseAitSection', () {
    test('not HbbTV or too short', () {
      expect(parseAitSection([0x74, 0x00]), isEmpty);
      expect(parseAitSection(List.filled(20, 0)), isEmpty);
    });
  });

  test('joinAppUrl', () {
    expect(joinAppUrl('http://a.b/c/', 'index.html'), 'http://a.b/c/index.html');
    expect(joinAppUrl('http://a.b/c/', '/index.html'), 'http://a.b/c/index.html');
    expect(joinAppUrl('http://a.b/c', 'index.html'), 'http://a.b/c/index.html');
    expect(joinAppUrl('http://a.b/c/', ''), 'http://a.b/c/');
  });

  group('fallback table', () {
    test('known channels', () {
      expect(hbbtvFallbackUrl('Das Erste HD'), 'http://itv.ard.de/ardstart/index.html');
      expect(hbbtvFallbackUrl('BR Fernsehen Süd HD'), 'http://itv.ard.de/ardstart/index.html');
      expect(hbbtvFallbackUrl('ZDF HD'), 'http://hbbtv.zdf.de/zdfstart/index.php');
      expect(hbbtvFallbackUrl('ZDF_neo HD'), 'http://hbbtv.zdf.de/zdfstart/index.php');
      expect(hbbtvFallbackUrl('ORF2St HD'), 'http://orfhbbtv.orf.at/orf/redbutton/index.html');
      expect(hbbtvFallbackUrl('ORF III HD'), 'http://orfhbbtv.orf.at/orf/redbutton/index.html');
      expect(hbbtvFallbackUrl('ServusTV HD Oesterreich'), startsWith('http://hbbtv.servustv.com/'));
    });

    test('unknown channels', () {
      expect(hbbtvFallbackUrl('Crime Time'), isNull);
      expect(hbbtvFallbackUrl('ProSieben HD AUSTRIA'), isNull);
    });
  });

  test('preparing a page: shim first in <head>, self-closed tags opened', () {
    const page = '<?xml version="1.0" encoding="utf-8" ?>\n<!DOCTYPE html>\n<html><head><title>x</title>'
        '<script>var s = "<b/>";</script></head><body><div id="a"/><object type="video/broadcast"/><br/></body></html>';
    final html = prepareHbbtvPage(page, '/*SHIM*/');
    expect(html.indexOf('/*SHIM*/'), lessThan(html.indexOf('<title>')));
    expect(html, isNot(contains('<?xml')));
    expect(html, contains('<div id="a"></div>'));
    expect(html, contains('<object type="video/broadcast"></object>'));
    expect(html, contains('<br/>'));
    expect(html, contains('var s = "<b/>";'));
  });

  group('fetchHbbtvPage', () {
    test('follows redirects, takes the HbbTV content type as a page, sends the user agent', () async {
      final seen = <String>[];
      final client = MockClient((request) async {
        seen.add('${request.url} ${request.headers['User-Agent']}');
        if (request.url.path == '/start') {
          return http.Response('', 302, headers: {'location': '/app/index.html'});
        }
        return http.Response('<html><head></head><body><div/></body></html>', 200,
            headers: {'content-type': 'application/vnd.hbbtv.xhtml+xml; charset=UTF-8'});
      });
      final page = await fetchHbbtvPage(Uri.parse('http://tv.example/start'), userAgent: 'UA HbbTV/1.5.1', shim: '/*S*/', client: client);
      expect(page.url.toString(), 'http://tv.example/app/index.html');
      expect(page.isDocument, isTrue);
      expect(page.html, contains('/*S*/'));
      expect(page.html, contains('<div></div>'));
      expect(seen.first, 'http://tv.example/start UA HbbTV/1.5.1');
    });

    test('not a page: left to the WebView', () async {
      final client = MockClient((_) async => http.Response('xx', 200, headers: {'content-type': 'video/mp4'}));
      final page = await fetchHbbtvPage(Uri.parse('http://tv.example/v.mp4'), userAgent: 'UA', shim: '', client: client);
      expect(page.isDocument, isFalse);
    });

    test('an error status throws', () async {
      final client = MockClient((_) async => http.Response('', 404));
      expect(fetchHbbtvPage(Uri.parse('http://tv.example/x'), userAgent: 'UA', shim: '', client: client), throwsA(isA<http.ClientException>()));
    });
  });

  test('user agent', () {
    expect(hbbtvUserAgent('Mozilla/5.0 (Linux; Android 11) Chrome/120'), 'Mozilla/5.0 (Linux; Android 11) Chrome/120 $hbbtvUserAgentSuffix');
    expect(hbbtvUserAgent(), contains('HbbTV/1.5.1 (+DRM;'));
  });

  test('preparing a page without <head>', () {
    final html = prepareHbbtvPage('<html><body>x</body></html>', '/*SHIM*/');
    expect(html.indexOf('/*SHIM*/'), lessThan(html.indexOf('x</body>')));
  });
}

/// A PSI section with its CRC.
List<int> _section(List<int> body) {
  final crc = mpegCrc32(body);
  return [...body, crc >> 24 & 0xFF, crc >> 16 & 0xFF, crc >> 8 & 0xFF, crc & 0xFF];
}

/// One TS packet with [section] (payload start, pointer 0).
Uint8List _packet(int pid, List<int> section) {
  final p = Uint8List(188)..fillRange(0, 188, 0xFF);
  p.setAll(0, [0x47, 0x40 | (pid >> 8), pid & 0xFF, 0x10, 0x00]);
  p.setAll(5, section);
  return p;
}
