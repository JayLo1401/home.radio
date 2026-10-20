import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

/// Shaded green relief of the Alpine region (tools/make_relief.py, from the
/// Copernicus DEM GLO-90), plate carree between [west]..[east] / [south]..[north].
class ReliefMap {
  static const west = 7.0, east = 19.0, south = 45.0, north = 50.0;

  static Future<ui.Image>? _loading;

  static Future<ui.Image> load() => _loading ??= () async {
        final data = await rootBundle.load('assets/map/relief.jpg');
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        return (await codec.getNextFrame()).image;
      }();
}

/// Background map of the Alpine region from Natural Earth (public domain),
/// see tools/make_basemap.py: lines and rings as flat [lon, lat, ...] lists.
class BaseMap {
  BaseMap._(this.countries, this.coast, this.states, this.lakes, this.rivers, this.cities);

  final List<Float32List> countries;
  final List<Float32List> coast;
  final List<Float32List> states;
  final List<Float32List> lakes;
  final List<Float32List> rivers;
  final List<BaseMapCity> cities;

  static Future<BaseMap>? _loading;

  static Future<BaseMap> load() => _loading ??= _load();

  static Future<BaseMap> _load() async {
    final json = jsonDecode(await rootBundle.loadString('assets/map/alpine_basemap.json')) as Map<String, dynamic>;
    final scale = (json['scale'] as num).toDouble();
    List<Float32List> lines(String key) => [
          for (final l in json[key] as List)
            Float32List.fromList([for (final v in l as List) (v as num) / scale]),
        ];
    return BaseMap._(
      lines('countries'),
      lines('coast'),
      lines('states'),
      lines('lakes'),
      lines('rivers'),
      [
        for (final c in json['cities'] as List)
          BaseMapCity(c[0] as String, (c[1] as num) / scale, (c[2] as num) / scale, c[3] as int),
      ],
    );
  }
}

class BaseMapCity {
  const BaseMapCity(this.name, this.lon, this.lat, this.rank);

  final String name;
  final double lon, lat;

  /// Natural Earth scalerank: 0 = most important.
  final int rank;
}
