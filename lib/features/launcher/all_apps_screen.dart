import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ok_long_press.dart';
import '../../core/popup_text_field.dart';
import '../../core/theme.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/services/launcher_service.dart';
import 'launcher_providers.dart';
import 'launcher_screen.dart' show TileArt;

/// Every installed app, searchable: OK opens it, ☰ (menu) or holding OK adds
/// it to the launcher's favourites (or takes it out again). The star marks
/// the ones already in the row.
class AllAppsScreen extends ConsumerStatefulWidget {
  const AllAppsScreen({super.key});

  @override
  ConsumerState<AllAppsScreen> createState() => _AllAppsScreenState();
}

class _AllAppsScreenState extends ConsumerState<AllAppsScreen> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _launch(InstalledApp app) async {
    ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
    await ref.read(launcherServiceProvider).launchApp(app.package);
  }

  Future<void> _toggleFavorite(InstalledApp app) async {
    final notifier = ref.read(launcherTilesProvider.notifier);
    final tile = LauncherTile.app(package: app.package, label: app.label);
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
        content: Text(inRow ? '„${app.label}“ aus den Favoriten entfernt' : '„${app.label}“ zu den Favoriten hinzugefügt'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final apps = ref.watch(installedAppsProvider);
    final tiles = ref.watch(launcherTilesProvider);
    final query = _search.text.trim().toLowerCase();
    final settingsInRow = tiles.any((t) => t.isSystemSettings);
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.7),
        title: const Text('Alle Apps'),
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
                  child: PopupTextField(controller: _search, label: 'App suchen', icon: Icons.search),
                ),
                const SizedBox(width: 16),
                if (query.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _search.clear(),
                    icon: const Icon(Icons.clear),
                    label: const Text('Suche löschen'),
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
                  label: Text(settingsInRow ? 'TV-Einstellungen in den Favoriten' : 'TV-Einstellungen als Favorit'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'OK: App öffnen  ·  ☰ oder OK lange drücken: zu den Favoriten hinzufügen / entfernen',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: apps.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Apps konnten nicht gelesen werden: $e')),
                data: (list) {
                  final shown = query.isEmpty
                      ? list
                      : list.where((a) => a.label.toLowerCase().contains(query) || a.package.contains(query)).toList();
                  if (shown.isEmpty) {
                    return Center(
                      child: Text(query.isEmpty ? 'Keine Apps gefunden.' : 'Keine App passt zu „${_search.text}“.'),
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
                        onToggleFavorite: () => _toggleFavorite(app),
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
    required this.onToggleFavorite,
    this.autofocus = false,
  });

  final InstalledApp app;
  final LauncherTile tile;
  final bool favorite;
  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;
  final bool autofocus;

  @override
  State<_AppCell> createState() => _AppCellState();
}

class _AppCellState extends State<_AppCell> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.contextMenu) {
      widget.onToggleFavorite();
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
        onLongPress: widget.onToggleFavorite,
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
                  onLongPress: widget.onToggleFavorite,
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
