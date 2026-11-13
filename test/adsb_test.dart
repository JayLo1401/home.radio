import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/models/adsb.dart';

Uint8List hex(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

void main() {
  test('identification (callsign)', () {
    final t = AircraftTracker(homeLat: 52, homeLon: 4);
    t.update(hex('8D4840D6202CC371C32CE0576098'), 0x4840D6, -20);
    expect(t.aircraft[0x4840D6]!.callsign, 'KLM1023');
  });

  test('airborne position from an even/odd pair, altitude', () {
    final t = AircraftTracker(homeLat: 52, homeLon: 4);
    final at = DateTime(2026);
    // Known example pair (ICAO 40621D): 52.2572 N, 3.9194 E, 38000 ft.
    // Odd first, the even one is the newest (as in the textbook example).
    t.update(hex('8D40621D58C386435CC412692AD6'), 0x40621D, -20, at);
    t.update(hex('8D40621D58C382D690C8AC2863A7'), 0x40621D, -20, at.add(const Duration(seconds: 1)));
    final a = t.aircraft[0x40621D]!;
    expect(a.altitudeFt, 38000);
    expect(a.lat, closeTo(52.2572, 0.001));
    expect(a.lon, closeTo(3.9194, 0.001));
  });

  test('velocity', () {
    final t = AircraftTracker(homeLat: 52, homeLon: 4);
    // Known example (ICAO 485020): 159 kt, track 182.88°, -832 ft/min.
    t.update(hex('8D485020994409940838175B284F'), 0x485020, -20);
    final a = t.aircraft[0x485020]!;
    expect(a.speedKt, closeTo(159.2, 0.5));
    expect(a.track, closeTo(182.88, 0.1));
    expect(a.verticalRateFpm, -832);
  });

  test('country', () {
    expect(icaoCountry(0x440123), 'Österreich');
    expect(icaoCountry(0x3C6589), 'Deutschland');
  });
}
