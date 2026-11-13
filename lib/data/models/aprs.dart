import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// An APRS packet as decoded from an AX.25 frame (see the receiver's AFSK
/// 1200 packet decoder): who sent it, the path it took, and what it says -
/// position (plain, compressed or Mic-E), object, message, status, weather.
class AprsPacket {
  final DateTime receivedAt;
  final String source;
  final String destination;

  /// Digipeaters, "*" after those the packet already went through.
  final List<String> path;

  /// The raw information field, as text.
  final String info;

  /// What kind of packet ("Position", "Mic-E", "Objekt", "Nachricht", ...).
  final String kind;
  final double? lat;
  final double? lon;

  /// Two characters: symbol table ('/' or '\' or overlay) and symbol code.
  final String? symbol;

  /// Object/item name, or the addressee of a message.
  final String? name;
  final String? comment;

  /// Mic-E speed (km/h) and course (degrees).
  final double? speedKmh;
  final int? course;
  final AprsWeather? weather;

  const AprsPacket({
    required this.receivedAt,
    required this.source,
    required this.destination,
    required this.path,
    required this.info,
    required this.kind,
    this.lat,
    this.lon,
    this.symbol,
    this.name,
    this.comment,
    this.speedKmh,
    this.course,
    this.weather,
  });

  bool get hasPosition => lat != null && lon != null;

  /// "OE6XYZ-9>APRS,WIDE1-1*:info" - like a TNC shows it.
  String get tnc2 => '$source>$destination${path.isEmpty ? '' : ',${path.join(',')}'}:$info';

  /// Kilometres from ([homeLat], [homeLon]).
  double? distanceKm(double homeLat, double homeLon) {
    if (!hasPosition) return null;
    const r = 6371.0;
    final dLat = _rad(lat! - homeLat), dLon = _rad(lon! - homeLon);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(homeLat)) * math.cos(_rad(lat!)) * math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  /// Compass direction from ([homeLat], [homeLon]), e.g. "NO".
  String? bearingFrom(double homeLat, double homeLon) {
    if (!hasPosition) return null;
    final y = math.sin(_rad(lon! - homeLon)) * math.cos(_rad(lat!));
    final x = math.cos(_rad(homeLat)) * math.sin(_rad(lat!)) -
        math.sin(_rad(homeLat)) * math.cos(_rad(lat!)) * math.cos(_rad(lon! - homeLon));
    final deg = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    const names = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    return names[((deg + 22.5) ~/ 45) % 8];
  }

  static double _rad(double d) => d * math.pi / 180;

  /// What the symbol shows, in a word ("Auto", "Wetterstation", ...).
  String? get symbolName => symbol == null ? null : aprsSymbolName(symbol!);
}

/// Weather from a weather station's report, metric.
class AprsWeather {
  final int? windDirection; // degrees
  final double? windKmh;
  final double? gustKmh;
  final double? temperatureC;
  final double? rain1hMm;
  final int? humidity; // %
  final double? pressureHpa;

  const AprsWeather({
    this.windDirection,
    this.windKmh,
    this.gustKmh,
    this.temperatureC,
    this.rain1hMm,
    this.humidity,
    this.pressureHpa,
  });

  bool get isEmpty =>
      windDirection == null &&
      windKmh == null &&
      temperatureC == null &&
      humidity == null &&
      pressureHpa == null &&
      rain1hMm == null;

  String describe() {
    String n(double v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');
    return [
      if (temperatureC != null) '${n(temperatureC!, 1)} °C',
      if (humidity != null) '$humidity %',
      if (pressureHpa != null) '${n(pressureHpa!, 1)} hPa',
      if (windKmh != null)
        'Wind ${n(windKmh!, 0)} km/h'
            '${windDirection != null ? ' aus ${windDirection!}°' : ''}'
            '${gustKmh != null ? ', Böen ${n(gustKmh!, 0)}' : ''}',
      if (rain1hMm != null && rain1hMm! > 0) 'Regen ${n(rain1hMm!, 1)} mm/h',
    ].join(' · ');
  }
}

/// The frame's bytes from an `nbPacket` event: Android sends them as a
/// Uint8List ('data'), the desktop receiver as hex ('hex').
Uint8List? aprsFrameFromEvent(Map<String, dynamic> event) {
  final data = event['data'];
  if (data is Uint8List) return data;
  if (data is List) return Uint8List.fromList(data.cast<int>());
  final hex = event['hex'] as String?;
  if (hex == null || hex.length.isOdd) return null;
  return Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

/// Parses an AX.25 UI frame (addresses, control, PID, info - FCS already
/// removed) into an [AprsPacket]; null if it isn't one.
AprsPacket? parseAx25(Uint8List f, {DateTime? at}) {
  if (f.length < 16) return null;
  final addresses = <String>[];
  var i = 0;
  var last = false;
  while (!last && i + 7 <= f.length && addresses.length < 10) {
    final call = String.fromCharCodes([for (var k = 0; k < 6; k++) f[i + k] >> 1]).trim();
    final ssidByte = f[i + 6];
    final ssid = (ssidByte >> 1) & 0x0F;
    final repeated = (ssidByte & 0x80) != 0;
    var name = ssid == 0 ? call : '$call-$ssid';
    // H bit: on digipeaters "already repeated".
    if (addresses.length >= 2 && repeated) name = '$name*';
    addresses.add(name);
    last = (ssidByte & 1) != 0;
    i += 7;
  }
  if (!last || addresses.length < 2 || i + 2 > f.length) return null;
  final control = f[i], pid = f[i + 1];
  if (control != 0x03 || pid != 0xF0) return null; // only UI frames carry APRS
  final info = latin1.decode(f.sublist(i + 2), allowInvalid: true);
  return parseAprs(
    source: addresses[1],
    destination: addresses[0],
    path: addresses.sublist(2),
    info: info,
    at: at ?? DateTime.now(),
  );
}

/// Decodes the APRS information field.
AprsPacket parseAprs({
  required String source,
  required String destination,
  required List<String> path,
  required String info,
  required DateTime at,
}) {
  AprsPacket packet(
    String kind, {
    double? lat,
    double? lon,
    String? symbol,
    String? name,
    String? comment,
    double? speedKmh,
    int? course,
    AprsWeather? weather,
  }) =>
      AprsPacket(
        receivedAt: at,
        source: source,
        destination: destination,
        path: path,
        info: info,
        kind: kind,
        lat: lat,
        lon: lon,
        symbol: symbol,
        name: name,
        comment: _clean(comment),
        speedKmh: speedKmh,
        course: course,
        weather: weather == null || weather.isEmpty ? null : weather,
      );

  if (info.isEmpty) return packet('Leer');
  final type = info[0];
  try {
    switch (type) {
      case '!' || '=' || '/' || '@':
        // With a timestamp (/ @) the position starts after 7 characters.
        final body = (type == '/' || type == '@') && info.length > 8 ? info.substring(8) : info.substring(1);
        final pos = _position(body);
        if (pos == null) return packet('Position', comment: body);
        final weather = pos.symbol.endsWith('_') ? _weather(pos.rest) : null;
        return packet(
          weather != null ? 'Wetter' : 'Position',
          lat: pos.lat,
          lon: pos.lon,
          symbol: pos.symbol,
          comment: weather != null ? null : pos.rest,
          weather: weather,
        );
      case '`' || "'" || '\x1c' || '\x1d':
        return _micE(destination, info, packet) ?? packet('Mic-E', comment: info.substring(1));
      case ';':
        // ;NAME_____*DDHHMMzposition
        if (info.length < 18) return packet('Objekt', comment: info.substring(1));
        final name = info.substring(1, 10).trim();
        final alive = info[10] == '*';
        final pos = _position(info.substring(18));
        return packet(
          alive ? 'Objekt' : 'Objekt (gelöscht)',
          name: name,
          lat: pos?.lat,
          lon: pos?.lon,
          symbol: pos?.symbol,
          comment: pos?.rest,
        );
      case ')':
        final end = info.indexOf(RegExp('[!_]'), 1);
        if (end < 0) return packet('Item', comment: info.substring(1));
        final pos = _position(info.substring(end + 1));
        return packet('Item', name: info.substring(1, end), lat: pos?.lat, lon: pos?.lon, symbol: pos?.symbol, comment: pos?.rest);
      case ':':
        // :ADDRESSEE:text{id
        if (info.length < 11) return packet('Nachricht', comment: info.substring(1));
        final to = info.substring(1, 10).trim();
        var text = info.substring(11);
        final id = text.lastIndexOf('{');
        if (id >= 0) text = text.substring(0, id);
        if (to.startsWith('BLN')) return packet('Bulletin', name: to, comment: text);
        if (RegExp(r'^(ack|rej)\w+$').hasMatch(text)) return packet('Bestätigung', name: to, comment: text);
        return packet('Nachricht', name: to, comment: text);
      case '>':
        return packet('Status', comment: info.substring(1));
      case '_':
        // Positionless weather: _MMDDHHMM then the data.
        return packet('Wetter', weather: _weather(info.length > 9 ? info.substring(9) : ''));
      case 'T':
        return packet('Telemetrie', comment: info.substring(1));
      case '<':
        return packet('Fähigkeiten', comment: info.substring(1));
      case '}':
        // Third party (e.g. from the internet via a gateway): the inner packet.
        final inner = info.substring(1);
        final colon = inner.indexOf(':'), gt = inner.indexOf('>');
        if (colon > 0 && gt > 0 && gt < colon) {
          final head = inner.substring(0, colon).split(',');
          final p = parseAprs(
            source: head.first.substring(0, gt),
            destination: head.first.substring(gt + 1),
            path: [...head.skip(1), 'via $source'],
            info: inner.substring(colon + 1),
            at: at,
          );
          return p;
        }
        return packet('Weitergeleitet', comment: inner);
      default:
        // Some send a position without the '!' (it may start further in).
        final bang = info.indexOf('!');
        if (bang > 0 && bang < 40) {
          final pos = _position(info.substring(bang + 1));
          if (pos != null) return packet('Position', lat: pos.lat, lon: pos.lon, symbol: pos.symbol, comment: pos.rest);
        }
        return packet('Daten', comment: info);
    }
  } catch (_) {
    return packet('Daten', comment: info);
  }
}

typedef _Pos = ({double lat, double lon, String symbol, String rest});

/// "4807.38N/01131.00E>comment" or compressed "/5L!!<*e7>7P[".
_Pos? _position(String s) {
  final plain = RegExp(r'^(\d{2})([\d ]{2}\.[\d ]{2})([NS])(.)(\d{3})([\d ]{2}\.[\d ]{2})([EW])(.)').firstMatch(s);
  if (plain != null) {
    double minutes(String m) => double.parse(m.replaceAll(' ', '0'));
    var lat = int.parse(plain[1]!) + minutes(plain[2]!) / 60;
    var lon = int.parse(plain[5]!) + minutes(plain[6]!) / 60;
    if (plain[3] == 'S') lat = -lat;
    if (plain[7] == 'W') lon = -lon;
    return (lat: lat, lon: lon, symbol: '${plain[4]}${plain[8]}', rest: s.substring(plain.end));
  }
  // Compressed: table, 4 base-91 lat, 4 lon, code, cs, s, t.
  if (s.length >= 13 && RegExp(r'^[/\\A-Za-j]').hasMatch(s)) {
    int b91(String x) => x.codeUnits.fold(0, (v, c) => v * 91 + (c - 33));
    final latV = b91(s.substring(1, 5)), lonV = b91(s.substring(5, 9));
    if (s.substring(1, 9).codeUnits.every((c) => c >= 33 && c <= 124)) {
      final lat = 90 - latV / 380926.0, lon = -180 + lonV / 190463.0;
      if (lat.abs() <= 90 && lon.abs() <= 180) {
        return (lat: lat, lon: lon, symbol: '${s[0]}${s[9]}', rest: s.substring(13));
      }
    }
  }
  return null;
}

/// Mic-E: latitude in the destination callsign, the rest in the info field.
AprsPacket? _micE(
  String destination,
  String info,
  AprsPacket Function(String kind, {double? lat, double? lon, String? symbol, String? comment, double? speedKmh, int? course})
      packet,
) {
  final dest = destination.split('-').first;
  if (dest.length < 6 || info.length < 9) return null;
  int digit(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
    if (c >= 0x41 && c <= 0x4A) return c - 0x41; // A-J
    if (c >= 0x50 && c <= 0x59) return c - 0x50; // P-Y
    return 0; // K, L, Z: space
  }

  final d = dest.codeUnits;
  bool high(int c) => c >= 0x50 && c <= 0x5A; // P-Z
  final latDeg = digit(d[0]) * 10 + digit(d[1]);
  final latMin = digit(d[2]) * 10 + digit(d[3]) + (digit(d[4]) * 10 + digit(d[5])) / 100;
  var lat = latDeg + latMin / 60;
  if (!high(d[3])) lat = -lat; // south
  final lonOffset = high(d[4]);
  final west = high(d[5]);

  final b = info.codeUnits;
  var lonDeg = b[1] - 28;
  if (lonOffset) lonDeg += 100;
  if (lonDeg >= 180 && lonDeg <= 189) lonDeg -= 80;
  if (lonDeg >= 190 && lonDeg <= 199) lonDeg -= 190;
  var lonMin = b[2] - 28;
  if (lonMin >= 60) lonMin -= 60;
  final lonHund = b[3] - 28;
  var lon = lonDeg + (lonMin + lonHund / 100) / 60;
  if (west) lon = -lon;

  var speed = (b[4] - 28) * 10 + (b[5] - 28) ~/ 10;
  var course = ((b[5] - 28) % 10) * 100 + (b[6] - 28);
  if (speed >= 800) speed -= 800;
  if (course >= 400) course -= 400;
  final symbol = '${info[8]}${info[7]}';
  var comment = info.length > 9 ? info.substring(9) : '';
  // Radio type markers and the base-91 altitude ("xxx}") aren't text.
  comment = comment.replaceFirst(RegExp(r'^[>\]`\x27]'), '');
  comment = comment.replaceFirst(RegExp(r'^.{3}\}'), '');
  comment = comment.replaceFirst(RegExp(r'[=^~_\]]$'), '');
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return packet(
    'Mic-E',
    lat: lat,
    lon: lon,
    symbol: symbol,
    comment: comment,
    speedKmh: speed > 0 ? speed * 1.852 : null,
    course: speed > 0 && course > 0 ? course : null,
  );
}

/// Weather data: c=wind dir, s=wind (mph), g=gust, t=°F, r=rain/h (1/100"),
/// h=humidity, b=pressure (1/10 hPa).
AprsWeather? _weather(String s) {
  int? field(String key, int len) {
    final m = RegExp('$key(-?[0-9]{${len - 1},$len})').firstMatch(s);
    return m == null ? null : int.tryParse(m[1]!);
  }

  // The plain position format puts direction/speed first: "220/004".
  final ds = RegExp(r'^(\d{3})/(\d{3})').firstMatch(s);
  final dir = ds != null ? int.parse(ds[1]!) : field('c', 3);
  final wind = ds != null ? int.parse(ds[2]!) : field('s', 3);
  final t = field('t', 3), h = field('h', 2), b = field('b', 5), r = field('r', 3), g = field('g', 3);
  final w = AprsWeather(
    windDirection: dir,
    windKmh: wind?.let((v) => v * 1.609),
    gustKmh: g?.let((v) => v * 1.609),
    temperatureC: t?.let((v) => (v - 32) * 5 / 9),
    rain1hMm: r?.let((v) => v * 0.254),
    humidity: h == null ? null : (h == 0 ? 100 : h),
    pressureHpa: b?.let((v) => v / 10),
  );
  return w.isEmpty ? null : w;
}

extension<T extends num> on T {
  R let<R>(R Function(T v) f) => f(this);
}

String? _clean(String? s) {
  if (s == null) return null;
  final t = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  return t.isEmpty ? null : t;
}

/// The common APRS symbols in a word.
String aprsSymbolName(String symbol) {
  if (symbol.length < 2) return '';
  final alt = symbol[0] != '/';
  final code = symbol[1];
  if (alt) {
    return switch (code) {
      '#' => 'Digipeater',
      '&' => 'Gateway',
      '_' => 'Wetterstation',
      '-' => 'Haus',
      '>' => 'Auto',
      'a' => 'Rettung',
      'n' => 'Knoten',
      'k' => 'SUV',
      'u' => 'LKW',
      'v' => 'Bus/Van',
      '^' => 'Flugzeug',
      'O' => 'Ballon',
      'r' => 'Relais',
      'D' => 'DMR/D-Star',
      _ => 'Symbol $symbol',
    };
  }
  return switch (code) {
    '>' => 'Auto',
    '-' => 'Haus',
    '_' => 'Wetterstation',
    '#' => 'Digipeater',
    '&' => 'Gateway',
    'k' => 'LKW',
    'u' => 'LKW',
    'v' => 'Van',
    'j' => 'Jeep',
    'R' => 'Wohnmobil',
    '<' => 'Motorrad',
    'b' => 'Fahrrad',
    '[' => 'Fußgänger',
    'y' => 'Station mit Antenne',
    'r' => 'Relais',
    'Y' => 'Yacht',
    's' => 'Schiff',
    'O' => 'Ballon',
    '^' => 'Flugzeug',
    "'" => 'Kleinflugzeug',
    'X' => 'Hubschrauber',
    'f' => 'Feuerwehr',
    'a' => 'Rettung',
    'P' => 'Polizei',
    'S' => 'Satellit',
    'U' => 'Bus',
    '=' => 'Zug',
    _ => 'Symbol $symbol',
  };
}
