import 'dart:math' as math;
import 'dart:typed_data';

/// One aircraft as put together from its Mode S / ADS-B messages.
class Aircraft {
  final int icao;
  String? callsign;
  int? altitudeFt;
  double? speedKt;
  double? track; // degrees
  int? verticalRateFpm;
  double? lat;
  double? lon;
  String? squawk;
  bool onGround = false;
  DateTime lastSeen;
  DateTime? lastPosition;
  int messages = 0;
  double signalDb = -99;

  // CPR halves of the last airborne positions (even = 0, odd = 1).
  final _cpr = <int, ({int lat, int lon, DateTime at})>{};

  Aircraft(this.icao, this.lastSeen);

  String get icaoHex => icao.toRadixString(16).toUpperCase().padLeft(6, '0');
  bool get hasPosition => lat != null && lon != null;

  /// Registration country by the ICAO address block.
  String? get country => icaoCountry(icao);

  int? get altitudeM => altitudeFt == null ? null : (altitudeFt! * 0.3048).round();
  int? get speedKmh => speedKt == null ? null : (speedKt! * 1.852).round();

  double? distanceKm(double homeLat, double homeLon) =>
      hasPosition ? greatCircleKm(homeLat, homeLon, lat!, lon!) : null;
}

double greatCircleKm(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * 6371 * math.asin(math.sqrt(a));
}

/// Bearing (degrees) from point 1 to point 2.
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final y = math.sin(rad(lon2 - lon1)) * math.cos(rad(lat2));
  final x = math.cos(rad(lat1)) * math.sin(rad(lat2)) - math.sin(rad(lat1)) * math.cos(rad(lat2)) * math.cos(rad(lon2 - lon1));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Keeps track of the aircraft heard, from the receiver's `adsbFrame`
/// events. Positions are decoded with even/odd CPR pairs (global) or,
/// until there is a pair, relative to the home location (local - fine
/// within ~300 km, which is about the reception range anyway).
class AircraftTracker {
  final double homeLat;
  final double homeLon;
  final Map<int, Aircraft> aircraft = {};
  int messageCount = 0;

  AircraftTracker({required this.homeLat, required this.homeLon});

  static const _timeout = Duration(seconds: 60);
  static const _maxRangeKm = 600.0;

  /// Drops aircraft not heard for a minute.
  void prune([DateTime? now]) {
    final t = now ?? DateTime.now();
    aircraft.removeWhere((_, a) => t.difference(a.lastSeen) > _timeout);
  }

  /// One frame (7 or 14 bytes) with the address the receiver resolved.
  void update(Uint8List msg, int icao, double signalDb, [DateTime? at]) {
    if (msg.isEmpty) return;
    final now = at ?? DateTime.now();
    final a = aircraft.putIfAbsent(icao, () => Aircraft(icao, now));
    a.lastSeen = now;
    a.messages++;
    a.signalDb = signalDb;
    messageCount++;
    final df = msg[0] >> 3;
    switch (df) {
      case 17 || 18 when msg.length >= 14:
        _extendedSquitter(a, msg.sublist(4, 11), now);
      case 0 || 4 || 16 || 20 when msg.length >= 4:
        final alt = _altitude13(((msg[2] & 0x1F) << 8) | msg[3]);
        if (alt != null) a.altitudeFt = alt;
      case 5 || 21 when msg.length >= 4:
        a.squawk = _squawk(((msg[2] & 0x1F) << 8) | msg[3]);
    }
  }

  void _extendedSquitter(Aircraft a, Uint8List me, DateTime now) {
    int bits(int from, int count) {
      // ME bits, 1-based like the spec.
      var v = 0;
      for (var i = from - 1; i < from - 1 + count; i++) {
        v = (v << 1) | ((me[i ~/ 8] >> (7 - i % 8)) & 1);
      }
      return v;
    }

    final tc = bits(1, 5);
    if (tc >= 1 && tc <= 4) {
      const charset = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######';
      final sb = StringBuffer();
      for (var i = 0; i < 8; i++) {
        sb.write(charset[bits(9 + 6 * i, 6)]);
      }
      final cs = sb.toString().replaceAll('#', '').trim();
      if (cs.isNotEmpty) a.callsign = cs;
    } else if ((tc >= 9 && tc <= 18) || (tc >= 20 && tc <= 22)) {
      a.onGround = false;
      if (tc <= 18) {
        final alt = _altitude12(bits(9, 12));
        if (alt != null) a.altitudeFt = alt;
      }
      final odd = bits(22, 1);
      a._cpr[odd] = (lat: bits(23, 17), lon: bits(40, 17), at: now);
      _position(a, odd, now);
    } else if (tc >= 5 && tc <= 8) {
      a.onGround = true;
    } else if (tc == 19) {
      final st = bits(6, 3);
      if (st == 1 || st == 2) {
        final vew = bits(15, 10) - 1, vns = bits(26, 10) - 1;
        if (vew >= 0 && vns >= 0) {
          final factor = st == 2 ? 4 : 1; // supersonic
          final ew = (bits(14, 1) == 1 ? -vew : vew) * factor.toDouble();
          final ns = (bits(25, 1) == 1 ? -vns : vns) * factor.toDouble();
          a.speedKt = math.sqrt(ew * ew + ns * ns);
          a.track = (math.atan2(ew, ns) * 180 / math.pi + 360) % 360;
        }
      } else if (st == 3 || st == 4) {
        if (bits(14, 1) == 1) a.track = bits(15, 10) * 360 / 1024;
        final as = bits(26, 10) - 1;
        if (as >= 0) a.speedKt = as.toDouble() * (st == 4 ? 4 : 1);
      }
      final vr = bits(38, 9) - 1;
      if (vr >= 0) a.verticalRateFpm = (bits(37, 1) == 1 ? -vr : vr) * 64;
    }
  }

  void _position(Aircraft a, int newest, DateTime now) {
    final even = a._cpr[0], odd = a._cpr[1];
    double? lat, lon;
    if (even != null && odd != null && now.difference(even.at).abs() < const Duration(seconds: 10) &&
        now.difference(odd.at).abs() < const Duration(seconds: 10)) {
      final g = _globalCpr(even.lat / 131072, even.lon / 131072, odd.lat / 131072, odd.lon / 131072, newest);
      if (g != null) (lat, lon) = g;
    }
    if (lat == null) {
      // Relative to the last position, or else to home.
      final c = a._cpr[newest]!;
      final refLat = a.lat ?? homeLat, refLon = a.lon ?? homeLon;
      (lat, lon) = _localCpr(c.lat / 131072, c.lon / 131072, newest, refLat, refLon);
    }
    if (lat.abs() > 90 || greatCircleKm(homeLat, homeLon, lat, lon!) > _maxRangeKm) return;
    a.lat = lat;
    a.lon = lon;
    a.lastPosition = now;
  }

  static (double, double)? _globalCpr(double lat0, double lon0, double lat1, double lon1, int newest) {
    const dLat0 = 360.0 / 60, dLat1 = 360.0 / 59;
    final j = (59 * lat0 - 60 * lat1 + 0.5).floor();
    var rlat0 = dLat0 * (_mod(j, 60) + lat0);
    var rlat1 = dLat1 * (_mod(j, 59) + lat1);
    if (rlat0 >= 270) rlat0 -= 360;
    if (rlat1 >= 270) rlat1 -= 360;
    if (_nl(rlat0) != _nl(rlat1)) return null;
    final lat = newest == 0 ? rlat0 : rlat1;
    final nl = _nl(lat);
    final ni = math.max(nl - newest, 1);
    final m = (lon0 * (nl - 1) - lon1 * nl + 0.5).floor();
    var lon = (360.0 / ni) * (_mod(m, ni) + (newest == 0 ? lon0 : lon1));
    if (lon >= 180) lon -= 360;
    return (lat, lon);
  }

  static (double, double) _localCpr(double latCpr, double lonCpr, int odd, double refLat, double refLon) {
    final dLat = 360.0 / (odd == 1 ? 59 : 60);
    final j = (refLat / dLat).floor() + (0.5 + _modD(refLat, dLat) / dLat - latCpr).floor();
    final lat = dLat * (j + latCpr);
    final ni = math.max(_nl(lat) - odd, 1);
    final dLon = 360.0 / ni;
    final m = (refLon / dLon).floor() + (0.5 + _modD(refLon, dLon) / dLon - lonCpr).floor();
    return (lat, dLon * (m + lonCpr));
  }

  static int _mod(int a, int b) => ((a % b) + b) % b;
  static double _modD(double a, double b) => a - b * (a / b).floor();

  /// Number of longitude zones at a latitude (CPR).
  static int _nl(double lat) {
    final l = lat.abs();
    if (l == 0) return 59;
    if (l == 87) return 2;
    if (l > 87) return 1;
    final a = 1 - math.cos(math.pi / (2 * 15));
    final b = math.pow(math.cos(math.pi / 180 * l), 2);
    return (2 * math.pi / math.acos(1 - a / b)).floor();
  }

  /// 12-bit altitude of an airborne position (25 ft steps with the Q bit).
  static int? _altitude12(int ac) {
    if (ac == 0) return null;
    if ((ac & 0x10) == 0) return null; // 100 ft Gillham - rare, skipped
    final n = ((ac & 0xFE0) >> 1) | (ac & 0x0F);
    return n * 25 - 1000;
  }

  /// 13-bit altitude code of DF0/4/16/20 (M bit 0, Q bit 1 only).
  static int? _altitude13(int ac) {
    if (ac == 0) return null;
    final m = (ac >> 6) & 1, q = (ac >> 4) & 1;
    if (m == 1 || q == 0) return null;
    final n = ((ac & 0x1F80) >> 2) | ((ac & 0x20) >> 1) | (ac & 0x0F);
    return n * 25 - 1000;
  }

  /// 13-bit identity code -> squawk "7000".
  static String _squawk(int id) {
    int b(int bit) => (id >> (12 - bit)) & 1; // bit 0 = C1 ... bit 12 = D4
    final a = b(1) | (b(3) << 1) | (b(5) << 2);
    final bb = b(7) | (b(9) << 1) | (b(11) << 2);
    final c = b(0) | (b(2) << 1) | (b(4) << 2);
    final d = b(8) | (b(10) << 1) | (b(12) << 2);
    return '$a$bb$c$d';
  }
}

/// The frame bytes of an `adsbFrame` event (Uint8List on Android, hex on
/// the desktop).
Uint8List? adsbFrameFromEvent(Map<String, dynamic> event) {
  final data = event['data'];
  if (data is Uint8List) return data;
  if (data is List) return Uint8List.fromList(data.cast<int>());
  final hex = event['hex'] as String?;
  if (hex == null || hex.length.isOdd) return null;
  return Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

/// Registration country by ICAO 24-bit address block (Europe and a few
/// frequent others).
String? icaoCountry(int icao) {
  const blocks = [
    (0x440000, 0x447FFF, 'Österreich'),
    (0x3C0000, 0x3FFFFF, 'Deutschland'),
    (0x4B0000, 0x4B7FFF, 'Schweiz'),
    (0x300000, 0x33FFFF, 'Italien'),
    (0x380000, 0x3BFFFF, 'Frankreich'),
    (0x400000, 0x43FFFF, 'Großbritannien'),
    (0x480000, 0x487FFF, 'Niederlande'),
    (0x448000, 0x44FFFF, 'Belgien'),
    (0x340000, 0x37FFFF, 'Spanien'),
    (0x490000, 0x497FFF, 'Tschechien'),
    (0x488000, 0x48FFFF, 'Polen'),
    (0x470000, 0x477FFF, 'Ungarn'),
    (0x505C00, 0x505FFF, 'Slowenien'),
    (0x501C00, 0x501FFF, 'Kroatien'),
    (0x505800, 0x505BFF, 'Slowakei'),
    (0x4CA000, 0x4CAFFF, 'Irland'),
    (0x4A0000, 0x4A7FFF, 'Rumänien'),
    (0x4B8000, 0x4BFFFF, 'Türkei'),
    (0x468000, 0x46FFFF, 'Griechenland'),
    (0x458000, 0x45FFFF, 'Dänemark'),
    (0x4A8000, 0x4AFFFF, 'Schweden'),
    (0x478000, 0x47FFFF, 'Norwegen'),
    (0x460000, 0x467FFF, 'Finnland'),
    (0x490000, 0x497FFF, 'Tschechien'),
    (0x4D0000, 0x4D03FF, 'Luxemburg'),
    (0x4D2000, 0x4D23FF, 'Malta'),
    (0x510000, 0x5103FF, 'Weißrussland'),
    (0x508000, 0x50FFFF, 'Ukraine'),
    (0x100000, 0x1FFFFF, 'Russland'),
    (0x896000, 0x896FFF, 'VAE'),
    (0x06A000, 0x06AFFF, 'Katar'),
    (0x710000, 0x717FFF, 'Saudi-Arabien'),
    (0xA00000, 0xAFFFFF, 'USA'),
    (0xC00000, 0xC3FFFF, 'Kanada'),
    (0x780000, 0x7BFFFF, 'China'),
  ];
  for (final (lo, hi, name) in blocks) {
    if (icao >= lo && icao <= hi) return name;
  }
  return null;
}
