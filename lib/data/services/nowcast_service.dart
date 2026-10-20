import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'hdf5_lite.dart';

/// Geographic extent, in degrees.
class GeoBox {
  const GeoBox(this.south, this.west, this.north, this.east);

  final double south, west, north, east;

  GeoBox? intersect(GeoBox o) {
    final s = south > o.south ? south : o.south;
    final n = north < o.north ? north : o.north;
    final w = west > o.west ? west : o.west;
    final e = east < o.east ? east : o.east;
    return (s < n && w < e) ? GeoBox(s, w, n, e) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GeoBox && other.south == south && other.west == west && other.north == north && other.east == east;

  @override
  int get hashCode => Object.hash(south, west, north, east);
}

/// One parameter of the nowcast on its 1 km grid, one value per cell.
class NowcastField {
  const NowcastField({required this.lat, required this.lon, required this.values, required this.time});

  final Float32List lat;
  final Float32List lon;

  /// NaN where there is no data.
  final Float32List values;
  final DateTime time;
}

/// GeoSphere Austria's INCA-based nowcast (dataset nowcast-v1-15min-1km,
/// CC BY 4.0): 1 km grid over Austria, 15-minute steps up to 3 hours ahead,
/// built from radar, stations, satellite and the weather model. Fetched as
/// netCDF (one parameter and one time step per request, ~0.1-0.7 MB) and
/// decoded with [Hdf5Lite].
class NowcastService {
  static const _base = 'https://dataset.api.hub.geosphere.at/v1/grid/forecast/nowcast-v1-15min-1km';

  /// The dataset's own extent (from its metadata).
  static const coverage = GeoBox(45.50, 8.10, 49.47, 17.74);

  DateTime? _refTime;
  DateTime? _refCheckedAt;

  Future<DateTime> _referenceTime() async {
    final now = DateTime.now();
    if (_refTime != null && _refCheckedAt != null && now.difference(_refCheckedAt!) < const Duration(minutes: 4)) {
      return _refTime!;
    }
    final r = await http.get(Uri.parse('$_base/metadata'), headers: {'User-Agent': 'home_radio/1.0'});
    if (r.statusCode != 200) throw Exception('nowcast metadata: HTTP ${r.statusCode}');
    final ref = DateTime.parse(jsonDecode(r.body)['last_forecast_reftime'] as String).toUtc();
    _refTime = ref;
    _refCheckedAt = now;
    return ref;
  }

  /// The forecast step closest to now (steps are reference + 15..180 min).
  Future<DateTime> currentStep() async {
    final ref = await _referenceTime();
    var minutes = (DateTime.now().toUtc().difference(ref).inMinutes / 15).round() * 15;
    if (minutes < 15) minutes = 15;
    if (minutes > 180) minutes = 180;
    return ref.add(Duration(minutes: minutes));
  }

  // The datasets' scale_factor attributes (the files store int16).
  static const _scale = {'rr': 0.01, 'fx': 0.01, 'pt': 1.0};

  /// Precipitation type codes of `pt` (from the dataset's flag_meaning).
  static const typeRain = 1, typeFreezingRain = 3, typeSnow = 5, typeRainAndSnow = 7;

  /// [parameter]: `rr` (precipitation, mm per 15 min), `fx` (gusts, m/s) or
  /// `pt` (precipitation type, see [typeRain] etc.; 255 = none).
  Future<NowcastField?> fetch(String parameter, GeoBox area, DateTime step) async {
    final box = area.intersect(coverage);
    if (box == null) return null;
    String f(double v) => v.toStringAsFixed(3);
    final t = '${step.year.toString().padLeft(4, '0')}-${_two(step.month)}-${_two(step.day)}T'
        '${_two(step.hour)}:${_two(step.minute)}';
    final uri = Uri.parse(
      '$_base?parameters=$parameter&bbox=${f(box.south)},${f(box.west)},${f(box.north)},${f(box.east)}'
      '&output_format=netcdf&start=$t&end=$t',
    );
    final r = await http.get(uri, headers: {'User-Agent': 'home_radio/1.0'});
    if (r.statusCode != 200) throw Exception('nowcast $parameter: HTTP ${r.statusCode}');
    return compute(_decode, (r.bodyBytes, step.millisecondsSinceEpoch, _scale[parameter] ?? 1.0));
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

NowcastField? _decode((Uint8List, int, double) input) {
  final (bytes, timeMs, scale) = input;
  final arrays = Hdf5Lite(bytes).readArrays();
  Hdf5Array? values;
  final coords = <Hdf5Array>[];
  for (final a in arrays) {
    if (a.shape.length == 3 && !a.isFloat) values = a;
    if (a.shape.length == 2 && a.isFloat) coords.add(a);
  }
  if (values == null || coords.length != 2) return null;
  // Latitude vs longitude by value: over Austria latitudes (45-50) are always
  // larger than longitudes (8-18).
  final c0 = coords[0].valueAt(0), c1 = coords[1].valueAt(0);
  final latA = c0 > c1 ? coords[0] : coords[1];
  final lonA = c0 > c1 ? coords[1] : coords[0];
  final cells = latA.length;
  final lat = Float32List(cells), lon = Float32List(cells), out = Float32List(cells);
  for (var i = 0; i < cells; i++) {
    lat[i] = latA.valueAt(i);
    lon[i] = lonA.valueAt(i);
    final raw = values.valueAt(i); // first (only) time step
    // int16 times the parameter's scale factor; -999 / -9999 mark missing values
    out[i] = raw <= -999 ? double.nan : raw * scale;
  }
  return NowcastField(lat: lat, lon: lon, values: out, time: DateTime.fromMillisecondsSinceEpoch(timeMs, isUtc: true));
}
