import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../db/database.dart';

/// Passwords outside the plain settings table: Android Keystore, Windows
/// Credential Manager, libsecret on Linux. Where that isn't available (e.g. a
/// Linux box without a keyring) it falls back to the settings table, so the
/// login still works - as the other credentials in the app do (radar, FTP).
///
/// Backups carry the secrets in their own section ([exportAll]/[importAll]),
/// like all other credentials (see BackupService).
class SecretStore {
  SecretStore(this._db);

  final AppDatabase _db;

  static const _storage = FlutterSecureStorage();
  static const _fallbackPrefix = 'secret_fallback.';

  /// Every secret the app keeps (for backups). Empty since the rtl_tcp login
  /// is gone; older backups may still carry 'rtl_tcp_password' - ignored.
  static const keys = <String>[];

  Future<String?> read(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value != null) return value;
    } catch (e) {
      debugPrint('SecretStore: secure storage unavailable ($e)');
    }
    return _db.getSetting('$_fallbackPrefix$key');
  }

  Future<void> write(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
      // Secure storage worked - no copy in the settings table.
      if (await _db.getSetting('$_fallbackPrefix$key') != null) {
        await _db.setSetting('$_fallbackPrefix$key', '');
      }
    } catch (e) {
      debugPrint('SecretStore: secure storage unavailable, using the settings table ($e)');
      await _db.setSetting('$_fallbackPrefix$key', value);
    }
  }

  /// Removes [key] from secure storage and the settings-table fallback.
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('SecretStore: secure storage unavailable ($e)');
    }
    await _db.deleteSettings(['$_fallbackPrefix$key']);
  }

  Future<Map<String, String>> exportAll() async => {
        for (final key in keys) key: await read(key) ?? '',
      };

  Future<void> importAll(Map<String, dynamic> secrets) async {
    for (final key in keys) {
      final value = secrets[key];
      if (value is String) await write(key, value);
    }
  }
}
