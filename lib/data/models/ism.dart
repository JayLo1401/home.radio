import 'dart:math' as math;

/// One burst from the receiver's ISM detector (`ismBurst` event):
/// alternating high/low durations in microseconds, starting with high.
/// For OOK high = carrier on; for FSK high = the upper frequency.
class IsmBurst {
  final String modulation; // "ook" / "fsk"
  final List<int> durations;
  final double offsetHz;
  final double levelDb;
  final double snrDb;
  final DateTime at;

  /// The tuned frequency (433,92 / 868,3 MHz), 0 = unknown.
  final int freqHz;

  IsmBurst({
    required this.modulation,
    required this.durations,
    required this.offsetHz,
    required this.levelDb,
    required this.snrDb,
    required this.at,
    this.freqHz = 0,
  });

  factory IsmBurst.fromEvent(Map<String, dynamic> e, {DateTime? at, int freqHz = 0}) => IsmBurst(
        modulation: e['modulation'] as String? ?? 'ook',
        durations: [for (final v in e['durationsUs'] as List) (v as num).toInt()],
        offsetHz: (e['offsetHz'] as num?)?.toDouble() ?? 0,
        levelDb: (e['levelDb'] as num?)?.toDouble() ?? 0,
        snrDb: (e['snrDb'] as num?)?.toDouble() ?? 0,
        at: at ?? DateTime.now(),
        freqHz: freqHz,
      );

  Iterable<int> get pulses sync* {
    for (var i = 0; i < durations.length; i += 2) {
      yield durations[i];
    }
  }

  Iterable<int> get gaps sync* {
    for (var i = 1; i < durations.length; i += 2) {
      yield durations[i];
    }
  }
}

enum IsmCategory { weather, switches, unknown }

/// What a decoder read from one sensor transmission.
class IsmReading {
  final String model;
  final String id; // device id as shown (and part of the key)
  final int? channel;
  final IsmCategory category;
  final double? temperatureC;
  final int? humidity;
  final bool? batteryOk;
  final double? windMs;
  final double? gustMs;
  final double? windDirection;
  final double? rainMm;

  /// Switches: which button / state.
  final String? event;

  const IsmReading({
    required this.model,
    required this.id,
    this.channel,
    this.category = IsmCategory.weather,
    this.temperatureC,
    this.humidity,
    this.batteryOk,
    this.windMs,
    this.gustMs,
    this.windDirection,
    this.rainMm,
    this.event,
  });

  /// Identifies the device: model, id and channel.
  String get key => '$model|$id|${channel ?? ''}';
}

// --- bit helpers ---

/// Reads [count] bits from [bits] at [from] as an unsigned number (MSB first).
int bitsAt(List<int> bits, int from, int count) {
  var v = 0;
  for (var i = from; i < from + count; i++) {
    v = (v << 1) | bits[i];
  }
  return v;
}

int signed(int v, int width) => v >= (1 << (width - 1)) ? v - (1 << width) : v;

bool near(int value, int target, [double tolerance = 0.3]) => (value - target).abs() <= target * tolerance;

/// PPM: fixed pulses, the gap carries the bit ([short] = 0, [long] = 1);
/// gaps of [syncMin] and more separate rows.
List<List<int>> ppmRows(IsmBurst b, {required int short, required int long, required int syncMin}) {
  final rows = <List<int>>[[]];
  for (final g in b.gaps) {
    if (g >= syncMin) {
      rows.add([]);
    } else if (near(g, short)) {
      rows.last.add(0);
    } else if (near(g, long)) {
      rows.last.add(1);
    } else {
      rows.add([]);
    }
  }
  return rows.where((r) => r.isNotEmpty).toList();
}

/// PWM: the pulse width carries the bit ([short] = 1, [long] = 0, or the
/// other way round with [shortIsOne] false); gaps of [syncMin] and more
/// separate rows.
List<List<int>> pwmRows(IsmBurst b, {required int short, required int long, required int syncMin, bool shortIsOne = true}) {
  final rows = <List<int>>[[]];
  final d = b.durations;
  for (var i = 0; i < d.length; i += 2) {
    final p = d[i];
    if (near(p, short)) {
      rows.last.add(shortIsOne ? 1 : 0);
    } else if (near(p, long)) {
      rows.last.add(shortIsOne ? 0 : 1);
    } else if (rows.last.isNotEmpty) {
      rows.add([]);
    }
    if (i + 1 < d.length && d[i + 1] >= syncMin) rows.add([]);
  }
  return rows.where((r) => r.isNotEmpty).toList();
}

/// PCM/NRZ: each run is round(run / [bitUs]) bits of its level.
List<int> pcmBits(IsmBurst b, int bitUs) {
  final out = <int>[];
  for (var i = 0; i < b.durations.length; i++) {
    final n = (b.durations[i] / bitUs).round();
    for (var k = 0; k < n && out.length < 4000; k++) {
      out.add(i.isEven ? 1 : 0);
    }
  }
  return out;
}

List<int> bytesOf(List<int> bits, int from, int count) =>
    [for (var i = 0; i < count; i++) bitsAt(bits, from + 8 * i, 8)];

/// Finds [pattern] (bits) in [bits]; the index after it, or -1.
int findAfter(List<int> bits, List<int> pattern) {
  outer:
  for (var i = 0; i + pattern.length <= bits.length; i++) {
    for (var k = 0; k < pattern.length; k++) {
      if (bits[i + k] != pattern[k]) continue outer;
    }
    return i + pattern.length;
  }
  return -1;
}

List<int> bitsOfHex(String hex) => [
      for (final c in hex.split(''))
        for (var b = 3; b >= 0; b--) (int.parse(c, radix: 16) >> b) & 1,
    ];

/// The most frequent row (and how often) - sensors repeat their message.
(List<int>, int)? mostCommon(List<List<int>> rows, int length) {
  final counts = <String, int>{};
  for (final r in rows) {
    if (r.length != length) continue;
    counts.update(r.join(), (v) => v + 1, ifAbsent: () => 1);
  }
  if (counts.isEmpty) return null;
  final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  return ([for (final c in best.key.split('')) int.parse(c)], best.value);
}

int crc8(List<int> bytes, int poly, int init) {
  var c = init;
  for (final b in bytes) {
    c ^= b;
    for (var i = 0; i < 8; i++) {
      c = (c & 0x80) != 0 ? ((c << 1) ^ poly) & 0xFF : (c << 1) & 0xFF;
    }
  }
  return c;
}

/// LFSR digest as used by LaCrosse TX141 sensors.
int lfsrDigest8Reflect(List<int> bytes, int gen, int key) {
  var sum = 0;
  for (var k = bytes.length - 1; k >= 0; k--) {
    final data = bytes[k];
    for (var i = 0; i < 8; i++) {
      if ((data >> i) & 1 == 1) sum ^= key;
      key = (key & 0x80) != 0 ? ((key << 1) ^ gen) & 0xFF : (key << 1) & 0xFF;
    }
  }
  return sum;
}

// --- decoders ---

typedef IsmDecoder = List<IsmReading> Function(IsmBurst b);

/// Nexus / Sencor / Lidl Auriol, TFA, Rubicson-like (433, PPM 1000/2000 us):
/// [id 8][battery 1][? 1][channel 2][temp 12][1111][humidity 8].
List<IsmReading> decodeNexus(IsmBurst b) {
  if (b.modulation != 'ook') return const [];
  final rows = ppmRows(b, short: 1000, long: 2000, syncMin: 3200);
  // Often only one complete row per burst arrives - the fixed nibble and
  // plausible values guard against noise then.
  final best = mostCommon(rows, 36);
  if (best == null) return const [];
  final r = best.$1;
  if (bitsAt(r, 24, 4) != 0xF) return const [];
  final temp = signed(bitsAt(r, 12, 12), 12) / 10;
  final hum = bitsAt(r, 28, 8);
  if (temp < -40 || temp > 70) return const [];
  return [
    IsmReading(
      model: 'Nexus-TH',
      id: bitsAt(r, 0, 8).toString(),
      channel: bitsAt(r, 10, 2) + 1,
      batteryOk: r[8] == 1,
      temperatureC: temp,
      humidity: hum > 0 && hum <= 100 ? hum : null,
    ),
  ];
}

/// Prologue / Clas Ohlson / TFA (433, PPM 2000/4000 us):
/// [type 4 = 5 or 9][id 8][battery 1][button 1][channel 2][temp 12][humidity 8].
List<IsmReading> decodePrologue(IsmBurst b) {
  if (b.modulation != 'ook') return const [];
  final rows = ppmRows(b, short: 2000, long: 4000, syncMin: 6000);
  final best = mostCommon(rows, 36);
  if (best == null || best.$2 < 2) return const [];
  final r = best.$1;
  final type = bitsAt(r, 0, 4);
  if (type != 5 && type != 9) return const [];
  final temp = signed(bitsAt(r, 16, 12), 12) / 10;
  final hum = bitsAt(r, 28, 8);
  if (temp < -40 || temp > 70) return const [];
  return [
    IsmReading(
      model: 'Prologue-TH',
      id: bitsAt(r, 4, 8).toString(),
      channel: bitsAt(r, 14, 2) + 1,
      batteryOk: r[12] == 1,
      temperatureC: temp,
      humidity: hum > 0 && hum <= 100 ? hum : null,
    ),
  ];
}

/// LaCrosse TX141TH-Bv2 / TFA 30.3221 and relatives (433, PWM 208/417 us):
/// [id 8][battery 1][test 1][channel 2][temp 12, +500][humidity 8][digest 8].
List<IsmReading> decodeLaCrosseTx141(IsmBurst b) {
  if (b.modulation != 'ook') return const [];
  final rows = pwmRows(b, short: 208, long: 417, syncMin: 700);
  for (final r in rows) {
    if (r.length < 40) continue;
    final bits = r.sublist(r.length - 40);
    final bytes = bytesOf(bits, 0, 5);
    if (lfsrDigest8Reflect(bytes.sublist(0, 4), 0x31, 0xF4) != bytes[4]) continue;
    final temp = (bitsAt(bits, 12, 12) - 500) / 10;
    final hum = bytes[3];
    return [
      IsmReading(
        model: 'LaCrosse-TX141TH',
        id: bytes[0].toString(),
        channel: bitsAt(bits, 10, 2) + 1,
        batteryOk: bits[8] == 0,
        temperatureC: temp,
        humidity: hum > 0 && hum <= 100 ? hum : null,
      ),
    ];
  }
  return const [];
}

/// Fine Offset WH2 / Renkforce / Telldus (433, PWM 500/1500 us):
/// [0xFF][type 4 = 4][id 8][temp 12, sign + magnitude][humidity 8][crc8].
List<IsmReading> decodeFineOffsetWh2(IsmBurst b) {
  if (b.modulation != 'ook') return const [];
  final rows = pwmRows(b, short: 500, long: 1500, syncMin: 3000);
  for (final r in rows) {
    // Preamble + type 4; the preamble's first bit often gets lost (47-bit
    // rows), so 7 of its ones are enough.
    final start = findAfter(r, const [1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0]);
    if (start < 0 || start - 4 + 40 > r.length) continue;
    final bits = r.sublist(start - 4, start - 4 + 40);
    final bytes = bytesOf(bits, 0, 5);
    if (crc8(bytes.sublist(0, 4), 0x31, 0) != bytes[4]) continue;
    final rawT = bitsAt(bits, 12, 12);
    final hum = bitsAt(bits, 24, 8);
    // With humidity: sign + magnitude. Temperature-only sensors (humidity
    // 0xFF) count from -40 °C instead (a real one read 45,7 instead of 5,7).
    final temp = hum == 0xFF ? rawT / 10 - 40 : ((rawT & 0x800) != 0 ? -(rawT & 0x7FF) : rawT) / 10;
    return [
      IsmReading(
        model: hum == 0xFF ? 'FineOffset-Temp' : 'FineOffset-WH2',
        id: bitsAt(bits, 4, 8).toString(),
        temperatureC: double.parse(temp.toStringAsFixed(1)),
        humidity: hum > 0 && hum <= 100 ? hum : null,
      ),
    ];
  }
  return const [];
}

/// Bresser 5-in-1 weather station (868, FSK 124 us): 26 bytes after
/// AA AA 2D D4, the first 13 the inverse of the last 13; BCD values.
List<IsmReading> decodeBresser5in1(IsmBurst b) {
  if (b.modulation != 'fsk') return const [];
  for (final bits in [pcmBits(b, 124), [for (final x in pcmBits(b, 124)) 1 - x]]) {
    final start = findAfter(bits, bitsOfHex('AA2DD4'));
    if (start < 0 || start + 26 * 8 > bits.length) continue;
    final m = bytesOf(bits, start, 26);
    var ok = true;
    for (var i = 0; i < 13; i++) {
      if ((m[i] ^ m[i + 13]) != 0xFF) ok = false;
    }
    if (!ok) continue;
    int bcd(int byte) => (byte & 0x0F) + ((byte >> 4) & 0x0F) * 10;
    var tempRaw = bcd(m[20]) + (m[21] & 0x0F) * 100;
    if ((m[25] & 0x0F) != 0) tempRaw = -tempRaw;
    return [
      IsmReading(
        model: 'Bresser-5in1',
        id: m[14].toString(),
        temperatureC: tempRaw / 10,
        humidity: bcd(m[22]),
        windDirection: ((m[17] & 0xF0) >> 4) * 22.5,
        gustMs: (((m[17] & 0x0F) << 8) + m[16]) / 10,
        windMs: (bcd(m[18]) + (m[19] & 0x0F) * 100) / 10,
        rainMm: (bcd(m[23]) + (m[24] & 0x0F) * 100) / 10,
        batteryOk: (m[25] & 0x80) == 0,
      ),
    ];
  }
  return const [];
}

/// The bit width of a PCM/FSK burst: the short runs, refined to their
/// median (slivers of a sample or two ignored).
int estimateBitUs(IsmBurst b) {
  final runs = b.durations.where((v) => v >= 8).toList()..sort();
  if (runs.isEmpty) return 100;
  final guess = runs[(runs.length * 0.2).floor()];
  final near = runs.where((v) => v >= guess * 0.6 && v <= guess * 1.4).toList()..sort();
  return near.isEmpty ? guess : near[near.length ~/ 2];
}

/// LaCrosse / Technoline / TFA "IT+" (TX29, TX35, TX27...; 868,3 FSK,
/// 17,24 or 9,58 kbit/s): after AA 2D D4 five bytes
/// [9][id 6][new battery][?][temp BCD - 40][weak battery][humidity 7][crc8].
List<IsmReading> decodeLaCrosseItPlus(IsmBurst b) {
  if (b.modulation != 'fsk') return const [];
  for (final bitUs in [58, 104, estimateBitUs(b)]) {
    final raw = pcmBits(b, bitUs);
    for (final bits in [raw, [for (final x in raw) 1 - x]]) {
      final start = findAfter(bits, bitsOfHex('2DD4'));
      if (start < 0 || start + 40 > bits.length) continue;
      final m = bytesOf(bits, start, 5);
      if (m[0] >> 4 != 9 || crc8(m.sublist(0, 4), 0x31, 0) != m[4]) continue;
      final temp = 10 * (m[1] & 0x0F) + (m[2] >> 4) + (m[2] & 0x0F) / 10 - 40;
      final hum = m[3] & 0x7F;
      return [
        IsmReading(
          model: 'LaCrosse-IT+',
          id: (((m[0] & 0x0F) << 2) | (m[1] >> 6)).toString(),
          temperatureC: double.parse(temp.toStringAsFixed(1)),
          humidity: hum <= 100 ? hum : null, // 106 = no humidity sensor
          batteryOk: (m[3] & 0x80) == 0,
        ),
      ];
    }
  }
  return const [];
}

/// EV1527 / PT2262-style remotes: sockets, doorbells, PIR and window
/// contacts (433, PWM with 1:3 ratio, 24 bits, long sync gap). The bit
/// width is taken from the burst itself.
List<IsmReading> decodeEv1527(IsmBurst b) {
  if (b.modulation != 'ook') return const [];
  final p = b.pulses.toList()..sort();
  if (p.length < 25) return const [];
  final short = p[p.length ~/ 4], long = p[p.length * 3 ~/ 4];
  if (short < 150 || short > 700 || long < short * 2.2 || long > short * 4) return const [];
  final rows = pwmRows(b, short: short, long: long, syncMin: short * 15, shortIsOne: false);
  final best = mostCommon(rows, 24);
  if (best == null || best.$2 < 2) return const [];
  final r = best.$1;
  final id = bitsAt(r, 0, 20);
  final data = bitsAt(r, 20, 4);
  return [
    IsmReading(
      model: 'Funkschalter (EV1527)',
      id: id.toRadixString(16).toUpperCase().padLeft(5, '0'),
      category: IsmCategory.switches,
      event: 'Taste ${data.toRadixString(2).padLeft(4, '0')}',
    ),
  ];
}

const ismDecoders = <IsmDecoder>[
  decodeNexus,
  decodePrologue,
  decodeLaCrosseTx141,
  decodeFineOffsetWh2,
  decodeBresser5in1,
  decodeLaCrosseItPlus,
  decodeEv1527,
];

String _hex(List<int> bits, {int maxChars = 64}) {
  final sb = StringBuffer();
  for (var i = 0; i < bits.length && sb.length < maxChars; i += 4) {
    final n = math.min(4, bits.length - i);
    sb.write((bitsAt(bits, i, n) << (4 - n)).toRadixString(16));
  }
  return sb.toString().toUpperCase();
}

/// Manchester (01 = 0, 10 = 1) from [from]; null if too many invalid pairs.
List<int>? manchester(List<int> bits, int from) {
  final out = <int>[];
  var bad = 0;
  for (var i = from; i + 1 < bits.length; i += 2) {
    if (bits[i] == bits[i + 1]) {
      if (++bad > 2) break;
      continue;
    }
    out.add(bits[i]);
  }
  return out.length >= 16 ? out : null;
}

/// A burst no decoder understood: its coding, the bit rows (split at the
/// sync gaps, repeats dropped) and for FSK the Manchester decoding.
class IsmUnknown {
  final IsmBurst burst;
  final String coding; // "PWM", "PPM", "PCM"
  final List<String> rows; // "36 Bit: 5A1F..."
  final String? manchesterHex;

  /// FSK: the bytes after the sync word 2D D4 (Bresser, LaCrosse & co.).
  final String? afterSync;

  /// FSK: bit width (us).
  final int? bitUs;

  IsmUnknown(this.burst, this.coding, this.rows, this.manchesterHex, {this.afterSync, this.bitUs});

  /// A long FSK stream without sync word: one continuous sender (each
  /// excerpt starts elsewhere in its pattern, so the data can't tell).
  bool get continuous => burst.modulation == 'fsk' && afterSync == null && burst.durations.length > 200;

  /// Same coding and data = the same sender; a continuous one by its
  /// frequency offset and bit rate.
  String get key => continuous
      ? 'cont|${burst.freqHz}|${(burst.offsetHz / 5000).round()}|${((bitUs ?? 0) / 4).round()}'
      : '${burst.freqHz}|${burst.modulation}|$coding|${rows.join(',')}|$manchesterHex|$afterSync';

  static IsmUnknown of(IsmBurst b) {
    final p = b.pulses.toList()..sort();
    final g = b.gaps.toList()..sort();
    bool twoWidths(List<int> v) => v.length > 4 && v[v.length * 3 ~/ 4] > v[v.length ~/ 4] * 1.6;
    int q(List<int> v, double f) => v[(v.length * f).floor().clamp(0, v.length - 1)];
    var rowBits = <List<int>>[];
    String coding;
    String? man, afterSync;
    int? bitUs;
    if (b.modulation == 'ook' && twoWidths(p)) {
      // PWM: the pulse width is the bit (the gap may vary inversely, so
      // that each bit takes the same time).
      coding = 'PWM';
      final s = q(p, 0.25), l = q(p, 0.75);
      final sync = math.max(l, q(g, 0.75)) * 2.5;
      rowBits = pwmRows(b, short: s, long: l, syncMin: sync.round());
      if (rowBits.isEmpty) rowBits = [for (final v in b.pulses) (v - s).abs() < (v - l).abs() ? 1 : 0].let((r) => [r]);
    } else if (b.modulation == 'ook' && twoWidths(g)) {
      coding = 'PPM';
      final s = q(g, 0.25), l = q(g.where((v) => v < s * 3).toList()..sort(), 0.9);
      rowBits = ppmRows(b, short: s, long: l, syncMin: (l * 1.6).round());
    } else {
      coding = 'PCM';
      final w = math.max(4, estimateBitUs(b));
      bitUs = w;
      final bits = pcmBits(b, w);
      rowBits = [bits];
      // Sync word 2D D4 (either polarity): the payload behind it as bytes.
      for (final cand in [bits, [for (final x in bits) 1 - x]]) {
        final s = findAfter(cand, bitsOfHex('2DD4'));
        if (s < 0) continue;
        final n = math.min(32, (cand.length - s) ~/ 8);
        if (n < 3) continue;
        afterSync = [for (final x in bytesOf(cand, s, n)) x.toRadixString(16).padLeft(2, '0').toUpperCase()].join(' ');
        break;
      }
      // After an 0xAA... preamble, FSK sensors usually use Manchester.
      final start = findAfter(bits, const [1, 0, 1, 0, 1, 0, 1, 0]);
      if (start >= 0) {
        var i = start;
        while (i + 1 < bits.length && bits[i] != bits[i + 1]) {
          i += 2; // rest of the alternating preamble
        }
        final m = manchester(bits, i - 2 >= 0 ? i - 2 : i) ?? manchester(bits, i - 1 >= 0 ? i - 1 : i);
        if (m != null) man = _hex(m);
      }
    }
    // Repeats once, longest first.
    final seen = <String>{};
    final rows = <String>[];
    for (final r in rowBits..sort((a, c) => c.length - a.length)) {
      if (r.length < 8) continue;
      final s = '${r.length} Bit: ${_hex(r)}';
      if (seen.add(s)) rows.add(s);
      if (rows.length >= 3) break;
    }
    return IsmUnknown(b, coding, rows, man, afterSync: afterSync, bitUs: bitUs);
  }
}

/// Unknown bursts with the same data, counted.
class IsmUnknownGroup {
  final String key;
  IsmUnknown sample;
  int count = 1;
  DateTime lastSeen;

  IsmUnknownGroup(this.key, this.sample, this.lastSeen);
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// A sensor heard, with its latest values and a 24 h history.
class IsmDevice {
  final String key;
  IsmReading last;
  DateTime lastSeen;
  int count = 1;
  double levelDb;
  final List<({DateTime at, double? temp, int? hum})> history = [];
  final List<({DateTime at, String event})> events = [];

  IsmDevice(this.key, this.last, this.lastSeen, this.levelDb);
}

/// Looks like a remote key (car key fob, rolling code): OOK where every
/// pulse and gap is one or two units of 250-600 us (Manchester-like), a few
/// dozen of them, clearly above the noise. Only counted - never shown with
/// its code, a key's fixed part would identify it (and so its owner).
bool looksLikeKeyFob(IsmBurst b) {
  if (b.modulation != 'ook' || b.snrDb < 10) return false;
  final d = b.durations;
  if (d.length < 80 || d.length > 400) return false;
  final sorted = [...d]..sort();
  final unit = sorted[sorted.length ~/ 5];
  if (unit < 250 || unit > 600) return false;
  var ok = 0, doubles = 0;
  for (final v in d) {
    if (near(v, unit, 0.25)) {
      ok++;
    } else if (near(v, 2 * unit, 0.2)) {
      ok++;
      doubles++;
    }
  }
  return ok >= d.length * 0.9 && doubles >= d.length * 0.15;
}

/// Decodes bursts and keeps the devices.
class IsmTracker {
  /// Remote key presses nearby (anonymous; a press sends several bursts).
  int keyPresses = 0;
  DateTime? lastKeyPress;
  final Map<String, IsmDevice> devices = {};

  /// Undecoded senders, newest first (same data counted once).
  final List<IsmUnknownGroup> unknown = [];
  int bursts = 0;

  static const _historyStep = Duration(minutes: 1);
  static const _historyKeep = Duration(hours: 24);

  /// The readings decoded from [b] (empty = unknown, kept in [unknown]).
  List<IsmReading> add(IsmBurst b) {
    bursts++;
    final readings = <IsmReading>[];
    for (final d in ismDecoders) {
      readings.addAll(d(b));
      if (readings.isNotEmpty) break;
    }
    if (readings.isEmpty && looksLikeKeyFob(b)) {
      // Bursts within 3 s are one press.
      if (lastKeyPress == null || b.at.difference(lastKeyPress!) > const Duration(seconds: 3)) keyPresses++;
      lastKeyPress = b.at;
      return readings;
    }
    if (readings.isEmpty) {
      final u = IsmUnknown.of(b);
      if (u.rows.isEmpty && u.manchesterHex == null && u.afterSync == null) return readings; // nothing to show
      final i = unknown.indexWhere((g) => g.key == u.key);
      final group = i >= 0 ? unknown.removeAt(i) : IsmUnknownGroup(u.key, u, b.at);
      if (i >= 0) {
        group
          ..sample = u
          ..count += 1
          ..lastSeen = b.at;
      }
      unknown.insert(0, group);
      if (unknown.length > 50) unknown.removeLast();
      return readings;
    }
    for (final r in readings) {
      final dev = devices[r.key];
      if (dev == null) {
        final d = IsmDevice(r.key, r, b.at, b.levelDb);
        _record(d, r, b.at);
        devices[r.key] = d;
      } else {
        dev
          ..last = r
          ..lastSeen = b.at
          ..levelDb = b.levelDb
          ..count += 1;
        _record(dev, r, b.at);
      }
    }
    return readings;
  }

  void _record(IsmDevice d, IsmReading r, DateTime at) {
    if (r.event != null) {
      // The same button repeated within a few seconds is one press.
      final lastEvent = d.events.isEmpty ? null : d.events.first;
      if (lastEvent == null || lastEvent.event != r.event || at.difference(lastEvent.at) > const Duration(seconds: 3)) {
        d.events.insert(0, (at: at, event: r.event!));
        if (d.events.length > 50) d.events.removeLast();
      }
    }
    if (r.temperatureC == null && r.humidity == null) return;
    if (d.history.isNotEmpty && at.difference(d.history.last.at) < _historyStep) return;
    d.history.add((at: at, temp: r.temperatureC, hum: r.humidity));
    while (d.history.isNotEmpty && at.difference(d.history.first.at) > _historyKeep) {
      d.history.removeAt(0);
    }
  }
}
