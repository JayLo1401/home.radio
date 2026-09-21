import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Sunrise/sunset, civil-twilight (dawn/dusk) and solar-noon for one local
/// day, plus the current moon phase.
class SunTimes {
  const SunTimes({
    required this.sunrise,
    required this.sunset,
    required this.dawn,
    required this.dusk,
    required this.solarNoon,
  });

  final DateTime sunrise;
  final DateTime sunset;

  /// Civil twilight (sun 6° below the horizon) - the common everyday
  /// "dawn"/"dusk" definition, matching Home Assistant's sun card (the
  /// visual reference for this panel).
  final DateTime dawn;
  final DateTime dusk;

  final DateTime solarNoon;
}

class MoonPhaseInfo {
  const MoonPhaseInfo({required this.name, required this.illumination, required this.waxing});

  final String name;

  /// 0.0 (new) .. 1.0 (full).
  final double illumination;
  final bool waxing;
}

/// Sunrise/sunset/twilight/solar-noon and moon-phase - pure astronomical
/// geometry (the standard, public-domain NOAA Solar Calculator equations,
/// and a standard synodic-month moon-phase estimate), computed locally
/// rather than fetched: both are fully determined by date/lat/lon and don't
/// need live data, unlike UV index (see [UvIndexService] below), which
/// depends on actual atmospheric/ozone conditions.
class SunMoonService {
  SunTimes sunTimes({required DateTime date, required double lat, required double lon}) {
    final localMidnight = DateTime(date.year, date.month, date.day);
    final utcOffsetHours = localMidnight.timeZoneOffset.inMinutes / 60.0;
    return SunTimes(
      sunrise: _solarEvent(localMidnight, lat, lon, utcOffsetHours, 90.833, rising: true),
      sunset: _solarEvent(localMidnight, lat, lon, utcOffsetHours, 90.833, rising: false),
      dawn: _solarEvent(localMidnight, lat, lon, utcOffsetHours, 96.0, rising: true),
      dusk: _solarEvent(localMidnight, lat, lon, utcOffsetHours, 96.0, rising: false),
      solarNoon: _solarNoon(localMidnight, lon, utcOffsetHours),
    );
  }

  MoonPhaseInfo moonPhase(DateTime date) {
    // A known new-moon reference instant; the phase repeats every synodic
    // month from there. Accurate to well under a day, which is all a
    // cosmetic phase display needs.
    final reference = DateTime.utc(2000, 1, 6, 18, 14);
    const synodicMonthDays = 29.530588853;
    final daysSinceReference = date.toUtc().difference(reference).inMinutes / 1440.0;
    var age = daysSinceReference % synodicMonthDays;
    if (age < 0) age += synodicMonthDays;
    final fraction = age / synodicMonthDays; // 0=new, 0.25=first quarter, 0.5=full, 0.75=last quarter
    final illumination = (1 - math.cos(2 * math.pi * fraction)) / 2;
    return MoonPhaseInfo(name: _phaseName(fraction), illumination: illumination, waxing: fraction < 0.5);
  }

  String _phaseName(double f) {
    if (f < 0.02 || f > 0.98) return 'Neumond';
    if (f < 0.23) return 'Zunehmende Sichel';
    if (f < 0.27) return 'Zunehmender Halbmond';
    if (f < 0.48) return 'Zunehmender Dreiviertelmond';
    if (f < 0.52) return 'Vollmond';
    if (f < 0.73) return 'Abnehmender Dreiviertelmond';
    if (f < 0.77) return 'Abnehmender Halbmond';
    return 'Abnehmende Sichel';
  }

  // --- NOAA Solar Calculator equations (public domain) ---

  double _julianDay(int year, int month, int day) {
    var y = year;
    var m = month;
    if (m <= 2) {
      y -= 1;
      m += 12;
    }
    final a = (y / 100).floor();
    final b = 2 - a + (a / 4).floor();
    return (365.25 * (y + 4716)).floorToDouble() + (30.6001 * (m + 1)).floorToDouble() + day + b - 1524.5;
  }

  double _julianCentury(double jd) => (jd - 2451545.0) / 36525.0;

  double _geomMeanLongSun(double t) {
    final l = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360;
    return l < 0 ? l + 360 : l;
  }

  double _geomMeanAnomalySun(double t) => 357.52911 + t * (35999.05029 - 0.0001537 * t);

  double _eccentEarthOrbit(double t) => 0.016708634 - t * (0.000042037 + 0.0000001267 * t);

  double _sunEqOfCenter(double t) {
    final m = _deg2rad(_geomMeanAnomalySun(t));
    return math.sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
        math.sin(2 * m) * (0.019993 - 0.000101 * t) +
        math.sin(3 * m) * 0.000289;
  }

  double _sunTrueLong(double t) => _geomMeanLongSun(t) + _sunEqOfCenter(t);

  double _sunAppLong(double t) {
    final omega = 125.04 - 1934.136 * t;
    return _sunTrueLong(t) - 0.00569 - 0.00478 * math.sin(_deg2rad(omega));
  }

  double _meanObliquityEcliptic(double t) {
    final seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813));
    return 23.0 + (26.0 + seconds / 60.0) / 60.0;
  }

  double _obliquityCorrection(double t) {
    final omega = 125.04 - 1934.136 * t;
    return _meanObliquityEcliptic(t) + 0.00256 * math.cos(_deg2rad(omega));
  }

  double _sunDeclination(double t) {
    final sinDec = math.sin(_deg2rad(_obliquityCorrection(t))) * math.sin(_deg2rad(_sunAppLong(t)));
    return _rad2deg(math.asin(sinDec));
  }

  double _eqOfTime(double t) {
    final epsilon = _deg2rad(_obliquityCorrection(t));
    final l0 = _deg2rad(_geomMeanLongSun(t));
    final e = _eccentEarthOrbit(t);
    final m = _deg2rad(_geomMeanAnomalySun(t));
    var y = math.tan(epsilon / 2);
    y *= y;
    final etime = y * math.sin(2 * l0) -
        2 * e * math.sin(m) +
        4 * e * y * math.sin(m) * math.cos(2 * l0) -
        0.5 * y * y * math.sin(4 * l0) -
        1.25 * e * e * math.sin(2 * m);
    return _rad2deg(etime) * 4;
  }

  double _hourAngle(double lat, double solarDec, double zenith) {
    final latRad = _deg2rad(lat);
    final decRad = _deg2rad(solarDec);
    final cosH =
        (math.cos(_deg2rad(zenith)) - math.sin(latRad) * math.sin(decRad)) / (math.cos(latRad) * math.cos(decRad));
    return _rad2deg(math.acos(cosH.clamp(-1.0, 1.0)));
  }

  DateTime _solarNoon(DateTime localMidnight, double lon, double utcOffsetHours) {
    final t = _julianCentury(_localNoonJulianDay(localMidnight, utcOffsetHours));
    final solarNoonUtcMinutes = 720 - 4 * lon - _eqOfTime(t);
    return _utcMinutesToLocal(localMidnight, solarNoonUtcMinutes, utcOffsetHours);
  }

  DateTime _solarEvent(
    DateTime localMidnight,
    double lat,
    double lon,
    double utcOffsetHours,
    double zenith, {
    required bool rising,
  }) {
    final t = _julianCentury(_localNoonJulianDay(localMidnight, utcOffsetHours));
    final eqTime = _eqOfTime(t);
    final solarDec = _sunDeclination(t);
    final hourAngle = _hourAngle(lat, solarDec, zenith);
    final delta = rising ? hourAngle : -hourAngle;
    final eventUtcMinutes = 720 - 4 * (lon + delta) - eqTime;
    return _utcMinutesToLocal(localMidnight, eventUtcMinutes, utcOffsetHours);
  }

  /// Julian Day for local noon of [localMidnight]'s date - evaluating the
  /// slowly-changing solar parameters (declination, equation of time) once
  /// per day at local noon (rather than separately for sunrise/dawn/etc.)
  /// is the standard simplification this algorithm is normally used with;
  /// those parameters move far too little over one day to matter here.
  double _localNoonJulianDay(DateTime localMidnight, double utcOffsetHours) =>
      _julianDay(localMidnight.year, localMidnight.month, localMidnight.day) + 0.5 - utcOffsetHours / 24.0;

  DateTime _utcMinutesToLocal(DateTime localMidnight, double utcMinutes, double utcOffsetHours) {
    final localMinutes = utcMinutes + utcOffsetHours * 60;
    return localMidnight.add(Duration(minutes: localMinutes.round()));
  }

  double _deg2rad(double deg) => deg * math.pi / 180.0;
  double _rad2deg(double rad) => rad * 180.0 / math.pi;
}

/// Current UV index via Open-Meteo's free, no-API-key forecast endpoint -
/// unlike sunrise/sunset/moon phase, this genuinely needs live data (ozone
/// column, cloud cover, aerosols), not just geometry, and isn't available
/// from GeoSphere Austria's AROME model (checked its parameter list
/// directly - no UV-related parameter exists there at all).
class UvIndexService {
  static const _baseUrl = 'https://api.open-meteo.com/v1/forecast';

  Future<double?> getCurrentUvIndex({required double lat, required double lon}) async {
    final uri = Uri.parse('$_baseUrl?latitude=$lat&longitude=$lon&hourly=uv_index&timezone=auto&forecast_days=1');
    final response = await http.get(uri, headers: {'User-Agent': 'home_radio/1.0'});
    if (response.statusCode != 200) {
      throw Exception('Open-Meteo UV request failed: HTTP ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final hourly = json['hourly'] as Map<String, dynamic>;
    final times = (hourly['time'] as List).cast<String>();
    final values = (hourly['uv_index'] as List).cast<num>();
    final now = DateTime.now();
    for (var i = 0; i < times.length; i++) {
      final t = DateTime.parse(times[i]);
      if (t.year == now.year && t.month == now.month && t.day == now.day && t.hour == now.hour) {
        return values[i].toDouble();
      }
    }
    return values.isEmpty ? null : values.last.toDouble();
  }
}
