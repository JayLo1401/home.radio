import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/loading_wave.dart';
import '../../core/nas_providers.dart';
import '../../core/pictures_providers.dart';
import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/repositories/nas_settings_repository.dart';
import '../../data/services/nas_service.dart';
import '../../data/services/picture_library.dart';
import '../../l10n/l10n.dart';
import '../settings/nas_settings_screen.dart';
import 'slideshow_screen.dart';
import 'thumbnails.dart';

/// Bilder: the NAS pictures folder (Settings → NAS) to browse - its
/// subfolders as large tiles, first a "Diashow" entry for the folder with
/// everything below it, then the folder's own pictures as thumbnails. The
/// radio plays on.
///
/// Remote: D-Pad through the tiles, OK opens a folder (or starts the
/// slideshow on its entry - offering to go on where it was last), OK on a
/// picture starts the slideshow from that picture, ⏯ or the options key on
/// a folder starts its slideshow straight away, Back goes up a level and
/// leaves at the top. Touch: tap opens, holding a folder starts its
/// slideshow.
class PicturesScreen extends ConsumerStatefulWidget {
  const PicturesScreen({super.key, @visibleForTesting this.createClient});

  /// Tests: the NAS to browse (else the configured one's client).
  final NasClient Function(NasConfig config)? createClient;

  @override
  ConsumerState<PicturesScreen> createState() => _PicturesScreenState();
}

class _PicturesScreenState extends ConsumerState<PicturesScreen> {
  static const _tileWidth = 300.0;
  static const _tileHeight = 150.0;
  static const _spacing = 20.0;
  static const _thumbWidth = 210.0;
  static const _thumbSpacing = 12.0;

  /// Subfolders looked into for their numbers (one listing each).
  static const _maxCounted = 200;

  NasClient? _client;
  NasConfig? _config;
  String? _root;

  /// The thumbnails have a connection of their own - listings don't wait
  /// behind photos.
  NasClient? _thumbClient;
  ThumbnailLoader? _thumbs;

  /// The folders opened, the top one is shown.
  final _stack = <String>[];

  /// Listings of this visit - going back up or into a folder already
  /// counted needs no new request.
  final _cache = <String, PictureFolder>{};
  bool _loading = false;
  String? _error;
  var _generation = 0;

  /// Counts the runs of [_countSubfolders] - a new one ends the old.
  var _counting = 0;

  /// The folder to put the focus on when shown (the one just left).
  String? _focusPath;
  final _nodes = <String, FocusNode>{};
  final _scroll = ScrollController();
  var _columns = 1;

  String get _path => _stack.last;

  FocusNode _node(String id) => _nodes.putIfAbsent(id, () => FocusNode(debugLabel: id));

  @override
  void dispose() {
    _generation++;
    _counting++;
    _closeClient();
    _closeThumbnails();
    for (final node in _nodes.values) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _closeClient() {
    _client?.close();
    _client = null;
  }

  void _closeThumbnails() {
    _thumbs?.close();
    _thumbs = null;
    _thumbClient?.close();
    _thumbClient = null;
  }

  NasClient _newClient() => widget.createClient?.call(_config!) ?? _config!.createClient();

  NasClient get _nas => _client ??= _newClient();

  /// A broken connection (e.g. the FTP server dropped it while a slideshow
  /// ran) gets one more try on a new one.
  Future<List<NasEntry>> _list(String path) async {
    try {
      return await _nas.list(path);
    } on NasException {
      _closeClient();
      return _nas.list(path);
    }
  }

  /// A new pictures folder or NAS: start over at its top.
  void _reset(NasSettings nas, String root) {
    _closeClient();
    _closeThumbnails();
    _config = nas.config;
    _thumbs = ThumbnailLoader(() => _thumbClient ??= _newClient());
    _root = root;
    _stack
      ..clear()
      ..add(root);
    _cache.clear();
    _focusPath = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final path = _path;
    final generation = ++_generation;
    final cached = _cache[path];
    if (cached == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final entries = await _list(path);
        if (!mounted || generation != _generation) return;
        _cache[path] = PictureFolder.of(entries);
      } catch (e) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _error = e is NasException ? e.message : '$e';
        });
        return;
      }
    }
    setState(() {
      _loading = false;
      _error = null;
    });
    _placeFocus();
    _countSubfolders();
  }

  /// The numbers on the folder tiles: each subfolder listed once, one
  /// after the other, until another folder is opened or a slideshow starts.
  Future<void> _countSubfolders() async {
    final run = ++_counting;
    final path = _path;
    final folders = _cache[path]?.folders ?? const [];
    for (final folder in folders.take(_maxCounted)) {
      if (!mounted || run != _counting) return;
      if (_cache.containsKey(folder.path)) continue;
      try {
        final entries = await _nas.list(folder.path);
        _cache[folder.path] = PictureFolder.of(entries);
        if (mounted && run == _counting) setState(() {});
      } catch (e) {
        debugPrint('pictures: ${folder.path} not counted ($e)');
      }
    }
  }

  /// After a folder is shown: the focus on the folder just left (scrolled
  /// to it - the grid only builds what's visible), else on the first tile.
  void _placeFocus() {
    final content = _cache[_path];
    if (content == null) return;
    final target = _focusPath;
    _focusPath = null;
    final index = target == null ? -1 : content.folders.indexWhere((f) => f.path == target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        final row = index < 0 ? 0 : (index + 1) ~/ _columns;
        final offset = max(0.0, row * (_tileHeight + _spacing) - _tileHeight / 2);
        _scroll.jumpTo(min(offset, _scroll.position.maxScrollExtent));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _node(index < 0 ? 'slideshow:$_path' : content.folders[index].path).requestFocus();
      });
    });
  }

  void _open(NasEntry folder) {
    _stack.add(folder.path);
    _load();
  }

  void _up() {
    if (_stack.length <= 1) return;
    _focusPath = _stack.removeLast();
    _load();
  }

  /// [folder]'s slideshow - from [startAt] (a picture), else from where it
  /// was last if the user wants (or from the start).
  Future<void> _startSlideshow(String folder, {String? startAt}) async {
    startAt ??= await _askResume(folder);
    if (startAt == '' || !mounted) return;
    // The slideshow has its own connection; this one would only idle (and
    // an FTP server drops it after a while). Counting and thumbnails go on
    // afterwards.
    _counting++;
    _closeClient();
    _thumbs?.suspend();
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SlideshowScreen(folder: folder, startAt: startAt)));
    if (!mounted) return;
    _thumbs?.resume();
    if (_root != null && _cache.containsKey(_path)) _countSubfolders();
  }

  /// The folder's slideshow was stopped somewhere before: go on there
  /// (its path) or start over (null)? '' when the question was dismissed.
  Future<String?> _askResume(String folder) async {
    final config = _config;
    if (config == null) return null;
    SlideshowResumePoint? point;
    try {
      point = await ref.read(slideshowResumeProvider).get(SlideshowResumeStore.keyOf(config.identity, folder));
    } catch (e) {
      debugPrint('pictures: no resume point ($e)');
    }
    if (point == null || point.position <= 1 || !mounted) return null;
    final l = context.l10n;
    final from = point;
    final resume = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.picturesSlideshow(_name(folder))),
        children: [
          ListTile(
            autofocus: true,
            leading: const Icon(Icons.play_arrow, color: brandGreen),
            title: Text(l.picturesResumeFrom(from.position, from.name)),
            onTap: () => Navigator.of(context).pop(true),
          ),
          ListTile(
            leading: const Icon(Icons.replay),
            title: Text(l.picturesResumeRestart),
            onTap: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
    if (resume == null) return '';
    return resume ? from.path : null;
  }

  /// ⏯ or the options key on a picture: the slideshow from it.
  KeyEventResult _pictureKey(KeyEvent event, NasEntry picture) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        ref.read(remoteKeysProvider).matches(RemoteAction.options, key)) {
      _startSlideshow(_path, startAt: picture.path);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openNasSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NasSettingsScreen()));
  }

  /// ⏯ or the options key: [folder]'s slideshow.
  KeyEventResult _slideshowKey(KeyEvent event, String folder) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        ref.read(remoteKeysProvider).matches(RemoteAction.options, key)) {
      _startSlideshow(folder);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _name(String path) {
    if (path == _root) {
      final name = path.split('/').where((p) => p.isNotEmpty).lastOrNull;
      return name ?? context.l10n.picturesTitle;
    }
    return path.split('/').last;
  }

  /// "Bilder › Urlaub 2026 › Tag 2"
  String get _breadcrumb => [for (final p in _stack) _name(p)].join('  ›  ');

  String _countLabel(PictureFolder content) {
    final l = context.l10n;
    return [
      if (content.pictures.isNotEmpty || content.folders.isEmpty) l.picturesCount(content.pictures.length),
      if (content.folders.isNotEmpty) l.picturesFolderCount(content.folders.length),
    ].join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final nas = ref.watch(nasSettingsProvider);
    final settings = nas.value;
    final root = settings?.folder(NasFolder.pictures);
    if (settings != null && root != null && (root != _root || settings.config.identity != _config?.identity)) {
      _reset(settings, root);
    }
    final content = _root == null ? null : _cache[_path];
    Widget body;
    if (settings == null) {
      body = const Center(child: LoadingWave());
    } else if (root == null) {
      body = _Message(text: l.picturesNoFolder, action: l.picturesOpenNasSettings, onAction: _openNasSettings);
    } else if (_error != null) {
      body = _Message(
        text: l.picturesLoadError(_error!),
        action: l.commonRetry,
        onAction: _load,
        secondAction: l.picturesOpenNasSettings,
        onSecondAction: _openNasSettings,
      );
    } else if (content == null || _loading) {
      body = const Center(child: LoadingWave());
    } else if (content.folders.isEmpty && content.pictures.isEmpty) {
      body = _Message(text: l.picturesEmptyFolder);
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth - 16;
          _columns = max(1, ((width + _spacing) / (_tileWidth + _spacing)).floor());
          final thumbColumns = max(2, ((width + _thumbSpacing) / (_thumbWidth + _thumbSpacing)).floor());
          final thumbWidth = (width - (thumbColumns - 1) * _thumbSpacing) / thumbColumns;
          final pictures = content.pictures;
          final thumbs = _thumbs;
          return CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _columns,
                    mainAxisSpacing: _spacing,
                    crossAxisSpacing: _spacing,
                    mainAxisExtent: _tileHeight,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    childCount: content.folders.length + 1,
                    (context, i) {
                      if (i == 0) {
                        return _Tile(
                          focusNode: _node('slideshow:$_path'),
                          icon: Icons.play_circle_fill,
                          title: content.folders.isEmpty
                              ? l.picturesSlideshow(_name(_path))
                              : l.picturesSlideshowWithSubfolders(_name(_path)),
                          subtitle: _countLabel(content),
                          accent: true,
                          onTap: () => _startSlideshow(_path),
                          onKey: (e) => _slideshowKey(e, _path),
                        );
                      }
                      final folder = content.folders[i - 1];
                      final inside = _cache[folder.path];
                      return _Tile(
                        focusNode: _node(folder.path),
                        icon: Icons.folder,
                        title: folder.name,
                        subtitle: inside == null ? '' : _countLabel(inside),
                        onTap: () => _open(folder),
                        onLongPress: () => _startSlideshow(folder.path),
                        onKey: (e) => _slideshowKey(e, folder.path),
                      );
                    },
                  ),
                ),
              ),
              if (pictures.isNotEmpty && thumbs != null) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 28, 8, 12),
                    child: Text(
                      l.picturesInThisFolder(pictures.length),
                      style: const TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ),
                ),
                // Built (and loaded) only as far as it's scrolled - folders
                // with thousands of photos.
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 32),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: thumbColumns,
                      mainAxisSpacing: _thumbSpacing,
                      crossAxisSpacing: _thumbSpacing,
                      mainAxisExtent: thumbWidth * 0.66 + 24,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      childCount: pictures.length,
                      (context, i) {
                        final picture = pictures[i];
                        return ThumbnailTile(
                          key: ValueKey(picture.path),
                          entry: picture,
                          loader: thumbs,
                          onTap: () => _startSlideshow(_path, startAt: picture.path),
                          onKey: (e) => _pictureKey(e, picture),
                        );
                      },
                    ),
                  ),
                ),
              ] else
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          );
        },
      );
    }
    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Focus(
        // ⏯ anywhere: the shown folder's slideshow.
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) => root == null || content == null ? KeyEventResult.ignored : _slideshowKey(event, _path),
        child: Scaffold(
          backgroundColor: const Color(0xFF05070A),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 20, 32, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/icon/pictures_logo.png', width: 44, height: 44),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          root == null ? l.picturesTitle : _breadcrumb,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(child: body),
                  if (content != null && _error == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        l.picturesBrowserHint(remoteKeyHint(ref.watch(remoteKeysProvider), RemoteAction.options)),
                        style: const TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A large focusable tile: a folder, or the slideshow entry ([accent]).
class _Tile extends StatefulWidget {
  const _Tile({
    required this.focusNode,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.onKey,
    this.onLongPress,
    this.accent = false,
  });

  final FocusNode focusNode;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final KeyEventResult Function(KeyEvent event) onKey;
  final bool accent;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => widget.onKey(event),
      child: TvFocusHighlight(
        focused: _focused,
        child: Material(
          color: accent ? const Color(0xFF12301C) : const Color(0xFF15191B),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            focusNode: widget.focusNode,
            focusColor: Colors.white.withValues(alpha: 0.06),
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(widget.icon, size: 52, color: accent ? brandGreen : const Color(0xFFB4F05A)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (widget.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            widget.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white60, fontSize: 15),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, this.onAction, this.secondAction, this.onSecondAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;
  final String? secondAction;
  final VoidCallback? onSecondAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icon/pictures_logo.png', width: 96, height: 96),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, color: Colors.white70)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                if (action != null) FilledButton(autofocus: true, onPressed: onAction, child: Text(action!)),
                if (secondAction != null) OutlinedButton(onPressed: onSecondAction, child: Text(secondAction!)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
