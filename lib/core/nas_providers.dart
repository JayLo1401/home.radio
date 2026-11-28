import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/nas_settings_repository.dart';
import '../data/services/nas_backup_service.dart';
import '../data/services/nas_picture_cache.dart';
import '../data/services/nas_service.dart';
import 'providers.dart';
import 'system_providers.dart';

final nasSettingsRepositoryProvider = Provider<NasSettingsRepository>((ref) {
  return NasSettingsRepository(ref.watch(databaseProvider));
});

/// Settings → NAS (loaded from the database).
final nasSettingsProvider = AsyncNotifierProvider<NasSettingsNotifier, NasSettings>(NasSettingsNotifier.new);

class NasSettingsNotifier extends AsyncNotifier<NasSettings> {
  NasSettingsRepository get _repo => ref.read(nasSettingsRepositoryProvider);

  @override
  Future<NasSettings> build() => _repo.load();

  Future<void> setConfig(NasConfig config) async {
    await _repo.saveConfig(config);
    final current = state.value ?? const NasSettings();
    state = AsyncData(current.copyWith(config: config));
  }

  /// [path] null clears the folder.
  Future<void> setFolder(NasFolder kind, String? path) async {
    await _repo.setFolder(kind, path);
    final current = state.value ?? const NasSettings();
    final folders = {...current.folders};
    if (path == null || path.isEmpty) {
      folders.remove(kind);
    } else {
      folders[kind] = path;
    }
    state = AsyncData(current.copyWith(folders: folders));
    // Bilder goes on with its folder (unless switched off by hand before).
    if (kind == NasFolder.pictures && path != null && path.isNotEmpty) {
      await ref.read(systemPartsProvider.notifier).picturesFolderChosen();
    }
    if (kind == NasFolder.music && path != null && path.isNotEmpty) {
      await ref.read(systemPartsProvider.notifier).musicFolderChosen();
    }
  }

  /// The films part's folders, in this order.
  Future<void> setMovieFolders(List<MovieFolder> folders) async {
    await _repo.saveMovieFolders(folders);
    final current = state.value ?? const NasSettings();
    state = AsyncData(current.copyWith(movieFolders: List.unmodifiable(folders)));
  }

  /// A copy of the list to change (loaded first if needed).
  Future<List<MovieFolder>> _movieFolders() async => [...(state.value ?? await future).movieFolders];

  /// Adds [path] at the end - named [name], or after the folder if empty.
  /// Filme goes on with its first folder (unless switched off by hand).
  Future<void> addMovieFolder(String path, {String name = ''}) async {
    await setMovieFolders([...await _movieFolders(), MovieFolder(path: normalizeNasPath(path), name: name.trim())]);
    await ref.read(systemPartsProvider.notifier).moviesFolderChosen();
  }

  Future<void> removeMovieFolder(int index) async {
    final folders = await _movieFolders();
    if (index < 0 || index >= folders.length) return;
    folders.removeAt(index);
    await setMovieFolders(folders);
  }

  /// [name] empty: the folder's own name.
  Future<void> renameMovieFolder(int index, String name) async {
    final folders = await _movieFolders();
    if (index < 0 || index >= folders.length) return;
    folders[index] = folders[index].copyWith(name: name.trim());
    await setMovieFolders(folders);
  }

  /// Another folder for the entry [index] (the name stays).
  Future<void> setMovieFolderPath(int index, String path) async {
    final folders = await _movieFolders();
    if (index < 0 || index >= folders.length) return;
    folders[index] = folders[index].copyWith(path: normalizeNasPath(path));
    await setMovieFolders(folders);
  }

  /// Moves the entry [from] to the place [to].
  Future<void> moveMovieFolder(int from, int to) async {
    final folders = await _movieFolders();
    if (from < 0 || from >= folders.length || to < 0 || to >= folders.length || from == to) return;
    folders.insert(to, folders.removeAt(from));
    await setMovieFolders(folders);
  }
}

final nasBackupServiceProvider = Provider<NasBackupService>((ref) {
  return NasBackupService(ref.watch(backupServiceProvider), ref.watch(nasSettingsRepositoryProvider));
});

/// The launcher background's pictures from the NAS (one per app).
final nasPictureCacheProvider = Provider<NasPictureCache>((ref) {
  return NasPictureCache(ref.watch(nasSettingsRepositoryProvider));
});
