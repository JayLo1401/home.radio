import 'dart:async';

import 'package:flutter/material.dart';
import 'package:weather_svg_icons/weather_svg_icons.dart';

import '../../data/models/hourly_forecast.dart';
import '../../data/services/geosphere_weather_service.dart';

/// Vertical (top-to-bottom) hourly forecast for the rest of today, sourced
/// from GeoSphere Austria (see GeoSphereWeatherService's doc comment for
/// why - Austria-specific, free, no API key).
class WeatherPanel extends StatefulWidget {
  const WeatherPanel({super.key, required this.locationName, required this.lat, required this.lon});

  final String locationName;
  final double lat;
  final double lon;

  @override
  State<WeatherPanel> createState() => _WeatherPanelState();
}

class _WeatherPanelState extends State<WeatherPanel> {
  final _service = GeoSphereWeatherService();
  List<HourlyForecast>? _hours;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(minutes: 30), (_) => _load());
  }

  @override
  void didUpdateWidget(covariant WeatherPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lat != widget.lat || oldWidget.lon != widget.lon) _load();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final hours = await _service.getHourlyForecast(lat: widget.lat, lon: widget.lon);
      if (mounted) setState(() => _hours = hours);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // Proper illustrated meteorological icons (the "meteocons"-style set via
  // the weather_svg_icons package) instead of repurposed generic Material
  // icons - drawn in their own natural colours (sun = yellow, cloud = grey,
  // ...), so no colour tint is applied on top.
  static const _conditionIcons = {
    WeatherCondition.clear: WeatherSvgIcons.clearDay,
    WeatherCondition.partlyCloudy: WeatherSvgIcons.partlyCloudyDay,
    WeatherCondition.cloudy: WeatherSvgIcons.overcast,
    WeatherCondition.rainy: WeatherSvgIcons.rain,
    WeatherCondition.pouring: WeatherSvgIcons.extremeRain,
    WeatherCondition.snowy: WeatherSvgIcons.snow,
  };

  @override
  Widget build(BuildContext context) {
    final hours = _hours;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.blueGrey.shade900.withValues(alpha: 0.88), Colors.black.withValues(alpha: 0.8)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                const Icon(Icons.place_rounded, color: Colors.white70, size: 16),
                const SizedBox(width: 4),
                Text(
                  widget.locationName,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(width: 8),
                const Text('· Heute', style: TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _HeaderRow(),
          ),
          const Divider(height: 8, color: Colors.white12, thickness: 1),
          Expanded(
            child: hours == null
                ? Center(
                    child: _error != null
                        ? const Text('Wetter nicht verfügbar', style: TextStyle(color: Colors.white54, fontSize: 12))
                        : const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                          ),
                  )
                : hours.isEmpty
                    ? const Center(
                        child: Text('Keine Daten', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        itemCount: hours.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white10),
                        itemBuilder: (context, index) => _HourRow(
                          hour: hours[index],
                          icon: _conditionIcons[hours[index].condition]!,
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  static const _style = TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(width: 38, child: Text('Zeit', style: _style)),
        SizedBox(width: 30),
        SizedBox(width: 40, child: Text('Temp', style: _style)),
        Expanded(child: Text('Wind', style: _style)),
        Text('Regen', style: _style),
      ],
    );
  }
}

class _HourRow extends StatelessWidget {
  const _HourRow({required this.hour, required this.icon});

  final HourlyForecast hour;
  final WeatherSvgIconData icon;

  @override
  Widget build(BuildContext context) {
    final windKmh = (hour.windSpeedMs * 3.6).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            // No explicit fontSize: inherits the app's default text size, so
            // this matches the station name text size in FavoritesSidebar.
            child: Text(
              '${hour.time.hour.toString().padLeft(2, '0')}:00',
              style: const TextStyle(color: Colors.white60),
            ),
          ),
          SizedBox(
            width: 34,
            child: WeatherSvgIcon(icon, size: 28),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${hour.tempC.round()}°',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                const Icon(Icons.air_rounded, color: Colors.white38, size: 16),
                const SizedBox(width: 3),
                Text('$windKmh km/h', style: const TextStyle(color: Colors.white54)),
              ],
            ),
          ),
          SizedBox(
            width: 68,
            child: hour.rainMmPerHour >= 0.2
                ? Align(
                    alignment: Alignment.centerRight,
                    child: _RainBadge(mmPerHour: hour.rainMmPerHour),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// Precipitation badge: background blueness scales with the hourly amount
/// (light blue just above the display threshold, deeper blue the more it
/// rains, capped at [_maxMm]) - text/icon are always white, since even the
/// lightest badge shade needs the contrast.
class _RainBadge extends StatelessWidget {
  const _RainBadge({required this.mmPerHour});

  final double mmPerHour;

  static const _maxMm = 5.0;
  static const _lightBlue = Color(0xFF4FA3E0);
  static const _deepBlue = Color(0xFF0D47A1);

  @override
  Widget build(BuildContext context) {
    final t = (mmPerHour / _maxMm).clamp(0.0, 1.0);
    final background = Color.lerp(_lightBlue, _deepBlue, t)!.withValues(alpha: 0.35 + 0.55 * t);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.water_drop_rounded, color: Colors.white, size: 13),
          const SizedBox(width: 3),
          Text('${mmPerHour.toStringAsFixed(1)} l', style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}
