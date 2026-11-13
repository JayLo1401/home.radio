import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Map tiles (256 px, Web Mercator) for a background map - OpenStreetMap's
/// standard tiles, drawn dark ([_darkFilter]). Licence: OSM data is ODbL,
/// the attribution [attribution] must be visible on the map. The OSM tile
/// server's usage policy allows light use like this one: an identifying
/// User-Agent, tiles kept (in memory here), nothing fetched ahead of use.
class MapTiles {
  MapTiles({required this.onLoaded});

  /// Called when a tile arrived (the painter draws it on the next frame).
  final VoidCallback onLoaded;

  static const attribution = '© OpenStreetMap-Mitwirkende';
  static const _maxCached = 200;

  /// Dark mode for the light OSM style: colours inverted, then the hue
  /// turned back by 180° (water stays blue, land goes dark), dimmed to 75 %.
  /// Inversion + hue rotation = -H·v + 255 (each row of H sums to 1).
  static const _darkFilter = ColorFilter.matrix(<double>[
    0.4305, -1.0725, -0.108, 0, 191.25, //
    -0.3195, -0.3225, -0.108, 0, 191.25,
    -0.3195, -1.0725, 0.642, 0, 191.25,
    0, 0, 0, 1, 0,
  ]);

  final _images = <String, ui.Image>{};
  final _pending = <String>{};
  final _failed = <String, DateTime>{};
  final _client = http.Client();
  bool _disposed = false;

  /// The tile, or null while loading (the load starts here).
  ui.Image? tile(int z, int x, int y) {
    final n = 1 << z;
    if (y < 0 || y >= n) return null;
    x = ((x % n) + n) % n;
    final key = '$z/$x/$y';
    final img = _images[key];
    if (img != null) return img;
    if (_pending.contains(key)) return null;
    final failedAt = _failed[key];
    if (failedAt != null && DateTime.now().difference(failedAt) < const Duration(minutes: 1)) return null;
    _load(key, z, x, y);
    return null;
  }

  Future<void> _load(String key, int z, int x, int y) async {
    _pending.add(key);
    try {
      final res = await _client
          .get(
            Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png'),
            headers: {'User-Agent': 'HomeRadio/1.2 (private home radio app; ADS-B map)'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final codec = await ui.instantiateImageCodec(res.bodyBytes);
      final frame = await codec.getNextFrame();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      if (_images.length >= _maxCached) {
        final oldest = _images.keys.first;
        _images.remove(oldest)?.dispose();
      }
      _images[key] = frame.image;
      onLoaded();
    } catch (_) {
      _failed[key] = DateTime.now();
    } finally {
      _pending.remove(key);
    }
  }

  void dispose() {
    _disposed = true;
    _client.close();
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
  }

  // --- Web Mercator ---

  /// World pixel coordinates (256 px tiles) at zoom [z].
  static Offset project(double lat, double lon, double z) {
    final scale = 256 * math.pow(2, z);
    final x = (lon + 180) / 360 * scale;
    final s = math.sin(lat * math.pi / 180).clamp(-0.9999, 0.9999);
    final y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * scale;
    return Offset(x, y.toDouble());
  }

  /// Zoom (fractional) at which [km] span [pixels] at [lat].
  static double zoomFor(double lat, double km, double pixels) {
    final metersPerPixel = km * 1000 / pixels;
    return math.log(156543.03 * math.cos(lat * math.pi / 180) / metersPerPixel) / math.ln2;
  }

  /// Draws the map so that ([lat], [lon]) is at [center] and [km] span
  /// [radius] pixels; clipped by the caller.
  void paint(Canvas canvas, Offset center, double radius, double lat, double lon, double km) {
    final zf = zoomFor(lat, km, radius);
    final z = zf.floor().clamp(1, 18);
    final scale = math.pow(2, zf - z).toDouble(); // tile pixels -> screen pixels
    final c = project(lat, lon, z.toDouble());
    final tileScreen = 256 * scale;
    final x0 = ((c.dx - radius / scale) / 256).floor(), x1 = ((c.dx + radius / scale) / 256).floor();
    final y0 = ((c.dy - radius / scale) / 256).floor(), y1 = ((c.dy + radius / scale) / 256).floor();
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = _darkFilter;
    for (var tx = x0; tx <= x1; tx++) {
      for (var ty = y0; ty <= y1; ty++) {
        final img = tile(z, tx, ty);
        if (img == null) continue;
        final dst = Rect.fromLTWH(
          center.dx + (tx * 256 - c.dx) * scale,
          center.dy + (ty * 256 - c.dy) * scale,
          tileScreen,
          tileScreen,
        );
        canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), dst, paint);
      }
    }
  }
}
