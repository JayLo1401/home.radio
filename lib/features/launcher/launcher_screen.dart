import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/music_providers.dart';
import '../../core/ok_long_press.dart';
import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../core/remote_keys.dart';
import '../../core/system_providers.dart';
import '../../core/theme.dart';
import '../../data/models/launcher_group.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/services/launcher_service.dart';
import '../../l10n/l10n.dart';
import '../browser/browser_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../movies/movies_screen.dart';
import '../music/music_mini_bar.dart';
import '../music/music_screen.dart';
import '../pictures/pictures_screen.dart';
import '../settings/settings_screen.dart';
import '../tv/tv_screen.dart';
import 'all_apps_screen.dart';
import 'launcher_background.dart';
import 'launcher_move_mode.dart';
import 'launcher_navigation.dart';
import 'launcher_providers.dart';

/// Home System's launcher: a background picture, the clock, the favourites
/// row - Radio, the user's apps (Netflix, Disney+, ...) and "Alle Apps" -
/// and under it the user's own groups of apps (if any), one row each.
/// Opened over Radio (see launcher_navigation.dart), so the radio keeps
/// playing while it's open.
///
/// Remote: ◀/▶ through a row, ▲/▼ between the rows (to the nearest tile),
/// OK opens, ☰ (menu) or holding OK gives the tile's options (move,
/// picture, groups, app info, remove), ▲ from the favourites reaches the
/// music bar and the settings. Back does nothing - this is the home screen.
///
/// Move mode (the tile's "Verschieben", or "Kacheln verschieben" in the top
/// bar's menu - see LauncherMoveMode): OK picks a tile up / puts it down,
/// ◀/▶ move the lifted tile one place (held: on and on), Back puts it back
/// where it was (or, with none lifted, ends move mode), holding OK ends move
/// mode (a lifted tile stays where it is).
class LauncherScreen extends ConsumerStatefulWidget {
  const LauncherScreen({super.key});

  @override
  ConsumerState<LauncherScreen> createState() => _LauncherScreenState();
}

/// Tile sizes: the favourites' tiles, and the groups' slightly smaller ones
/// (more of them fit, and the favourites stay the eye-catcher).
class _TileSize {
  const _TileSize(this.width, this.height, this.gap, this.labelSize, this.rowExtra);

  final double width;
  final double height;
  final double gap;
  final double labelSize;

  /// Room around the tile in its row: the list's padding (focused tiles
  /// grow), the gap and the name - with room for taller fonts (Segoe UI
  /// on the PC).
  final double rowExtra;

  double get pitch => width + gap;
  double get rowHeight => height + rowExtra;

  static const favorite = _TileSize(256, 144, 22, 16, 72);
  static const group = _TileSize(192, 108, 18, 14, 64);
}

/// The rows' horizontal padding (left of the first tile).
const _rowLeading = 6.0;

/// One row on Home: the favourites ([group] null, with "Alle Apps" at the
/// end) or a group (with a placeholder while it's empty).
class _RowInfo {
  const _RowInfo({required this.id, required this.tiles, this.group, this.appsTile = false});

  /// '' for the favourites, else the group's id.
  final String id;
  final LauncherGroup? group;
  final List<LauncherTile> tiles;
  final bool appsTile;

  _TileSize get size => group == null ? _TileSize.favorite : _TileSize.group;

  /// The row's focusable items.
  int get count => group == null ? tiles.length + (appsTile ? 1 : 0) : (tiles.isEmpty ? 1 : tiles.length);

  /// The focus key of item [i] - an app can be in several rows, so a
  /// group's keys carry the group's id.
  String keyAt(int i) {
    if (group == null) return i < tiles.length ? tiles[i].id : _LauncherScreenState._appsKey;
    return '${group!.id}/${tiles.isEmpty ? '' : tiles[i].id}';
  }
}

/// A group's name - or "Gruppe" if it has none.
String launcherGroupName(BuildContext context, LauncherGroup? group) {
  final name = group?.name.trim() ?? '';
  return name.isEmpty ? context.l10n.launcherGroupUnnamed : name;
}

class _LauncherScreenState extends ConsumerState<LauncherScreen> {
  static const _favorites = '';
  static const _appsKey = '#apps';

  final _tileFocus = <String, FocusNode>{};
  final _appsFocus = FocusNode(debugLabel: 'apps');
  final _menuFocus = FocusNode(debugLabel: 'menu');
  final _musicFocus = FocusNode(debugLabel: 'music');
  final _scrolls = <String, ScrollController>{};
  final _rowKeys = <String, GlobalKey>{};
  final _vScroll = ScrollController();

  /// The rows as last built - for ▲/▼ between them.
  var _rows = const <_RowInfo>[];

  /// Move mode ("Verschiebemodus") - see LauncherMoveMode.
  final _move = LauncherMoveMode();

  /// Where the focus is (or was last) in the rows. Plain fields: moving
  /// the focus rebuilds only the two tiles concerned.
  String _focusRow = _favorites;
  int _focusIndex = 0;
  bool _musicShown = false;

  FocusNode _focusFor(String key) =>
      key == _appsKey ? _appsFocus : _tileFocus.putIfAbsent(key, () => FocusNode(debugLabel: key));

  ScrollController _scrollFor(String row) => _scrolls.putIfAbsent(row, ScrollController.new);

  GlobalKey _rowKey(String row) => _rowKeys.putIfAbsent(row, () => GlobalKey(debugLabel: 'row $row'));

  _RowInfo? _row(String id) => _rows.where((r) => r.id == id).firstOrNull;

  /// Back into the rows (from the top bar or the music bar): where the
  /// focus was last.
  void _focusCurrentTile() {
    final row = _row(_focusRow) ?? _rows.firstOrNull;
    if (row == null || row.count == 0) return;
    _focusItem(row, _focusIndex.clamp(0, row.count - 1));
  }

  /// Down from the top bar: the music bar if there is one, else the tiles.
  void _focusBelowMenu() => _musicShown ? _musicFocus.requestFocus() : _focusCurrentTile();

  void _focusItem(_RowInfo row, int index) {
    final node = _focusFor(row.keyAt(index));
    if (node.context?.mounted ?? false) {
      node.requestFocus();
      return;
    }
    // Not built (scrolled far away): scroll there first.
    final scroll = _scrollFor(row.id);
    if (scroll.hasClients) {
      final p = scroll.position;
      final s = row.size;
      scroll.jumpTo(
        (_rowLeading + index * s.pitch - (p.viewportDimension - s.width) / 2).clamp(p.minScrollExtent, p.maxScrollExtent),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (node.context?.mounted ?? false)) node.requestFocus();
    });
  }

  double _offset(String row) {
    final scroll = _scrolls[row];
    return scroll != null && scroll.hasClients ? scroll.offset : 0;
  }

  /// ▲/▼: the tile in [to] nearest to the focused one on screen.
  void _moveToRow(_RowInfo from, _RowInfo to) {
    final index = nearestTileIndex(
      fromIndex: _focusIndex,
      fromOffset: _offset(from.id),
      fromWidth: from.size.width,
      fromPitch: from.size.pitch,
      toOffset: _offset(to.id),
      toWidth: to.size.width,
      toPitch: to.size.pitch,
      toCount: to.count,
      leading: _rowLeading,
    );
    if (index >= 0) _focusItem(to, index);
  }

  void _onFocused(String row, int index) {
    final before = _rows.indexWhere((r) => r.id == _focusRow);
    _focusRow = row;
    _focusIndex = index;
    final now = _rows.indexWhere((r) => r.id == row);
    if (now == before) return;
    // Another row: the page scrolls just enough to show all of it.
    final ctx = _rowKeys[row]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignmentPolicy:
          now > before ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  }

  /// ▲/▼ between the rows (keeping the horizontal position), ▲ from the
  /// favourites to the music bar or the top bar. ◀/▶ at a row's end stay
  /// there - the D-Pad would otherwise jump into another row.
  KeyEventResult _onRowsKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final from = _rows.indexWhere((r) => r.id == _focusRow);
    if (from < 0) return KeyEventResult.ignored;
    final row = _rows[from];
    if (_move.active) {
      final lifted = _move.lifted;
      if (lifted != null) {
        // A lifted tile: ◀/▶ move it (the focus stays on it), ▲/▼ do
        // nothing - it stays in its row.
        if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
          _stepLifted(lifted, key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) return KeyEventResult.handled;
      } else if (key == LogicalKeyboardKey.arrowUp && from == 0) {
        // The focus stays in the rows while moving.
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (from == 0) {
        (_musicShown ? _musicFocus : _menuFocus).requestFocus();
      } else {
        _moveToRow(row, _rows[from - 1]);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (from < _rows.length - 1) _moveToRow(row, _rows[from + 1]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && _focusIndex <= 0) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.arrowRight && _focusIndex >= row.count - 1) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  /// Move mode on - with [tile] of [row] already lifted, if given.
  void _startMove([_RowInfo? row, LauncherTile? tile]) {
    final index = row == null || tile == null ? -1 : row.tiles.indexWhere((t) => t.id == tile.id);
    setState(() {
      index < 0 ? _move.start() : _move.start(row: row!.id, tileId: tile!.id, index: index);
    });
    if (index >= 0) {
      _focusRow = row!.id;
      _focusIndex = index;
    }
    // Back from the menu: the focus to the (lifted) tile.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _move.active) _focusCurrentTile();
    });
  }

  /// ◀/▶ with a tile lifted: one place on; the focus stays on the tile and
  /// the row scrolls along.
  void _stepLifted(LiftedTile lifted, int direction) {
    final row = _row(lifted.row);
    if (row == null) return;
    final before = lifted.index;
    final index = _move.step(direction, row.tiles.length);
    if (index == null || index == before) return;
    setState(() {});
    _focusRow = row.id;
    _focusIndex = index;
    _scrollToIndex(row, index);
    // Should the tile have lost the focus all the same: back to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = _row(row.id);
      final current = _move.lifted;
      if (!mounted || now == null || current == null || current.row != row.id) return;
      final i = current.index;
      if (i >= now.count || now.keyAt(i) != (row.group == null ? current.tileId : '${row.id}/${current.tileId}')) return;
      if (!_focusFor(now.keyAt(i)).hasFocus) {
        _focusRow = row.id;
        _focusIndex = i;
        _focusItem(now, i);
      }
    });
  }

  /// OK in move mode on the focused item.
  void _moveOkFocused() {
    final row = _row(_focusRow);
    if (row != null) _moveOkAt(row, _focusIndex);
  }

  /// OK (or a tap) in move mode on item [index] of [row]: lifts the tile,
  /// or puts the lifted one down where it is now.
  void _moveOkAt(_RowInfo row, int index) {
    final tileId = index >= 0 && index < row.tiles.length ? row.tiles[index].id : null;
    final drop = _move.ok(row.id, tileId, index);
    setState(() {});
    if (drop != null) _saveDrop(drop);
  }

  /// Holding OK (or ☰) in move mode: move mode ends, a lifted tile stays
  /// where it is now.
  void _finishMove() {
    if (!_move.active) return;
    final drop = _move.finish();
    setState(() {});
    if (drop != null) _saveDrop(drop);
  }

  /// Back in move mode: a lifted tile goes back to where it was; with none
  /// lifted, move mode ends.
  void _moveBack() {
    final lifted = _move.lifted;
    final result = _move.back();
    if (result == LauncherMoveBack.ignored) return;
    setState(() {});
    if (result == LauncherMoveBack.putBack && lifted != null) {
      final row = _row(lifted.row);
      _focusRow = lifted.row;
      _focusIndex = lifted.from;
      if (row != null) _scrollToIndex(row, lifted.from);
    }
  }

  /// Saves a drop - with the same notifiers (and so the same storage) as
  /// every other change of the rows.
  Future<void> _saveDrop(LauncherMoveDrop drop) async {
    try {
      if (drop.row == _favorites) {
        final parts = ref.read(systemPartsProvider.notifier);
        await ref.read(launcherTilesProvider.notifier).place(drop.tileId, drop.index, shown: parts.showsTile);
      } else {
        await ref.read(launcherGroupsProvider.notifier).placeTile(drop.row, drop.tileId, drop.index);
      }
    } catch (e) {
      debugPrint('Launcher: saving the moved tile failed: $e');
    }
  }

  /// Scrolls [row] just enough that its item [index] is fully on screen
  /// (a lifted tile keeps its focus, so nothing else scrolls the row).
  void _scrollToIndex(_RowInfo row, int index) {
    final scroll = _scrolls[row.id];
    if (scroll == null || !scroll.hasClients) return;
    final p = scroll.position;
    final s = row.size;
    // With a gap's room on either side - the lifted tile is enlarged.
    final start = _rowLeading + index * s.pitch - s.gap;
    final end = _rowLeading + index * s.pitch + s.width + s.gap;
    double? target;
    if (start < p.pixels) {
      target = start;
    } else if (end > p.pixels + p.viewportDimension) {
      target = end - p.viewportDimension;
    }
    if (target == null) return;
    target = target.clamp(p.minScrollExtent, p.maxScrollExtent);
    // More than a place behind (a held key outruns the animation): jump, so
    // the lifted tile never leaves the built part of the row (and with it
    // the focus).
    if ((target - p.pixels).abs() > s.pitch) {
      scroll.jumpTo(target);
    } else {
      scroll.animateTo(target, duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
    }
  }

  /// The music bar: ▲ to the top bar, ▼ back to the tiles.
  KeyEventResult _onMusicKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _menuFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focusCurrentTile();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The top bar's "Einstellungen": Home System's own settings, the device's
  /// (Android) settings, all apps - on the PC straight the app's settings.
  Future<void> _openMenu() async {
    if (!LauncherService.supported) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      return;
    }
    final l = context.l10n;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.systemTileSettingsShort),
        children: [
          _option(context, 'app', Icons.tune, l.settingsLauncherMenuApp, autofocus: true),
          _option(context, 'android', Icons.settings_applications_outlined, l.settingsLauncherMenuAndroid),
          _option(context, 'apps', Icons.apps, l.miscAllAppsTitle),
          _option(context, 'move', Icons.open_with, l.launcherMoveTiles),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'app':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      case 'android':
        await ref.read(launcherServiceProvider).openSystemSettings();
      case 'apps':
        await _openAllApps();
      case 'move':
        _startMove();
    }
  }

  @override
  void dispose() {
    for (final node in _tileFocus.values) {
      node.dispose();
    }
    for (final scroll in _scrolls.values) {
      scroll.dispose();
    }
    _appsFocus.dispose();
    _menuFocus.dispose();
    _musicFocus.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Music that's loaded gets the media keys first.
    if (ref.read(musicPlayerProvider).handleMediaKey(key)) return KeyEventResult.handled;
    if (!ref.read(systemPartsProvider).radio) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      ref.read(radioCommandProvider.notifier).send(RadioCommand.togglePlayPause);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaStop || key == LogicalKeyboardKey.mediaPause) {
      ref.read(radioCommandProvider.notifier).send(RadioCommand.stop);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Another app or TV takes the speakers: radio and music pause (the radio
  /// plays on when Radio is opened again).
  void _pauseForApp() => pauseRadioAndMusicForApp(ref);

  Future<void> _open(LauncherTile tile) async {
    final service = ref.read(launcherServiceProvider);
    if (tile.isRadio) {
      hideLauncher(ref);
      return;
    }
    if (tile.isTv) {
      _pauseForApp();
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TvScreen()));
      return;
    }
    if (tile.isDashboard) {
      await openDashboard(context, ref);
      return;
    }
    if (tile.isPictures) {
      // The radio (or music) plays on - pictures to the music.
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PicturesScreen()));
      return;
    }
    if (tile.isMovies) {
      // The film pauses the radio itself when it starts playing.
      await openMovies(context);
      return;
    }
    if (tile.isMusic) {
      // The radio pauses only when music starts (see MusicPlayer).
      await openMusic(context);
      return;
    }
    if (tile.isBrowser) {
      // The radio pauses only when a page plays sound.
      await openBrowser(context);
      return;
    }
    if (tile.isSystemSettings) {
      await service.openSystemSettings();
      return;
    }
    if (tile.isApp) {
      // The other app gets the screen and the speakers.
      _pauseForApp();
      final ok = await service.launchApp(tile.package!);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.settingsLauncherNotInstalled(tile.displayLabel))),
        );
      }
    }
  }

  Future<void> _openAllApps() async {
    ref.invalidate(installedAppsProvider);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AllAppsScreen()));
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: Text(text)));
  }

  /// A tile's options (☰ / long OK): move, picture, groups, app info,
  /// remove - and, in a group, the group's own options.
  Future<void> _options(LauncherTile tile, _RowInfo row) async {
    final group = row.group;
    final favorites = ref.read(launcherTilesProvider);
    final movable = row.tiles.length > 1 && row.tiles.any((t) => t.id == tile.id);
    final groupable = LauncherService.supported && LauncherGroup.allows(tile);
    final inFavorites = favorites.any((t) => t.id == tile.id);
    final l = context.l10n;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tile.displayLabel),
        children: [
          // Move mode, with this tile already lifted.
          if (movable) _option(context, 'move', Icons.open_with, l.launcherMoveTile, autofocus: true),
          _option(context, 'image', Icons.image_outlined, l.settingsLauncherChangeImage, autofocus: !movable),
          if (groupable && group == null) _option(context, 'toGroup', Icons.playlist_add, l.launcherAddToGroup),
          if (group != null) _option(context, 'moveGroup', Icons.drive_file_move_outline, l.launcherMoveToGroup),
          if (group != null && groupable && !inFavorites)
            _option(context, 'favorite', Icons.star_border, l.miscAllAppsAddFavorite),
          if (tile.isApp && LauncherService.supported) _option(context, 'info', Icons.info_outline, l.miscAllAppsAppInfo),
          // TV comes back through "Alle Apps" - there is none on the PC.
          if (group == null && !tile.isRadio && (LauncherService.supported || !tile.isBuiltIn))
            _option(context, 'remove', Icons.delete_outline, l.settingsLauncherRemove),
          if (group != null) _option(context, 'removeGroup', Icons.playlist_remove, l.launcherRemoveFromGroup),
          if (group != null)
            _option(context, 'group', Icons.folder_outlined, l.launcherGroupOptions(launcherGroupName(context, group))),
        ],
      ),
    );
    if (!mounted) return;
    final tiles = ref.read(launcherTilesProvider.notifier);
    final groups = ref.read(launcherGroupsProvider.notifier);
    final position = row.tiles.indexWhere((t) => t.id == tile.id);
    final key = row.keyAt(position < 0 ? 0 : position);
    switch (action) {
      case 'move':
        _startMove(row, tile);
      case 'image':
        if (mounted) await chooseTileImage(context, ref, tile);
      case 'toGroup':
        await chooseGroupFor(context, ref, tile);
      case 'moveGroup':
        final to = await chooseGroupFor(context, ref, tile, fromGroupId: group!.id);
        if (to != null) {
          _dropFocus(key);
          _keepVisible('$to/${tile.id}');
        }
      case 'favorite':
        await tiles.add(tile);
        if (mounted) _snack(l.miscAllAppsFavoriteAdded(tile.displayLabel));
      case 'info':
        await openAppInfo(context, ref, tile.package!, tile.displayLabel);
      case 'remove':
        await tiles.remove(tile.id);
        _dropFocus(key);
        _refocus();
      case 'removeGroup':
        await groups.removeTile(group!.id, tile.id);
        _dropFocus(key);
        if (mounted) _snack(l.launcherRemovedFromGroup(tile.displayLabel, launcherGroupName(context, group)));
        _refocus();
      case 'group':
        await _groupOptions(group!);
    }
  }

  /// A group's options: rename, move up/down, delete.
  Future<void> _groupOptions(LauncherGroup group) async {
    final all = ref.read(launcherGroupsProvider);
    final i = all.indexWhere((g) => g.id == group.id);
    if (i < 0) return;
    final name = launcherGroupName(context, group);
    final l = context.l10n;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(name),
        children: [
          _option(context, 'rename', Icons.edit_outlined, l.launcherGroupRename, autofocus: true),
          if (i > 0) _option(context, 'up', Icons.arrow_upward, l.launcherGroupMoveUp),
          if (i < all.length - 1) _option(context, 'down', Icons.arrow_downward, l.launcherGroupMoveDown),
          _option(context, 'delete', Icons.delete_outline, l.launcherGroupDelete),
        ],
      ),
    );
    if (!mounted) return;
    final groups = ref.read(launcherGroupsProvider.notifier);
    switch (action) {
      case 'rename':
        final value = await showTextInputDialog(
          context,
          title: l.launcherGroupRenameTitle,
          initialValue: group.name,
          hint: l.launcherGroupNameHint,
        );
        if (value != null && value.isNotEmpty) await groups.rename(group.id, value);
      case 'up' || 'down':
        await groups.moveGroup(group.id, action == 'up' ? -1 : 1);
        _refocus();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.launcherGroupDeleteTitle(name)),
            content: Text(l.launcherGroupDeleteBody),
            actions: [
              TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: Text(l.commonCancel)),
              FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l.commonDelete)),
            ],
          ),
        );
        if (ok != true) return;
        await groups.delete(group.id);
        for (final key in _tileFocus.keys.where((k) => k.startsWith('${group.id}/')).toList()) {
          _dropFocus(key);
        }
        final scroll = _scrolls.remove(group.id);
        if (scroll != null) WidgetsBinding.instance.addPostFrameCallback((_) => scroll.dispose());
        _rowKeys.remove(group.id);
        // The row above takes the focus.
        _focusRow = i > 0 ? all[i - 1].id : _favorites;
        _focusIndex = 0;
        _refocus();
    }
  }

  /// A tile left its row: its focus node goes once the row is rebuilt.
  void _dropFocus(String key) {
    final node = _tileFocus.remove(key);
    if (node != null) WidgetsBinding.instance.addPostFrameCallback((_) => node.dispose());
  }

  /// After a change of the rows: the focus where it was (or nearby).
  void _refocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusCurrentTile();
      final ctx = _rowKeys[_focusRow]?.currentContext;
      if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200));
    });
  }

  void _keepVisible(String key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final node = _tileFocus[key];
      if (node == null) return;
      node.requestFocus();
      final ctx = node.context;
      if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 200));
    });
  }

  @override
  Widget build(BuildContext context) {
    // Switched-off parts (Settings → System) keep their place in the row,
    // they're just not shown.
    ref.watch(systemPartsProvider);
    final parts = ref.read(systemPartsProvider.notifier);
    final tiles = [
      for (final t in ref.watch(launcherTilesProvider))
        if (parts.showsTile(t)) t,
    ];
    final groups = LauncherService.supported ? ref.watch(launcherGroupsProvider) : const <LauncherGroup>[];
    // In move mode the lifted tile shows where it is now (see LauncherMoveMode).
    String idOf(LauncherTile t) => t.id;
    _rows = [
      _RowInfo(id: _favorites, tiles: _move.arrange(_favorites, tiles, idOf), appsTile: LauncherService.supported),
      for (final g in groups) _RowInfo(id: g.id, group: g, tiles: _move.arrange(g.id, g.tiles, idOf)),
    ];
    // The lifted tile left its row meanwhile: nothing to drop any more.
    if (_move.lifted case final lifted?) {
      if (!(_row(lifted.row)?.tiles.any((t) => t.id == lifted.tileId) ?? false)) _move.cancelLift();
    }
    _musicShown = ref.watch(musicStateProvider.select((s) => s.current != null));
    final moving = _move.active;
    return PopScope(
      canPop: false,
      // Back (Esc on the PC) only matters in move mode.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _moveBack();
      },
      child: Focus(
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              const LauncherBackground(),
              // Keeps text and tiles readable on bright pictures.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Color(0x00000000), Color(0x00000000), Color(0xCC000000)],
                    stops: [0, 0.25, 0.5, 1],
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _MenuBar(menuFocus: _menuFocus, onMenu: _openMenu, onDown: _focusBelowMenu),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // What the music plays - OK opens the player.
                          if (_musicShown)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(32, 12, 32, 12),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Focus(
                                  canRequestFocus: false,
                                  skipTraversal: true,
                                  onKeyEvent: _onMusicKey,
                                  child: MusicMiniBar(width: 560, focusNode: _musicFocus),
                                ),
                              ),
                            ),
                          if (moving) _MoveBanner(lifted: _move.lifted != null),
                          // A band across the whole width, like Radio's
                          // "now playing" banner - top bar and band frame
                          // the picture. With groups it grows upwards and
                          // scrolls once it fills the screen.
                          Flexible(
                            child: Container(
                              color: Colors.black.withValues(alpha: ref.watch(launcherSettingsProvider).bandOpacity),
                              // In move mode OK (short / held) is the rows'
                              // - the tiles let it through.
                              child: OkLongPress(
                                onTap: moving ? _moveOkFocused : null,
                                onLongPress: moving ? _finishMove : null,
                                child: Focus(
                                  canRequestFocus: false,
                                  skipTraversal: true,
                                  onKeyEvent: _onRowsKey,
                                  child: SingleChildScrollView(
                                    controller: _vScroll,
                                    padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        _favoritesRow(_rows.first),
                                        for (final row in _rows.skip(1)) _groupRow(row),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _favoritesRow(_RowInfo row) {
    final tiles = row.tiles;
    return Column(
      key: _rowKey(row.id),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.favorite, color: brandGreen, size: 20),
            const SizedBox(width: 8),
            Text(context.l10n.radioFavorites,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(
              LauncherService.supported
                  ? context.l10n.settingsLauncherOptionsHint(_keyHint(ref, RemoteAction.options))
                  : context.l10n.settingsLauncherOptionsHintMouse(_keyHint(ref, RemoteAction.options)),
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
        SizedBox(
          height: _TileSize.favorite.rowHeight,
          child: ListView.builder(
            controller: _scrollFor(row.id),
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(horizontal: _rowLeading, vertical: 14),
            itemCount: row.count,
            findChildIndexCallback: (key) => _indexOfKey(row, key),
            itemBuilder: (context, i) {
              if (i >= tiles.length) {
                return KeyedSubtree(
                  key: const ValueKey(_appsKey),
                  child: _AppsTile(
                    focusNode: _appsFocus,
                    onOpen: () {
                      if (!_move.active) _openAllApps();
                    },
                    onFocused: () => _onFocused(row.id, i),
                  ),
                );
              }
              final tile = tiles[i];
              return Padding(
                key: ValueKey(tile.id),
                padding: EdgeInsets.only(right: _TileSize.favorite.gap),
                child: _TileView(
                  tile: tile,
                  focusNode: _focusFor(tile.id),
                  autofocus: i == 0,
                  moving: _move.active,
                  lifted: _liftedState(row, i),
                  onOpen: _move.active ? () => _moveOkAt(row, i) : () => _open(tile),
                  onOptions: _move.active ? _finishMove : () => _options(tile, row),
                  onFocused: () => _onFocused(row.id, i),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _groupRow(_RowInfo row) {
    final group = row.group!;
    final tiles = row.tiles;
    const size = _TileSize.group;
    return Column(
      key: _rowKey(row.id),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The name - by touch or mouse also the way to the group's options.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _groupOptions(group),
          onLongPress: () => _groupOptions(group),
          onSecondaryTap: () => _groupOptions(group),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_outlined, color: brandGreen, size: 18),
                const SizedBox(width: 8),
                Text(
                  launcherGroupName(context, group),
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: size.rowHeight,
          child: ListView.builder(
            controller: _scrollFor(row.id),
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(horizontal: _rowLeading, vertical: 12),
            itemCount: row.count,
            findChildIndexCallback: (key) => _indexOfKey(row, key),
            itemBuilder: (context, i) {
              final key = row.keyAt(i);
              if (tiles.isEmpty) {
                return KeyedSubtree(
                  key: ValueKey(key),
                  child: _EmptyGroupTile(
                    focusNode: _focusFor(key),
                    hint: context.l10n.launcherGroupEmptyHint(_keyHint(ref, RemoteAction.options)),
                    onOptions: _move.active ? _finishMove : () => _groupOptions(group),
                    onFocused: () => _onFocused(row.id, i),
                  ),
                );
              }
              final tile = tiles[i];
              return Padding(
                key: ValueKey(key),
                padding: EdgeInsets.only(right: size.gap),
                child: _TileView(
                  tile: tile,
                  size: size,
                  focusNode: _focusFor(key),
                  moving: _move.active,
                  lifted: _liftedState(row, i),
                  onOpen: _move.active ? () => _moveOkAt(row, i) : () => _open(tile),
                  onOptions: _move.active ? _finishMove : () => _options(tile, row),
                  onFocused: () => _onFocused(row.id, i),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Tile [i] of [row] in move mode: null if it isn't lifted, else which
  /// ways it can still go.
  _Lifted? _liftedState(_RowInfo row, int i) {
    final tile = row.tiles[i];
    if (!_move.isLifted(row.id, tile.id)) return null;
    return _Lifted(left: i > 0, right: i < row.tiles.length - 1);
  }

  /// Keeps a tile's state (and focus) when the row is reordered.
  static int? _indexOfKey(_RowInfo row, Key key) {
    if (key is! ValueKey<String>) return null;
    for (var i = 0; i < row.count; i++) {
      if (row.keyAt(i) == key.value) return i;
    }
    return null;
  }

  /// The (first) key assigned to [action], for the hints on screen.
  static String _keyHint(WidgetRef ref, RemoteAction action) => remoteKeyHint(ref.watch(remoteKeysProvider), action);

  static Widget _option(BuildContext context, String value, IconData icon, String label, {bool autofocus = false}) =>
      launcherMenuOption(context, value, icon, label, autofocus: autofocus);
}

/// "Zu Gruppe hinzufügen …" (or, with [fromGroupId], "In andere Gruppe
/// verschieben …"): the groups to choose from, or a new one with a name.
/// Returns the group the tile went into, null if nothing happened.
Future<String?> chooseGroupFor(BuildContext context, WidgetRef ref, LauncherTile tile, {String? fromGroupId}) async {
  const newGroup = '#new';
  final l = context.l10n;
  final notifier = ref.read(launcherGroupsProvider.notifier);
  final groups = [
    for (final g in ref.read(launcherGroupsProvider))
      if (g.id != fromGroupId && !g.contains(tile.id)) g,
  ];
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(fromGroupId == null
          ? l.launcherAddToGroupTitle(tile.displayLabel)
          : l.launcherMoveToGroupTitle(tile.displayLabel)),
      children: [
        for (final (i, g) in groups.indexed)
          launcherMenuOption(context, g.id, Icons.folder_outlined, launcherGroupName(context, g), autofocus: i == 0),
        launcherMenuOption(context, newGroup, Icons.create_new_folder_outlined, l.launcherNewGroup,
            autofocus: groups.isEmpty),
      ],
    ),
  );
  if (choice == null || !context.mounted) return null;
  final String groupId;
  final String name;
  if (choice == newGroup) {
    final input = await showTextInputDialog(context, title: l.launcherNewGroupTitle, hint: l.launcherGroupNameHint);
    if (input == null || input.isEmpty) return null;
    if (fromGroupId != null) await notifier.removeTile(fromGroupId, tile.id);
    groupId = await notifier.create(input, first: tile);
    name = input;
  } else {
    if (fromGroupId == null) {
      await notifier.addTile(choice, tile);
    } else {
      await notifier.moveTileTo(fromGroupId, choice, tile);
    }
    groupId = choice;
    if (!context.mounted) return groupId;
    name = launcherGroupName(context, groups.byId(choice));
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(l.launcherAddedToGroup(tile.displayLabel, name)),
      ));
  }
  return groupId;
}

/// One row of the launcher's popups (SimpleDialog): pops [value] on OK.
Widget launcherMenuOption(BuildContext context, String value, IconData icon, String label, {bool autofocus = false}) {
  return SimpleDialogOption(
    onPressed: () => Navigator.of(context).pop(value),
    child: _DialogRow(icon: icon, label: label, autofocus: autofocus, onTap: () => Navigator.of(context).pop(value)),
  );
}

/// "App-Info": the system's page for the app - force stop, uninstall.
Future<void> openAppInfo(BuildContext context, WidgetRef ref, String package, String label) async {
  final ok = await ref.read(launcherServiceProvider).openAppInfo(package);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.settingsLauncherAppInfoFailed(label))),
    );
  }
}

/// A focusable dialog row with the app's focus frame.
class _DialogRow extends StatefulWidget {
  const _DialogRow({required this.icon, required this.label, required this.onTap, this.autofocus = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_DialogRow> createState() => _DialogRowState();
}

class _DialogRowState extends State<_DialogRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        autofocus: widget.autofocus,
        borderRadius: BorderRadius.circular(8),
        focusColor: Colors.transparent,
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [Icon(widget.icon), const SizedBox(width: 12), Text(widget.label)]),
        ),
      ),
    );
  }
}

/// "Bild ändern" for a tile: automatic (icon pack, else the app's own
/// picture), the app's own picture, or a picture from an address.
Future<void> chooseTileImage(BuildContext context, WidgetRef ref, LauncherTile tile) async {
  final favorites = ref.read(launcherTilesProvider.notifier);
  final groups = ref.read(launcherGroupsProvider.notifier);
  // The picture belongs to the app - the same in the favourites and groups.
  Future<void> setImage(String? image) async {
    await favorites.setImage(tile.id, image);
    await groups.setImage(tile.id, image);
  }

  final hasPack = ref.read(launcherSettingsProvider).iconPack != null;
  final l = context.l10n;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l.settingsLauncherImageTitle(tile.displayLabel)),
      children: [
        _LauncherScreenState._option(
          context,
          'auto',
          Icons.auto_awesome_outlined,
          tile.isApp && hasPack ? l.settingsLauncherImageAuto : l.settingsLauncherImageDefault,
          autofocus: true,
        ),
        if (tile.isApp && hasPack) _LauncherScreenState._option(context, 'original', Icons.apps, l.settingsLauncherImageOriginal),
        _LauncherScreenState._option(context, 'url', Icons.link, l.settingsLauncherImageFromUrl),
      ],
    ),
  );
  switch (choice) {
    case 'auto':
      await setImage(null);
    case 'original':
      await setImage(LauncherTile.originalImage);
    case 'url':
      if (!context.mounted) return;
      final url = await showTextInputDialog(
        context,
        title: l.settingsLauncherImageUrlTitle,
        initialValue: tile.imageUrl ?? '',
        hint: 'http://…',
        keyboardType: TextInputType.url,
      );
      if (url == null) return;
      final uri = Uri.tryParse(url);
      if (url.isEmpty) {
        await setImage(null);
      } else if (uri != null && uri.scheme.startsWith('http')) {
        await setImage(url);
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.miscRadarInvalidUrl)),
        );
      }
  }
}

/// The same top bar as Radio's (translucent black, logo and name left,
/// date and time centred, icon buttons right that show their label when
/// focused) - Home System's launcher and Radio read as one app.
class _MenuBar extends StatelessWidget {
  const _MenuBar({required this.menuFocus, required this.onMenu, required this.onDown});

  final FocusNode menuFocus;
  final VoidCallback onMenu;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset('assets/icon/home_system_logo.png', width: 36, height: 36),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Home System', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      Text('Powered by jaycloud.at', style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ],
              ),
            ),
            const _LauncherClock(),
            Align(
              alignment: Alignment.centerRight,
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    onDown();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: _BarButton(
                  focusNode: menuFocus,
                  icon: Icons.settings,
                  label: context.l10n.systemTileSettingsShort,
                  onTap: onMenu,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Like Radio's top-bar buttons: the icon, plus its label while focused.
class _BarButton extends StatefulWidget {
  const _BarButton({required this.icon, required this.label, required this.onTap, this.focusNode});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      child: InkWell(
        focusNode: widget.focusNode,
        borderRadius: BorderRadius.circular(8),
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.08),
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: Colors.white),
              AnimatedSize(
                duration: const Duration(milliseconds: 150),
                child: _focused
                    ? Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(widget.label, style: const TextStyle(color: Colors.white)),
                      )
                    : const SizedBox(height: 24),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Weekday, date and time in one line - as Radio's clock.
class _LauncherClock extends StatefulWidget {
  const _LauncherClock();

  @override
  State<_LauncherClock> createState() => _LauncherClockState();
}

class _LauncherClockState extends State<_LauncherClock> {
  late DateTime _now = DateTime.now();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now();
      if (now.minute != _now.minute) setState(() => _now = now);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String two(int v) => v.toString().padLeft(2, '0');
    final locale = context.l10n.localeName;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          // "Montag 24.11.2026" / "Monday, Nov 24, 2026" - as Radio's clock.
          DateFormat(locale == 'de' ? 'EEEE dd.MM.yyyy' : 'EEEE, MMM d, y', locale).format(_now),
          style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 12),
        Text(
          '${two(_now.hour)}:${two(_now.minute)}',
          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

/// One tile of the row: the picture with the app's name underneath, larger
/// and framed while focused.
class _TileView extends ConsumerStatefulWidget {
  const _TileView({
    required this.tile,
    required this.focusNode,
    required this.onOpen,
    required this.onOptions,
    this.onFocused,
    this.autofocus = false,
    this.size = _TileSize.favorite,
    this.moving = false,
    this.lifted,
  });

  /// Move mode is on: OK (short and held) is the rows' then.
  final bool moving;

  /// Picked up in move mode (null: not lifted).
  final _Lifted? lifted;
  final VoidCallback? onFocused;
  final _TileSize size;
  final LauncherTile tile;
  final FocusNode focusNode;
  final VoidCallback onOpen;
  final VoidCallback onOptions;
  final bool autofocus;

  @override
  ConsumerState<_TileView> createState() => _TileViewState();
}

class _TileViewState extends ConsumerState<_TileView> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && ref.read(remoteKeysProvider).matches(RemoteAction.options, event.logicalKey)) {
      widget.onOptions();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: OkLongPress(
        onTap: widget.onOpen,
        // Null lets OK through to the rows in move mode.
        onLongPress: widget.moving ? null : widget.onOptions,
        child: _TileFrame(
          focused: _focused,
          label: widget.tile.displayLabel,
          size: widget.size,
          moving: widget.moving,
          lifted: widget.lifted,
          child: InkWell(
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            borderRadius: BorderRadius.circular(14),
            focusColor: Colors.transparent,
            onFocusChange: (v) {
              setState(() => _focused = v);
              if (v) widget.onFocused?.call();
            },
            onTap: widget.onOpen,
            onLongPress: widget.onOptions,
            // The mouse on the PC.
            onSecondaryTap: widget.onOptions,
            child: TileArt(tile: widget.tile),
          ),
        ),
      ),
    );
  }
}

/// Size, scale and frame of a focused/unfocused tile, with its label.
class _TileFrame extends StatelessWidget {
  const _TileFrame({
    required this.focused,
    required this.label,
    required this.child,
    this.size = _TileSize.favorite,
    this.moving = false,
    this.lifted,
  });

  final bool focused;
  final String label;
  final Widget child;
  final _TileSize size;

  /// Move mode: the focused tile shows that OK picks it up.
  final bool moving;

  /// Picked up in move mode: raised, larger, green frame, ◀ ▶ arrows.
  final _Lifted? lifted;

  @override
  Widget build(BuildContext context) {
    final small = size.height < _TileSize.favorite.height;
    final lifted = this.lifted;
    final picture = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(width: size.width, height: size.height, child: child),
    );
    return SizedBox(
      width: size.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSlide(
            offset: lifted != null ? const Offset(0, -0.06) : Offset.zero,
            duration: const Duration(milliseconds: 150),
            child: AnimatedScale(
              scale: lifted != null ? 1.14 : (focused ? 1.08 : 1.0),
              duration: const Duration(milliseconds: 150),
              child: lifted != null
                  ? _LiftedFrame(lifted: lifted, small: small, child: picture)
                  : Stack(
                      clipBehavior: Clip.none,
                      children: [
                        TvFocusHighlight(focused: focused, borderRadius: BorderRadius.circular(16), child: picture),
                        if (moving && focused)
                          const Positioned(top: 6, right: 6, child: _RoundIcon(icon: Icons.open_with, size: 20)),
                      ],
                    ),
            ),
          ),
          SizedBox(height: small ? 10 : 14),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: lifted != null ? brandGreen : (focused ? Colors.white : Colors.white70),
              fontSize: size.labelSize,
              fontWeight: focused || lifted != null ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

/// A lifted tile in move mode: which ways it can still go.
class _Lifted {
  const _Lifted({required this.left, required this.right});

  final bool left;
  final bool right;
}

/// The lifted tile's look: a thick green frame, a shadow underneath (it
/// "floats" over the row) and ◀ ▶ on its sides where it can still go.
class _LiftedFrame extends StatelessWidget {
  const _LiftedFrame({required this.lifted, required this.small, required this.child});

  final _Lifted lifted;
  final bool small;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final arrow = small ? 22.0 : 28.0;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: brandGreen, width: 4),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                const BoxShadow(color: Colors.black87, blurRadius: 22, offset: Offset(0, 12)),
                BoxShadow(color: brandGreen.withValues(alpha: 0.6), blurRadius: 16, spreadRadius: 2),
              ],
            ),
            child: child,
          ),
        ),
        if (lifted.left) Positioned(left: 6, child: _RoundIcon(icon: Icons.chevron_left, size: arrow)),
        if (lifted.right) Positioned(right: 6, child: _RoundIcon(icon: Icons.chevron_right, size: arrow)),
      ],
    );
  }
}

/// A small white icon on a dark round badge - readable on any picture.
class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        shape: BoxShape.circle,
        border: Border.all(color: brandGreen, width: 1.5),
      ),
      child: Icon(icon, color: Colors.white, size: size),
    );
  }
}

/// Move mode's hint over the rows: which keys do what.
class _MoveBanner extends StatelessWidget {
  const _MoveBanner({required this.lifted});

  final bool lifted;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: brandGreen, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.open_with, color: brandGreen, size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  lifted ? l.launcherMoveModeLiftedHint : l.launcherMoveModeHint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppsTile extends StatefulWidget {
  const _AppsTile({required this.focusNode, required this.onOpen, this.onFocused});

  final FocusNode focusNode;
  final VoidCallback onOpen;
  final VoidCallback? onFocused;

  @override
  State<_AppsTile> createState() => _AppsTileState();
}

class _AppsTileState extends State<_AppsTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return _TileFrame(
      focused: _focused,
      label: context.l10n.miscAllAppsTitle,
      child: InkWell(
        focusNode: widget.focusNode,
        borderRadius: BorderRadius.circular(14),
        focusColor: Colors.transparent,
        onFocusChange: (v) {
          setState(() => _focused = v);
          if (v) widget.onFocused?.call();
        },
        onTap: widget.onOpen,
        child: Container(
          color: Colors.white.withValues(alpha: 0.12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.apps, color: Colors.white, size: 48),
              const SizedBox(height: 6),
              Text(context.l10n.settingsLauncherFindApps, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A group without apps yet: a calm placeholder - OK or ☰ give the group's
/// options (rename, move, delete), so an empty group is reachable too.
class _EmptyGroupTile extends ConsumerStatefulWidget {
  const _EmptyGroupTile({required this.focusNode, required this.hint, required this.onOptions, this.onFocused});

  final FocusNode focusNode;
  final String hint;
  final VoidCallback onOptions;
  final VoidCallback? onFocused;

  @override
  ConsumerState<_EmptyGroupTile> createState() => _EmptyGroupTileState();
}

class _EmptyGroupTileState extends ConsumerState<_EmptyGroupTile> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && ref.read(remoteKeysProvider).matches(RemoteAction.options, event.logicalKey)) {
      widget.onOptions();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: _TileFrame(
        focused: _focused,
        size: _TileSize.group,
        label: context.l10n.launcherGroupEmpty,
        child: InkWell(
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(14),
          focusColor: Colors.transparent,
          onFocusChange: (v) {
            setState(() => _focused = v);
            if (v) widget.onFocused?.call();
          },
          onTap: widget.onOptions,
          onLongPress: widget.onOptions,
          onSecondaryTap: widget.onOptions,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.folder_open_outlined, color: Colors.white54, size: 36),
                const SizedBox(height: 6),
                Text(
                  widget.hint,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tile's picture: Radio's own design, an app's banner/icon (or the
/// icon pack's, or the tile's own picture from an address).
class TileArt extends ConsumerWidget {
  const TileArt({super.key, required this.tile});

  final LauncherTile tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = tile.imageUrl;
    final fallback = _builtInArt(context, ref);
    if (url != null) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (_, child, progress) => progress == null ? child : fallback,
      );
    }
    return fallback;
  }

  Widget _builtInArt(BuildContext context, WidgetRef ref) {
    if (tile.isRadio) return const _RadioArt();
    if (tile.isTv) return const _PartArt(logo: 'assets/icon/tv_logo.png', title: 'TV');
    if (tile.isDashboard) return _PartArt(logo: 'assets/icon/dashboard_logo.png', title: tile.displayLabel);
    if (tile.isPictures) return _PartArt(logo: 'assets/icon/pictures_logo.png', title: tile.displayLabel);
    if (tile.isMovies) return _PartArt(logo: 'assets/icon/movies_logo.png', title: tile.displayLabel);
    if (tile.isMusic) return _PartArt(logo: 'assets/icon/music_logo.png', title: tile.displayLabel);
    if (tile.isBrowser) return _PartArt(logo: 'assets/icon/browser_logo.png', title: tile.displayLabel);
    if (tile.isSystemSettings) {
      return _BrandArt(icon: Icons.settings_outlined, title: context.l10n.systemTileSettingsShort);
    }
    final package = tile.package!;
    final pack = ref.watch(launcherSettingsProvider).iconPack;
    if (pack != null && tile.image != LauncherTile.originalImage) {
      final packImage = ref.watch(iconPackImageProvider((pack, package)));
      if (packImage.isLoading) return const _Placeholder();
      if (packImage.value case final image?) return _AppArt(image: image, label: tile.displayLabel);
    }
    final own = ref.watch(appImageProvider(package));
    return own.when(
      data: (image) => image == null ? _NameArt(label: tile.displayLabel) : _AppArt(image: image, label: tile.displayLabel),
      loading: () => const _Placeholder(),
      error: (_, _) => _NameArt(label: tile.displayLabel),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) => Container(color: Colors.white10);
}

class _AppArt extends StatelessWidget {
  const _AppArt({required this.image, required this.label});

  final AppImage image;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (image.banner) {
      return Image.memory(image.bytes, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium);
    }
    // A square icon: centred on a calm card, with the name next to it.
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFF1E2A32), Color(0xFF0E151A)]),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Image.memory(image.bytes, width: 80, height: 80, gaplessPlayback: true, filterQuality: FilterQuality.medium),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _NameArt extends StatelessWidget {
  const _NameArt({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1E2A32),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20)),
    );
  }
}

/// A Home System part's tile (Radio, TV): its logo on the logos'
/// own dark graphite with a green glow, name and a line underneath.
class _PartArt extends StatelessWidget {
  const _PartArt({required this.logo, required this.title, this.subtitle});

  final String logo;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.7, 0.9),
          radius: 1.3,
          colors: [Color(0xFF14361C), Color(0xFF15191B), Color(0xFF07090A)],
          stops: [0, 0.55, 1],
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset(logo, width: 80, height: 80, filterQuality: FilterQuality.medium),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFFB4F05A), fontSize: 13),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Radio's tile, with what's tuned.
class _RadioArt extends ConsumerWidget {
  const _RadioArt();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _PartArt(logo: 'assets/icon/radio_logo.png', title: 'Radio', subtitle: _currentStation(ref));

  String? _currentStation(WidgetRef ref) {
    final program = ref.watch(currentProgramNumberProvider);
    if (program != null) {
      final favorites = ref.watch(favoritesStreamProvider).value ?? const [];
      return favorites.where((f) => f.programNumber == program).firstOrNull?.displayName;
    }
    final dab = ref.watch(currentDabStationProvider);
    if (dab != null) {
      final s = (ref.watch(dabStationsStreamProvider).value ?? const [])
          .where((s) => s.freqKhz == dab.freqKhz && s.serviceId == dab.serviceId)
          .firstOrNull;
      return s == null ? null : (s.customLabel ?? s.stationLabel).trim();
    }
    final fm = ref.watch(currentFmStationProvider);
    if (fm != null) {
      final s = (ref.watch(fmStationsStreamProvider).value ?? const []).where((s) => s.freqKhz == fm).firstOrNull;
      return s?.customLabel ?? s?.psName ?? '${(fm / 1000).toStringAsFixed(1)} MHz';
    }
    return null;
  }
}

/// The TV's own settings tile.
class _BrandArt extends StatelessWidget {
  const _BrandArt({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A3640), Color(0xFF11181D)],
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 64),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
