import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'nowcast_service.dart' show GeoBox;

/// Current clouds as a white-to-grey overlay, built from two EUMETSAT
/// satellite layers on EUMETView (no key, no fees):
/// - MTG FCI infrared 10.5 um (`mtg_fd:ir105_hrfi`, 10 min, ~2 km): the cloud
///   shapes - the colder (higher/thicker) the whiter, low clouds grey
/// - MSG cloud mask (`msg_fes:clm`, 15 min): only to learn the clear-ground
///   infrared level, so clouds are told apart from cold ground at night
class CloudFrame {
  const CloudFrame({required this.image, required this.area});

  final ui.Image image;
  final GeoBox area;
}

class CloudService {
  static const _wms = 'https://view.eumetsat.int/geoserver/ows';

  Future<Uint8List> _layer(String layer, GeoBox area, int width, int height) async {
    final uri = Uri.parse(
      '$_wms?service=WMS&version=1.3.0&request=GetMap&layers=$layer&styles='
      '&crs=EPSG:4326&bbox=${area.south},${area.west},${area.north},${area.east}'
      '&width=$width&height=$height&format=image/png&transparent=true',
    );
    final r = await http.get(uri, headers: {'User-Agent': 'home_radio/1.0'});
    if (r.statusCode != 200 || !(r.headers['content-type'] ?? '').startsWith('image/')) {
      throw Exception('clouds $layer: HTTP ${r.statusCode}');
    }
    final codec = await ui.instantiateImageCodec(r.bodyBytes);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  Future<CloudFrame> fetch(GeoBox area) async {
    // About the satellite's own resolution (~1.5-2 km per pixel over the
    // Alps); the painter scales it up smoothly instead of showing blocks.
    final kmWide = (area.east - area.west) * 111.32 * math.cos((area.north + area.south) / 2 * math.pi / 180);
    final width = (kmWide / 1.5).round().clamp(80, 800);
    final aspect = (area.east - area.west) / (area.north - area.south);
    final height = (width / aspect).round().clamp(40, 800);
    final results = await Future.wait([
      _layer('msg_fes:clm', area, width, height),
      _layer('mtg_fd:ir105_hrfi', area, width, height),
    ]);
    final mask = results[0], ir = results[1];
    final n = width * height;

    // The cloud mask (white = cloud, green = clear land, blue = water) is
    // far too coarse (~3-4 km) to draw. It is only used to learn how bright
    // the clear ground looks in the infrared right now (that changes a lot
    // between day and night); clouds are whatever is clearly colder.
    final clear = <int>[];
    for (var i = 0; i < n; i++) {
      final r = mask[i * 4], g = mask[i * 4 + 1], b = mask[i * 4 + 2], a = mask[i * 4 + 3];
      final isCloud = r > 180 && g > 180 && b > 180;
      if (a > 100 && !isCloud && ir[i * 4 + 3] > 0) clear.add(ir[i * 4]);
    }
    int ground;
    if (clear.length > n ~/ 50) {
      clear.sort();
      ground = clear[(clear.length * 0.7).floor()]; // warm side of the clear pixels
    } else {
      // (Almost) fully overcast: take the warmest tenth of the image.
      final all = [for (var i = 0; i < n; i++) ir[i * 4]]..sort();
      ground = all[(all.length * 0.1).floor()];
    }

    debugPrint('CloudService: ${width}x$height, clear-ground IR level $ground');

    // Upsample the infrared bilinearly ourselves (GPU filtering of a small
    // image is not reliably smooth on TV boxes), then turn it into clouds.
    const f = 3;
    final ow = width * f, oh = height * f;
    final out = Uint8List(ow * oh * 4);
    for (var y = 0; y < oh; y++) {
      final sy = ((y + 0.5) / f - 0.5).clamp(0.0, height - 1.0);
      final y0 = sy.floor(), y1 = math.min(y0 + 1, height - 1);
      final fy = sy - y0;
      for (var x = 0; x < ow; x++) {
        final sx = ((x + 0.5) / f - 0.5).clamp(0.0, width - 1.0);
        final x0 = sx.floor(), x1 = math.min(x0 + 1, width - 1);
        final fx = sx - x0;
        final i00 = (y0 * width + x0) * 4, i01 = (y0 * width + x1) * 4;
        final i10 = (y1 * width + x0) * 4, i11 = (y1 * width + x1) * 4;
        if (ir[i00 + 3] == 0 || ir[i11 + 3] == 0) continue;
        final v = (ir[i00] * (1 - fx) + ir[i01] * fx) * (1 - fy) + (ir[i10] * (1 - fx) + ir[i11] * fx) * fy;
        // IR grey value: brighter = colder = higher / thicker cloud. The
        // served image is low in contrast (a few dozen grey levels between
        // ground and thick cloud), hence the small range.
        final t = ((v - ground - 3) / 20).clamp(0.0, 1.0);
        if (t <= 0) continue;
        final o = (y * ow + x) * 4;
        final alpha = math.pow(t, 0.6) * 0.95;
        // Premultiplied alpha, which is what the engine composites with.
        final grey = ((170 + 85 * t) * alpha).round();
        out[o] = grey;
        out[o + 1] = grey;
        out[o + 2] = grey;
        out[o + 3] = (alpha * 255).round().clamp(0, 255);
      }
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(out, ow, oh, ui.PixelFormat.rgba8888, completer.complete);
    return CloudFrame(image: await completer.future, area: area);
  }
}
