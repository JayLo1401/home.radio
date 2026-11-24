import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nas_providers.dart';
import '../../core/providers.dart';
import '../../data/models/launcher_group.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/launcher_background_service.dart';
import '../../data/services/launcher_service.dart';

final launcherServiceProvider = Provider<LauncherService>((ref) => LauncherService());

final launcherBackgroundServiceProvider = Provider<LauncherBackgroundService>(
    (ref) => LauncherBackgroundService(nasPictures: ref.read(nasPictureCacheProvider)));

/// The app's navigator - the launcher is pushed over Radio from
/// anywhere (Home key, start, Back on the radio screen).
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Whether the launcher is open (on top of Radio, which stays mounted
/// underneath and keeps playing).
class LauncherVisible extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final launcherVisibleProvider = NotifierProvider<LauncherVisible, bool>(LauncherVisible.new);

/// Commands for Radio's playback from outside its screen - the
/// launcher pauses the radio before another app takes over the screen
/// ([pauseForApp]: it plays on once Radio is opened again), and passes
/// the remote's play/pause key on. The counter makes the same command twice
/// in a row still a change.
enum RadioCommand { stop, togglePlayPause, pauseForApp }

class RadioCommandNotifier extends Notifier<(RadioCommand, int)?> {
  @override
  (RadioCommand, int)? build() => null;

  void send(RadioCommand command) => state = (command, (state?.$2 ?? 0) + 1);
}

final radioCommandProvider = NotifierProvider<RadioCommandNotifier, (RadioCommand, int)?>(RadioCommandNotifier.new);

class LauncherSettings {
  const LauncherSettings({
    this.startScreen = StartScreen.radio,
    this.backgroundSource = LauncherBackgroundSource.builtin,
    this.backgroundUrl = '',
    this.backgroundInterval = SettingsRepository.defaultLauncherBackgroundInterval,
    this.iconPack,
    this.bandOpacity = SettingsRepository.defaultLauncherBandOpacity,
    this.loaded = false,
  });

  /// How solid the band behind the tiles is (0 = none).
  final double bandOpacity;
  final StartScreen startScreen;
  final LauncherBackgroundSource backgroundSource;
  final String backgroundUrl;
  final int backgroundInterval;
  final String? iconPack;
  final bool loaded;
}

class LauncherSettingsNotifier extends Notifier<LauncherSettings> {
  @override
  LauncherSettings build() {
    _load();
    return const LauncherSettings();
  }

  SettingsRepository get _repo => ref.read(settingsRepositoryProvider);

  Future<void> _load() async {
    final repo = _repo;
    state = LauncherSettings(
      startScreen: await repo.getStartScreen(),
      backgroundSource: await repo.getLauncherBackgroundSource(),
      backgroundUrl: await repo.getLauncherBackgroundUrl(),
      backgroundInterval: await repo.getLauncherBackgroundInterval(),
      iconPack: await repo.getLauncherIconPack(),
      bandOpacity: await repo.getLauncherBandOpacity(),
      loaded: true,
    );
  }

  LauncherSettings _copy({
    StartScreen? startScreen,
    LauncherBackgroundSource? backgroundSource,
    String? backgroundUrl,
    int? backgroundInterval,
    String? Function()? iconPack,
    double? bandOpacity,
  }) =>
      LauncherSettings(
        startScreen: startScreen ?? state.startScreen,
        backgroundSource: backgroundSource ?? state.backgroundSource,
        backgroundUrl: backgroundUrl ?? state.backgroundUrl,
        backgroundInterval: backgroundInterval ?? state.backgroundInterval,
        iconPack: iconPack != null ? iconPack() : state.iconPack,
        bandOpacity: bandOpacity ?? state.bandOpacity,
        loaded: true,
      );

  Future<void> setBandOpacity(double value) async {
    state = _copy(bandOpacity: value);
    await _repo.setLauncherBandOpacity(value);
  }

  Future<void> setStartScreen(StartScreen value) async {
    state = _copy(startScreen: value);
    await _repo.setStartScreen(value);
  }

  Future<void> setBackground({required LauncherBackgroundSource source, required String url, required int interval}) async {
    state = _copy(backgroundSource: source, backgroundUrl: url, backgroundInterval: interval);
    await _repo.setLauncherBackgroundSource(source);
    await _repo.setLauncherBackgroundUrl(url);
    await _repo.setLauncherBackgroundInterval(interval);
  }

  Future<void> setIconPack(String? package) async {
    state = _copy(iconPack: () => package);
    await _repo.setLauncherIconPack(package);
  }
}

final launcherSettingsProvider =
    NotifierProvider<LauncherSettingsNotifier, LauncherSettings>(LauncherSettingsNotifier.new);

/// The launcher's row. On the very first start: Radio and the installed
/// streaming apps of [defaultLauncherPackages].
class LauncherTilesNotifier extends Notifier<List<LauncherTile>> {
  /// The saved row is loaded - a tile added before (a part switched on at
  /// the start) mustn't replace it.
  late Future<void> _ready;

  @override
  List<LauncherTile> build() {
    _ready = _load();
    return const [LauncherTile.radio()];
  }

  SettingsRepository get _repo => ref.read(settingsRepositoryProvider);

  Future<void> _load() async {
    var saved = await _repo.getLauncherTiles();
    // Without the device's apps (PC): only Home System's own parts - app
    // tiles could come along with a backup from the TV box.
    if (saved != null && !LauncherService.supported) saved = saved.where((t) => t.isBuiltIn).toList();
    if (saved != null) {
      if (!saved.any((t) => t.isTv) && !await _repo.getLauncherTvAdded()) {
        saved.insert(saved.indexWhere((t) => t.isRadio) + 1, const LauncherTile.tv());
        await _repo.setLauncherTiles(saved);
      }
      await _repo.setLauncherTvAdded();
      // Once: parts added to the end before (behind the apps) move up to
      // the other own tiles - later the user's own order stays.
      if (!await _repo.getLauncherOwnTilesMoved()) {
        saved = ownTilesToFront(saved);
        await _repo.setLauncherTiles(saved);
        await _repo.setLauncherOwnTilesMoved();
      }
      state = saved;
      return;
    }
    await _repo.setLauncherTvAdded();
    final apps = await ref.read(launcherServiceProvider).listApps();
    final tiles = <LauncherTile>[const LauncherTile.radio(), const LauncherTile.tv()];
    for (final package in defaultLauncherPackages) {
      final app = apps.where((a) => a.package == package).firstOrNull;
      if (app != null) tiles.add(LauncherTile.app(package: app.package, label: app.label));
    }
    state = tiles;
    await _repo.setLauncherTiles(tiles);
  }

  Future<void> _save(List<LauncherTile> tiles) async {
    state = tiles;
    await _repo.setLauncherTiles(tiles);
  }

  bool contains(String id) => state.any((t) => t.id == id);

  /// Home System's parts go right after the last part in the row (so one
  /// switched on later isn't put behind the apps), everything else at the
  /// end - see insertLauncherTile.
  Future<void> add(LauncherTile tile) async {
    await _ready.catchError((_) {});
    if (contains(tile.id)) return;
    await _save(insertLauncherTile(state, tile));
  }

  Future<void> remove(String id) async {
    final tile = state.where((t) => t.id == id).firstOrNull;
    if (tile == null || tile.isRadio) return;
    await _save([...state]..removeWhere((t) => t.id == id));
  }

  /// Moves a tile one place left (-1) or right (+1).
  Future<void> move(String id, int direction) async {
    final i = state.indexWhere((t) => t.id == id);
    final j = i + direction;
    if (i < 0 || j < 0 || j >= state.length) return;
    final tiles = [...state];
    final tile = tiles.removeAt(i);
    tiles.insert(j, tile);
    await _save(tiles);
  }

  /// Move mode's drop: the tile at place [index] of the row as shown
  /// ([shown]: which tiles are on screen) - see placeLauncherTile.
  Future<void> place(String id, int index, {bool Function(LauncherTile tile)? shown}) async {
    final tiles = placeLauncherTile(state, id, index, shown: shown);
    if (identical(tiles, state)) return;
    await _save(tiles);
  }

  Future<void> setImage(String id, String? image) async {
    if (!contains(id)) return;
    await _save([for (final t in state) t.id == id ? t.withImage(image) : t]);
  }
}

final launcherTilesProvider = NotifierProvider<LauncherTilesNotifier, List<LauncherTile>>(LauncherTilesNotifier.new);

/// The launcher's groups - rows of apps under the favourites, each with a
/// name (see LauncherGroup). None until the user makes one; there are no
/// app tiles on the PC, so none there either.
class LauncherGroupsNotifier extends Notifier<List<LauncherGroup>> {
  late Future<void> _ready;

  @override
  List<LauncherGroup> build() {
    _ready = _load();
    return const [];
  }

  SettingsRepository get _repo => ref.read(settingsRepositoryProvider);

  Future<void> _load() async {
    if (!LauncherService.supported) return;
    state = await _repo.getLauncherGroups();
  }

  Future<void> _save(List<LauncherGroup> groups) async {
    await _ready.catchError((_) {});
    state = groups;
    await _repo.setLauncherGroups(groups);
  }

  Future<void> _edit(List<LauncherGroup> Function(List<LauncherGroup> groups) change) async {
    await _ready.catchError((_) {});
    await _save(change(state));
  }

  /// A new group at the end (with [first] in it); returns its id.
  Future<String> create(String name, {LauncherTile? first}) async {
    await _ready.catchError((_) {});
    final group = LauncherGroup(id: newLauncherGroupId(state), name: name.trim());
    var groups = [...state, group];
    if (first != null) groups = groups.addTile(group.id, first);
    await _save(groups);
    return group.id;
  }

  Future<void> rename(String id, String name) => _edit((g) => g.rename(id, name.trim()));
  Future<void> delete(String id) => _edit((g) => g.without(id));
  Future<void> moveGroup(String id, int direction) => _edit((g) => g.moveGroup(id, direction));
  Future<void> addTile(String groupId, LauncherTile tile) => _edit((g) => g.addTile(groupId, tile));
  Future<void> removeTile(String groupId, String tileId) => _edit((g) => g.removeTile(groupId, tileId));
  Future<void> moveTile(String groupId, String tileId, int direction) =>
      _edit((g) => g.moveTile(groupId, tileId, direction));
  Future<void> placeTile(String groupId, String tileId, int index) =>
      _edit((g) => g.placeTile(groupId, tileId, index));
  Future<void> moveTileTo(String fromId, String toId, LauncherTile tile) =>
      _edit((g) => g.moveTileTo(fromId, toId, tile));

  /// The tile's picture in every group it's in.
  Future<void> setImage(String tileId, String? image) async {
    await _ready.catchError((_) {});
    if (!state.any((g) => g.contains(tileId))) return;
    await _save(state.setImage(tileId, image));
  }
}

final launcherGroupsProvider =
    NotifierProvider<LauncherGroupsNotifier, List<LauncherGroup>>(LauncherGroupsNotifier.new);

/// Every installed app (refreshed with ref.invalidate when "Alle Apps" opens).
final installedAppsProvider = FutureProvider<List<InstalledApp>>((ref) {
  return ref.watch(launcherServiceProvider).listApps();
});

/// Installed icon packs.
final iconPacksProvider = FutureProvider<List<({String package, String label})>>((ref) {
  return ref.watch(launcherServiceProvider).listIconPacks();
});

/// An app's own picture (banner or icon), kept once loaded.
final appImageProvider = FutureProvider.family<AppImage?, String>((ref, package) {
  return ref.watch(launcherServiceProvider).appImage(package);
});

/// The icon an icon pack has for an app.
final iconPackImageProvider = FutureProvider.family<AppImage?, (String, String)>((ref, key) {
  return ref.watch(launcherServiceProvider).iconPackImage(key.$1, key.$2);
});
