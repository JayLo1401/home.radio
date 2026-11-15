import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// An airport as adsbdb.com knows it.
class Airport {
  final String name;
  final String? iata;
  final String? icao;
  final String? city;
  final String? country;
  final double lat;
  final double lon;

  const Airport({
    required this.name,
    required this.iata,
    required this.icao,
    required this.city,
    required this.country,
    required this.lat,
    required this.lon,
  });

  /// Short code for the radar: IATA (VIE), else ICAO (LOWW).
  String get code => iata ?? icao ?? name;

  static Airport? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final lat = (j['latitude'] as num?)?.toDouble(), lon = (j['longitude'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    String? s(String k) => (j[k] as String?)?.trim().isEmpty ?? true ? null : (j[k] as String).trim();
    return Airport(
      name: s('name') ?? '?',
      iata: s('iata_code'),
      icao: s('icao_code'),
      city: s('municipality'),
      country: s('country_name'),
      lat: lat,
      lon: lon,
    );
  }
}

/// What adsbdb.com knows about a flight (route by callsign) and the
/// aircraft (by its ICAO address). Every field may be missing.
class FlightInfo {
  final String? airline;
  final Airport? origin;
  final Airport? destination;
  final String? aircraftType;
  /// ICAO type designator ("A320", "B77W", "C172") - short, for the list.
  final String? icaoType;
  final String? manufacturer;
  final String? registration;
  final String? owner;

  const FlightInfo({
    this.airline,
    this.origin,
    this.destination,
    this.aircraftType,
    this.icaoType,
    this.manufacturer,
    this.registration,
    this.owner,
  });

  bool get hasRoute => origin != null && destination != null;

  /// Whether the route fits an aircraft at ([lat], [lon]) flying [track]:
  /// heading roughly towards the destination. adsbdb knows routes by
  /// callsign, and many airlines (Ryanair, easyJet, Wizz, ...) give their
  /// alphanumeric callsigns to other routes from day to day - then adsbdb
  /// still has the old one (about one in six around Graz, checked against
  /// live tracks). Near the destination (approach turns) or without a track
  /// it counts as fitting.
  bool fits({double? lat, double? lon, double? track}) {
    final d = destination;
    if (d == null || lat == null || lon == null || track == null) return true;
    if (_km(lat, lon, d.lat, d.lon) < 80) return true;
    final off = ((_bearing(lat, lon, d.lat, d.lon) - track + 540) % 360) - 180;
    return off.abs() <= 75;
  }

  static double _rad(double d) => d * math.pi / 180;

  static double _bearing(double lat1, double lon1, double lat2, double lon2) {
    final y = math.sin(_rad(lon2 - lon1)) * math.cos(_rad(lat2));
    final x = math.cos(_rad(lat1)) * math.sin(_rad(lat2)) -
        math.sin(_rad(lat1)) * math.cos(_rad(lat2)) * math.cos(_rad(lon2 - lon1));
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static double _km(double lat1, double lon1, double lat2, double lon2) {
    final dLat = _rad(lat2 - lat1), dLon = _rad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
    return 2 * 6371 * math.asin(math.sqrt(a));
  }
}

/// Route and aircraft data from adsbdb.com (free, no key, open-source
/// project). ADS-B itself carries no route - this is schedule/crowd data and
/// usually right, not always (charters, diversions). Asked once per
/// aircraft + callsign and kept for the app's lifetime; nothing is sent but
/// the publicly broadcast address and callsign.
class AdsbdbService {
  static final Map<String, Future<FlightInfo?>> _cache = {};
  static final Map<String, FlightInfo?> _done = {};

  static String _key(String icaoHex, String? callsign) => '$icaoHex/${callsign?.trim().toUpperCase() ?? ''}';

  /// Whether this aircraft + callsign was asked already (answer or not).
  static bool known({required String icaoHex, String? callsign}) => _cache.containsKey(_key(icaoHex, callsign));

  /// The answer if it's there already (no request).
  static FlightInfo? cached({required String icaoHex, String? callsign}) => _done[_key(icaoHex, callsign)];

  static Future<FlightInfo?> lookup({required String icaoHex, String? callsign}) {
    final cs = callsign?.trim().toUpperCase();
    final key = _key(icaoHex, callsign);
    return _cache.putIfAbsent(key, () async {
      final info = await _fetch(key, icaoHex, cs);
      _done[key] = info;
      return info;
    });
  }

  static Future<FlightInfo?> _fetch(String key, String icaoHex, String? cs) async {
    try {
      final uri = Uri.https('api.adsbdb.com', '/v0/aircraft/$icaoHex', {
        if (cs != null && cs.isNotEmpty) 'callsign': cs,
      });
      final r = await http.get(uri, headers: {'User-Agent': 'home_radio/1.0'}).timeout(const Duration(seconds: 10));
      // 404 with "unknown aircraft": the callsign alone may still be known.
      if (r.statusCode == 404 && cs != null && cs.isNotEmpty) return _routeOnly(cs);
      if (r.statusCode != 200) return null;
      final response = (jsonDecode(r.body) as Map<String, dynamic>)['response'];
      if (response is! Map<String, dynamic>) return null;
      return _parse(response);
    } catch (_) {
      // Network trouble: ask again next time.
      _cache.remove(key);
      return null;
    }
  }

  static Future<FlightInfo?> _routeOnly(String callsign) async {
    final r = await http
        .get(Uri.https('api.adsbdb.com', '/v0/callsign/$callsign'), headers: {'User-Agent': 'home_radio/1.0'})
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final response = (jsonDecode(r.body) as Map<String, dynamic>)['response'];
    return response is Map<String, dynamic> ? _parse(response) : null;
  }

  static FlightInfo _parse(Map<String, dynamic> response) {
    final route = response['flightroute'] as Map<String, dynamic>?;
    final aircraft = response['aircraft'] as Map<String, dynamic>?;
    String? s(Map<String, dynamic>? m, String k) {
      final v = (m?[k] as String?)?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    return FlightInfo(
      airline: s(route?['airline'] as Map<String, dynamic>?, 'name'),
      origin: Airport.fromJson(route?['origin']),
      destination: Airport.fromJson(route?['destination']),
      aircraftType: s(aircraft, 'type'),
      icaoType: s(aircraft, 'icao_type'),
      manufacturer: s(aircraft, 'manufacturer'),
      registration: s(aircraft, 'registration'),
      owner: s(aircraft, 'registered_owner'),
    );
  }
}
