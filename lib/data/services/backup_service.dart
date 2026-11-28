import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../l10n/l10n.dart';
import '../db/database.dart';
import 'backup_areas.dart';
import 'desktop/hrdab_desktop.dart';
import 'secret_store.dart';

export 'backup_areas.dart' show BackupArea, backupAreaTitle, backupAreaHint;

/// One backup file found in Download/HomeSystem (see BackupPlugin.kt).
class BackupFile {
  final String id; // file path or content:// URI - only meaningful to BackupPlugin
  final String name;
  final DateTime modified;

  const BackupFile({required this.id, required this.name, required this.modified});
}

/// What a restore takes over from a backup (see [BackupService.restoreJson]).
class BackupRestoreSelection {
  const BackupRestoreSelection({required this.areas, this.deviceName});

  /// The areas replaced by the backup's; all others stay as they are.
  final Set<BackupArea> areas;

  /// The device name to set; null or blank keeps the current one.
  final String? deviceName;

  @override
  String toString() => 'BackupRestoreSelection($areas, $deviceName)';
}

/// What a backup contains (see [BackupService.inspect]) - for the selection
/// before restoring.
class BackupPreview {
  const BackupPreview({
    required this.deviceName,
    required this.createdAt,
    required this.counts,
    this.favorites = 0,
    this.dabStations = 0,
    this.fmStations = 0,
  });

  /// The device name in the backup ('' if it had none).
  final String deviceName;
  final DateTime? createdAt;

  /// Entries per area (settings, table rows, passwords) - only areas the
  /// backup has something for.
  final Map<BackupArea, int> counts;
  final int favorites;
  final int dabStations;
  final int fmStations;

  /// The areas in the backup, in the order of [BackupArea].
  List<BackupArea> get areas => [for (final a in BackupArea.values) if ((counts[a] ?? 0) > 0) a];
}

/// The area's line in the selection: what it contains - for Radio with
/// the number of favorites and stations in the backup.
String backupAreaSummary(AppLocalizations l, BackupArea area, BackupPreview preview) {
  final hint = backupAreaHint(l, area);
  if (area != BackupArea.radio || preview.favorites + preview.dabStations + preview.fmStations == 0) return hint;
  return '$hint (${l.backupAreaRadioCounts(preview.favorites, preview.dabStations, preview.fmStations)})';
}

/// A backup read and checked (see BackupService._parse).
class _ParsedBackup {
  _ParsedBackup({
    required this.createdAt,
    required this.favorites,
    required this.dabStations,
    required this.fmStations,
    required this.settings,
    required this.secrets,
  });

  final DateTime? createdAt;
  final List<Favorite> favorites;
  final List<DabStation> dabStations;
  final List<FmStation> fmStations;
  final List<Setting> settings;

  /// Null in backups from before secure storage.
  final Map<String, dynamic>? secrets;

  int tableRows(String table) => switch (table) {
        'favorites' => favorites.length,
        'dabStations' => dabStations.length,
        'fmStations' => fmStations.length,
        _ => 0,
      };
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
/// Download/HomeSystem folder, which survives uninstalling the app.
///
/// Restoring replaces the current data completely - or only the areas
/// chosen in the selection (see [BackupArea]) - and then restarts the app,
/// since lots of settings are only read once at startup.
///
/// On Windows/Linux the files live in Documents/HomeSystem instead (no
/// BackupPlugin there).
class BackupService {
  BackupService(this._db);

  static const _channel = MethodChannel('home_system/backup');
  // The app's former name - kept, so backups of Home Radio
  // (at.jaycloud.home.radio) and Home System restore into each other.
  static const _app = 'home_radio';
  static const _format = 1;

  final AppDatabase _db;

  /// The whole backup as JSON text and the file name it should get, e.g.
  /// "home_system_backup_Terrassen-Media_2026-11-24_121500.json" - for the
  /// file in Download/HomeSystem and the admin page's download.
  Future<({String name, String content})> export() async {
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
      // Passwords from secure storage (SecretStore.keys, currently none) -
      // backups carry all credentials, see the backup screen.
      'secrets': await SecretStore(_db).exportAll(),
    };
    final device = fileNamePart(await _db.getSetting('device_name') ?? '');
    return (
      name: 'home_system_backup_${device.isEmpty ? '' : '${device}_'}${_timestamp(now)}.json',
      content: const JsonEncoder.withIndent('  ').convert(data),
    );
  }

  /// [text] reduced to what's safe in a file name (letters, digits, - and _).
  static String fileNamePart(String text) => text
      .trim()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^A-Za-z0-9ÄÖÜäöüß_-]'), '')
      .replaceAll('Ä', 'Ae')
      .replaceAll('Ö', 'Oe')
      .replaceAll('Ü', 'Ue')
      .replaceAll('ä', 'ae')
      .replaceAll('ö', 'oe')
      .replaceAll('ü', 'ue')
      .replaceAll('ß', 'ss');

  /// Returns where the backup was written, e.g. "Download/HomeSystem/...".
  Future<String> createBackup() async {
    final (:name, :content) = await export();
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
      final docs = (await getApplicationDocumentsDirectory()).path;
      // Also the folder of the app's former name (HomeRadio).
      final files = [
        for (final dir in [await _desktopDir(), Directory(p.join(docs, 'HomeRadio'))])
          if (dir.existsSync()) ...dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')),
      ];
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

  /// The text of the backup [file] (for [inspect] and [restoreJson]).
  Future<String> read(BackupFile file) async {
    if (!Platform.isAndroid) return File(file.id).readAsString();
    final content = await _channel.invokeMethod<String>('read', {'id': file.id});
    if (content == null) throw BackupFormatException(l10n.adminFileInvalid);
    return content;
  }

  /// Lets the user pick a backup file via the system document picker (also
  /// reaches USB sticks) and returns its text - null if the user cancelled.
  /// Throws a [PlatformException] with code NO_PICKER if the device has no
  /// picker - common on Android TV.
  Future<String?> pick() async {
    if (!Platform.isAndroid) throw PlatformException(code: 'NO_PICKER');
    return _channel.invokeMethod<String>('pick');
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
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'HomeSystem'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Reads and checks the backup [content] - throws [BackupFormatException].
  _ParsedBackup _parse(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw BackupFormatException(l10n.adminFileInvalid);
    }
    if (decoded is! Map<String, dynamic> || decoded['app'] != _app) {
      throw BackupFormatException(l10n.settingsBackupNotHomeSystem);
    }
    if ((decoded['format'] as num? ?? 0) > _format) {
      throw BackupFormatException(l10n.settingsBackupNewerVersion);
    }

    List<Map<String, dynamic>> rows(String key) =>
        ((decoded as Map<String, dynamic>)[key] as List? ?? const []).cast<Map<String, dynamic>>();

    try {
      final secrets = decoded['secrets'];
      return _ParsedBackup(
        createdAt: DateTime.tryParse('${decoded['createdAt'] ?? ''}'),
        // Locally captured logo files live in the app's private storage and
        // are gone after a reinstall - drop references to missing ones so
        // the logo URL is used instead.
        favorites: rows('favorites').map(Favorite.fromJson).map((f) {
          return _fileExists(f.logoLocalPath) ? f : f.copyWith(logoLocalPath: const Value(null));
        }).toList(),
        dabStations: rows('dabStations').map(DabStation.fromJson).map((s) {
          return _fileExists(s.logoLocalPath) ? s : s.copyWith(logoLocalPath: const Value(null));
        }).toList(),
        // Missing in backups from before FM existed - then simply none.
        fmStations: rows('fmStations').map(FmStation.fromJson).map((s) {
          return _fileExists(s.logoLocalPath) ? s : s.copyWith(logoLocalPath: const Value(null));
        }).toList(),
        settings: rows('settings').map(Setting.fromJson).toList(),
        // Missing in backups from before secure storage.
        secrets: secrets is Map<String, dynamic> ? secrets : null,
      );
    } catch (_) {
      throw BackupFormatException(l10n.settingsBackupCorrupt);
    }
  }

  /// What the backup [content] contains, per area - for the selection
  /// before [restoreJson]. Throws [BackupFormatException] like it.
  BackupPreview inspect(String content) {
    final backup = _parse(content);
    final counts = <BackupArea, int>{};
    void add(BackupArea area, int n) {
      if (n > 0) counts[area] = (counts[area] ?? 0) + n;
    }

    for (final MapEntry(key: table, value: area) in backupTableAreas.entries) {
      add(area, backup.tableRows(table));
    }
    var deviceName = '';
    for (final s in backup.settings) {
      if (s.key == 'device_name') deviceName = s.value.trim();
      if (!backupSpecialKeys.contains(s.key)) add(backupAreaOf(s.key), 1);
    }
    // Every backup lists all passwords, empty ones too - only set ones count.
    for (final MapEntry(:key, :value) in (backup.secrets ?? const <String, dynamic>{}).entries) {
      if (value is String && value.isNotEmpty) add(backupAreaOf(key), 1);
    }
    return BackupPreview(
      deviceName: deviceName,
      createdAt: backup.createdAt,
      counts: counts,
      favorites: backup.favorites.length,
      dabStations: backup.dabStations.length,
      fmStations: backup.fmStations.length,
    );
  }

  /// Restores the backup [content] (checked first - throws
  /// [BackupFormatException]). Without [selection] it replaces all data;
  /// with one only the chosen areas - each completely, as it is in the
  /// backup - and the device name if one is given; everything else stays
  /// untouched. All in one transaction: on an error nothing has changed.
  /// The app must be restarted afterwards.
  Future<void> restoreJson(String content, {BackupRestoreSelection? selection}) async {
    final backup = _parse(content);
    final areas = selection?.areas;
    bool chosen(BackupArea area) => areas == null || areas.contains(area);
    bool chosenKey(String key) => !backupSpecialKeys.contains(key) && chosen(backupAreaOf(key));
    bool chosenTable(String table) => chosen(backupTableAreas[table] ?? BackupArea.other);

    final settings = areas == null ? backup.settings : backup.settings.where((s) => chosenKey(s.key)).toList();
    await _db.transaction(() async {
      if (chosenTable('favorites')) await _db.delete(_db.favorites).go();
      if (chosenTable('dabStations')) await _db.delete(_db.dabStations).go();
      if (chosenTable('fmStations')) await _db.delete(_db.fmStations).go();
      if (areas == null) {
        await _db.delete(_db.settings).go();
      } else {
        final current = await _db.select(_db.settings).get();
        final replaced = [for (final s in current) if (chosenKey(s.key)) s.key];
        if (replaced.isNotEmpty) await _db.deleteSettings(replaced);
      }
      await _db.batch((b) {
        if (chosenTable('favorites')) b.insertAll(_db.favorites, backup.favorites);
        if (chosenTable('dabStations')) b.insertAll(_db.dabStations, backup.dabStations);
        if (chosenTable('fmStations')) b.insertAll(_db.fmStations, backup.fmStations);
        b.insertAll(_db.settings, settings, mode: InsertMode.insertOrReplace);
      });
      final name = selection?.deviceName?.trim() ?? '';
      if (name.isNotEmpty) await _db.setSetting('device_name', name);
      // A restored device is set up - also with backups from before the
      // setup wizard.
      await _db.setSetting('setup_done', 'true');
    });
    // Missing in backups from before secure storage - the passwords stay.
    final secrets = backup.secrets;
    if (secrets != null) {
      await SecretStore(_db).importAll({
        for (final MapEntry(:key, :value) in secrets.entries)
          if (chosen(backupAreaOf(key))) key: value,
      });
    }
  }

  static bool _fileExists(String? path) => path != null && File(path).existsSync();

  static String _timestamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
