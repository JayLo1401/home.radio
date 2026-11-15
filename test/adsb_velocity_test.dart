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
  test('velocity message type 3 (heading)', () {
    final t = AircraftTracker(homeLat: 47, homeLon: 15);
    // Airspeed message: heading 243.98°, airspeed 375 kt.
    t.update(hex('8DA05F219B06B6AF189400CBC33F'), 0xA05F21, -10);
    final a = t.aircraft[0xA05F21]!;
    expect(a.track!, closeTo(243.98, 0.5));
  });
}
