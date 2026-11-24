import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/loading_wave.dart';
import '../../core/music_providers.dart';
import '../../core/nas_providers.dart';
import '../../core/ok_long_press.dart';
import '../../core/remote_keys.dart';
import '../../data/services/music_library.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';
import '../settings/nas_settings_screen.dart';
import 'music_mini_bar.dart';
import 'music_now_playing_screen.dart';
import 'music_search_screen.dart';
import 'music_settings_screen.dart';
import 'music_widgets.dart';

/// Opens Musik (from Home's tile). The radio is paused only when music
/// actually starts (see MusicPlayer), not on opening - browsing while the
/// radio plays is fine.
Future<void> openMusic(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MusicScreen()));

/// Musik: the NAS's music folder, browsed live - no index needed. OK on a
/// folder opens it, on a track plays the folder from there; long OK or ☰
/// on a folder: play it (subfolders too if chosen), shuffled or in order. At
/// the top: everything shuffled, search (with the index), the player and
/// the settings. Back goes up a folder, at the top closes.
class MusicScreen extends ConsumerStatefulWidget {
  const MusicScreen({super.key, this.initialFolder});

  /// A folder below the music folder to start in (e.g. from a search).
  final String? initialFolder;

  @override
  ConsumerState<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends ConsumerState<MusicScreen> {
  NasClient? _client;
  String? _clientIdentity;
  String? _root;
  String? _folder;
  MusicFolderListing? _listing;
  String? _error;
  bool _loading = false;
  int _generation = 0;
  final _scroll = ScrollController();

  /// Per folder the entry that had the focus - focused again on the way back.
  final _focusedIn = <String, String>{};
  String? _focusPath;

  @override
  void initState() {
    super.initState();
    // An interrupted index build goes on in the background.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final store = ref.read(musicIndexStoreProvider);
      await store.load();
      if (mounted && store.progress.value.interrupted && store.progress.value.error == null) {
        buildMusicIndexFrom(ref);
      }
    });
  }

  @override
  void dispose() {
    _client?.close();
    _scroll.dispose();
    super.dispose();
  }

  NasClient? _clientFor(NasConfig config) {
    if (_clientIdentity != config.identity || _client == null) {
      _client?.close();
      _client = config.createClient();
      _clientIdentity = config.identity;
    }
    return _client;
  }

  Future<void> _open(String folder, {String? focus}) async {
    final nas = ref.read(nasSettingsProvider).value;
    final root = _root;
    if (nas == null || root == null) return;
    final client = _clientFor(nas.config)!;
    final generation = ++_generation;
    if (_folder != null && _focusPath != null) _focusedIn[_folder!] = _focusPath!;
    setState(() {
      _folder = folder;
      _loading = true;
      _error = null;
      _focusPath = focus ?? _focusedIn[folder];
    });
    try {
      final listing = MusicFolderListing.of(await client.list(folder));
      if (generation != _generation || !mounted) return;
      ref.read(musicIndexStoreProvider).noteListing(nas.config.identity, root, folder, listing);
      setState(() {
        _listing = listing;
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } on NasException catch (e) {
      if (generation != _generation || !mounted) return;
      setState(() {
        _listing = null;
        _error = e.message;
        _loading = false;
      });
    }
  }

  bool get _atRoot => _folder == null || _folder == _root;

  void _up() {
    final folder = _folder;
    if (folder == null || _atRoot) return;
    _open(parentNasPath(folder), focus: folder);
  }

  String _folderTitle(String folder) {
    if (folder == _root) return context.l10n.musicTitle;
    return folder.split('/').where((s) => s.isNotEmpty).lastOrNull ?? folder;
  }

  Future<void> _playFolder(String folder, {required bool shuffle}) async {
    final player = ref.read(musicPlayerProvider);
    final label = _folderTitle(folder);
    // Starts right away; the walk goes on in the background.
    final subfolders = ref.read(musicSettingsProvider).subfolders;
    player.playFolder(folder, shuffle: shuffle, label: label, subfolders: subfolders);
    if (mounted) await openMusicNowPlaying(context);
  }

  Future<void> _playTrack(int index) async {
    final listing = _listing;
    final folder = _folder;
    if (listing == null || folder == null) return;
    final player = ref.read(musicPlayerProvider);
    final shuffle = ref.read(musicStateProvider).shuffle;
    // Shuffled: this one first, then the folder's others in random order.
    player.playTracks(listing.tracks, start: index, shuffle: shuffle, label: _folderTitle(folder));
    if (mounted) await openMusicNowPlaying(context);
  }

  Future<void> _folderOptions(String folder) async {
    final l10n = context.l10n;
    final hasIndex = ref.read(musicIndexProvider) != null;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(_folderTitle(folder)),
        children: [
          _option(context, 'play', Icons.play_arrow_rounded, l10n.musicPlayFolder, autofocus: true),
          _option(context, 'shuffle', Icons.shuffle_rounded, l10n.musicShuffleFolder),
          if (hasIndex) _option(context, 'index', Icons.refresh_rounded, l10n.musicRefreshFolderIndex),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'play':
        await _playFolder(folder, shuffle: false);
      case 'shuffle':
        await _playFolder(folder, shuffle: true);
      case 'index':
        final messenger = ScaffoldMessenger.of(context);
        final text = context.l10n;
        final count = await refreshMusicIndexFolder(ref, folder);
        messenger.showSnackBar(SnackBar(content: Text(text.musicFolderIndexed(count))));
    }
  }

  Widget _option(BuildContext context, String value, IconData icon, String label, {bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: MusicRow(
        autofocus: autofocus,
        onTap: () => Navigator.of(context).pop(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: musicLime),
              const SizedBox(width: 16),
              Text(label, style: const TextStyle(fontSize: 18)),
            ],
          ),
        ),
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (ref.read(musicPlayerProvider).handleMediaKey(key)) return KeyEventResult.handled;
    if (ref.read(remoteKeysProvider).matches(RemoteAction.options, key)) {
      final path = _focusPath;
      final folder = _listing?.folders.where((f) => f.path == path).firstOrNull;
      _folderOptions(folder?.path ?? _folder ?? _root ?? '/');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final root = ref.watch(musicFolderProvider);
    final nasLoaded = ref.watch(nasSettingsProvider).hasValue;
    if (root != _root) {
      _root = root;
      if (root != null) {
        final start = widget.initialFolder;
        WidgetsBinding.instance.addPostFrameCallback((_) => _open(start ?? root));
      }
    }
    final active = ref.watch(musicActiveProvider);
    final hasIndex = ref.watch(musicIndexProvider) != null;

    return PopScope(
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [musicGraphite, Colors.black],
              ),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context, hasIndex, active),
                  Expanded(
                    child: !nasLoaded
                        ? const Center(child: LoadingWave())
                        : root == null
                            ? _notSetUp(context)
                            : _body(context),
                  ),
                  if (active)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(32, 0, 32, 16),
                      child: MusicMiniBar(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, bool hasIndex, bool active) {
    final l10n = context.l10n;
    final folder = _folder;
    final crumbs = folder == null || _root == null || folder == _root
        ? null
        : folder.substring(_root!.length).split('/').where((s) => s.isNotEmpty).join('  ›  ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 12),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (r) => musicBrandGradient.createShader(r),
            child: const Icon(Icons.library_music_rounded, size: 40, color: Colors.white),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.musicTitle,
                    style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700)),
                if (crumbs != null)
                  Text(crumbs,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 16)),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: _root == null
                ? null
                : () async {
                    ref.read(musicPlayerProvider).playAllShuffled();
                    await openMusicNowPlaying(context);
                  },
            icon: const Icon(Icons.shuffle_rounded),
            label: Text(l10n.musicAllShuffled),
          ),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(
            onPressed: _root == null
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MusicSearchScreen())),
            icon: const Icon(Icons.search_rounded),
            label: Text(l10n.musicSearch),
          ),
          if (active) ...[
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: () => openMusicNowPlaying(context),
              icon: const Icon(Icons.graphic_eq_rounded),
              label: Text(l10n.musicNowPlaying),
            ),
          ],
          const SizedBox(width: 12),
          IconButton(
            tooltip: l10n.musicSettingsTitle,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MusicSettingsScreen())),
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
      ),
    );
  }

  Widget _notSetUp(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_off_rounded, size: 64, color: Colors.white38),
          const SizedBox(height: 16),
          Text(l10n.musicNoFolder, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 20)),
          const SizedBox(height: 20),
          FilledButton.icon(
            autofocus: true,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NasSettingsScreen())),
            icon: const Icon(Icons.storage_rounded),
            label: Text(l10n.musicOpenNasSettings),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    final listing = _listing;
    if (_loading && listing == null) return const Center(child: LoadingWave());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.amberAccent, fontSize: 18)),
            const SizedBox(height: 16),
            FilledButton.icon(
              autofocus: true,
              onPressed: () => _open(_folder ?? _root!),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(l10n.musicRetry),
            ),
          ],
        ),
      );
    }
    if (listing == null) return const SizedBox.shrink();
    final folder = _folder!;
    final rows = listing.folders.length + listing.tracks.length;
    // Focus on the entry we came from, else the first.
    final focus = _focusPath;
    var focusIndex = 0;
    if (focus != null) {
      final f = listing.folders.indexWhere((e) => e.path == focus);
      final t = listing.tracks.indexWhere((e) => e.path == focus);
      focusIndex = f >= 0 ? f : (t >= 0 ? listing.folders.length + t : 0);
    }
    return Stack(
      children: [
        ListView.builder(
          key: PageStorageKey(folder),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          itemCount: rows + 1,
          itemBuilder: (context, i) {
            if (i == 0) return _folderActions(context, folder, listing);
            final index = i - 1;
            final autofocus = index == focusIndex;
            if (index < listing.folders.length) {
              final entry = listing.folders[index];
              return OkLongPress(
                onTap: () => _open(entry.path),
                onLongPress: () => _folderOptions(entry.path),
                child: MusicRow(
                  key: ValueKey(entry.path),
                  autofocus: autofocus,
                  onFocused: () => _focusPath = entry.path,
                  onTap: () => _open(entry.path),
                  onLongPress: () => _folderOptions(entry.path),
                  child: _rowContent(
                    icon: Icons.folder_rounded,
                    iconColor: musicLime,
                    title: entry.name,
                    trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                  ),
                ),
              );
            }
            final t = index - listing.folders.length;
            final track = listing.tracks[t];
            final guess = ref.watch(musicSettingsProvider.select((s) => s.preferTags))
                ? track.nameGuess
                : (artist: null, title: track.baseName);
            final current = ref.watch(musicStateProvider.select((s) => s.current)) == track;
            return MusicRow(
              key: ValueKey(track.path),
              autofocus: autofocus,
              selected: current,
              onFocused: () => _focusPath = track.path,
              onTap: () => _playTrack(t),
              child: _rowContent(
                icon: current ? Icons.equalizer_rounded : Icons.music_note_rounded,
                iconColor: current ? musicLime : Colors.white54,
                title: guess.title,
                subtitle: guess.artist,
                trailing: Text(
                  track.extension.replaceFirst('.', '').toUpperCase(),
                  style: const TextStyle(color: Colors.white30, fontSize: 13),
                ),
              ),
            );
          },
        ),
        if (_loading) const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator(color: musicGreen)),
      ],
    );
  }

  /// The row above a folder's content: play / shuffle all of it.
  Widget _folderActions(BuildContext context, String folder, MusicFolderListing listing) {
    final l10n = context.l10n;
    if (listing.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(l10n.musicEmptyFolder, style: const TextStyle(color: Colors.white54, fontSize: 18)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: () => _playFolder(folder, shuffle: false),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(l10n.musicPlayFolder),
          ),
          OutlinedButton.icon(
            onPressed: () => _playFolder(folder, shuffle: true),
            icon: const Icon(Icons.shuffle_rounded),
            label: Text(l10n.musicShuffleFolder),
          ),
          // Subfolders along or not - remembered (Musik settings).
          if (listing.folders.isNotEmpty)
            Consumer(
              builder: (context, ref, _) {
                final on = ref.watch(musicSettingsProvider).subfolders;
                return FilterChip(
                  selected: on,
                  showCheckmark: true,
                  label: Text(l10n.musicWithSubfolders),
                  onSelected: (v) => ref.read(musicSettingsProvider.notifier).set((s) => s.copyWith(subfolders: v)),
                );
              },
            ),
          Text(
            l10n.musicFolderSummary(listing.folders.length, listing.tracks.length),
            style: const TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _rowContent({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 19)),
                if (subtitle != null)
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 15)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
