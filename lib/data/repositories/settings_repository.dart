import '../db/database.dart';

enum AutostartMode { lastStation, fixedStation }

class SettingsRepository {
  static const _keyAutostartMode = 'autostart_mode';
  static const _keyFixedProgramNumber = 'autostart_fixed_program_number';
  static const _keyLastProgramNumber = 'last_played_program_number';
  static const _keyWeatherEnabled = 'weather_enabled';
  static const _keyRadarEnabled = 'radar_enabled';
  static const _keyWeatherLat = 'weather_lat';
  static const _keyWeatherLon = 'weather_lon';
  static const _keyUiScale = 'ui_scale';
  static const _keyFtpHost = 'ftp_host';
  static const _keyFtpUser = 'ftp_user';
  static const _keyFtpPass = 'ftp_pass';
  static const _keyFtpDir = 'ftp_dir';

  final AppDatabase _db;
  SettingsRepository(this._db);

  Future<AutostartMode> getAutostartMode() async {
    final v = await _db.getSetting(_keyAutostartMode);
    return v == 'fixed' ? AutostartMode.fixedStation : AutostartMode.lastStation;
  }

  Future<void> setAutostartMode(AutostartMode mode) => _db.setSetting(
      _keyAutostartMode, mode == AutostartMode.fixedStation ? 'fixed' : 'last');

  Future<int?> getFixedProgramNumber() async {
    final v = await _db.getSetting(_keyFixedProgramNumber);
    return v == null ? null : int.tryParse(v);
  }

  Future<void> setFixedProgramNumber(int programNumber) =>
      _db.setSetting(_keyFixedProgramNumber, '$programNumber');

  Future<int?> getLastProgramNumber() async {
    final v = await _db.getSetting(_keyLastProgramNumber);
    return v == null ? null : int.tryParse(v);
  }

  Future<void> setLastProgramNumber(int programNumber) =>
      _db.setSetting(_keyLastProgramNumber, '$programNumber');

  Future<bool> getWeatherEnabled() async =>
      (await _db.getSetting(_keyWeatherEnabled)) != 'false';

  Future<void> setWeatherEnabled(bool enabled) =>
      _db.setSetting(_keyWeatherEnabled, '$enabled');

  Future<bool> getRadarEnabled() async =>
      (await _db.getSetting(_keyRadarEnabled)) != 'false';

  Future<void> setRadarEnabled(bool enabled) =>
      _db.setSetting(_keyRadarEnabled, '$enabled');

  static const defaultLat = 47.0707;
  static const defaultLon = 15.4395; // Graz

  Future<double> getWeatherLat() async =>
      double.tryParse(await _db.getSetting(_keyWeatherLat) ?? '') ?? defaultLat;

  Future<double> getWeatherLon() async =>
      double.tryParse(await _db.getSetting(_keyWeatherLon) ?? '') ?? defaultLon;

  Future<void> setWeatherLocation(double lat, double lon) async {
    await _db.setSetting(_keyWeatherLat, '$lat');
    await _db.setSetting(_keyWeatherLon, '$lon');
  }

  // Default is intentionally below 100%: unscaled Material widget sizes look
  // oversized on a 65" TV viewed from a couch/terrace distance.
  static const defaultUiScale = 0.85;

  Future<double> getUiScale() async =>
      double.tryParse(await _db.getSetting(_keyUiScale) ?? '') ?? defaultUiScale;

  Future<void> setUiScale(double scale) => _db.setSetting(_keyUiScale, '$scale');

  Future<Map<String, String?>> getFtpConfig() async => {
        'host': await _db.getSetting(_keyFtpHost),
        'user': await _db.getSetting(_keyFtpUser),
        'pass': await _db.getSetting(_keyFtpPass),
        'dir': await _db.getSetting(_keyFtpDir),
      };

  Future<void> setFtpConfig({
    required String host,
    required String user,
    required String pass,
    required String dir,
  }) async {
    await _db.setSetting(_keyFtpHost, host);
    await _db.setSetting(_keyFtpUser, user);
    await _db.setSetting(_keyFtpPass, pass);
    await _db.setSetting(_keyFtpDir, dir);
  }
}
