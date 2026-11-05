import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import 'desktop/hrdab_desktop.dart';
import 'secret_store.dart';

/// One backup file found in Download/HomeRadio (see BackupPlugin.kt).
class BackupFile {
  final String id; // file path or content:// URI - only meaningful to BackupPlugin
  final String name;
  final DateTime modified;

  const BackupFile({required this.id, required this.name, required this.modified});
}

class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);

  @override
  String toString() => message;
}

/// Full backup of everything the app stores - favorites, the DAB+ station
/// list and all settings (the whole `settings` table, so new settings are
/// covered without touching this) - as one JSON file in the public
/// Download/HomeRadio folder, which survives uninstalling the app.
///
/// Restoring replaces the current data completely and then restarts the
/// app, since lots of settings are only read once at startup.
///
/// On Windows/Linux the files live in Documents/HomeRadio instead (no
/// BackupPlugin there).
class BackupService {
  BackupService(this._db);

  static const _channel = MethodChannel('home_radio/backup');
  static const _app = 'home_radio';
  static const _format = 1;

  final AppDatabase _db;

  /// Returns where the backup was written, e.g. "Download/HomeRadio/...".
  Future<String> createBackup() async {
    final now = DateTime.now();
    final data = {
      'app': _app,
      'format': _format,
      'schemaVersion': _db.schemaVersion,
      'createdAt': now.toIso8601String(),
      'favorites': (await _db.select(_db.favorites).get()).map((r) => r.toJson()).toList(),
      'dabStations': (await _db.select(_db.dabStations).get()).map((r) => r.toJson()).toList(),
      'fmStations': (await _db.select(_db.fmStations).get()).map((r) => r.toJson()).toList(),
      'settings': (await _db.select(_db.settings).get()).map((r) => r.toJson()).toList(),
      // Passwords from secure storage (rtl_tcp login) - backups carry all
      // credentials, see the backup screen.
      'secrets': await SecretStore(_db).exportAll(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(data);
    final name = 'home_radio_backup_${_timestamp(now)}.json';
    if (!Platform.isAndroid) {
      final dir = await _desktopDir();
      await File(p.join(dir.path, name)).writeAsString(content, flush: true);
      return dir.path;
    }
    final location = await _channel.invokeMethod<String>('save', {
      'name': name,
      'content': content,
    });
    return location!;
  }

  Future<List<BackupFile>> listBackups() async {
    if (!Platform.isAndroid) {
      final files = (await _desktopDir()).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      final list = [
        for (final f in files) BackupFile(id: f.path, name: p.basename(f.path), modified: f.lastModifiedSync()),
      ]..sort((a, b) => b.modified.compareTo(a.modified));
      return list;
    }
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('list') ?? const [];
    return raw
        .map((m) => BackupFile(
              id: m['id']! as String,
              name: m['name']! as String,
              modified: DateTime.fromMillisecondsSinceEpoch((m['modified']! as num).toInt()),
            ))
        .toList();
  }

  Future<void> restore(BackupFile file) async {
    if (!Platform.isAndroid) return _restoreJson(await File(file.id).readAsString());
    final content = await _channel.invokeMethod<String>('read', {'id': file.id});
    await _restoreJson(content!);
  }

  /// Lets the user pick a backup file via the system document picker (also
  /// reaches USB sticks). Returns false if the user cancelled. Throws a
  /// [PlatformException] with code NO_PICKER if the device has no picker -
  /// common on Android TV.
  Future<bool> restoreFromPicker() async {
    if (!Platform.isAndroid) throw PlatformException(code: 'NO_PICKER');
    final content = await _channel.invokeMethod<String>('pick');
    if (content == null) return false;
    await _restoreJson(content);
    return true;
  }

  /// Whether reading backups from a previous installation needs "All files
  /// access" first (Android 11+ without it granted).
  Future<bool> canRequestAllFilesAccess() async =>
      Platform.isAndroid && (await _channel.invokeMethod<bool>('canRequestAllFilesAccess') ?? false);

  /// Opens the system settings page for "All files access". Returns false if
  /// the device doesn't have one.
  Future<bool> requestAllFilesAccess() async =>
      Platform.isAndroid && (await _channel.invokeMethod<bool>('requestAllFilesAccess') ?? false);

  Future<void> restartApp() async {
    if (Platform.isAndroid) return _channel.invokeMethod('restartApp');
    // rtl_tcp takes one client - free it before the new instance connects.
    HrdabDesktop.shutdownIfStarted();
    await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
    exit(0);
  }

  static Future<Directory> _desktopDir() async {
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'HomeRadio'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _restoreJson(String content) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw const BackupFormatException('Die Datei ist kein gültiges Backup.');
    }
    if (decoded is! Map<String, dynamic> || decoded['app'] != _app) {
      throw const BackupFormatException('Die Datei ist kein Home-Radio-Backup.');
    }
    if ((decoded['format'] as num? ?? 0) > _format) {
      throw const BackupFormatException('Das Backup stammt von einer neueren App-Version.');
    }

    List<Map<String, dynamic>> rows(String key) =>
        ((decoded as Map<String, dynamic>)[key] as List? ?? const []).cast<Map<String, dynamic>>();

    final List<Favorite> favorites;
    final List<DabStation> dabStations;
    final List<FmStation> fmStations;
    final List<Setting> settings;
    try {
      // Locally captured logo files live in the app's private storage and
      // are gone after a reinstall - drop references to missing ones so the
      // logo URL is used instead.
      favorites = rows('favorites').map(Favorite.fromJson).map((f) {
        return _fileExists(f.logoLocalPath) ? f : f.copyWith(logoLocalPath: const Value(null));
      }).toList();
      dabStations = rows('dabStations').map(DabStation.fromJson).map((s) {
        return _fileExists(s.logoLocalPath) ? s : s.copyWith(logoLocalPath: const Value(null));
      }).toList();
      // Missing in backups from before FM existed - then simply none.
      fmStations = rows('fmStations').map(FmStation.fromJson).map((s) {
        return _fileExists(s.logoLocalPath) ? s : s.copyWith(logoLocalPath: const Value(null));
      }).toList();
      settings = rows('settings').map(Setting.fromJson).toList();
    } catch (_) {
      throw const BackupFormatException('Das Backup ist beschädigt oder unvollständig.');
    }

    await _db.transaction(() async {
      await _db.delete(_db.favorites).go();
      await _db.delete(_db.dabStations).go();
      await _db.delete(_db.fmStations).go();
      await _db.delete(_db.settings).go();
      await _db.batch((b) {
        b.insertAll(_db.favorites, favorites);
        b.insertAll(_db.dabStations, dabStations);
        b.insertAll(_db.fmStations, fmStations);
        b.insertAll(_db.settings, settings);
      });
    });
    // Missing in backups from before secure storage - the passwords stay.
    final secrets = decoded['secrets'];
    if (secrets is Map<String, dynamic>) await SecretStore(_db).importAll(secrets);
  }

  static bool _fileExists(String? path) => path != null && File(path).existsSync();

  static String _timestamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
