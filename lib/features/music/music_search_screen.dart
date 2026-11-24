import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/loading_wave.dart';
import '../../core/music_providers.dart';
import '../../core/nas_providers.dart';
import '../../core/ok_long_press.dart';
import '../../core/popup_text_field.dart';
import '../../core/remote_keys.dart';
import '../../data/models/music_track.dart';
import '../../data/services/music_index.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';
import 'music_now_playing_screen.dart';
import 'music_screen.dart';
import 'music_widgets.dart';

/// Search over the whole collection - needs the index (file and folder
/// names; tags aren't in it). Every word must appear somewhere in the path.
/// OK plays the results from there on; long OK / ☰: the track's folder.
class MusicSearchScreen extends ConsumerStatefulWidget {
  const MusicSearchScreen({super.key});

  @override
  ConsumerState<MusicSearchScreen> createState() => _MusicSearchScreenState();
}

class _MusicSearchScreenState extends ConsumerState<MusicSearchScreen> {
  final _query = TextEditingController();
  List<MusicTrack> _results = const [];
  bool _searching = false;
  bool _searched = false;
  String? _focusedPath;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final text = _query.text.trim();
    if (text.isEmpty) return;
    setState(() => _searching = true);
    final nas = await ref.read(nasSettingsProvider.future);
    final root = nas.folder(NasFolder.music);
    MusicIndexSearch? search;
    if (root != null) search = await ref.read(musicIndexStoreProvider).searchFor(nas.config.identity, root);
    // Let the spinner show before the (short) search runs.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final results = search?.search(text) ?? const <MusicTrack>[];
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _searched = true;
    });
  }

  Future<void> _play(int index) async {
    ref.read(musicPlayerProvider).playTracks(_results, start: index, shuffle: false, label: context.l10n.musicSearchResults(_query.text.trim()));
    await openMusicNowPlaying(context);
  }

  Future<void> _openFolder(MusicTrack track) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => MusicScreen(initialFolder: track.folder)));

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (ref.read(musicPlayerProvider).handleMediaKey(event.logicalKey)) return KeyEventResult.handled;
    if (ref.read(remoteKeysProvider).matches(RemoteAction.options, event.logicalKey)) {
      final track = _results.where((t) => t.path == _focusedPath).firstOrNull;
      if (track != null) _openFolder(track);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final index = ref.watch(musicIndexProvider);
    final progress = ref.watch(musicIndexProgressProvider);
    final preferTags = ref.watch(musicSettingsProvider.select((s) => s.preferTags));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(l10n.musicSearch), backgroundColor: musicGraphite),
      body: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: index == null
            ? _noIndex(context, progress)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: PopupTextField(
                            controller: _query,
                            label: l10n.musicSearchLabel,
                            hint: l10n.musicSearchHint,
                            icon: Icons.search_rounded,
                            autofocus: true,
                            onSubmitted: (_) => _search(),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          l10n.musicIndexSummary(index.trackCount, index.folders.length),
                          style: const TextStyle(color: Colors.white38, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  if (_searching) const LinearProgressIndicator(color: musicGreen),
                  Expanded(
                    child: _results.isEmpty
                        ? Center(
                            child: Text(
                              _searched ? l10n.musicSearchNothing : l10n.musicSearchIntro,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white54, fontSize: 18),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                            itemCount: _results.length,
                            itemBuilder: (context, i) {
                              final track = _results[i];
                              final guess = preferTags ? track.nameGuess : (artist: null, title: track.baseName);
                              final where = track.folder.length > index.root.length
                                  ? track.folder.substring(index.root.length).replaceFirst('/', '')
                                  : track.folderName;
                              return OkLongPress(
                                onTap: () => _play(i),
                                onLongPress: () => _openFolder(track),
                                child: MusicRow(
                                  onFocused: () => _focusedPath = track.path,
                                  onTap: () => _play(i),
                                  onLongPress: () => _openFolder(track),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.music_note_rounded, color: Colors.white54),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                guess.artist == null ? guess.title : '${guess.artist} - ${guess.title}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(color: Colors.white, fontSize: 18),
                                              ),
                                              Text(where,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(color: Colors.white38, fontSize: 14)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _noIndex(BuildContext context, MusicIndexProgress progress) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.musicSearchNeedsIndex,
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 20)),
            const SizedBox(height: 24),
            if (progress.running) ...[
              const LoadingWave(),
              const SizedBox(height: 12),
              Text(l10n.musicIndexRunning(progress.folders, progress.tracks),
                  style: const TextStyle(color: Colors.white54, fontSize: 16)),
            ] else
              FilledButton.icon(
                autofocus: true,
                onPressed: () => unawaited(buildMusicIndexFrom(ref)),
                icon: const Icon(Icons.manage_search_rounded),
                label: Text(progress.interrupted ? l10n.musicIndexContinue : l10n.musicIndexBuild),
              ),
          ],
        ),
      ),
    );
  }
}
