import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/repositories/music_settings_repository.dart';
import '../data/services/music_index.dart';
import '../data/services/music_player.dart';
import '../data/services/music_spectrum.dart';
import '../data/services/nas_service.dart';
import '../features/launcher/launcher_providers.dart' show RadioCommand, radioCommandProvider;
import 'nas_providers.dart';
import 'providers.dart';

final musicSettingsRepositoryProvider = Provider<MusicSettingsRepository>((ref) {
  return MusicSettingsRepository(ref.watch(databaseProvider));
});

/// Settings → Musik (loaded from the database).
class MusicSettingsNotifier extends Notifier<MusicSettings> {
  @override
  MusicSettings build() {
    _load();
    return const MusicSettings();
  }

  Future<void> _load() async {
    final loaded = await ref.read(musicSettingsRepositoryProvider).load();
    state = loaded;
    ref.read(musicPlayerProvider).applyModes(shuffle: loaded.shuffle, repeat: loaded.repeat);
  }

  /// Changes and saves - also from the admin page before the settings were
  /// loaded here. Shuffle and repeat reach the player.
  Future<void> set(MusicSettings Function(MusicSettings s) change) async {
    final repo = ref.read(musicSettingsRepositoryProvider);
    final old = state.loaded ? state : await repo.load();
    final next = change(old);
    state = next;
    await repo.save(next);
    final player = ref.read(musicPlayerProvider);
    final playing = player.state.value;
    if (next.shuffle != playing.shuffle) await player.setShuffle(next.shuffle);
    if (next.repeat != playing.repeat) await player.setRepeat(next.repeat);
  }
}

final musicSettingsProvider = NotifierProvider<MusicSettingsNotifier, MusicSettings>(MusicSettingsNotifier.new);

/// The index of the music folder (optional, see MusicIndexStore).
final musicIndexStoreProvider = Provider<MusicIndexStore>((ref) {
  return MusicIndexStore(() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'music')));
});

/// The music folder on the NAS (null: NAS not set up or no folder chosen).
final musicFolderProvider = Provider<String?>((ref) {
  return ref.watch(nasSettingsProvider).value?.folder(NasFolder.music);
});

/// The app-wide music player (created on first use; its platform player
/// only with the first track).
final musicPlayerProvider = Provider<MusicPlayer>((ref) {
  final player = MusicPlayer(
    nasSettings: () => ref.read(nasSettingsProvider.future),
    indexStore: ref.read(musicIndexStoreProvider),
    // The radio pauses and plays on when Radio is opened again - like for
    // TV (and the music pauses then, see MusicPlayer.radioStarted).
    onTakeSpeakers: () => ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp),
    handler: () async {
      try {
        return await ref.read(radioAudioHandlerProvider.future);
      } catch (e) {
        debugPrint('music: no media session: $e');
        return null;
      }
    },
    onModesChanged: (shuffle, repeat) => ref
        .read(musicSettingsProvider.notifier)
        .set((s) => s.copyWith(shuffle: shuffle, repeat: repeat))
        .catchError((Object e) => debugPrint('music settings: $e')),
  );
  ref.onDispose(player.dispose);
  return player;
});

/// The player's state for widgets (rebuilds on every change).
class MusicStateNotifier extends Notifier<MusicState> {
  @override
  MusicState build() {
    final player = ref.watch(musicPlayerProvider);
    // The saved shuffle/repeat modes reach the player.
    ref.read(musicSettingsProvider);
    void listener() => state = player.state.value;
    player.state.addListener(listener);
    ref.onDispose(() => player.state.removeListener(listener));
    return player.state.value;
  }
}

final musicStateProvider = NotifierProvider<MusicStateNotifier, MusicState>(MusicStateNotifier.new);

/// Whether music is loaded (playing or paused) - e.g. for Home to show the
/// mini player and route the media keys.
final musicActiveProvider = Provider<bool>((ref) => ref.watch(musicStateProvider.select((s) => s.active)));

final musicSpectrumProvider = Provider<MusicSpectrum>((ref) => MusicSpectrum());

/// The index builder's progress.
final musicIndexProgressProvider = NotifierProvider<_IndexProgressNotifier, MusicIndexProgress>(
  _IndexProgressNotifier.new,
);

class _IndexProgressNotifier extends Notifier<MusicIndexProgress> {
  @override
  MusicIndexProgress build() {
    final store = ref.watch(musicIndexStoreProvider);
    void listener() => state = store.progress.value;
    store.progress.addListener(listener);
    ref.onDispose(() => store.progress.removeListener(listener));
    store.load();
    return store.progress.value;
  }
}

/// The saved index (null: none, or of another NAS/folder).
final musicIndexProvider = NotifierProvider<_IndexNotifier, MusicIndexData?>(_IndexNotifier.new);

class _IndexNotifier extends Notifier<MusicIndexData?> {
  @override
  MusicIndexData? build() {
    final store = ref.watch(musicIndexStoreProvider);
    final nas = ref.watch(nasSettingsProvider).value;
    final root = nas?.folder(NasFolder.music);
    MusicIndexData? fitting() {
      final data = store.current.value;
      if (data == null || nas == null || root == null) return null;
      return data.fits(nas.config.identity, root) ? data : null;
    }

    void listener() => state = fitting();
    store.current.addListener(listener);
    ref.onDispose(() => store.current.removeListener(listener));
    store.load().then((_) => state = fitting());
    return fitting();
  }
}

/// Starts (or continues) building the index in the background.
Future<void> buildMusicIndex(Ref ref, {bool fresh = false}) async {
  final nas = await ref.read(nasSettingsProvider.future);
  final root = nas.folder(NasFolder.music);
  if (root == null) return;
  await ref.read(musicIndexStoreProvider).build(nas.config.createClient(), nas.config.identity, root, fresh: fresh);
}

/// The same from a widget.
Future<void> buildMusicIndexFrom(WidgetRef ref, {bool fresh = false}) async {
  final nas = await ref.read(nasSettingsProvider.future);
  final root = nas.folder(NasFolder.music);
  if (root == null) return;
  await ref.read(musicIndexStoreProvider).build(nas.config.createClient(), nas.config.identity, root, fresh: fresh);
}

/// Walks [folder] anew into the index; the number of tracks found.
Future<int> refreshMusicIndexFolder(WidgetRef ref, String folder) async {
  final nas = await ref.read(nasSettingsProvider.future);
  final root = nas.folder(NasFolder.music);
  if (root == null) return 0;
  return ref.read(musicIndexStoreProvider).refreshFolder(nas.config.createClient(), nas.config.identity, root, folder);
}

