import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ok_long_press.dart';
import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/services/launcher_service.dart';
import '../settings/settings_screen.dart';
import '../tv/tv_screen.dart';
import 'all_apps_screen.dart';
import 'launcher_background.dart';
import 'launcher_navigation.dart';
import 'launcher_providers.dart';

/// Home Media's launcher: a background picture, the clock, and one row of
/// tiles - Home Radio, the user's apps (Netflix, Disney+, ...) and "Alle
/// Apps". Opened over Home Radio (see launcher_navigation.dart), so the radio
/// keeps playing while it's open.
///
/// Remote: D-Pad through the tiles, OK opens, ☰ (menu) or holding OK
/// gives the tile's options (move, picture, remove), up reaches the
/// settings. Back does nothing - this is the home screen.
class LauncherScreen extends ConsumerStatefulWidget {
  const LauncherScreen({super.key});

  @override
  ConsumerState<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends ConsumerState<LauncherScreen> {
  final _tileFocus = <String, FocusNode>{};
  final _appsFocus = FocusNode(debugLabel: 'apps');
  final _menuFocus = FocusNode(debugLabel: 'menu');
  final _scroll = ScrollController();
  String? _lastTileId;

  FocusNode _focusFor(String id) => _tileFocus.putIfAbsent(id, () => FocusNode(debugLabel: id));

  void _focusLastTile() => (_tileFocus[_lastTileId] ?? _tileFocus.values.firstOrNull ?? _appsFocus).requestFocus();

  /// The top bar's "Einstellungen": Home Media's own settings, the device's
  /// (Android) settings, all apps - on the PC straight the app's settings.
  Future<void> _openMenu() async {
    if (!LauncherService.supported) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Einstellungen'),
        children: [
          _option(context, 'app', Icons.tune, 'Home Media (App-Einstellungen)', autofocus: true),
          _option(context, 'android', Icons.settings_applications_outlined, 'Android-Einstellungen'),
          _option(context, 'apps', Icons.apps, 'Alle Apps'),
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
    }
  }

  @override
  void dispose() {
    for (final node in _tileFocus.values) {
      node.dispose();
    }
    _appsFocus.dispose();
    _menuFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
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

  Future<void> _open(LauncherTile tile) async {
    final service = ref.read(launcherServiceProvider);
    if (tile.isRadio) {
      hideLauncher(ref);
      return;
    }
    if (tile.isTv) {
      // TV takes the speakers; the radio plays on when opened again.
      ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TvScreen()));
      return;
    }
    if (tile.isSystemSettings) {
      await service.openSystemSettings();
      return;
    }
    if (tile.isApp) {
      // The other app gets the screen and the speakers.
      ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
      final ok = await service.launchApp(tile.package!);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('„${tile.displayLabel}“ ist nicht (mehr) installiert.')),
        );
      }
    }
  }

  Future<void> _openAllApps() async {
    ref.invalidate(installedAppsProvider);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AllAppsScreen()));
  }

  Future<void> _options(LauncherTile tile) async {
    final tiles = ref.read(launcherTilesProvider);
    final index = tiles.indexWhere((t) => t.id == tile.id);
    final notifier = ref.read(launcherTilesProvider.notifier);
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tile.displayLabel),
        children: [
          if (index > 0) _option(context, 'left', Icons.arrow_back, 'Nach links verschieben', autofocus: true),
          if (index < tiles.length - 1)
            _option(context, 'right', Icons.arrow_forward, 'Nach rechts verschieben', autofocus: index == 0),
          _option(context, 'image', Icons.image_outlined, 'Bild ändern'),
          // Home TV comes back through "Alle Apps" - there is none on the PC.
          if (!tile.isRadio && (LauncherService.supported || !tile.isBuiltIn))
            _option(context, 'remove', Icons.delete_outline, 'Aus der Startleiste entfernen'),
        ],
      ),
    );
    switch (action) {
      case 'left':
        await notifier.move(tile.id, -1);
        _keepVisible(tile.id);
      case 'right':
        await notifier.move(tile.id, 1);
        _keepVisible(tile.id);
      case 'image':
        if (mounted) await chooseTileImage(context, ref, tile);
      case 'remove':
        await notifier.remove(tile.id);
        _tileFocus.remove(tile.id)?.dispose();
        _lastTileId = null;
        _focusLastTile();
    }
  }

  void _keepVisible(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final node = _tileFocus[id];
      if (node == null) return;
      node.requestFocus();
      final ctx = node.context;
      if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 200));
    });
  }

  @override
  Widget build(BuildContext context) {
    final tiles = ref.watch(launcherTilesProvider);
    return PopScope(
      canPop: false,
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
                    _MenuBar(menuFocus: _menuFocus, onMenu: _openMenu, onDown: _focusLastTile),
                    const Spacer(),
                    // A band across the whole width, like Home Radio's
                    // "now playing" banner - top bar and band frame the
                    // picture.
                    Container(
                      color: Colors.black.withValues(alpha: ref.watch(launcherSettingsProvider).bandOpacity),
                      padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.favorite, color: brandGreen, size: 20),
                              const SizedBox(width: 8),
                              const Text('Favoriten',
                                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Text(
                                '${_keyHint(ref, RemoteAction.options)}'
                                '${LauncherService.supported ? '' : ' oder Rechtsklick'}  Optionen der Kachel',
                                style: const TextStyle(color: Colors.white38, fontSize: 13),
                              ),
                            ],
                          ),
                          // Up from any tile goes to the top bar - by itself
                          // the D-Pad found no way there.
                          Focus(
                            canRequestFocus: false,
                            skipTraversal: true,
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowUp) {
                                _menuFocus.requestFocus();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: SizedBox(
                              // Tile, gap and its name - with room for taller
                              // fonts (Segoe UI on the PC).
                              height: _TileView.height + 72,
                              child: ListView(
                                controller: _scroll,
                                scrollDirection: Axis.horizontal,
                                clipBehavior: Clip.none,
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
                                children: [
                                  for (final (i, tile) in tiles.indexed)
                                    Padding(
                                      key: ValueKey(tile.id),
                                      padding: const EdgeInsets.only(right: 22),
                                      child: _TileView(
                                        tile: tile,
                                        focusNode: _focusFor(tile.id),
                                        autofocus: i == 0,
                                        onOpen: () => _open(tile),
                                        onOptions: () => _options(tile),
                                        onFocused: () => _lastTileId = tile.id,
                                      ),
                                    ),
                                  if (LauncherService.supported) _AppsTile(focusNode: _appsFocus, onOpen: _openAllApps),
                                ],
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

  /// The (first) key assigned to [action], for the hints on screen.
  static String _keyHint(WidgetRef ref, RemoteAction action) => remoteKeyHint(ref.watch(remoteKeysProvider), action);

  static Widget _option(BuildContext context, String value, IconData icon, String label, {bool autofocus = false}) {
    return SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop(value),
      child: _DialogRow(icon: icon, label: label, autofocus: autofocus, onTap: () => Navigator.of(context).pop(value)),
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
  final notifier = ref.read(launcherTilesProvider.notifier);
  final hasPack = ref.read(launcherSettingsProvider).iconPack != null;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Bild für „${tile.displayLabel}“'),
      children: [
        _LauncherScreenState._option(
          context,
          'auto',
          Icons.auto_awesome_outlined,
          tile.isApp && hasPack ? 'Automatisch (Icon-Paket, sonst Original)' : 'Standard',
          autofocus: true,
        ),
        if (tile.isApp && hasPack) _LauncherScreenState._option(context, 'original', Icons.apps, 'Original der App'),
        _LauncherScreenState._option(context, 'url', Icons.link, 'Bild von einer Adresse (URL) …'),
      ],
    ),
  );
  switch (choice) {
    case 'auto':
      await notifier.setImage(tile.id, null);
    case 'original':
      await notifier.setImage(tile.id, LauncherTile.originalImage);
    case 'url':
      if (!context.mounted) return;
      final url = await showTextInputDialog(
        context,
        title: 'Bild-Adresse (PNG/JPG, am besten 16:9)',
        initialValue: tile.imageUrl ?? '',
        hint: 'http://…',
        keyboardType: TextInputType.url,
      );
      if (url == null) return;
      final uri = Uri.tryParse(url);
      if (url.isEmpty) {
        await notifier.setImage(tile.id, null);
      } else if (uri != null && uri.scheme.startsWith('http')) {
        await notifier.setImage(tile.id, url);
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bitte eine vollständige Adresse mit http:// oder https:// eingeben.')),
        );
      }
  }
}

/// The same top bar as Home Radio's (translucent black, logo and name left,
/// date and time centred, icon buttons right that show their label when
/// focused) - Home Media's launcher and Home Radio read as one app.
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
                    child: Image.asset('assets/icon/home_media_logo.png', width: 36, height: 36),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Home Media', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      Text('Powered by Jay', style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600)),
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
                child: _BarButton(focusNode: menuFocus, icon: Icons.settings, label: 'Einstellungen', onTap: onMenu),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Like Home Radio's top-bar buttons: the icon, plus its label while focused.
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

/// Weekday, date and time in one line - as Home Radio's clock.
class _LauncherClock extends StatefulWidget {
  const _LauncherClock();

  @override
  State<_LauncherClock> createState() => _LauncherClockState();
}

class _LauncherClockState extends State<_LauncherClock> {
  static const _weekdays = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${_weekdays[_now.weekday - 1]} ${two(_now.day)}.${two(_now.month)}.${_now.year}',
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
  });

  final VoidCallback? onFocused;

  static const width = 256.0;
  static const height = 144.0;

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
        onLongPress: widget.onOptions,
        child: _TileFrame(
          focused: _focused,
          label: widget.tile.displayLabel,
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
  const _TileFrame({required this.focused, required this.label, required this.child});

  final bool focused;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _TileView.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedScale(
            scale: focused ? 1.08 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: TvFocusHighlight(
              focused: focused,
              borderRadius: BorderRadius.circular(16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(width: _TileView.width, height: _TileView.height, child: child),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: focused ? Colors.white : Colors.white70,
              fontSize: 16,
              fontWeight: focused ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppsTile extends StatefulWidget {
  const _AppsTile({required this.focusNode, required this.onOpen});

  final FocusNode focusNode;
  final VoidCallback onOpen;

  @override
  State<_AppsTile> createState() => _AppsTileState();
}

class _AppsTileState extends State<_AppsTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return _TileFrame(
      focused: _focused,
      label: 'Alle Apps',
      child: InkWell(
        focusNode: widget.focusNode,
        borderRadius: BorderRadius.circular(14),
        focusColor: Colors.transparent,
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onOpen,
        child: Container(
          color: Colors.white.withValues(alpha: 0.12),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.apps, color: Colors.white, size: 48),
              SizedBox(height: 6),
              Text('Apps suchen & hinzufügen', style: TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tile's picture: Home Radio's own design, an app's banner/icon (or the
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
    if (tile.isTv) return const _PartArt(logo: 'assets/icon/home_tv_logo.png', title: 'Home TV');
    if (tile.isSystemSettings) return const _BrandArt(icon: Icons.settings_outlined, title: 'Einstellungen');
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

/// A Home Media part's tile (Home Radio, Home TV): its logo on the logos'
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

/// Home Radio's tile, with what's tuned.
class _RadioArt extends ConsumerWidget {
  const _RadioArt();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _PartArt(logo: 'assets/icon/home_radio_logo.png', title: 'Home Radio', subtitle: _currentStation(ref));

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
