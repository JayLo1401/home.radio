/// Simplified weather condition for icon selection, derived from physical
/// parameters (temperature/precipitation/cloud cover) rather than
/// GeoSphere Austria's own `sy` weather-symbol code, which is undocumented
/// and proprietary (confirmed 2026-09-17 while researching this - even the
/// most complete open-source GeoSphere integration derives its own
/// condition the same way rather than decoding `sy`).
enum WeatherCondition {
  clear,
  partlyCloudy,
  cloudy,
  rainy,
  pouring,
  snowy,
}

class HourlyForecast {
  const HourlyForecast({
    required this.time,
    required this.tempC,
    required this.rainMmPerHour,
    required this.windSpeedMs,
    required this.cloudCoverPct,
    required this.condition,
  });

  final DateTime time;
  final double tempC;
  final double rainMmPerHour;
  final double windSpeedMs;
  final double cloudCoverPct;
  final WeatherCondition condition;
}
