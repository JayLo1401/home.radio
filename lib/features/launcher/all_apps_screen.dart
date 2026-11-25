import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/music_providers.dart';
import '../../core/ok_long_press.dart';
import '../../core/popup_text_field.dart';
import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/services/launcher_service.dart';
import '../../l10n/l10n.dart';
import 'launcher_providers.dart';
import 'launcher_screen.dart' show TileArt, chooseGroupFor, launcherMenuOption, openAppInfo;

/// Every installed app, searchable: OK opens it, ☰ (menu) or holding OK
/// gives its options - favourite on/off, into a group of Home, app info
/// (force stop, uninstall). The star marks the ones in the favourites.
class AllAppsScreen extends ConsumerStatefulWidget {
  const AllAppsScreen({super.key});

  @override
  ConsumerState<AllAppsScreen> createState() => _AllAppsScreenState();
}

class _AllAppsScreenState extends ConsumerState<AllAppsScreen> with WidgetsBindingObserver {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  Future<void> _launch(InstalledApp app) async {
    pauseRadioAndMusicForApp(ref);
    await ref.read(launcherServiceProvider).launchApp(app.package);
  }

  /// ☰ or holding OK: favourite on/off, into a group, app info (force
  /// stop, uninstall).
  Future<void> _options(InstalledApp app) async {
    final inRow = ref.read(launcherTilesProvider.notifier).contains(LauncherTile.app(package: app.package, label: app.label).id);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(app.label),
        children: [
          launcherMenuOption(context, 'open', Icons.open_in_new, context.l10n.miscAllAppsOpen, autofocus: true),
          launcherMenuOption(
            context,
            'favorite',
            inRow ? Icons.star : Icons.star_border,
            inRow ? context.l10n.miscAllAppsRemoveFavorite : context.l10n.miscAllAppsAddFavorite,
          ),
          launcherMenuOption(context, 'group', Icons.playlist_add, context.l10n.launcherAddToGroup),
          launcherMenuOption(context, 'info', Icons.info_outline, context.l10n.miscAllAppsAppInfo),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'open':
        await _launch(app);
      case 'favorite':
        await _toggleFavorite(app);
      case 'group':
        await chooseGroupFor(context, ref, _tileFor(app));
      case 'info':
        await openAppInfo(context, ref, app.package, app.label);
    }
  }

  // Back from the app info (maybe uninstalled there): read the list again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(installedAppsProvider);
  }

  /// The app's tile - with the picture it has on Home already, if any.
  LauncherTile _tileFor(InstalledApp app) {
    final tile = LauncherTile.app(package: app.package, label: app.label);
    return [
          ...ref.read(launcherTilesProvider),
          for (final g in ref.read(launcherGroupsProvider)) ...g.tiles,
        ].where((t) => t.id == tile.id).firstOrNull ??
        tile;
  }

  Future<void> _toggleFavorite(InstalledApp app) async {
    final notifier = ref.read(launcherTilesProvider.notifier);
    final tile = _tileFor(app);
    final inRow = notifier.contains(tile.id);
    if (inRow) {
      await notifier.remove(tile.id);
    } else {
      await notifier.add(tile);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          inRow ? context.l10n.miscAllAppsFavoriteRemoved(app.label) : context.l10n.miscAllAppsFavoriteAdded(app.label),
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final apps = ref.watch(installedAppsProvider);
    final tiles = ref.watch(launcherTilesProvider);
    final query = _search.text.trim().toLowerCase();
    final settingsInRow = tiles.any((t) => t.isSystemSettings);
    final l = context.l10n;
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.7),
        title: Text(l.miscAllAppsTitle),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(32, 16, 32, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 420,
                  child: PopupTextField(controller: _search, label: l.miscAllAppsSearch, icon: Icons.search),
                ),
                const SizedBox(width: 16),
                if (query.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _search.clear(),
                    icon: const Icon(Icons.clear),
                    label: Text(l.miscAllAppsClearSearch),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    final notifier = ref.read(launcherTilesProvider.notifier);
                    settingsInRow
                        ? notifier.remove(const LauncherTile.systemSettings().id)
                        : notifier.add(const LauncherTile.systemSettings());
                  },
                  icon: Icon(settingsInRow ? Icons.star : Icons.star_border),
                  label: Text(settingsInRow ? l.miscAllAppsSettingsIsFavorite : l.miscAllAppsSettingsAddFavorite),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.launcherAllAppsHelp,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: apps.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text(l.miscAllAppsLoadError('$e'))),
                data: (list) {
                  final shown = query.isEmpty
                      ? list
                      : list.where((a) => a.label.toLowerCase().contains(query) || a.package.contains(query)).toList();
                  if (shown.isEmpty) {
                    return Center(
                      child: Text(query.isEmpty ? l.miscAllAppsNone : l.miscAllAppsNoMatch(_search.text)),
                    );
                  }
                  return GridView.builder(
                    padding: const EdgeInsets.only(top: 12, bottom: 32, left: 8, right: 8),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 240,
                      mainAxisSpacing: 20,
                      crossAxisSpacing: 20,
                      childAspectRatio: 16 / 12,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final app = shown[i];
                      final tile = LauncherTile.app(package: app.package, label: app.label);
                      return _AppCell(
                        app: app,
                        tile: tiles.where((t) => t.id == tile.id).firstOrNull ?? tile,
                        favorite: tiles.any((t) => t.id == tile.id),
                        autofocus: i == 0,
                        onOpen: () => _launch(app),
                        onOptions: () => _options(app),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppCell extends StatefulWidget {
  const _AppCell({
    required this.app,
    required this.tile,
    required this.favorite,
    required this.onOpen,
    required this.onOptions,
    this.autofocus = false,
  });

  final InstalledApp app;
  final LauncherTile tile;
  final bool favorite;
  final VoidCallback onOpen;
  final VoidCallback onOptions;
  final bool autofocus;

  @override
  State<_AppCell> createState() => _AppCellState();
}

class _AppCellState extends State<_AppCell> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        ProviderScope.containerOf(context, listen: false)
            .read(remoteKeysProvider)
            .matches(RemoteAction.options, event.logicalKey)) {
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
        onLongPress: widget.onOptions,
        child: Column(
          children: [
            Expanded(
              child: TvFocusHighlight(
                focused: _focused,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  autofocus: widget.autofocus,
                  borderRadius: BorderRadius.circular(12),
                  focusColor: Colors.transparent,
                  onFocusChange: (v) {
                    setState(() => _focused = v);
                    if (v) Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 150));
                  },
                  onTap: widget.onOpen,
                  onLongPress: widget.onOptions,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        TileArt(tile: widget.tile),
                        if (widget.favorite)
                          const Positioned(
                            top: 6,
                            right: 6,
                            child: Icon(Icons.star, color: Colors.amber, size: 24, shadows: [Shadow(blurRadius: 4)]),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.app.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _focused ? Colors.white : Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
