import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/models/ism.dart';

List<int> bitsOf(int value, int width) => [for (var i = width - 1; i >= 0; i--) (value >> i) & 1];

IsmBurst burst(List<int> durations, {String modulation = 'ook'}) =>
    IsmBurst(modulation: modulation, durations: durations, offsetHz: 0, levelDb: -40, snrDb: 25, at: DateTime(2026));

/// PPM rows: pulse, then gap short/long per bit, sync gap between rows.
List<int> ppm(List<int> bits, {required int pulse, required int short, required int long, required int sync, int repeats = 4}) {
  final d = <int>[];
  for (var r = 0; r < repeats; r++) {
    for (final b in bits) {
      d.addAll([pulse, b == 1 ? long : short]);
    }
    d.addAll([pulse, sync]);
  }
  return d..removeLast();
}

/// PWM rows: pulse short (= 1) / long (= 0), fixed gap.
List<int> pwm(List<int> bits, {required int short, required int long, required int gap, required int sync, int repeats = 3, bool shortIsOne = true}) {
  final d = <int>[];
  for (var r = 0; r < repeats; r++) {
    for (final b in bits) {
      final isShort = shortIsOne ? b == 1 : b == 0;
      d.addAll([isShort ? short : long, gap]);
    }
    d[d.length - 1] = sync;
  }
  return d..removeLast();
}

void main() {
  test('Nexus-TH: 21.6 °C, 48 %, channel 2', () {
    final bits = [
      ...bitsOf(0x5A, 8), 1, 0, ...bitsOf(1, 2), // id, battery, ?, channel-1
      ...bitsOf(216, 12), ...bitsOf(0xF, 4), ...bitsOf(48, 8),
    ];
    final r = decodeNexus(burst(ppm(bits, pulse: 500, short: 1000, long: 2000, sync: 4000)));
    expect(r, hasLength(1));
    expect(r.first.temperatureC, closeTo(21.6, 0.01));
    expect(r.first.humidity, 48);
    expect(r.first.channel, 2);
    expect(r.first.batteryOk, isTrue);
  });

  test('Nexus-TH: negative temperature', () {
    final bits = [...bitsOf(7, 8), 1, 0, 0, 0, ...bitsOf((-52) & 0xFFF, 12), ...bitsOf(0xF, 4), ...bitsOf(90, 8)];
    final r = decodeNexus(burst(ppm(bits, pulse: 500, short: 1000, long: 2000, sync: 4000)));
    expect(r.first.temperatureC, closeTo(-5.2, 0.01));
  });

  test('LaCrosse TX141TH: digest checked', () {
    // id 0x8C, battery ok, channel 1, 18.5 °C -> 685, 55 %.
    final b0 = 0x8C, b1 = (0 << 7) | (0 << 6) | (0 << 4) | (685 >> 8), b2 = 685 & 0xFF, b3 = 55;
    final digest = lfsrDigest8Reflect([b0, b1, b2, b3], 0x31, 0xF4);
    final bits = [for (final x in [b0, b1, b2, b3, digest]) ...bitsOf(x, 8)];
    final r = decodeLaCrosseTx141(burst(pwm(bits, short: 208, long: 417, gap: 208, sync: 900)));
    expect(r, hasLength(1));
    expect(r.first.temperatureC, closeTo(18.5, 0.01));
    expect(r.first.humidity, 55);
    // A flipped bit fails the digest.
    final bad = [...bits]..[20] ^= 1;
    expect(decodeLaCrosseTx141(burst(pwm(bad, short: 208, long: 417, gap: 208, sync: 900))), isEmpty);
  });

  test('Fine Offset WH2', () {
    final bytes = [0x40 | 0x1, 0x20 | 0x0, 0xD7, 0x3C]; // type 4, id 0x12, temp 0x0D7 = 21.5, hum 60
    final crc = crc8(bytes, 0x31, 0);
    final bits = [...bitsOf(0xFF, 8), for (final x in [...bytes, crc]) ...bitsOf(x, 8)];
    final r = decodeFineOffsetWh2(burst(pwm(bits, short: 500, long: 1500, gap: 1000, sync: 5000, repeats: 2)));
    expect(r, hasLength(1));
    expect(r.first.id, '18');
    expect(r.first.temperatureC, closeTo(21.5, 0.01));
    expect(r.first.humidity, 60);
  });

  test('LaCrosse IT+ (FSK 58 us): 21.3 °C, 45 %', () {
    // 9, id 23 (6 bits), new battery 0, ?, temp BCD 61.3 (= 21.3 + 40), hum 45.
    final m0 = 0x90 | (23 >> 2), m1 = ((23 & 3) << 6) | 0x06, m2 = 0x13, m3 = 45;
    final crc = crc8([m0, m1, m2, m3], 0x31, 0);
    final bits = [...bitsOfHex('AAAAAA2DD4'), for (final x in [m0, m1, m2, m3, crc]) ...bitsOf(x, 8), 0, 1, 0, 1];
    // Runs of equal bits -> durations (FSK high/low).
    final durations = <int>[];
    if (bits.first == 0) durations.add(0);
    var run = 1;
    for (var i = 1; i <= bits.length; i++) {
      if (i < bits.length && bits[i] == bits[i - 1]) {
        run++;
      } else {
        durations.add(run * 58);
        run = 1;
      }
    }
    final r = decodeLaCrosseItPlus(burst(durations, modulation: 'fsk'));
    expect(r, hasLength(1));
    expect(r.first.id, '23');
    expect(r.first.temperatureC, closeTo(21.3, 0.01));
    expect(r.first.humidity, 45);
  });

  test('Fine Offset WH2 with the first preamble bit lost (47 bits)', () {
    final bytes = [0x40 | 0x1, 0x20 | 0x0, 0xD7, 0x3C];
    final crc = crc8(bytes, 0x31, 0);
    final bits = [...bitsOf(0x7F, 7), for (final x in [...bytes, crc]) ...bitsOf(x, 8)];
    final r = decodeFineOffsetWh2(burst(pwm(bits, short: 500, long: 1500, gap: 1000, sync: 5000, repeats: 2)));
    expect(r, hasLength(1));
    expect(r.first.temperatureC, closeTo(21.5, 0.01));
  });

  test('Fine Offset temperature-only (humidity 0xFF): offset -40 °C', () {
    // raw 0x1C9 = 457 -> 5.7 °C (it showed 45.7 °C before).
    final bytes = [0x40 | 0x2, 0xB0 | 0x1, 0xC9, 0xFF];
    final crc = crc8(bytes, 0x31, 0);
    final bits = [...bitsOf(0xFF, 8), for (final x in [...bytes, crc]) ...bitsOf(x, 8)];
    final r = decodeFineOffsetWh2(burst(pwm(bits, short: 500, long: 1500, gap: 1000, sync: 5000, repeats: 2)));
    expect(r.first.temperatureC, closeTo(5.7, 0.01));
    expect(r.first.humidity, isNull);
  });

  test('car key fob: counted, not listed', () {
    final t = IsmTracker();
    // Manchester-like 500/1000 us, 66 pulses (as received from a real key).
    final d = <int>[];
    for (var i = 0; i < 66; i++) {
      d.addAll([i % 3 == 0 ? 1000 : 500, i % 4 == 0 ? 1000 : 500]);
    }
    final b = IsmBurst(modulation: 'ook', durations: d, offsetHz: 0, levelDb: -30, snrDb: 22, at: DateTime(2026));
    t.add(b);
    t.add(IsmBurst(modulation: 'ook', durations: d, offsetHz: 0, levelDb: -30, snrDb: 22, at: DateTime(2026, 1, 1, 0, 0, 1)));
    expect(t.keyPresses, 1);
    expect(t.unknown, isEmpty);
  });

  test('EV1527 remote', () {
    final bits = [...bitsOf(0xA5C3E, 20), ...bitsOf(0x2, 4)];
    final r = decodeEv1527(burst(pwm(bits, short: 350, long: 1050, gap: 350, sync: 10850, repeats: 5, shortIsOne: false)));
    expect(r, hasLength(1));
    expect(r.first.id, 'A5C3E');
    expect(r.first.event, 'Taste 0010');
  });

  test('tracker: unknown bursts kept, history per minute', () {
    final t = IsmTracker();
    t.add(burst([100, 100, 100, 100, 300, 100, 100, 100, 100, 300, 100, 100, 100, 100, 300, 100]));
    expect(t.unknown, hasLength(1));
    final bits = [...bitsOf(0x5A, 8), 1, 0, 0, 1, ...bitsOf(216, 12), ...bitsOf(0xF, 4), ...bitsOf(48, 8)];
    final b = burst(ppm(bits, pulse: 500, short: 1000, long: 2000, sync: 4000));
    t.add(b);
    t.add(b);
    expect(t.devices, hasLength(1));
    expect(t.devices.values.first.count, 2);
    expect(t.devices.values.first.history, hasLength(1));
  });
}
