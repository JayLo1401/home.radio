import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/hourly_forecast.dart';

/// Hourly forecast via GeoSphere Austria's (formerly ZAMG) public Data Hub -
/// the AROME-based `nwp-v1-1h-2500m` point forecast, free/CC0, no API key
/// (endpoint verified directly, 2026-09-17: `dataset.api.hub.geosphere.at`,
/// same one Home Assistant's ZAMG/GeoSphere integrations use). Chosen over
/// Open-Meteo/Bergfex specifically for Austria-sourced data.
///
/// `sy` (GeoSphere's own weather-symbol code) is deliberately not
/// requested - it's an undocumented, proprietary code table (confirmed
/// against the most complete open-source GeoSphere integration, which
/// derives its own condition from physical parameters instead of decoding
/// it). [WeatherCondition] here is derived the same way, simplified
/// (no CAPE/CIN thunderstorm detection, which AROME's basic parameter set
/// doesn't include).
class GeoSphereWeatherService {
  static const _baseUrl = 'https://dataset.api.hub.geosphere.at/v1/timeseries/forecast/nwp-v1-1h-2500m';
  static const _parameters = 't2m,rr_acc,u10m,v10m,tcc';

  /// Only hours up to the next 02:00 are returned - "today's" forecast, with
  /// a late-night cutoff rather than stopping dead at midnight.
  DateTime _cutoff(DateTime now) {
    var cutoff = DateTime(now.year, now.month, now.day, 2);
    if (!cutoff.isAfter(now)) cutoff = cutoff.add(const Duration(days: 1));
    return cutoff;
  }

  Future<List<HourlyForecast>> getHourlyForecast({required double lat, required double lon}) async {
    final uri = Uri.parse('$_baseUrl?parameters=$_parameters&lat_lon=$lat,$lon');
    final response = await http.get(uri, headers: {'User-Agent': 'home_radio/1.0'});
    if (response.statusCode != 200) {
      throw Exception('GeoSphere Austria request failed: HTTP ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final timestamps = (json['timestamps'] as List).cast<String>();
    final features = json['features'] as List;
    if (features.isEmpty) {
      return const [];
    }
    final parameters = (features.first as Map<String, dynamic>)['properties']['parameters'] as Map<String, dynamic>;

    List<double?> series(String name) =>
        ((parameters[name] as Map<String, dynamic>?)?['data'] as List?)?.map((v) => (v as num?)?.toDouble()).toList() ??
        List.filled(timestamps.length, null);

    final t2m = series('t2m');
    final rrAcc = series('rr_acc');
    final u10m = series('u10m');
    final v10m = series('v10m');
    final tcc = series('tcc');
    final cutoff = _cutoff(DateTime.now());

    final result = <HourlyForecast>[];
    for (var i = 0; i < timestamps.length; i++) {
      final time = DateTime.parse(timestamps[i]).toLocal();
      if (time.isAfter(cutoff)) break;
      final temp = t2m[i] ?? 0;
      // rr_acc is accumulated since forecast start - the hourly amount is
      // the delta from the previous step (matches the reference GeoSphere
      // integration's approach; the very first step has no predecessor).
      final rainHour = i == 0 ? (rrAcc[i] ?? 0) : math.max((rrAcc[i] ?? 0) - (rrAcc[i - 1] ?? 0), 0.0);
      final windSpeed = math.sqrt(math.pow(u10m[i] ?? 0, 2) + math.pow(v10m[i] ?? 0, 2));
      final cloudPct = (tcc[i] ?? 0) * 100;
      result.add(
        HourlyForecast(
          time: time,
          tempC: temp,
          rainMmPerHour: rainHour,
          windSpeedMs: windSpeed,
          cloudCoverPct: cloudPct,
          condition: _deriveCondition(rainHour, cloudPct, temp),
        ),
      );
    }
    return result;
  }

  WeatherCondition _deriveCondition(double rainMmPerHour, double cloudCoverPct, double tempC) {
    const rainThreshold = 0.2; // mm/h - below this counts as dry
    const pouringThreshold = 4.0; // mm/h
    if (rainMmPerHour >= rainThreshold) {
      if (tempC <= 0.5) return WeatherCondition.snowy;
      return rainMmPerHour >= pouringThreshold ? WeatherCondition.pouring : WeatherCondition.rainy;
    }
    if (cloudCoverPct <= 20) return WeatherCondition.clear;
    if (cloudCoverPct <= 70) return WeatherCondition.partlyCloudy;
    return WeatherCondition.cloudy;
  }
}
