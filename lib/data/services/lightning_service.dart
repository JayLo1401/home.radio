import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'nowcast_service.dart' show GeoBox;

/// A spot with lightning in the last 5 minutes.
class LightningStrike {
  const LightningStrike(this.lat, this.lon, this.intensity);

  final double lat, lon;

  /// 0 (single flashes) .. 1 (very intense activity).
  final double intensity;
}

/// Lightning activity of the last 5 minutes as seen by the Lightning Imager
/// on EUMETSAT's MTG-I1 satellite ("LI Accumulated Flash Area"), served by
/// EUMETView (no key, no fees). The satellite sees all flashes optically, so
/// it cannot tell cloud-to-ground from intra-cloud lightning.
class LightningFrame {
  const LightningFrame({required this.strikes});

  final List<LightningStrike> strikes;
}

class LightningService {
  static const _wms = 'https://view.eumetsat.int/geoserver/ows';

  /// Sampling step in image pixels: one possible strike marker per cell.
  static const _cell = 3;

  Future<LightningFrame> fetch(GeoBox area, {int width = 600}) async {
    final aspect = (area.east - area.west) / (area.north - area.south);
    final height = (width / aspect).round().clamp(64, 1200);
    final uri = Uri.parse(
      '$_wms?service=WMS&version=1.3.0&request=GetMap&layers=mtg_fd:li_afa&styles='
      '&crs=EPSG:4326&bbox=${area.south},${area.west},${area.north},${area.east}'
      '&width=$width&height=$height&format=image/png&transparent=true',
    );
    final r = await http.get(uri, headers: {'User-Agent': 'home_radio/1.0'});
    if (r.statusCode != 200 || !(r.headers['content-type'] ?? '').startsWith('image/')) {
      throw Exception('lightning: HTTP ${r.statusCode}');
    }
    final codec = await ui.instantiateImageCodec(r.bodyBytes);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return LightningFrame(strikes: _strikes(data!.buffer.asUint8List(), width, height, area));
  }

  /// The layer's colour ramp runs from pale yellow (little flash area) over
  /// orange to dark red (a lot): the loss of green is the intensity.
  static List<LightningStrike> _strikes(Uint8List px, int w, int h, GeoBox area) {
    final out = <LightningStrike>[];
    for (var cy = 0; cy < h; cy += _cell) {
      for (var cx = 0; cx < w; cx += _cell) {
        var best = -1.0;
        for (var y = cy; y < cy + _cell && y < h; y++) {
          for (var x = cx; x < cx + _cell && x < w; x++) {
            final i = (y * w + x) * 4;
            if (px[i + 3] < 60) continue;
            final v = 1 - px[i + 1] / 255;
            if (v > best) best = v;
          }
        }
        if (best < 0) continue;
        final lon = area.west + (cx + _cell / 2) / w * (area.east - area.west);
        final lat = area.north - (cy + _cell / 2) / h * (area.north - area.south);
        out.add(LightningStrike(lat, lon, best.clamp(0.0, 1.0)));
      }
    }
    return out;
  }
}
