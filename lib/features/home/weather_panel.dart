import 'dart:async';

import 'package:flutter/material.dart';
import 'package:full_svg_flutter/full_svg_flutter.dart' as full_svg;
import 'package:weather_svg_icons/weather_svg_icons.dart';

import '../../data/models/hourly_forecast.dart';
import '../../data/services/geosphere_weather_service.dart';
import '../../data/services/sun_moon_service.dart';

/// Vertical (top-to-bottom) hourly forecast for the rest of today, sourced
/// from GeoSphere Austria (see GeoSphereWeatherService's doc comment for
/// why - Austria-specific, free, no API key).
class WeatherPanel extends StatefulWidget {
  const WeatherPanel({
    super.key,
    required this.locationName,
    required this.lat,
    required this.lon,
    this.contentScale = 1.0,
  });

  final String locationName;
  final double lat;
  final double lon;

  /// Scales the forecast content (icon/text/badge sizes, column widths)
  /// independently of the tile's own box size (see WeatherDisplaySettings'
  /// own doc comment for why those are kept separate) - 1.0 is this
  /// widget's own natural/previous fixed sizing.
  final double contentScale;

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
    _retryTimer?.cancel();
    super.dispose();
  }

  // Retries a failed load on its own (5s, 10s, 20s, ... capped at 60s)
  // instead of waiting for the next 30-minute refresh - on autostart right
  // after boot the network is often not up yet, which used to leave the
  // tile stuck on "Wetter nicht verfügbar" for half an hour.
  Timer? _retryTimer;
  int _failedAttempts = 0;

  Future<void> _load() async {
    _retryTimer?.cancel();
    try {
      final hours = await _service.getHourlyForecast(lat: widget.lat, lon: widget.lon);
      _failedAttempts = 0;
      if (mounted) {
        setState(() {
          _hours = hours;
          _error = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      final delaySeconds = (5 * (1 << _failedAttempts)).clamp(5, 60);
      _failedAttempts = (_failedAttempts + 1).clamp(0, 4);
      _retryTimer = Timer(Duration(seconds: delaySeconds), _load);
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

  // Night variants (moon instead of sun) for the conditions whose day icon
  // actually shows a sun - the rest (overcast/rain/snow) have no sun to swap.
  static const _nightConditionIcons = {
    WeatherCondition.clear: WeatherSvgIcons.clearNight,
    WeatherCondition.mostlyClear: WeatherSvgIcons.mostlyClearNight,
    WeatherCondition.partlyCloudy: WeatherSvgIcons.partlyCloudyNight,
  };

  final _sunMoonService = SunMoonService();

  /// Whether [hour]'s interval (it's an hourly average starting at
  /// hour.time - see the ListView's own doc comment) is mostly at night,
  /// judged by its midpoint against that day's sunrise/sunset.
  bool _isNight(HourlyForecast hour) {
    final mid = hour.time.add(const Duration(minutes: 30));
    final times = _sunMoonService.sunTimes(date: mid, lat: widget.lat, lon: widget.lon);
    return mid.isBefore(times.sunrise) || mid.isAfter(times.sunset);
  }

  WeatherSvgIconData _iconFor(HourlyForecast hour) =>
      (_isNight(hour) ? _nightConditionIcons[hour.condition] : null) ?? _conditionIcons[hour.condition]!;

  @override
  Widget build(BuildContext context) {
    final hours = _hours;
    final metrics = _Metrics(widget.contentScale);
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
            child: _HeaderRow(locationName: widget.locationName, metrics: metrics),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: hours == null
                ? Center(
                    child: _error != null
                        ? const Text(
                            'Wetter nicht verfügbar - versuche erneut…',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          )
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
                            return _HourBoundary(time: boundaryTime, metrics: metrics);
                          }
                          final hour = hours[index ~/ 2];
                          return _HourRow(hour: hour, icon: _iconFor(hour), metrics: metrics);
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// Shared column geometry between the header, the boundary lines and the hour
// rows, so everything lines up: the boundary line's time label sits in
// timeColWidth, the icon in iconColWidth, then temp - all fixed widths, left-
// aligned. Wind is centered in whatever space remains after that (an
// Expanded at the call site, not a metric here), and Regen gets a fixed-
// width column flush against the right edge - Temp left/Wind centered/Regen
// right, rather than all three bunched up together next to the icon. The
// badge column still comfortably fits the widest realistic content ("5.0 l",
// "35" km/h) at scale 1.0, verified against actual glyph widths, not just
// eyeballed. All of it scales with WeatherPanel.contentScale.
class _Metrics {
  const _Metrics(this.scale);

  final double scale;

  double get timeColWidth => 54 * scale;
  // Extra breathing room between the time label/boundary line and the
  // icon/content that follows - previously butted right up against it.
  double get leftGap => 8 * scale;
  double get iconColWidth => 40 * scale;
  double get tempColWidth => 50 * scale;
  double get badgeColWidth => 94 * scale;
  double get headerFontSize => 13 * scale;
  double get boundaryFontSize => 15 * scale;
  double get tempFontSize => 22 * scale;
  double get badgeFontSize => 22 * scale;
  double get badgeIconSize => 20 * scale;
  double get locationFontSize => 16 * scale;
  double get locationIconSize => 16 * scale;

  TextStyle get badgeTextStyle =>
      TextStyle(color: Colors.white, fontSize: badgeFontSize, fontWeight: FontWeight.w600);
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.locationName, required this.metrics});

  final String locationName;
  final _Metrics metrics;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: Colors.white38, fontSize: metrics.headerFontSize, fontWeight: FontWeight.w600);
    return Row(
      children: [
        SizedBox(
          width: metrics.timeColWidth + metrics.leftGap + metrics.iconColWidth + 10,
          child: Row(
            children: [
              Icon(Icons.place_rounded, color: Colors.white70, size: metrics.locationIconSize),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  locationName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: metrics.locationFontSize,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: metrics.tempColWidth, child: Text('Temp', style: style)),
        // Wind centered in whatever space is left between Temp and Regen,
        // Regen flush against the card's right edge - matches how the
        // badges themselves are now laid out below (see _HourRow).
        Expanded(child: Center(child: Text('Wind km/h', style: style))),
        SizedBox(width: metrics.badgeColWidth, child: Center(child: Text('Regen l/m²', style: style))),
      ],
    );
  }
}

/// The thin "10:00 ----" line between two hours' content - see the doc
/// comment on the ListView.builder above for why the label moved here
/// instead of living on the content row itself.
class _HourBoundary extends StatelessWidget {
  const _HourBoundary({required this.time, required this.metrics});

  final DateTime time;
  final _Metrics metrics;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: metrics.timeColWidth,
            child: Text(
              '${time.hour.toString().padLeft(2, '0')}:00',
              style: TextStyle(
                color: Colors.white70,
                fontSize: metrics.boundaryFontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(width: metrics.leftGap),
          Expanded(child: Container(height: 1, color: Colors.white24)),
        ],
      ),
    );
  }
}

class _HourRow extends StatelessWidget {
  const _HourRow({required this.hour, required this.icon, required this.metrics});

  final HourlyForecast hour;
  final WeatherSvgIconData icon;
  final _Metrics metrics;

  @override
  Widget build(BuildContext context) {
    final windKmh = (hour.windSpeedMs * 3.6).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: metrics.timeColWidth),
          SizedBox(width: metrics.leftGap),
          SizedBox(
            width: metrics.iconColWidth,
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
              width: metrics.iconColWidth,
              height: metrics.iconColWidth,
              semanticsLabel: icon.name,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: metrics.tempColWidth,
            child: Text(
              '${hour.tempC.round()}°',
              style: TextStyle(color: Colors.white, fontSize: metrics.tempFontSize, fontWeight: FontWeight.w600),
            ),
          ),
          // Wind centered in whatever space is left between Temp and Regen,
          // Regen flush against the card's right edge, rather than both
          // badges just sitting in their own narrow columns right next to
          // Temp - matches the header above.
          Expanded(child: Center(child: _WindBadge(kmh: windKmh, metrics: metrics))),
          SizedBox(
            width: metrics.badgeColWidth,
            child: Center(
              child: hour.rainMmPerHour >= 0.2 ? _RainBadge(mmPerHour: hour.rainMmPerHour, metrics: metrics) : null,
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
  const _WindBadge({required this.kmh, required this.metrics});

  final int kmh;
  final _Metrics metrics;

  static const _maxKmh = 35.0;
  static const _calm = Color(0xFF4A7A6B);
  static const _strong = Color(0xFFD32F2F);

  @override
  Widget build(BuildContext context) {
    final t = (kmh / _maxKmh).clamp(0.0, 1.0);
    final background = Color.lerp(_calm, _strong, t)!.withValues(alpha: 0.35 + 0.55 * t);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9 * metrics.scale, vertical: 4 * metrics.scale),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.air_rounded, color: Colors.white, size: metrics.badgeIconSize),
          const SizedBox(width: 4),
          Text('$kmh', style: metrics.badgeTextStyle),
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
  const _RainBadge({required this.mmPerHour, required this.metrics});

  final double mmPerHour;
  final _Metrics metrics;

  static const _maxMm = 5.0;
  static const _lightBlue = Color(0xFF4FA3E0);
  static const _deepBlue = Color(0xFF0D47A1);

  @override
  Widget build(BuildContext context) {
    final t = (mmPerHour / _maxMm).clamp(0.0, 1.0);
    final background = Color.lerp(_lightBlue, _deepBlue, t)!.withValues(alpha: 0.35 + 0.55 * t);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9 * metrics.scale, vertical: 4 * metrics.scale),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.water_drop_rounded, color: Colors.white, size: metrics.badgeIconSize),
          const SizedBox(width: 4),
          Text('${mmPerHour.toStringAsFixed(1)} l', style: metrics.badgeTextStyle),
        ],
      ),
    );
  }
}
