import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/services/sun_moon_service.dart';

/// Sun/moon path card - sunrise/sunset, civil dawn/dusk, solar noon, current
/// moon phase and the current UV index, modeled on Home Assistant's own sun
/// card (that's the explicit visual reference this was built against).
class SunMoonPanel extends StatefulWidget {
  const SunMoonPanel({super.key, required this.lat, required this.lon, this.contentScale = 1.0});

  final double lat;
  final double lon;
  final double contentScale;

  @override
  State<SunMoonPanel> createState() => _SunMoonPanelState();
}

class _SunMoonPanelState extends State<SunMoonPanel> {
  final _sunMoonService = SunMoonService();
  final _uvService = UvIndexService();

  SunTimes? _times;
  MoonPhaseInfo? _moon;
  double? _uvIndex;
  Timer? _dailyRefreshTimer;
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _computeAstronomy();
    _loadUv();
    // Sunrise/sunset et al. only meaningfully change day to day, not
    // minute to minute - an hourly refresh is just to catch the date
    // rolling over on an app that stays open for days.
    _dailyRefreshTimer = Timer.periodic(const Duration(hours: 1), (_) {
      _computeAstronomy();
      _loadUv();
    });
    // Moves the current-position dot along the curve - the astronomy
    // itself doesn't need recomputing for this, just a rebuild.
    _tickTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant SunMoonPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lat != widget.lat || oldWidget.lon != widget.lon) {
      _computeAstronomy();
      _loadUv();
    }
  }

  @override
  void dispose() {
    _dailyRefreshTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  void _computeAstronomy() {
    final now = DateTime.now();
    setState(() {
      _times = _sunMoonService.sunTimes(date: now, lat: widget.lat, lon: widget.lon);
      _moon = _sunMoonService.moonPhase(now);
    });
  }

  Future<void> _loadUv() async {
    try {
      final uv = await _uvService.getCurrentUvIndex(lat: widget.lat, lon: widget.lon);
      if (mounted) setState(() => _uvIndex = uv);
    } catch (_) {
      // UV is an extra, not core to the panel - fails silently rather than
      // showing an error state for what's otherwise a fully working card.
    }
  }

  @override
  Widget build(BuildContext context) {
    final times = _times;
    final moon = _moon;
    final scale = widget.contentScale;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.blueGrey.shade900.withValues(alpha: 0.88), Colors.black.withValues(alpha: 0.8)],
        ),
      ),
      child: times == null || moon == null
          ? const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
              ),
            )
          : Stack(
              children: [
                Padding(
                  padding: EdgeInsets.all(16 * scale),
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _TimeLabel(label: 'Sonnenaufgang', time: times.sunrise, scale: scale)),
                          Expanded(
                            child: _TimeLabel(
                              label: 'Sonnenuntergang',
                              time: times.sunset,
                              scale: scale,
                              alignEnd: true,
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 8 * scale),
                          child: CustomPaint(
                            size: Size.infinite,
                            painter: _SunPathPainter(times: times, now: DateTime.now()),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(child: _TimeLabel(label: 'Morgendämmerung', time: times.dawn, scale: scale)),
                          Expanded(
                            child: _TimeLabel(
                              label: 'Mittag',
                              time: times.solarNoon,
                              scale: scale,
                              alignCenter: true,
                            ),
                          ),
                          Expanded(
                            child: _TimeLabel(
                              label: 'Abenddämmerung',
                              time: times.dusk,
                              scale: scale,
                              alignEnd: true,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 10 * scale),
                      _MoonPhaseRow(moon: moon, scale: scale),
                    ],
                  ),
                ),
                if (_uvIndex != null &&
                    _uvIndex! > 1 &&
                    !DateTime.now().isBefore(times.sunrise) &&
                    !DateTime.now().isAfter(times.sunset))
                  Positioned(
                    top: 10 * scale,
                    left: 0,
                    right: 0,
                    child: Center(child: _UvBadge(uvIndex: _uvIndex!, scale: scale)),
                  ),
              ],
            ),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({
    required this.label,
    required this.time,
    required this.scale,
    this.alignEnd = false,
    this.alignCenter = false,
  });

  final String label;
  final DateTime time;
  final double scale;
  final bool alignEnd;
  final bool alignCenter;

  @override
  Widget build(BuildContext context) {
    final crossAlign = alignCenter
        ? CrossAxisAlignment.center
        : (alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start);
    return Column(
      crossAxisAlignment: crossAlign,
      children: [
        Text(label, style: TextStyle(color: Colors.white60, fontSize: 13 * scale)),
        SizedBox(height: 2 * scale),
        Text(
          '${time.hour}:${time.minute.toString().padLeft(2, '0')}',
          style: TextStyle(color: Colors.white, fontSize: 20 * scale, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _MoonPhaseRow extends StatelessWidget {
  const _MoonPhaseRow({required this.moon, required this.scale});

  final MoonPhaseInfo moon;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 22 * scale,
          height: 22 * scale,
          child: CustomPaint(painter: _MoonPhasePainter(illumination: moon.illumination, waxing: moon.waxing)),
        ),
        SizedBox(width: 8 * scale),
        Text(
          moon.name,
          style: TextStyle(color: Colors.white70, fontSize: 14 * scale, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Colour-coded like the weather panel's wind/rain badges - green (low) up
/// through purple (extreme), the standard WHO UV-index risk bands.
class _UvBadge extends StatelessWidget {
  const _UvBadge({required this.uvIndex, required this.scale});

  final double uvIndex;
  final double scale;

  Color get _color {
    if (uvIndex < 3) return const Color(0xFF4CAF50);
    if (uvIndex < 6) return const Color(0xFFFBC02D);
    if (uvIndex < 8) return const Color(0xFFFB8C00);
    if (uvIndex < 11) return const Color(0xFFE53935);
    return const Color(0xFF8E24AA);
  }

  // The mid bands (yellow/orange) are too light for white text to read well
  // - pick black or white per-badge based on the actual background's
  // luminance instead of hard-coding it per band.
  Color get _textColor => _color.computeLuminance() > 0.5 ? Colors.black : Colors.white;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 4 * scale),
      decoration: BoxDecoration(color: _color, borderRadius: BorderRadius.circular(20)),
      child: Text(
        'UV ${uvIndex.round()}',
        style: TextStyle(color: _textColor, fontSize: 13 * scale, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// The day/night "hill and valley" curve - a stylized sine-based elevation
/// diagram, not a physically literal solar elevation plot (matching how
/// Home Assistant's own sun card draws it too): a light-blue hill for
/// daylight (sunrise to sunset), a dark-navy valley for the night that's
/// already happened (whatever's visible before sunrise in the shown
/// window), and a thin unfilled preview line for the night still ahead
/// (after sunset) - so filled/solid always means "already happened or
/// happening now", the outline means "still to come". The current-time dot
/// is a sun while it's day, a moon while it's night.
class _SunPathPainter extends CustomPainter {
  _SunPathPainter({required this.times, required this.now});

  final SunTimes times;
  final DateTime now;

  static const _windowPadding = Duration(hours: 2);
  static const _lightBlue = Color(0xFF90CAF9);
  static const _darkNavy = Color(0xFF1A237E);

  double _elevationFraction(DateTime t) {
    final dayLength = times.sunset.difference(times.sunrise);
    final nightLength = const Duration(hours: 24) - dayLength;
    if (!t.isBefore(times.sunrise) && !t.isAfter(times.sunset)) {
      final frac = t.difference(times.sunrise).inSeconds / dayLength.inSeconds;
      return math.sin(math.pi * frac);
    }
    if (t.isAfter(times.sunset)) {
      final frac = (t.difference(times.sunset).inSeconds / nightLength.inSeconds).clamp(0.0, 1.0);
      return -math.sin(math.pi * frac);
    }
    final prevSunset = times.sunrise.subtract(nightLength);
    final frac = (t.difference(prevSunset).inSeconds / nightLength.inSeconds).clamp(0.0, 1.0);
    return -math.sin(math.pi * frac);
  }

  List<Offset> _sample(DateTime from, DateTime to, double Function(DateTime) toOffset, {int steps = 40}) {
    final totalSeconds = to.difference(from).inSeconds;
    if (totalSeconds <= 0) return const [];
    return List.generate(steps + 1, (i) {
      final frac = i / steps;
      final t = from.add(Duration(seconds: (totalSeconds * frac).round()));
      return Offset(toOffset(t), 0);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final windowStart = times.dawn.subtract(_windowPadding);
    final windowEnd = times.dusk.add(_windowPadding);
    final totalSeconds = windowEnd.difference(windowStart).inSeconds;
    final axisY = size.height * 0.58;
    final amplitude = size.height * 0.4;

    double xFor(DateTime t) => size.width * (t.difference(windowStart).inSeconds / totalSeconds);
    double yFor(DateTime t) => axisY - _elevationFraction(t) * amplitude;

    Path curvePath(DateTime from, DateTime to) {
      final path = Path();
      var first = true;
      for (final p in _sample(from, to, xFor)) {
        final t = windowStart.add(Duration(seconds: (p.dx / size.width * totalSeconds).round()));
        final y = yFor(t);
        if (first) {
          path.moveTo(p.dx, y);
          first = false;
        } else {
          path.lineTo(p.dx, y);
        }
      }
      return path;
    }

    Path fillPath(DateTime from, DateTime to) {
      final path = curvePath(from, to);
      path
        ..lineTo(xFor(to), axisY)
        ..lineTo(xFor(from), axisY)
        ..close();
      return path;
    }

    // Night before sunrise (filled dark navy - "already happened").
    if (windowStart.isBefore(times.sunrise)) {
      canvas.drawPath(fillPath(windowStart, times.sunrise), Paint()..color = _darkNavy.withValues(alpha: 0.85));
    }
    // Daylight hill (filled light blue).
    canvas.drawPath(fillPath(times.sunrise, times.sunset), Paint()..color = _lightBlue.withValues(alpha: 0.9));
    // Night after sunset (outline only - "still to come").
    if (windowEnd.isAfter(times.sunset)) {
      canvas.drawPath(
        curvePath(times.sunset, windowEnd),
        Paint()
          ..color = Colors.white38
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // Horizon axis.
    canvas.drawLine(
      Offset(0, axisY),
      Offset(size.width, axisY),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 1,
    );

    // Dawn/dusk tick marks.
    for (final t in [times.dawn, times.dusk]) {
      if (t.isBefore(windowStart) || t.isAfter(windowEnd)) continue;
      canvas.drawLine(
        Offset(xFor(t), axisY - amplitude * 0.15),
        Offset(xFor(t), axisY + amplitude * 0.15),
        Paint()
          ..color = Colors.white24
          ..strokeWidth = 1,
      );
    }

    // Current-time indicator: sun while it's day, moon while it's night.
    if (!now.isBefore(windowStart) && !now.isAfter(windowEnd)) {
      final isDay = !now.isBefore(times.sunrise) && !now.isAfter(times.sunset);
      final dot = Offset(xFor(now), yFor(now));
      canvas.drawCircle(
        dot,
        size.height * 0.09,
        Paint()..color = isDay ? const Color(0xFFFFC107) : const Color(0xFFCFD8DC),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SunPathPainter oldDelegate) =>
      oldDelegate.times != times || oldDelegate.now != now;
}

/// Terminator-shading moon icon: a bright half-disc on the correct side
/// (right if waxing, left if waning), then a shrinking/growing ellipse
/// either carving into it (crescent) or extending it (gibbous) - the
/// standard technique for a phase-accurate moon icon without needing 8
/// separate phase images.
class _MoonPhasePainter extends CustomPainter {
  _MoonPhasePainter({required this.illumination, required this.waxing});

  final double illumination;
  final bool waxing;

  static const _dark = Color(0xFF3A3A45);
  static const _lit = Color(0xFFE8E4D8);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, r, Paint()..color = _dark);

    final rect = Rect.fromCircle(center: center, radius: r);
    final startAngle = waxing ? -math.pi / 2 : math.pi / 2;
    canvas.drawArc(rect, startAngle, math.pi, true, Paint()..color = _lit);

    // t: 1 at new moon, 0 at quarter, -1 at full - the terminator ellipse's
    // half-width as a fraction of the radius.
    final t = 1 - 2 * illumination;
    if (t.abs() > 0.001) {
      final ellipseRect = Rect.fromCenter(center: center, width: r * 2 * t.abs(), height: r * 2);
      canvas.drawOval(ellipseRect, Paint()..color = t > 0 ? _dark : _lit);
    }
  }

  @override
  bool shouldRepaint(covariant _MoonPhasePainter oldDelegate) =>
      oldDelegate.illumination != illumination || oldDelegate.waxing != waxing;
}
