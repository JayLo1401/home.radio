import 'dart:convert';

/// What Home Media shows on start: the launcher, or straight Home Radio with
/// the autostart station (as before the launcher existed).
enum StartScreen { launcher, radio }

/// Where the launcher's background pictures come from.
/// - [builtin]: colour gradients that come with the app (offline).
/// - [photos]: landscape photos from the internet (Bing's pictures of the day).
/// - [server]: the user's own server, see LauncherBackgroundService.
enum LauncherBackgroundSource { builtin, photos, server }

/// One tile in the launcher's row.
class LauncherTile {
  const LauncherTile._(this.type, {this.package, this.label, this.image});

  const LauncherTile.radio({String? image}) : this._(radioType, image: image);
  const LauncherTile.tv({String? image}) : this._(tvType, image: image);
  const LauncherTile.systemSettings({String? image}) : this._(settingsType, image: image);
  const LauncherTile.app({required String package, required String label, String? image})
      : this._(appType, package: package, label: label, image: image);

  static const radioType = 'radio';
  static const tvType = 'tv';
  static const settingsType = 'settings';
  static const appType = 'app';

  /// [image] values besides a URL: the app's own banner/icon even with an
  /// icon pack set. Null = automatic (icon pack if it has one, else the
  /// app's own picture).
  static const originalImage = 'original';

  final String type;
  final String? package;
  final String? label;

  /// The tile's own picture: null (automatic), [originalImage], or an image
  /// URL (http/https) - e.g. a nicer logo on the user's own server.
  final String? image;

  bool get isRadio => type == radioType;
  bool get isTv => type == tvType;
  bool get isApp => type == appType;
  bool get isSystemSettings => type == settingsType;

  /// A built-in part of Home Media (Home Radio, Home TV) - can be moved, but
  /// not removed.
  bool get isBuiltIn => isRadio || isTv;

  String? get imageUrl => image != null && image!.startsWith('http') ? image : null;

  /// Unique within the row.
  String get id => isApp ? 'app:$package' : type;

  String get displayLabel => switch (type) {
        radioType => 'Home Radio',
        tvType => 'Home TV',
        settingsType => 'Einstellungen (TV)',
        _ => label ?? package ?? '',
      };

  LauncherTile withImage(String? image) => LauncherTile._(type, package: package, label: label, image: image);

  Map<String, Object?> toJson() => {
        'type': type,
        if (package != null) 'package': package,
        if (label != null) 'label': label,
        if (image != null) 'image': image,
      };

  static LauncherTile? fromJson(Object? json) {
    if (json is! Map) return null;
    final image = json['image'] is String ? json['image'] as String : null;
    switch (json['type']) {
      case radioType:
        return LauncherTile.radio(image: image);
      case tvType:
        return LauncherTile.tv(image: image);
      case settingsType:
        return LauncherTile.systemSettings(image: image);
      case appType:
        final package = json['package'];
        if (package is! String || package.isEmpty) return null;
        final label = json['label'];
        return LauncherTile.app(package: package, label: label is String ? label : package, image: image);
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is LauncherTile && other.id == id && other.image == image;

  @override
  int get hashCode => Object.hash(id, image);
}

/// The row as stored in the settings (JSON). Home Radio is always in it -
/// it's the way into the radio - and every tile only once.
List<LauncherTile> decodeLauncherTiles(String? raw) {
  final tiles = <LauncherTile>[];
  try {
    final decoded = jsonDecode(raw ?? '[]');
    if (decoded is List) {
      for (final tile in decoded.map(LauncherTile.fromJson).whereType<LauncherTile>()) {
        if (!tiles.any((t) => t.id == tile.id)) tiles.add(tile);
      }
    }
  } catch (_) {}
  if (!tiles.any((t) => t.isRadio)) tiles.insert(0, const LauncherTile.radio());
  return tiles;
}

String encodeLauncherTiles(List<LauncherTile> tiles) => jsonEncode([for (final t in tiles) t.toJson()]);

/// Streaming apps put in the row on the very first start, when installed -
/// TV packages of Fire TV and Android TV.
const defaultLauncherPackages = [
  'com.netflix.ninja', // Netflix (TV)
  'com.disney.disneyplus', // Disney+
  'com.amazon.avod', // Prime Video (Fire TV)
  'com.amazon.amazonvideo.livingroom', // Prime Video (Android TV)
  'com.amazon.firetv.youtube', // YouTube (Fire TV)
  'com.google.android.youtube.tv', // YouTube (Android TV)
  'com.spotify.tv.android', // Spotify (TV)
];
