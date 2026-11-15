import 'dart:convert';

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
  final String? manufacturer;
  final String? registration;
  final String? owner;

  const FlightInfo({
    this.airline,
    this.origin,
    this.destination,
    this.aircraftType,
    this.manufacturer,
    this.registration,
    this.owner,
  });

  bool get hasRoute => origin != null && destination != null;
}

/// Route and aircraft data from adsbdb.com (free, no key, open-source
/// project). ADS-B itself carries no route - this is schedule/crowd data and
/// usually right, not always (charters, diversions). Asked once per
/// aircraft + callsign and kept for the app's lifetime; nothing is sent but
/// the publicly broadcast address and callsign.
class AdsbdbService {
  static final Map<String, Future<FlightInfo?>> _cache = {};

  static Future<FlightInfo?> lookup({required String icaoHex, String? callsign}) {
    final cs = callsign?.trim().toUpperCase();
    final key = '$icaoHex/${cs ?? ''}';
    return _cache.putIfAbsent(key, () async {
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
    });
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
      manufacturer: s(aircraft, 'manufacturer'),
      registration: s(aircraft, 'registration'),
      owner: s(aircraft, 'registered_owner'),
    );
  }
}
