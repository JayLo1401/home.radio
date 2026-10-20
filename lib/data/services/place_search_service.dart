import 'dart:convert';

import 'package:http/http.dart' as http;

class PlaceResult {
  const PlaceResult({required this.name, required this.region, required this.lat, required this.lon});

  /// Short name for the location label, e.g. "Graz".
  final String name;

  /// Where it is, e.g. "Steiermark, Österreich".
  final String region;
  final double lat, lon;
}

/// Place search by name via OpenStreetMap's Nominatim (data (c) OpenStreetMap
/// contributors, ODbL). Its usage policy allows occasional interactive
/// lookups like this one - one request per explicit search, an identifying
/// User-Agent, nothing automated or bulk.
class PlaceSearchService {
  static const _endpoint = 'https://nominatim.openstreetmap.org/search';

  Future<List<PlaceResult>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.parse(_endpoint).replace(queryParameters: {
      'q': q,
      'format': 'jsonv2',
      'addressdetails': '1',
      'limit': '8',
      'accept-language': 'de',
    });
    final r = await http.get(uri, headers: {'User-Agent': 'HomeRadio/1.0 (github.com/JayLo1401/home.radio)'});
    if (r.statusCode != 200) throw Exception('Ortssuche: HTTP ${r.statusCode}');
    final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
    final results = <PlaceResult>[];
    final seen = <String>{};
    for (final e in list.cast<Map<String, dynamic>>()) {
      final lat = double.tryParse('${e['lat']}');
      final lon = double.tryParse('${e['lon']}');
      if (lat == null || lon == null) continue;
      final address = (e['address'] as Map?)?.cast<String, dynamic>() ?? const {};
      final display = '${e['display_name'] ?? ''}';
      final name = '${e['name'] ?? ''}'.trim().isNotEmpty ? '${e['name']}'.trim() : display.split(',').first.trim();
      final region = [
        address['county'],
        address['state'],
        address['country'],
      ].whereType<String>().where((s) => s.isNotEmpty && s != name).join(', ');
      final key = '$name|$region';
      if (!seen.add(key)) continue;
      results.add(PlaceResult(name: name, region: region, lat: lat, lon: lon));
    }
    return results;
  }
}
