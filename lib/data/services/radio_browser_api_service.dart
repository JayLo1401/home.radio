import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/internet_radio_station.dart';

/// Client for the community "Radio Browser" API (api.radio-browser.info),
/// the same station catalog used by Music Assistant's internet-radio provider.
class RadioBrowserApiService {
  static const _fallbackHost = 'de1.api.radio-browser.info';
  String? _cachedHost;

  Future<String> _resolveHost() async {
    if (_cachedHost != null) return _cachedHost!;
    try {
      final addresses = await InternetAddress.lookup('all.api.radio-browser.info');
      if (addresses.isNotEmpty) {
        final reverse = await addresses.first.reverse();
        _cachedHost = reverse.host;
        return _cachedHost!;
      }
    } catch (_) {
      // fall through to static fallback host
    }
    _cachedHost = _fallbackHost;
    return _cachedHost!;
  }

  Future<Uri> _uri(String path, Map<String, String> query) async {
    final host = await _resolveHost();
    return Uri.https(host, path, query);
  }

  Map<String, String> get _headers => const {
        'User-Agent': 'HomeRadioFlutterApp/1.0',
        'Content-Type': 'application/json',
      };

  Future<List<InternetRadioStation>> search({
    String? name,
    String? tag,
    String? countryCode,
    int limit = 60,
  }) async {
    final uri = await _uri('/json/stations/search', {
      if (name != null && name.isNotEmpty) 'name': name,
      if (tag != null && tag.isNotEmpty) 'tag': tag,
      if (countryCode != null && countryCode.isNotEmpty) 'countrycode': countryCode,
      'limit': '$limit',
      'hidebroken': 'true',
      'order': 'clickcount',
      'reverse': 'true',
    });
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Radio-Browser search failed: HTTP ${response.statusCode}');
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .cast<Map<String, dynamic>>()
        .map(InternetRadioStation.fromJson)
        .toList();
  }

  Future<List<String>> topTags({int limit = 100}) async {
    final uri = await _uri('/json/tags', {'order': 'stationcount', 'reverse': 'true', 'limit': '$limit'});
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) return const [];
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .cast<Map<String, dynamic>>()
        .map((e) => e['name'] as String)
        .where((n) => n.trim().isNotEmpty)
        .toList();
  }

  Future<List<Map<String, String>>> countries({int limit = 250}) async {
    final uri = await _uri('/json/countries', {'order': 'stationcount', 'reverse': 'true', 'limit': '$limit'});
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) return const [];
    final list = jsonDecode(response.body) as List<dynamic>;
    return list.cast<Map<String, dynamic>>().map((e) {
      return {
        'name': e['name'] as String? ?? '',
        'code': e['iso_3166_1'] as String? ?? '',
      };
    }).where((e) => e['code']!.isNotEmpty).toList();
  }

  /// Radio-Browser asks clients to register a "click" when a station is played,
  /// both to support the community stats and to resolve redirect-only stream URLs.
  Future<void> registerClick(String stationUuid) async {
    try {
      final uri = await _uri('/json/url/$stationUuid', const {});
      await http.get(uri, headers: _headers);
    } catch (_) {
      // best-effort only
    }
  }
}
