import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/models/aprs.dart';

/// AX.25 UI frame as the receiver's packet decoder delivers it (no FCS).
Uint8List frame(String dest, String src, List<String> path, String info) {
  final out = <int>[];
  void addr(String a, bool last) {
    final parts = a.replaceAll('*', '').split('-');
    final call = parts[0].padRight(6);
    for (final c in call.codeUnits.take(6)) {
      out.add(c << 1);
    }
    final ssid = parts.length > 1 ? int.parse(parts[1]) : 0;
    out.add(0x60 | (ssid << 1) | (a.endsWith('*') ? 0x80 : 0) | (last ? 1 : 0));
  }

  final all = [dest, src, ...path];
  for (var i = 0; i < all.length; i++) {
    addr(all[i], i == all.length - 1);
  }
  out.addAll([0x03, 0xF0, ...info.codeUnits]);
  return Uint8List.fromList(out);
}

void main() {
  test('plain position with path', () {
    final p = parseAx25(frame('APRS', 'OE6ABC-9', ['WIDE1-1*', 'WIDE2-1'], '!4807.38N/01131.00E>Unterwegs'))!;
    expect(p.source, 'OE6ABC-9');
    expect(p.path, ['WIDE1-1*', 'WIDE2-1']);
    expect(p.kind, 'Position');
    expect(p.lat, closeTo(48.1230, 0.0001));
    expect(p.lon, closeTo(11.5167, 0.0001));
    expect(p.symbolName, 'Auto');
    expect(p.comment, 'Unterwegs');
  });

  test('Mic-E', () {
    // 33°25.64'N (S32U V T: north, +100° longitude offset, west).
    final p = parseAx25(frame('S32UVT', 'OE1XYZ', [], '`(_fn"Oj/'))!;
    expect(p.kind, 'Mic-E');
    expect(p.lat, closeTo(33.4273, 0.0001));
    expect(p.lon, closeTo(-112.129, 0.001));
    expect(p.symbol, '/j');
  });

  test('compressed position', () {
    final p = parseAprs(source: 'X', destination: 'APRS', path: const [], info: '!/5L!!<*e7>7P[', at: DateTime(2026));
    expect(p.lat, closeTo(49.5, 0.01));
    expect(p.lon, closeTo(-72.75, 0.01));
  });

  test('weather station', () {
    final p = parseAprs(
      source: 'OE6WX',
      destination: 'APRS',
      path: const [],
      info: '!4903.50N/07201.75W_220/004g005t077r000p000P000h50b09900wRSW',
      at: DateTime(2026),
    );
    expect(p.kind, 'Wetter');
    expect(p.weather!.temperatureC, closeTo(25, 0.1));
    expect(p.weather!.humidity, 50);
    expect(p.weather!.pressureHpa, closeTo(990, 0.1));
    expect(p.weather!.windDirection, 220);
  });

  test('message and object', () {
    final m = parseAprs(source: 'A', destination: 'APRS', path: const [], info: ':OE6ABC-9 :Hallo{12', at: DateTime(2026));
    expect(m.kind, 'Nachricht');
    expect(m.name, 'OE6ABC-9');
    expect(m.comment, 'Hallo');
    final o = parseAprs(
      source: 'A',
      destination: 'APRS',
      path: const [],
      info: ';LEADER   *092345z4903.50N/07201.75W>088/036',
      at: DateTime(2026),
    );
    expect(o.kind, 'Objekt');
    expect(o.name, 'LEADER');
    expect(o.lat, closeTo(49.0583, 0.001));
  });

  test('distance', () {
    final p = parseAprs(source: 'A', destination: 'APRS', path: const [], info: '!4704.24N/01526.37E-', at: DateTime(2026));
    expect(p.distanceKm(47.0707, 15.4395)!, lessThan(0.5)); // Graz
  });

  test('hex from the desktop receiver', () {
    expect(aprsFrameFromEvent({'hex': '0a0bff'}), Uint8List.fromList([10, 11, 255]));
  });
}
