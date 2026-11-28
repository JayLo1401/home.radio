import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nas_providers.dart';
import '../../core/ok_long_press.dart';
import '../../core/theme.dart';
import '../../data/repositories/nas_settings_repository.dart';
import '../../data/services/movie_library.dart';
import '../../data/services/movie_resume_store.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';
import '../settings/nas_settings_screen.dart';
import 'movie_player_screen.dart';
import 'movie_posters.dart';

/// Opens the films part (its tile under Home). The radio plays on while
/// browsing - it pauses when a film starts.
Future<void> openMovies(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MoviesScreen()));

/// The films on this device (resume positions) - shared by the library and
/// the player.
final movieResumeStoreProvider = Provider<MovieResumeStore>((ref) => MovieResumeStore());

/// Film pictures, kept while the app runs.
final moviePosterCacheProvider = Provider<MoviePosterCache>((ref) => MoviePosterCache());

/// The films part: the NAS film folders (Settings → NAS, any number, each
/// with its name - the top page lists them, one folder opens straight
/// away) as a wall of tiles - folders, films (with their picture, if one lies
/// next to them), DVD images and DVD folders. A folder holding just one
/// film (or a DVD) shows as that film.
///
/// Remote: arrows move, OK plays / opens, holding OK on a film folder opens
/// the folder, Back goes up a folder and out.
class MoviesScreen extends ConsumerStatefulWidget {
  const MoviesScreen({super.key});

  @override
  ConsumerState<MoviesScreen> createState() => _MoviesScreenState();
}

/// One of the top places: a film folder of Settings → NAS.
typedef _Root = ({String name, String path});

class _MoviesScreenState extends ConsumerState<MoviesScreen> {
  NasClient? _client;
  String? _clientIdentity;

  /// The folders opened, the current one last - the first is a root.
  /// Empty: the top with all roots.
  List<String> _stack = [];
  bool _stackInitialised = false;

  final _pages = <String, List<MovieLibraryEntry>>{};
  final _errors = <String, String>{};
  final _loading = <String>{};
  final _peeks = <String, MovieFolderPeek>{};
  final _peeking = <String>{};

  /// Which tile had the focus, per folder - back there after "up".
  final _focusedIndex = <String, int>{};
  int _focusGeneration = 0;
  Map<String, double> _progress = const {};
  MovieLibraryEntry? _focusedEntry;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _loadProgress() async {
    final progress = await ref.read(movieResumeStoreProvider).progress();
    if (mounted) setState(() => _progress = progress);
  }

  List<_Root> _rootsOf(NasSettings settings) => [
        for (final folder in settings.movieSources) (name: folder.label, path: normalizeNasPath(folder.path)),
      ];

  NasClient _clientFor(NasConfig config) {
    if (_client == null || _clientIdentity != config.identity) {
      _client?.close();
      _client = config.createClient();
      _clientIdentity = config.identity;
      _pages.clear();
      _errors.clear();
      _peeks.clear();
      _peeking.clear();
    }
    return _client!;
  }

  String get _language => Localizations.localeOf(context).languageCode;

  Future<void> _load(String folder, {bool force = false}) async {
    final client = _client;
    if (client == null || _loading.contains(folder) || (!force && _pages.containsKey(folder))) return;
    _loading.add(folder);
    _errors.remove(folder);
    try {
      final entries = await client.list(folder);
      if (!mounted || client != _client) return;
      setState(() => _pages[folder] = buildMoviePage(folder, entries, language: _language));
    } catch (e) {
      if (!mounted || client != _client) return;
      setState(() => _errors[folder] = '$e');
    } finally {
      _loading.remove(folder);
    }
  }

  /// A folder tile came into view: what's in it (a film? a picture?).
  void _peek(NasEntry folder) {
    final client = _client;
    if (client == null || _peeks.containsKey(folder.path) || !_peeking.add(folder.path)) return;
    () async {
      try {
        final entries = await client.list(folder.path);
        if (!mounted || client != _client) return;
        setState(() => _peeks[folder.path] = peekMovieFolder(folder, entries, language: _language));
      } catch (_) {
        if (mounted && client == _client) setState(() => _peeks[folder.path] = const MovieFolderPeek());
      }
    }();
  }

  void _openFolder(String path) {
    setState(() {
      _stack = [..._stack, path];
      _focusGeneration++;
      _focusedEntry = null;
    });
  }

  /// Back: a folder up; out at the top.
  void _back(int topDepth) {
    if (_stack.length > topDepth) {
      setState(() {
        _stack = _stack.sublist(0, _stack.length - 1);
        _focusGeneration++;
        _focusedEntry = null;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _play(MovieItem movie, NasConfig config) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MoviePlayerScreen(movie: movie, config: config)),
    );
    await _loadProgress();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(nasSettingsProvider).value;
    if (settings == null) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));
    }
    final roots = _rootsOf(settings);
    if (roots.isEmpty) return const _NotSetUp();
    final config = settings.config;
    _clientFor(config);
    // One root: straight into it; more: the top shows them. A root gone
    // meanwhile (changed on the admin page): back to the top.
    final topDepth = roots.length == 1 ? 1 : 0;
    final rootGone = _stack.isNotEmpty && !roots.any((r) => _stack.first == r.path);
    if (!_stackInitialised || rootGone || (topDepth == 1 && _stack.isEmpty)) {
      _stackInitialised = true;
      _stack = topDepth == 1 ? [roots.single.path] : [];
    }
    final folder = _stack.lastOrNull;

    Widget body;
    if (folder == null) {
      body = _Grid(
        key: ValueKey('top-$_focusGeneration'),
        count: roots.length,
        initialFocus: (_focusedIndex[''] ?? 0).clamp(0, roots.length - 1),
        onFocused: (i) => _focusedIndex[''] = i,
        tile: (i, focusNode) {
          final root = roots[i];
          return _Tile(
            focusNode: focusNode,
            title: root.name,
            icon: Icons.video_library_outlined,
            isFolder: true,
            onTap: () => _openFolder(root.path),
          );
        },
      );
    } else {
      final page = _pages[folder];
      final error = _errors[folder];
      if (page == null && error == null) WidgetsBinding.instance.addPostFrameCallback((_) => _load(folder));
      if (error != null && page == null) {
        body = _Message(
          icon: Icons.error_outline,
          text: context.l10n.moviesListError(error),
          button: context.l10n.moviesRetry,
          onPressed: () => _load(folder, force: true),
        );
      } else if (page == null) {
        body = const Center(child: CircularProgressIndicator());
      } else if (page.isEmpty) {
        body = _Message(icon: Icons.movie_filter_outlined, text: context.l10n.moviesEmpty);
      } else {
        body = _Grid(
          key: ValueKey('$folder-$_focusGeneration'),
          count: page.length,
          initialFocus: (_focusedIndex[folder] ?? 0).clamp(0, page.length - 1),
          onFocused: (i) {
            _focusedIndex[folder] = i;
            final entry = page[i];
            if (entry.folder != null || _focusedEntry?.folder != null) setState(() => _focusedEntry = entry);
            _focusedEntry = entry;
          },
          tile: (i, focusNode) => _entryTile(page[i], focusNode, config),
        );
      }
    }

    final focusedFolder = _focusedEntry?.folder;
    final showFolderHint = folder != null && focusedFolder != null && _peeks[focusedFolder.path]?.movie != null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back(topDepth);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 24, 40, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.movie_outlined, color: brandGreen, size: 32),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        _breadcrumb(roots, folder),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (showFolderHint)
                      Text(context.l10n.moviesHoldOkForFolder, style: const TextStyle(color: Colors.white54, fontSize: 15)),
                  ],
                ),
                const SizedBox(height: 18),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _breadcrumb(List<_Root> roots, String? folder) {
    if (folder == null) return context.l10n.moviesTitle;
    // The root this way started from (two may lie inside each other).
    final first = _stack.firstOrNull;
    final root = roots.where((r) => r.path == first).firstOrNull;
    if (root == null || !(folder == root.path || folder.startsWith('${root.path == '/' ? '' : root.path}/'))) {
      return movieTitle(folder.split('/').last, isFile: false);
    }
    final rest = folder.substring(root.path.length).split('/').where((s) => s.isNotEmpty);
    return [root.name, ...rest.map((s) => movieTitle(s, isFile: false))].join('  ›  ');
  }

  Widget _entryTile(MovieLibraryEntry entry, FocusNode focusNode, NasConfig config) {
    final client = _client!;
    final folder = entry.folder;
    if (folder != null) {
      final peek = _peeks[folder.path];
      final movie = peek?.movie;
      return _Tile(
        key: ValueKey(folder.path),
        focusNode: focusNode,
        title: movie?.title ?? entry.title,
        icon: movie == null ? Icons.folder_outlined : _movieIcon(movie),
        poster: peek?.poster ?? movie?.poster,
        client: client,
        progress: movie == null ? null : _progress[movie.path],
        badge: movie?.kind == MovieKind.file || movie == null ? null : context.l10n.moviesDvd,
        isFolder: movie == null,
        onVisible: () => _peek(folder),
        onTap: () => movie != null ? _play(movie, config) : _openFolder(folder.path),
        onLongPress: movie == null ? null : () => _openFolder(folder.path),
      );
    }
    final movie = entry.movie!;
    return _Tile(
      key: ValueKey(movie.path),
      focusNode: focusNode,
      title: movie.title,
      icon: _movieIcon(movie),
      poster: movie.poster,
      client: client,
      progress: _progress[movie.path],
      badge: movie.kind == MovieKind.file ? null : context.l10n.moviesDvd,
      onTap: () => _play(movie, config),
    );
  }

  static IconData _movieIcon(MovieItem movie) => movie.kind == MovieKind.file ? Icons.movie_outlined : Icons.album_outlined;
}

/// The rows, the focus starting on [initialFocus].
class _Grid extends StatefulWidget {
  const _Grid({super.key, required this.count, required this.tile, required this.initialFocus, required this.onFocused});

  final int count;
  final Widget Function(int index, FocusNode focusNode) tile;
  final int initialFocus;
  final void Function(int index) onFocused;

  @override
  State<_Grid> createState() => _GridState();
}

class _GridState extends State<_Grid> {
  final _nodes = <int, FocusNode>{};
  final _scroll = ScrollController();

  FocusNode _node(int i) => _nodes[i] ??= FocusNode(debugLabel: 'movie row $i')
    ..addListener(() {
      if (_nodes[i]?.hasFocus ?? false) widget.onFocused(i);
    });

  /// One row with its gap.
  static const rowExtent = _Tile.height + 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusInitial());
  }

  /// The remembered row: scrolled to, then focused.
  void _focusInitial() {
    if (!mounted || !_scroll.hasClients) return;
    final index = widget.initialFocus.clamp(0, widget.count - 1);
    if (index > 2) _scroll.jumpTo(((index - 2) * rowExtent).clamp(0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _node(index).requestFocus();
    });
  }

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 32, top: 4),
      itemExtent: rowExtent,
      itemCount: widget.count,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: widget.tile(i, _node(i)),
      ),
    );
  }
}

/// A film or folder as a row: its poster (or an icon) small, its name large.
class _Tile extends StatefulWidget {
  const _Tile({
    super.key,
    required this.focusNode,
    required this.title,
    required this.icon,
    required this.onTap,
    this.onLongPress,
    this.onVisible,
    this.poster,
    this.client,
    this.progress,
    this.badge,
    this.isFolder = false,
  });

  /// A row's height.
  static const height = 96.0;

  final FocusNode focusNode;
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onVisible;
  final String? poster;
  final NasClient? client;
  final double? progress;
  final String? badge;

  /// Opens a folder (an arrow at the end) rather than playing.
  final bool isFolder;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _focused = false;
  Uint8List? _poster;
  String? _posterPath;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    _focused = widget.focusNode.hasFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onVisible?.call();
    });
  }

  @override
  void didUpdateWidget(_Tile old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (mounted && _focused != widget.focusNode.hasFocus) setState(() => _focused = widget.focusNode.hasFocus);
  }

  void _loadPoster() {
    final path = widget.poster;
    final client = widget.client;
    if (path == _posterPath) return;
    _posterPath = path;
    _poster = null;
    if (path == null || client == null) return;
    final cache = ProviderScope.containerOf(context, listen: false).read(moviePosterCacheProvider);
    final hit = cache.cached(path);
    if (hit != null) {
      _poster = hit;
      return;
    }
    cache.load(client, path).then((bytes) {
      if (mounted && _posterPath == path && bytes != null) setState(() => _poster = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    _loadPoster();
    final focusColor = Theme.of(context).focusColor;
    final poster = _poster;
    final picture = poster != null
        ? Image.memory(
            poster,
            fit: BoxFit.cover,
            cacheWidth: 140,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _iconBox(),
          )
        : _iconBox();
    final progress = widget.progress;
    final tile = InkWell(
      focusNode: widget.focusNode,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      borderRadius: BorderRadius.circular(12),
      focusColor: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.fromLTRB(10, 8, 20, 8),
        decoration: BoxDecoration(
          color: _focused ? focusColor.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _focused ? focusColor : Colors.transparent, width: 3),
        ),
        child: Row(
          children: [
            // The poster, small (2:3).
            SizedBox(
              width: 54,
              height: 80,
              child: ClipRRect(borderRadius: BorderRadius.circular(6), child: picture),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w500,
                            color: _focused ? Colors.white : Colors.white.withValues(alpha: 0.88),
                          ),
                        ),
                      ),
                      if (widget.badge != null) ...[
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.white38),
                          ),
                          child: Text(widget.badge!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ],
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: 260,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 5,
                          color: brandGreen,
                          backgroundColor: Colors.white12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (widget.isFolder) Icon(Icons.chevron_right_rounded, size: 30, color: _focused ? Colors.white : Colors.white38),
          ],
        ),
      ),
    );
    return widget.onLongPress == null ? tile : OkLongPress(onTap: widget.onTap, onLongPress: widget.onLongPress, child: tile);
  }

  Widget _iconBox() => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E2A24), Color(0xFF0E1412)],
          ),
        ),
        child: Center(child: Icon(widget.icon, size: 30, color: Colors.white54)),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.button, this.onPressed});

  final IconData icon;
  final String text;
  final String? button;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: Colors.white70)),
            if (button != null) ...[
              const SizedBox(height: 24),
              FilledButton(autofocus: true, onPressed: onPressed, child: Text(button!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// No NAS, or no film folder chosen: what to do.
class _NotSetUp extends StatelessWidget {
  const _NotSetUp();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.movie_outlined, size: 72, color: brandGreen),
                const SizedBox(height: 20),
                Text(context.l10n.moviesNotSetUpTitle, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Text(
                  context.l10n.moviesNotSetUp,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, color: Colors.white70),
                ),
                const SizedBox(height: 28),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      autofocus: true,
                      icon: const Icon(Icons.storage),
                      label: Text(context.l10n.moviesOpenNasSettings),
                      onPressed: () => Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => const NasSettingsScreen())),
                    ),
                    const SizedBox(width: 16),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(context.l10n.moviesBack),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
