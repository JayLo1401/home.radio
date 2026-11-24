import 'dart:convert';

import 'launcher_tile.dart';

/// A row of apps under Home's favourites, with its own name - e.g.
/// "System-Tools". Stored as JSON under 'launcher_groups' (the favourites
/// stay as they are under 'launcher_tiles'):
///
///     [{"id": "g1a2b3", "name": "System-Tools", "tiles": [<LauncherTile JSON>, ...]}]
///
/// Only apps (and the device's settings tile) go into groups - Home
/// System's own parts stay favourites. An app may be in the favourites and
/// in any number of groups, but only once per row.
class LauncherGroup {
  const LauncherGroup({required this.id, required this.name, this.tiles = const []});

  final String id;
  final String name;
  final List<LauncherTile> tiles;

  /// Whether [tile] may go into a group.
  static bool allows(LauncherTile tile) => !tile.isBuiltIn;

  bool contains(String tileId) => tiles.any((t) => t.id == tileId);

  LauncherGroup copyWith({String? name, List<LauncherTile>? tiles}) =>
      LauncherGroup(id: id, name: name ?? this.name, tiles: tiles ?? this.tiles);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'tiles': [for (final t in tiles) t.toJson()],
  };

  static LauncherGroup? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final name = json['name'] is String ? json['name'] as String : '';
    final tiles = <LauncherTile>[];
    final raw = json['tiles'];
    if (raw is List) {
      for (final tile in raw.map(LauncherTile.fromJson).whereType<LauncherTile>()) {
        if (allows(tile) && !tiles.any((t) => t.id == tile.id)) tiles.add(tile);
      }
    }
    return LauncherGroup(id: id, name: name, tiles: tiles);
  }

  @override
  bool operator ==(Object other) =>
      other is LauncherGroup &&
      other.id == id &&
      other.name == name &&
      other.tiles.length == tiles.length &&
      Iterable.generate(tiles.length).every((i) => other.tiles[i] == tiles[i]);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(tiles));
}

/// The groups as stored; junk and duplicate ids are dropped.
List<LauncherGroup> decodeLauncherGroups(String? raw) {
  final groups = <LauncherGroup>[];
  try {
    final decoded = jsonDecode(raw ?? '[]');
    if (decoded is List) {
      for (final group in decoded.map(LauncherGroup.fromJson).whereType<LauncherGroup>()) {
        if (!groups.any((g) => g.id == group.id)) groups.add(group);
      }
    }
  } catch (_) {}
  return groups;
}

String encodeLauncherGroups(List<LauncherGroup> groups) => jsonEncode([for (final g in groups) g.toJson()]);

/// A new group id that isn't in [groups] yet.
String newLauncherGroupId(List<LauncherGroup> groups, {DateTime? now}) {
  var n = (now ?? DateTime.now()).microsecondsSinceEpoch;
  while (groups.any((g) => g.id == 'g${n.toRadixString(36)}')) {
    n++;
  }
  return 'g${n.toRadixString(36)}';
}

/// Pure edits of the group list - the notifier saves what they return.
extension LauncherGroupEdits on List<LauncherGroup> {
  LauncherGroup? byId(String id) => where((g) => g.id == id).firstOrNull;

  List<LauncherGroup> _replace(String id, LauncherGroup Function(LauncherGroup g) change) => [
    for (final g in this) g.id == id ? change(g) : g,
  ];

  /// Appends [tile] to group [groupId] (not twice, no built-in parts).
  List<LauncherGroup> addTile(String groupId, LauncherTile tile) {
    if (!LauncherGroup.allows(tile)) return this;
    return _replace(groupId, (g) => g.contains(tile.id) ? g : g.copyWith(tiles: [...g.tiles, tile]));
  }

  List<LauncherGroup> removeTile(String groupId, String tileId) =>
      _replace(groupId, (g) => g.copyWith(tiles: [...g.tiles]..removeWhere((t) => t.id == tileId)));

  /// Moves a tile one place left (-1) or right (+1) inside its group.
  List<LauncherGroup> moveTile(String groupId, String tileId, int direction) => _replace(groupId, (g) {
    final i = g.tiles.indexWhere((t) => t.id == tileId);
    final j = i + direction;
    if (i < 0 || j < 0 || j >= g.tiles.length) return g;
    final tiles = [...g.tiles];
    tiles.insert(j, tiles.removeAt(i));
    return g.copyWith(tiles: tiles);
  });

  /// Takes a tile out of group [fromId] and appends it to [toId] (if it's
  /// already there, it's just taken out of [fromId]).
  List<LauncherGroup> moveTileTo(String fromId, String toId, LauncherTile tile) {
    if (fromId == toId) return this;
    return removeTile(fromId, tile.id).addTile(toId, tile);
  }

  /// Moves a whole group one place up (-1) or down (+1).
  List<LauncherGroup> moveGroup(String groupId, int direction) {
    final i = indexWhere((g) => g.id == groupId);
    final j = i + direction;
    if (i < 0 || j < 0 || j >= length) return this;
    final groups = [...this];
    groups.insert(j, groups.removeAt(i));
    return groups;
  }

  List<LauncherGroup> rename(String groupId, String name) => _replace(groupId, (g) => g.copyWith(name: name));

  List<LauncherGroup> without(String groupId) => [...this]..removeWhere((g) => g.id == groupId);

  /// The tile's picture in every group it's in.
  List<LauncherGroup> setImage(String tileId, String? image) => [
    for (final g in this)
      g.contains(tileId) ? g.copyWith(tiles: [for (final t in g.tiles) t.id == tileId ? t.withImage(image) : t]) : g,
  ];
}

/// Where a new favourite goes: Home System's own parts right after the
/// last part in the row (at the front if there's none) - so a part
/// switched on later doesn't end up behind the user's apps; apps and the
/// rest at the end.
List<LauncherTile> insertLauncherTile(List<LauncherTile> tiles, LauncherTile tile) {
  if (tiles.any((t) => t.id == tile.id)) return tiles;
  if (!tile.isBuiltIn) return [...tiles, tile];
  // Before the first own tile of a later media type, else after the last
  // own tile (see ownTileRank).
  final rank = ownTileRank(tile);
  final before = tiles.indexWhere((t) => t.isBuiltIn && ownTileRank(t) > rank);
  if (before >= 0) return [...tiles]..insert(before, tile);
  final last = tiles.lastIndexWhere((t) => t.isBuiltIn);
  return [...tiles]..insert(last + 1, tile);
}

/// Home System's own tiles by media type: audio (Radio, Musik), video
/// (TV, Filme), pictures, the Haussteuerung, the Browser last.
const _ownTileOrder = [
  LauncherTile.radioType,
  LauncherTile.musicType,
  LauncherTile.tvType,
  LauncherTile.moviesType,
  LauncherTile.picturesType,
  LauncherTile.dashboardType,
  LauncherTile.browserType,
];

int ownTileRank(LauncherTile t) {
  final i = _ownTileOrder.indexOf(t.type);
  return i < 0 ? _ownTileOrder.length : i;
}

/// The row with Home System's own tiles in front, sorted by media type
/// ([ownTileRank]) - apps behind them in their order. Applied once to
/// existing rows; afterwards the user's own order stays.
List<LauncherTile> ownTilesToFront(List<LauncherTile> tiles) {
  final own = tiles.where((t) => t.isBuiltIn).toList()..sort((a, b) => ownTileRank(a).compareTo(ownTileRank(b)));
  final sorted = [...own, ...tiles.where((t) => !t.isBuiltIn)];
  for (var i = 0; i < tiles.length; i++) {
    if (tiles[i].id != sorted[i].id) return sorted;
  }
  return tiles;
}

/// Up/down between rows: the index in the target row whose tile is
/// nearest to the focused one on screen. Every row is a horizontal list
/// with [leading] padding, tiles [width] wide, [pitch] apart (width plus
/// gap), scrolled by its own offset.
int nearestTileIndex({
  required int fromIndex,
  required double fromOffset,
  required double fromWidth,
  required double fromPitch,
  required double toOffset,
  required double toWidth,
  required double toPitch,
  required int toCount,
  double leading = 0,
}) {
  if (toCount <= 0) return -1;
  // Centre of the focused tile in the viewport.
  final x = leading + fromIndex * fromPitch + fromWidth / 2 - fromOffset;
  final index = ((x + toOffset - leading - toWidth / 2) / toPitch).round();
  return index.clamp(0, toCount - 1);
}
