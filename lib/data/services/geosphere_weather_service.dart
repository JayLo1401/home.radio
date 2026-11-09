import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/hourly_forecast.dart';

/// Hourly forecast via GeoSphere Austria's (formerly ZAMG) public Data Hub -
/// the `nwp-v2-1h-1km` point forecast, free/CC0, no API key
/// (`dataset.api.hub.geosphere.at`, same one Home Assistant's ZAMG/GeoSphere
/// integrations use). Chosen over Open-Meteo/Bergfex specifically for
/// Austria-sourced data.
///
/// Until 2026-11 this used `nwp-v1-1h-2500m`; GeoSphere stopped updating it
/// (last run 2026-11-04 03 UTC, since then HTTP 200 with an empty time
/// series - the panel showed "Keine Daten"). v2 names the parameters
/// differently (2t/10u/10v), gives precipitation per hour (tp) instead of
/// accumulated (rr_acc), and cloud cover in % instead of 0..1.
///
/// `sy` (GeoSphere's own weather-symbol code) is deliberately not
/// requested - it's an undocumented, proprietary code table (confirmed
/// against the most complete open-source GeoSphere integration, which
/// derives its own condition from physical parameters instead of decoding
/// it). [WeatherCondition] here is derived the same way, simplified
/// (no CAPE/CIN thunderstorm detection).
class GeoSphereWeatherService {
  static const _baseUrl = 'https://dataset.api.hub.geosphere.at/v1/timeseries/forecast/nwp-v2-1h-1km';
  static const _parameters = '2t,tp,10u,10v,tcc';

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

    final t2m = series('2t');
    final tp = series('tp'); // kg/m² = mm in the hour before the timestamp
    final u10m = series('10u');
    final v10m = series('10v');
    final tcc = series('tcc'); // %
    final now = DateTime.now();
    final cutoff = _cutoff(now);
    // The API returns the whole day starting near midnight, not "from now" -
    // nothing filtered out hours already in the past, so a user checking in
    // the afternoon saw the morning's (long-stale, since-revised) forecast
    // at the top of the list instead of the current hour. Only keep the
    // current hour onward (truncated to the hour, so "now" itself isn't
    // dropped for being a few minutes into it).
    final currentHour = DateTime(now.year, now.month, now.day, now.hour);

    final result = <HourlyForecast>[];
    var missingHours = 0;
    for (var i = 0; i < timestamps.length; i++) {
      final time = DateTime.parse(timestamps[i]).toLocal();
      if (time.isBefore(currentHour)) continue;
      if (time.isAfter(cutoff)) break;
      // A model run GeoSphere hasn't fully published yet comes back with
      // nulls instead of values - these used to be shown as "0° / 0 km/h"
      // rows. Such hours are skipped rather than made up.
      final temp = t2m[i], u = u10m[i], v = v10m[i];
      if (temp == null || u == null || v == null) {
        missingHours++;
        continue;
      }
      final rainHour = math.max(tp[i] ?? 0.0, 0.0);
      final windSpeed = math.sqrt(u * u + v * v);
      final cloudPct = (tcc[i] ?? 0).clamp(0.0, 100.0).toDouble();
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
    // Nothing usable at all - fail, so the panel keeps showing the last
    // good forecast and retries shortly instead of showing an empty list.
    if (result.isEmpty && missingHours > 0) {
      throw Exception('GeoSphere Austria returned no data for $missingHours hours');
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
    // Four gradations instead of the previous three ("clear"/"partly
    // cloudy"/"cloudy") - "leicht bewölkt" (mostly sunny, just a little
    // cloud) used to fall into the same bucket as genuinely balanced
    // cloud/sun conditions and showed the same icon as either extreme.
    if (cloudCoverPct <= 15) return WeatherCondition.clear;
    if (cloudCoverPct <= 40) return WeatherCondition.mostlyClear;
    if (cloudCoverPct <= 70) return WeatherCondition.partlyCloudy;
    return WeatherCondition.cloudy;
  }
}
