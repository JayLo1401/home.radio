import 'dart:convert';

import '../repositories/nas_settings_repository.dart';
import 'backup_service.dart';
import 'nas_service.dart';

/// Backups in the NAS backup folder (Settings → NAS): one before every
/// update, at most [keep] per device; and the list/download for restoring.
class NasBackupService {
  NasBackupService(this._backup, this._settings);

  final BackupService _backup;
  final NasSettingsRepository _settings;

  /// Backups of this device kept in the folder.
  static const keep = 14;

  /// The backup folder, or null if none is set.
  Future<({NasConfig config, String folder})?> _target() async {
    final settings = await _settings.load();
    final folder = settings.folder(NasFolder.backups);
    return folder == null ? null : (config: settings.config, folder: folder);
  }

  Future<bool> get hasBackupFolder async => await _target() != null;

  /// Puts a backup into the NAS backup folder and removes this device's
  /// older ones beyond [keep]. Returns the file name, or null if no backup
  /// folder is set. Throws [NasException].
  Future<String?> backupNow() async {
    final target = await _target();
    if (target == null) return null;
    final (:name, :content) = await _backup.export();
    final client = target.config.createClient();
    try {
      await client.write(joinNasPath(target.folder, name), utf8.encode(content));
      // Cleaning up is secondary - the backup is there.
      try {
        final names = [for (final e in await client.list(target.folder)) if (!e.isDirectory) e.name];
        for (final old in backupsToPrune(name, names, keep: keep)) {
          await client.delete(joinNasPath(target.folder, old));
        }
      } catch (_) {}
      return name;
    } finally {
      client.close();
    }
  }

  /// The backup files (*.json) in the NAS backup folder, newest first -
  /// also other devices'. Empty if no backup folder is set.
  Future<List<NasEntry>> listBackups() async {
    final target = await _target();
    if (target == null) return const [];
    final client = target.config.createClient();
    try {
      final files = (await client.list(target.folder))
          .where((e) => !e.isDirectory && e.name.toLowerCase().endsWith('.json'))
          .toList()
        ..sort((a, b) {
          final ma = a.modified, mb = b.modified;
          if (ma != null && mb != null && ma != mb) return mb.compareTo(ma);
          return b.name.compareTo(a.name);
        });
      return files;
    } finally {
      client.close();
    }
  }

  /// The backup file's text.
  Future<String> download(NasEntry file) async {
    final target = await _target();
    if (target == null) throw StateError('no NAS backup folder');
    final client = target.config.createClient();
    try {
      final bytes = await client.read(file.path, maxBytes: 64 * 1024 * 1024);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close();
    }
  }
}

final _backupName = RegExp(r'^(home_system_backup_(?:.*_)?)(\d{4}-\d{2}-\d{2}_\d{6})\.json$');
final _timestampOnly = RegExp(r'^\d{4}-\d{2}-\d{2}_\d{6}\.json$');

/// Which of [existing] (file names in the backup folder) to delete so that
/// [keep] backups of the device that just wrote [newName] remain - the
/// newest by the time stamp in the name. Only names with exactly
/// [newName]'s device part count (`home_system_backup_<device>_` or, for a
/// device without name, `home_system_backup_`), so other devices' backups
/// and other files are never touched.
List<String> backupsToPrune(String newName, Iterable<String> existing, {int keep = NasBackupService.keep}) {
  final match = _backupName.firstMatch(newName);
  if (match == null) return const [];
  final prefix = match.group(1)!;
  final own = <String>{
    for (final name in existing)
      if (name.startsWith(prefix) && _timestampOnly.hasMatch(name.substring(prefix.length))) name,
  }.toList()
    // Same prefix: the name orders by time stamp.
    ..sort((a, b) => b.compareTo(a));
  return own.length <= keep ? const [] : own.sublist(keep);
}
