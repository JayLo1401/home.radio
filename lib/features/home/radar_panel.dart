import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/models/base_map.dart';
import '../../data/services/cloud_service.dart';
import '../../data/services/lightning_service.dart';
import '../../data/services/nowcast_service.dart';

/// The app's own weather radar, drawn natively from open data:
/// - map: shaded relief (Copernicus DEM) with Natural Earth borders, lakes,
///   rivers and cities
/// - clouds (white = high/thick, grey = low): EUMETSAT satellite imagery
/// - precipitation by type and intensity (rain blue, snow pink, sleet lilac,
///   freezing rain red, >= 50 mm/h violet = hail possible) and gusts:
///   GeoSphere Austria nowcast (1 km, 15 min) - Austria and surroundings
/// - lightning of the last 5 minutes as dots sized/coloured by intensity:
///   EUMETSAT MTG Lightning Imager (Europe-wide)
class RadarPanel extends StatefulWidget {
  const RadarPanel({super.key, required this.lat, required this.lon, this.radiusKm = 50, this.dimming = 0.0});

  final double lat;
  final double lon;

  /// Distance (km) from the location to the top/bottom edge of the map.
  final double radiusKm;

  /// 0.0 = no dimming, 1.0 = fully black; a plain overlay so the intensity
  /// colours keep their meaning.
  final double dimming;

  @override
  State<RadarPanel> createState() => _RadarPanelState();
}

class _RadarPanelState extends State<RadarPanel> {
  final _nowcast = NowcastService();
  final _lightningService = LightningService();
  final _cloudService = CloudService();

  BaseMap? _map;
  ui.Image? _relief;
  NowcastField? _rain;
  NowcastField? _type;
  NowcastField? _gust;
  LightningFrame? _lightning;
  CloudFrame? _clouds;
  GeoBox? _area;
  DateTime? _rainStep;
  DateTime? _lightningAt;
  DateTime? _cloudsAt;
  Timer? _timer;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    BaseMap.load().then((m) {
      if (mounted) setState(() => _map = m);
    });
    ReliefMap.load().then((img) {
      if (mounted) setState(() => _relief = img);
    });
    _timer = Timer.periodic(const Duration(minutes: 2, seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  GeoBox _areaFor(Size size) {
    final halfKm = widget.radiusKm * 1.05;
    final halfLat = halfKm / 110.57;
    final halfLon = halfKm * (size.width / size.height) / (111.32 * math.cos(widget.lat * math.pi / 180));
    // Rounded so tiny layout changes don't trigger refetches.
    double r(double v) => (v * 200).round() / 200;
    return GeoBox(r(widget.lat - halfLat), r(widget.lon - halfLon), r(widget.lat + halfLat), r(widget.lon + halfLon));
  }

  void _setArea(GeoBox area) {
    if (area == _area) return;
    _area = area;
    _rain = _type = _gust = null;
    _rainStep = null;
    _lightning = null;
    _lightningAt = null;
    _clouds = null;
    _cloudsAt = null;
    // Deferred: this is called during build.
    scheduleMicrotask(_refresh);
  }

  Future<void> _refresh() async {
    final area = _area;
    if (area == null || _refreshing || !mounted) return;
    _refreshing = true;
    try {
      await Future.wait([_refreshNowcast(area), _refreshLightning(area), _refreshClouds(area)]);
    } finally {
      _refreshing = false;
    }
    // The area may have changed while fetching.
    if (mounted && _area != area) unawaited(_refresh());
  }

  Future<void> _refreshNowcast(GeoBox area) async {
    try {
      final step = await _nowcast.currentStep();
      if (step == _rainStep && _rain != null) return;
      final results = await Future.wait([
        _nowcast.fetch('rr', area, step),
        _nowcast.fetch('pt', area, step),
        _nowcast.fetch('fx', area, step),
      ]);
      if (!mounted || area != _area) return;
      setState(() {
        _rain = results[0];
        _type = results[1];
        _gust = results[2];
        _rainStep = step;
      });
    } catch (e) {
      debugPrint('RadarPanel: nowcast failed: $e');
    }
  }

  Future<void> _refreshLightning(GeoBox area) async {
    final last = _lightningAt;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 2)) return;
    try {
      final frame = await _lightningService.fetch(area);
      if (!mounted || area != _area) return;
      setState(() {
        _lightning = frame;
        _lightningAt = DateTime.now();
      });
    } catch (e) {
      debugPrint('RadarPanel: lightning failed: $e');
    }
  }

  Future<void> _refreshClouds(GeoBox area) async {
    final last = _cloudsAt;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 9)) return;
    try {
      final frame = await _cloudService.fetch(area);
      if (!mounted || area != _area) return;
      setState(() {
        _clouds = frame;
        _cloudsAt = DateTime.now();
      });
    } catch (e) {
      debugPrint('RadarPanel: clouds failed: $e');
    }
  }

  double get _kmPerDegLon => 111.32 * math.cos(widget.lat * math.pi / 180);

  /// Distance (km) of the nearest lightning within [radiusKm], or null.
  double? _nearestLightningKm(double radiusKm) {
    final f = _lightning;
    if (f == null) return null;
    double? best;
    for (final s in f.strikes) {
      final dx = (s.lon - widget.lon) * _kmPerDegLon;
      final dy = (s.lat - widget.lat) * 110.57;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d <= radiusKm && (best == null || d < best)) best = d;
    }
    return best;
  }

  /// Strongest gust (km/h) within [radiusKm] of the location.
  double? _maxGustKmh(double radiusKm) {
    final g = _gust;
    if (g == null) return null;
    double? best;
    for (var i = 0; i < g.values.length; i++) {
      final v = g.values[i];
      if (v.isNaN) continue;
      final dx = (g.lon[i] - widget.lon) * _kmPerDegLon;
      final dy = (g.lat[i] - widget.lat) * 110.57;
      if (dx * dx + dy * dy > radiusKm * radiusKm) continue;
      if (best == null || v > best) best = v;
    }
    return best == null ? null : best * 3.6;
  }

  String _hhmm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.width > 0 && size.height > 0) _setArea(_areaFor(size));
        final inCoverage = _area?.intersect(NowcastService.coverage) != null;
        final nearest = _nearestLightningKm(30);
        final gust = _maxGustKmh(15);
        const label = TextStyle(color: Colors.white, fontSize: 11, shadows: [Shadow(blurRadius: 3)]);
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _RadarPainter(
                  map: _map,
                  relief: _relief,
                  clouds: _clouds,
                  rain: _rain,
                  type: _type,
                  lightning: _lightning,
                  centerLat: widget.lat,
                  centerLon: widget.lon,
                  halfHeightKm: widget.radiusKm,
                ),
              ),
              Positioned(
                left: 8,
                top: 6,
                child: Text(
                  [
                    if (_rainStep != null) 'Niederschlag ${_hhmm(_rainStep!)}',
                    if (_rainStep == null && !inCoverage) 'Niederschlag nur für Österreich',
                    if (_lightningAt != null) 'Blitze ${_hhmm(_lightningAt!)}',
                  ].join(' · '),
                  style: label,
                ),
              ),
              Positioned(
                right: 8,
                top: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (nearest != null)
                      _Badge(
                        icon: Icons.bolt,
                        color: const Color(0xFFFFE600),
                        text: nearest < 3 ? 'Gewitter hier' : 'Blitze ${nearest.round()} km',
                      ),
                    if (gust != null && gust >= 40) ...[
                      const SizedBox(height: 4),
                      _Badge(
                        icon: Icons.air,
                        color: gust >= 90
                            ? const Color(0xFFFF5252)
                            : (gust >= 60 ? const Color(0xFFFF9800) : Colors.white),
                        text: 'Böen ${gust.round()} km/h',
                      ),
                    ],
                  ],
                ),
              ),
              const Positioned(left: 8, bottom: 6, child: _Legend()),
              if (widget.dimming > 0)
                IgnorePointer(child: Container(color: Colors.black.withValues(alpha: widget.dimming))),
            ],
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 3),
          Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white, fontSize: 10);
    Widget bar(List<Color> colors) => Container(
          width: 36,
          height: 6,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(3),
          ),
        );
    Widget dot(Color c) => Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.black54)),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Regen ', style: style),
          bar(const [Color(0xFFB3ECFF), Color(0xFF2E8FEA), Color(0xFF0F3075)]),
          const Text('  Schnee ', style: style),
          bar(const [Color(0xFFFFC2EE), Color(0xFFFF6FCF)]),
          const Text('  Hagel ', style: style),
          dot(const Color(0xFF9C27B0)),
          const Text('  Blitze ', style: style),
          dot(const Color(0xFFFFE600)),
          dot(const Color(0xFFFF6D00)),
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.map,
    required this.relief,
    required this.clouds,
    required this.rain,
    required this.type,
    required this.lightning,
    required this.centerLat,
    required this.centerLon,
    required this.halfHeightKm,
  });

  final BaseMap? map;
  final ui.Image? relief;
  final CloudFrame? clouds;
  final NowcastField? rain;
  final NowcastField? type;
  final LightningFrame? lightning;
  final double centerLat, centerLon, halfHeightKm;

  // Precipitation rate (mm/h) classes.
  static const _limits = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0];
  static const _hailRate = 50.0; // "hail possible" above this, any type
  static const _rain = [
    Color(0xE6B3ECFF),
    Color(0xE680D4FF),
    Color(0xE64DB8FF),
    Color(0xE62E8FEA),
    Color(0xE61F66CC),
    Color(0xE616479E),
    Color(0xE60F3075),
  ];
  static const _snow = [
    Color(0xE6FFD6F3),
    Color(0xE6FFC2EE),
    Color(0xE6FFADE8),
    Color(0xE6FF9BE0),
    Color(0xE6FF85D8),
    Color(0xE6FF6FCF),
    Color(0xE6F04DBE),
  ];
  static const _sleet = [
    Color(0xE6E6D4FF),
    Color(0xE6D7B8FF),
    Color(0xE6C9A3FF),
    Color(0xE6B48CFF),
    Color(0xE69F75F5),
    Color(0xE68A5EE8),
    Color(0xE6744AD6),
  ];
  static const _freezing = [
    Color(0xE6FFB3B3),
    Color(0xE6FF9999),
    Color(0xE6FF8080),
    Color(0xE6FF6B6B),
    Color(0xE6F05050),
    Color(0xE6E03A3A),
    Color(0xE6C62828),
  ];
  static const _hail = Color(0xF09C27B0);

  @override
  void paint(Canvas canvas, Size size) {
    final pxPerKm = (size.height / 2) / halfHeightKm;
    final kmPerDegLon = 111.32 * math.cos(centerLat * math.pi / 180);
    final cx = size.width / 2, cy = size.height / 2;
    double px(double lon) => cx + (lon - centerLon) * kmPerDegLon * pxPerKm;
    double py(double lat) => cy - (lat - centerLat) * 110.57 * pxPerKm;
    Rect geoRect(double west, double south, double east, double north) =>
        Rect.fromLTRB(px(west), py(north), px(east), py(south));

    // Background + relief.
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF3B6A2E));
    final rel = relief;
    if (rel != null) {
      final full = geoRect(ReliefMap.west, ReliefMap.south, ReliefMap.east, ReliefMap.north);
      final visible = full.intersect(Offset.zero & size);
      if (visible.width > 0 && visible.height > 0) {
        final sx = rel.width / full.width, sy = rel.height / full.height;
        final src = Rect.fromLTWH(
          (visible.left - full.left) * sx,
          (visible.top - full.top) * sy,
          visible.width * sx,
          visible.height * sy,
        );
        canvas.drawImageRect(rel, src, visible, Paint()..filterQuality = FilterQuality.medium);
      }
    }

    final m = map;
    Path? path(List<Float32List>? lines, {bool close = false}) {
      if (lines == null) return null;
      final p = Path();
      for (final l in lines) {
        if (l.length < 4) continue;
        p.moveTo(px(l[0]), py(l[1]));
        for (var i = 2; i + 1 < l.length; i += 2) {
          p.lineTo(px(l[i]), py(l[i + 1]));
        }
        if (close) p.close();
      }
      return p;
    }

    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;

    if (m != null) {
      canvas.drawPath(path(m.lakes, close: true)!, Paint()..color = const Color(0xFF2E5682));
      canvas.drawPath(path(m.rivers)!, stroke(const Color(0xFF3E6E9E), 0.9));
    }

    // Clouds.
    final cl = clouds;
    if (cl != null) {
      canvas.drawImageRect(
        cl.image,
        Rect.fromLTWH(0, 0, cl.image.width.toDouble(), cl.image.height.toDouble()),
        geoRect(cl.area.west, cl.area.south, cl.area.east, cl.area.north),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }

    // Precipitation: 1 km cells as square points, one draw call per colour.
    final cellPx = math.max(1.5, pxPerKm * 1.08);
    final snowSpots = <int>{};
    const flakeGrid = 26.0;
    final r = rain, t = type;
    if (r != null) {
      final buckets = <Color, List<double>>{};
      final hasType = t != null && t.values.length == r.values.length;
      for (var i = 0; i < r.values.length; i++) {
        final v = r.values[i];
        if (v.isNaN) continue;
        final rate = v * 4; // mm per 15 min -> mm/h
        if (rate < _limits[0]) continue;
        final x = px(r.lon[i]), y = py(r.lat[i]);
        if (x < -cellPx || y < -cellPx || x > size.width + cellPx || y > size.height + cellPx) continue;
        final code = hasType ? t.values[i] : NowcastService.typeRain.toDouble();
        Color color;
        if (rate >= _hailRate) {
          color = _hail;
        } else {
          var k = 0;
          while (k + 1 < _limits.length && rate >= _limits[k + 1]) {
            k++;
          }
          if (code == NowcastService.typeSnow) {
            color = _snow[k];
            snowSpots.add((x / flakeGrid).floor() * 100000 + (y / flakeGrid).floor());
          } else if (code == NowcastService.typeRainAndSnow) {
            color = _sleet[k];
          } else if (code == NowcastService.typeFreezingRain) {
            color = _freezing[k];
          } else {
            color = _rain[k];
          }
        }
        (buckets[color] ??= <double>[])
          ..add(x)
          ..add(y);
      }
      buckets.forEach((color, pts) {
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(pts),
          Paint()
            ..color = color
            ..strokeWidth = cellPx
            ..strokeCap = StrokeCap.square,
        );
      });
    }

    // Borders above the weather, like a printed map.
    if (m != null) {
      canvas.drawPath(path(m.states)!, stroke(const Color(0x55000000), 0.8));
      canvas.drawPath(path(m.countries)!, stroke(const Color(0xDD000000), 1.4));
    }

    // Snowflake markers on a coarse grid over snowing areas.
    if (snowSpots.isNotEmpty) {
      final flake = TextPainter(
        text: const TextSpan(
          text: '✱',
          style: TextStyle(color: Colors.white, fontSize: 10, shadows: [Shadow(blurRadius: 2)]),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      for (final key in snowSpots) {
        final gx = key ~/ 100000, gy = key % 100000;
        tpPaintCentered(canvas, flake, Offset((gx + 0.5) * flakeGrid, (gy + 0.5) * flakeGrid));
      }
    }

    // Lightning: yellow dots, bigger and more orange/red the more intense.
    final l = lightning;
    if (l != null) {
      final outline = stroke(const Color(0xAA000000), 0.8);
      for (final s in l.strikes) {
        final x = px(s.lon), y = py(s.lat);
        if (x < -6 || y < -6 || x > size.width + 6 || y > size.height + 6) continue;
        final radius = 2.2 + 3.0 * s.intensity;
        final color = Color.lerp(const Color(0xFFFFE600), const Color(0xFFFF3D00), s.intensity)!;
        canvas.drawCircle(Offset(x, y), radius, Paint()..color = color);
        canvas.drawCircle(Offset(x, y), radius, outline);
      }
    }

    // Cities.
    if (m != null) {
      final maxRank = halfHeightKm < 40 ? 10 : (halfHeightKm < 120 ? 7 : (halfHeightKm < 300 ? 5 : 3));
      final placed = <Rect>[];
      final dot = Paint()..color = Colors.white;
      final dotOutline = stroke(Colors.black, 0.8);
      final sorted = [...m.cities]..sort((a, b) => a.rank.compareTo(b.rank));
      for (final c in sorted) {
        if (c.rank > maxRank) continue;
        final x = px(c.lon), y = py(c.lat);
        if (x < 0 || y < 0 || x > size.width || y > size.height) continue;
        final tp = TextPainter(
          text: TextSpan(
            text: c.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(blurRadius: 3), Shadow(blurRadius: 1)],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // A city right at the location marker gets its label beside the
        // marker instead of a dot underneath it.
        final atMarker = (x - cx).abs() < 7 && (y - cy).abs() < 7;
        final lx = atMarker ? cx + 9 : x - tp.width / 2;
        final ly = atMarker ? y - tp.height / 2 : y + 3;
        final rect = Rect.fromLTWH(lx, ly, tp.width, tp.height).inflate(2);
        if (placed.any((p) => p.overlaps(rect))) continue;
        placed.add(rect);
        if (!atMarker) {
          canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: 4, height: 4), dot);
          canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: 4, height: 4), dotOutline);
        }
        tp.paint(canvas, Offset(lx, ly));
      }
    }

    // The configured location.
    final here = Offset(cx, cy);
    canvas.drawCircle(here, 5, Paint()..color = Colors.black54);
    canvas.drawCircle(here, 5, stroke(Colors.white, 1.5));
    canvas.drawCircle(here, 1.5, Paint()..color = Colors.white);
  }

  static void tpPaintCentered(Canvas canvas, TextPainter tp, Offset center) =>
      tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.map != map ||
      old.relief != relief ||
      old.clouds != clouds ||
      old.rain != rain ||
      old.type != type ||
      old.lightning != lightning ||
      old.centerLat != centerLat ||
      old.centerLon != centerLon ||
      old.halfHeightKm != halfHeightKm;
}
