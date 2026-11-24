import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/nas_settings_repository.dart';
import '../data/services/nas_backup_service.dart';
import '../data/services/nas_picture_cache.dart';
import '../data/services/nas_service.dart';
import 'providers.dart';

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
  }
}

final nasBackupServiceProvider = Provider<NasBackupService>((ref) {
  return NasBackupService(ref.watch(backupServiceProvider), ref.watch(nasSettingsRepositoryProvider));
});

/// The launcher background's pictures from the NAS (one per app).
final nasPictureCacheProvider = Provider<NasPictureCache>((ref) {
  return NasPictureCache(ref.watch(nasSettingsRepositoryProvider));
});
