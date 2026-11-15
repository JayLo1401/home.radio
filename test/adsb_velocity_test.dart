import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/models/adsb.dart';

Uint8List hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  test('velocity message: track and speed (1090 MHz Riddle example)', () {
    final t = AircraftTracker(homeLat: 47, homeLon: 15);
    // Ground speed 159 kt, track 182.88°, descending 832 ft/min.
    t.update(hex('8D485020994409940838175B284F'), 0x485020, -10);
    final a = t.aircraft[0x485020]!;
    expect(a.track!, closeTo(182.88, 0.5));
  });
  test('identification message: callsign and emitter category', () {
    final t = AircraftTracker(homeLat: 47, homeLon: 15);
    // KLM1023 (1090 MHz Riddle), the category set to TC 4 / CA 3 (large).
    t.update(hex('8D4840D6232CC371C32CE0576098'), 0x4840D6, -10);
    final a = t.aircraft[0x4840D6]!;
    expect(a.callsign, 'KLM1023');
    expect(a.category, AircraftCategory.large);
    expect(AircraftCategory.from(4, 5), AircraftCategory.heavy);
    expect(AircraftCategory.from(4, 7), AircraftCategory.rotorcraft);
    expect(AircraftCategory.from(3, 1), AircraftCategory.glider);
    expect(AircraftCategory.from(4, 0), AircraftCategory.unknown);
  });
  test('velocity message type 3 (heading)', () {
    final t = AircraftTracker(homeLat: 47, homeLon: 15);
    // Airspeed message: heading 243.98°, airspeed 375 kt.
    t.update(hex('8DA05F219B06B6AF189400CBC33F'), 0xA05F21, -10);
    final a = t.aircraft[0xA05F21]!;
    expect(a.track!, closeTo(243.98, 0.5));
  });
}
