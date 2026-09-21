import 'dart:async';

import 'package:flutter/material.dart';
import 'package:full_svg_flutter/full_svg_flutter.dart' as full_svg;
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
    WeatherCondition.mostlyClear: WeatherSvgIcons.mostlyClearDay,
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
            child: _HeaderRow(locationName: widget.locationName),
          ),
          const SizedBox(height: 8),
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
                    // A row per hour used to carry its own "10:00" label,
                    // which reads as the weather *at* 10:00 rather than what
                    // it actually is: an hourly average for the interval
                    // *starting* at 10:00. Interleaving a thin boundary line
                    // (carrying the label) between each hour's content row -
                    // one extra trailing line for the last interval's end -
                    // makes that interval reading explicit: "10:00" and
                    // "11:00" both sit on their own line, with that hour's
                    // icon/temp/wind/rain in between.
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        itemCount: hours.length * 2 + 1,
                        itemBuilder: (context, index) {
                          if (index.isEven) {
                            final k = index ~/ 2;
                            final boundaryTime = k < hours.length
                                ? hours[k].time
                                : hours[k - 1].time.add(const Duration(hours: 1));
                            return _HourBoundary(time: boundaryTime);
                          }
                          final hour = hours[index ~/ 2];
                          return _HourRow(hour: hour, icon: _conditionIcons[hour.condition]!);
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// Shared column geometry between the header, the boundary lines and the
// hour rows, so everything lines up: the boundary line's time label sits in
// [_timeColWidth], the icon in [_iconColWidth], then temp, then the wind and
// rain badges get equal fixed-width columns of their own (both are the same
// kind of colour-coded pill now, so they read as one consistent pair).
const _timeColWidth = 54.0;
const _iconColWidth = 40.0;
const _tempColWidth = 58.0;
const _badgeColWidth = 108.0;
const _colGap = 14.0;

/// Same size/weight as the temp column's text, per explicit request - the
/// wind/rain badges used to run a size smaller.
const _badgeTextStyle = TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600);

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.locationName});

  final String locationName;

  static const _style = TextStyle(color: Colors.white38, fontSize: 13, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: _timeColWidth + _iconColWidth + 10,
          child: Row(
            children: [
              const Icon(Icons.place_rounded, color: Colors.white70, size: 16),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  locationName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: _tempColWidth, child: const Text('Temp', style: _style)),
        const SizedBox(width: _colGap),
        SizedBox(width: _badgeColWidth, child: const Center(child: Text('Wind km/h', style: _style))),
        const SizedBox(width: _colGap),
        SizedBox(width: _badgeColWidth, child: const Center(child: Text('Regen l/m²', style: _style))),
      ],
    );
  }
}

/// The thin "10:00 ----" line between two hours' content - see the doc
/// comment on the ListView.builder above for why the label moved here
/// instead of living on the content row itself.
class _HourBoundary extends StatelessWidget {
  const _HourBoundary({required this.time});

  final DateTime time;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: _timeColWidth,
            child: Text(
              '${time.hour.toString().padLeft(2, '0')}:00',
              style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: Container(height: 1, color: Colors.white24)),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: _timeColWidth),
          SizedBox(
            width: _iconColWidth,
            // weather_svg_icons' own WeatherSvgIcon widget renders static
            // icons through flutter_svg/vector_graphics, whose <mask>
            // support is incomplete - several of this icon set's icons
            // (e.g. "partly cloudy") draw their sun inside a masked group,
            // which silently disappeared entirely instead of compositing,
            // leaving just the cloud with no sun (confirmed 2026-09-21: the
            // SVG itself is correct, checked byte-for-byte against
            // "overcast", which has no mask and always rendered fine).
            // full_svg_flutter is a from-scratch SVG renderer with real
            // mask support and a flutter_svg-compatible SvgPicture.asset
            // API, so pointing it at the exact same (static, non-animated)
            // asset file fixes this without touching the icon package.
            child: full_svg.SvgPicture.asset(
              icon.assetPath,
              package: 'weather_svg_icons',
              width: _iconColWidth,
              height: _iconColWidth,
              semanticsLabel: icon.name,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _tempColWidth,
            child: Text(
              '${hour.tempC.round()}°',
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: _colGap),
          SizedBox(
            width: _badgeColWidth,
            child: Center(child: _WindBadge(kmh: windKmh)),
          ),
          const SizedBox(width: _colGap),
          SizedBox(
            width: _badgeColWidth,
            child: Center(
              child: hour.rainMmPerHour >= 0.2 ? _RainBadge(mmPerHour: hour.rainMmPerHour) : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Same colour-coded pill as [_RainBadge] - calm wind fades in unobtrusively
/// (low alpha, muted colour), strong wind gets an opaque, urgent red -
/// instead of the previous plain (and easy to miss) tinted-text-only
/// treatment, for visual consistency with the rain badge next to it. Capped
/// at [_maxKmh]; text is just the number now, since the unit moved to the
/// column header.
class _WindBadge extends StatelessWidget {
  const _WindBadge({required this.kmh});

  final int kmh;

  static const _maxKmh = 35.0;
  static const _calm = Color(0xFF4A7A6B);
  static const _strong = Color(0xFFD32F2F);

  @override
  Widget build(BuildContext context) {
    final t = (kmh / _maxKmh).clamp(0.0, 1.0);
    final background = Color.lerp(_calm, _strong, t)!.withValues(alpha: 0.35 + 0.55 * t);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.air_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 4),
          Text('$kmh', style: _badgeTextStyle),
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
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.water_drop_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 4),
          Text('${mmPerHour.toStringAsFixed(1)} l', style: _badgeTextStyle),
        ],
      ),
    );
  }
}
