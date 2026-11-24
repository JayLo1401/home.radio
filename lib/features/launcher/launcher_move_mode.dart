/// A tile picked up in the launcher's move mode: in row [row] ('' for the
/// favourites, else the group's id), at place [from] when it was lifted,
/// now at [index] (places count the row's tiles as shown).
class LiftedTile {
  LiftedTile({required this.row, required this.tileId, required this.from}) : index = from;

  final String row;
  final String tileId;
  final int from;
  int index;
}

/// A dropped tile that changed its place - for the screen to save.
typedef LauncherMoveDrop = ({String row, String tileId, int from, int index});

/// What Back did in move mode.
enum LauncherMoveBack {
  /// Move mode is off - Back is the screen's as usual.
  ignored,

  /// The lifted tile went back to where it was; move mode stays on.
  putBack,

  /// Nothing was lifted: move mode ended.
  ended,
}

/// The launcher's move mode ("Verschiebemodus") as plain state - the
/// screen shows it, feeds it the remote's keys and saves the drops:
///
/// - [ok] on a tile lifts it; ◀/▶ ([step]) move it one place each (held
///   keys repeat); [ok] again drops it where it is - then the next tile.
/// - [back] puts a lifted tile back where it was, or, with none lifted,
///   ends move mode.
/// - [finish] (holding OK) drops a lifted tile where it is and ends move
///   mode.
///
/// Only one tile is lifted at a time, and only inside its own row.
class LauncherMoveMode {
  bool _active = false;
  LiftedTile? _lifted;

  bool get active => _active;
  LiftedTile? get lifted => _lifted;

  /// Switches move mode on - with [tileId] (at place [index] of [row])
  /// already lifted, if given.
  void start({String? row, String? tileId, int index = 0}) {
    _active = true;
    _lifted = row != null && tileId != null ? LiftedTile(row: row, tileId: tileId, from: index) : null;
  }

  bool isLifted(String row, String tileId) => _lifted?.row == row && _lifted?.tileId == tileId;

  /// OK on the focused item ([tileId] null: not a movable tile, like "Alle
  /// Apps"): lifts it, or drops the lifted tile. Returns the drop if the
  /// tile changed its place.
  LauncherMoveDrop? ok(String row, String? tileId, int index) {
    if (!_active) return null;
    if (_lifted != null) return _drop();
    if (tileId != null) _lifted = LiftedTile(row: row, tileId: tileId, from: index);
    return null;
  }

  /// ◀ (-1) / ▶ (+1) with a tile lifted, in a row of [count] tiles: its
  /// new place (the same at either end), or null if none is lifted.
  int? step(int direction, int count) {
    final lifted = _lifted;
    if (!_active || lifted == null) return null;
    if (count <= 0) return lifted.index;
    lifted.index = (lifted.index + direction.sign).clamp(0, count - 1);
    return lifted.index;
  }

  LauncherMoveBack back() {
    if (!_active) return LauncherMoveBack.ignored;
    if (_lifted != null) {
      _lifted = null;
      return LauncherMoveBack.putBack;
    }
    _active = false;
    return LauncherMoveBack.ended;
  }

  /// Ends move mode; a lifted tile stays where it is now (the drop, if it
  /// moved).
  LauncherMoveDrop? finish() {
    final drop = _lifted == null ? null : _drop();
    _active = false;
    _lifted = null;
    return drop;
  }

  /// Forgets the lifted tile without a drop (it left its row meanwhile).
  void cancelLift() => _lifted = null;

  LauncherMoveDrop? _drop() {
    final lifted = _lifted!;
    _lifted = null;
    if (lifted.index == lifted.from) return null;
    return (row: lifted.row, tileId: lifted.tileId, from: lifted.from, index: lifted.index);
  }

  /// Row [row]'s [items] as shown: with the lifted tile at its current
  /// place (until it's dropped, the saved order stays as it was).
  List<T> arrange<T>(String row, List<T> items, String Function(T item) idOf) {
    final lifted = _lifted;
    if (lifted == null || lifted.row != row) return items;
    final i = items.indexWhere((t) => idOf(t) == lifted.tileId);
    if (i < 0) return items;
    final to = lifted.index.clamp(0, items.length - 1);
    if (to == i) return items;
    final list = [...items];
    list.insert(to, list.removeAt(i));
    return list;
  }
}
