import '../db/database.dart';

enum AutostartMode { lastStation, fixedStation }

/// How "Alle DAB+ Sender" (FavoritesSidebar's DAB-Sender tab and
/// DabStationsScreen) is ordered - grouped by ensemble/multiplex first (the
/// previous, only behaviour) so stations sharing one transmitter/frequency
/// stay together, or purely alphabetically across all of them regardless of
/// ensemble. Applied client-side (see DabStationsRepository.sortDabStations)
/// rather than in SQL, since the "ignore a leading */space/!" comparison it
/// uses isn't expressible as a plain SQL ORDER BY.
enum DabSortMode { byEnsembleThenAlphabet, byAlphabet }

/// Either a favorite's program number or a DAB+ station played directly from
/// "Alle DAB+ Sender" without being favorited (see FavoritesSidebar) - the
/// latter has no program number of its own, so [AutostartMode.lastStation]
/// needs to remember which kind it was. See [SettingsRepository.getLastPlayed].
class LastPlayed {
  final int? favoriteProgramNumber;
  final int? dabFreqKhz;
  final int? dabServiceId;

  const LastPlayed.favorite(int programNumber)
      : favoriteProgramNumber = programNumber,
        dabFreqKhz = null,
        dabServiceId = null;

  const LastPlayed.dabStation({required int freqKhz, required int serviceId})
      : favoriteProgramNumber = null,
        dabFreqKhz = freqKhz,
        dabServiceId = serviceId;
}

class SettingsRepository {
  static const _keyAutostartMode = 'autostart_mode';
  static const _keyFixedProgramNumber = 'autostart_fixed_program_number';
  static const _keyLastProgramNumber = 'last_played_program_number';
  static const _keyLastPlayedKind = 'last_played_kind'; // 'favorite' | 'dab'
  static const _keyLastDabFreqKhz = 'last_played_dab_freq_khz';
  static const _keyLastDabServiceId = 'last_played_dab_service_id';
  static const _keyWeatherEnabled = 'weather_enabled';
  static const _keyRadarEnabled = 'radar_enabled';
  static const _keyWeatherLat = 'weather_lat';
  static const _keyWeatherLon = 'weather_lon';
  static const _keyWeatherLocationName = 'weather_location_name';
  static const _keyWeatherTileScale = 'weather_tile_scale';
  static const _keyWeatherContentScale = 'weather_content_scale';
  static const _keyWeatherSpanTwoTiles = 'weather_span_two_tiles';
  static const _keyRadarTileScale = 'radar_tile_scale';
  static const _keyRadarZoom = 'radar_zoom';
  static const _keyRadarDimming = 'radar_dimming';
  static const _keySunEnabled = 'sun_enabled';
  static const _keySunTileScale = 'sun_tile_scale';
  static const _keyUiScale = 'ui_scale';
  static const _keyFtpHost = 'ftp_host';
  static const _keyFtpUser = 'ftp_user';
  static const _keyFtpPass = 'ftp_pass';
  static const _keyFtpDir = 'ftp_dir';
  static const _keyRtlSdrHost = 'rtl_sdr_host';
  static const _keyRtlSdrPort = 'rtl_sdr_port';
  static const _keyRtlSdrMode = 'rtl_sdr_mode'; // 'own' | 'external'
  static const _keyDabSortMode = 'dab_sort_mode'; // 'ensemble' | 'alphabet'
  static const _keyShowClockDate = 'show_clock_date';
  static const _keyOrderEnabled = 'order_enabled';
  static const _keyOrderBaseUrl = 'order_base_url';
  static const _keyOrderUser = 'order_user';
  static const _keyOrderPassword = 'order_password';
  static const _keyOrderPollSeconds = 'order_poll_seconds';
  static const _keyPickupDisplaySeconds = 'pickup_display_seconds';
  static const _keyPickupSound = 'pickup_sound';

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

  Future<void> setLastPlayedFavorite(int programNumber) async {
    await setLastProgramNumber(programNumber);
    await _db.setSetting(_keyLastPlayedKind, 'favorite');
  }

  Future<void> setLastPlayedDabStation(int freqKhz, int serviceId) async {
    await _db.setSetting(_keyLastDabFreqKhz, '$freqKhz');
    await _db.setSetting(_keyLastDabServiceId, '$serviceId');
    await _db.setSetting(_keyLastPlayedKind, 'dab');
  }

  /// Whatever was last played, regardless of whether it's still a saved
  /// favorite - see [LastPlayed].
  Future<LastPlayed?> getLastPlayed() async {
    final kind = await _db.getSetting(_keyLastPlayedKind);
    if (kind == 'dab') {
      final freqKhz = int.tryParse(await _db.getSetting(_keyLastDabFreqKhz) ?? '');
      final serviceId = int.tryParse(await _db.getSetting(_keyLastDabServiceId) ?? '');
      if (freqKhz != null && serviceId != null) {
        return LastPlayed.dabStation(freqKhz: freqKhz, serviceId: serviceId);
      }
    }
    final programNumber = await getLastProgramNumber();
    return programNumber == null ? null : LastPlayed.favorite(programNumber);
  }

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
  static const defaultLocationName = 'Graz';

  Future<double> getWeatherLat() async =>
      double.tryParse(await _db.getSetting(_keyWeatherLat) ?? '') ?? defaultLat;

  Future<double> getWeatherLon() async =>
      double.tryParse(await _db.getSetting(_keyWeatherLon) ?? '') ?? defaultLon;

  Future<String> getWeatherLocationName() async =>
      (await _db.getSetting(_keyWeatherLocationName)) ?? defaultLocationName;

  Future<void> setWeatherLocation(double lat, double lon, String name) async {
    await _db.setSetting(_keyWeatherLat, '$lat');
    await _db.setSetting(_keyWeatherLon, '$lon');
    await _db.setSetting(_keyWeatherLocationName, name);
  }

  static const defaultTileScale = 1.0;

  Future<double> getWeatherTileScale() async =>
      double.tryParse(await _db.getSetting(_keyWeatherTileScale) ?? '') ?? defaultTileScale;

  Future<void> setWeatherTileScale(double scale) => _db.setSetting(_keyWeatherTileScale, '$scale');

  /// Separate from [getWeatherTileScale] - that resizes the tile's own box
  /// (and therefore how much of the app it takes up), this scales the
  /// forecast content *within* it (icon/text/badge sizes, column widths),
  /// so a small tile can still show larger, more readable content, or a
  /// large tile can show denser/smaller content, independently of each
  /// other.
  Future<double> getWeatherContentScale() async =>
      double.tryParse(await _db.getSetting(_keyWeatherContentScale) ?? '') ?? defaultTileScale;

  Future<void> setWeatherContentScale(double scale) => _db.setSetting(_keyWeatherContentScale, '$scale');

  /// Whether the weather forecast tile spans the full height of the other
  /// two tiles stacked next to it (radar + sun/moon), rather than just
  /// being one normal-height tile itself - see _WeatherRadarColumn's own
  /// doc comment. Only the forecast tile has this option; radar/sun always
  /// just sit at their own single height in that stacked column.
  Future<bool> getWeatherSpanTwoTiles() async => (await _db.getSetting(_keyWeatherSpanTwoTiles)) != 'false';

  Future<void> setWeatherSpanTwoTiles(bool span) => _db.setSetting(_keyWeatherSpanTwoTiles, '$span');

  Future<double> getRadarTileScale() async =>
      double.tryParse(await _db.getSetting(_keyRadarTileScale) ?? '') ?? defaultTileScale;

  Future<void> setRadarTileScale(double scale) => _db.setSetting(_keyRadarTileScale, '$scale');

  // wo-cloud's own "wrm" URL parameter (see RadarPanel) - how far the
  // embedded map is zoomed in by default, i.e. how much of the surrounding
  // area is visible at once. Previously only ever the hardcoded default (9)
  // RadarPanel itself used - not otherwise configurable.
  static const defaultRadarZoom = 9;
  static const minRadarZoom = 5;
  static const maxRadarZoom = 13;

  Future<int> getRadarZoom() async =>
      int.tryParse(await _db.getSetting(_keyRadarZoom) ?? '') ?? defaultRadarZoom;

  Future<void> setRadarZoom(int zoom) => _db.setSetting(_keyRadarZoom, '$zoom');

  static const defaultRadarDimming = 0.0;

  /// 0.0 = no dimming, 1.0 = fully black - a plain dark overlay over the
  /// radar webview rather than a CSS/colour-invert dark mode, which would
  /// risk distorting the map's own precipitation-intensity colour coding.
  Future<double> getRadarDimming() async =>
      double.tryParse(await _db.getSetting(_keyRadarDimming) ?? '') ?? defaultRadarDimming;

  Future<void> setRadarDimming(double dimming) => _db.setSetting(_keyRadarDimming, '$dimming');

  Future<bool> getSunEnabled() async => (await _db.getSetting(_keySunEnabled)) != 'false';

  Future<void> setSunEnabled(bool enabled) => _db.setSetting(_keySunEnabled, '$enabled');

  Future<double> getSunTileScale() async =>
      double.tryParse(await _db.getSetting(_keySunTileScale) ?? '') ?? defaultTileScale;

  Future<void> setSunTileScale(double scale) => _db.setSetting(_keySunTileScale, '$scale');

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

  static const defaultRtlSdrHost = '127.0.0.1';
  static const defaultRtlSdrPort = 1234;

  /// The rtl_tcp-protocol source used by both the raw RTL-SDR test screen
  /// and the DAB+ decoder - our own USB-TCP service, an external driver
  /// app, or a network service (e.g. a Raspberry Pi), all reached the same
  /// way (see RtlSdrTestScreen's mode selector).
  Future<String> getRtlSdrHost() async => (await _db.getSetting(_keyRtlSdrHost)) ?? defaultRtlSdrHost;

  Future<int> getRtlSdrPort() async =>
      int.tryParse(await _db.getSetting(_keyRtlSdrPort) ?? '') ?? defaultRtlSdrPort;

  Future<void> setRtlSdrServer(String host, int port) async {
    await _db.setSetting(_keyRtlSdrHost, host);
    await _db.setSetting(_keyRtlSdrPort, '$port');
  }

  /// Whether the app should automatically (re-)start its own USB-TCP RTL-SDR
  /// service (RtlSdrUsbService) at startup - set whenever the user actually
  /// starts that service from RtlSdrTestScreen, so the dongle is ready
  /// without any manual step the next time the app launches. 'external'
  /// means the user picked an external driver app or a network service
  /// instead, which this app has no business auto-starting.
  Future<bool> getRtlSdrAutoStartOwnService() async => (await _db.getSetting(_keyRtlSdrMode)) == 'own';

  Future<void> setRtlSdrMode({required bool ownUsbService}) =>
      _db.setSetting(_keyRtlSdrMode, ownUsbService ? 'own' : 'external');

  Future<DabSortMode> getDabSortMode() async {
    final v = await _db.getSetting(_keyDabSortMode);
    return v == 'alphabet' ? DabSortMode.byAlphabet : DabSortMode.byEnsembleThenAlphabet;
  }

  Future<void> setDabSortMode(DabSortMode mode) => _db.setSetting(
      _keyDabSortMode, mode == DabSortMode.byAlphabet ? 'alphabet' : 'ensemble');

  Future<bool> getShowClockDate() async => (await _db.getSetting(_keyShowClockDate)) == 'true';

  Future<void> setShowClockDate(bool value) => _db.setSetting(_keyShowClockDate, '$value');

  // bestell_manager's order-day API (see OrderService) - logs in with the
  // host's own bestell_manager account (e-mail + password), so each radio
  // shows its own host's order day. No default credentials: nothing is
  // polled until they've been entered.
  static const defaultOrderBaseUrl = 'https://bestellung.jaycloud.at';
  static const defaultOrderUser = '';

  Future<bool> getOrderEnabled() async => (await _db.getSetting(_keyOrderEnabled)) != 'false';

  Future<void> setOrderEnabled(bool enabled) => _db.setSetting(_keyOrderEnabled, '$enabled');

  Future<String> getOrderBaseUrl() async => (await _db.getSetting(_keyOrderBaseUrl)) ?? defaultOrderBaseUrl;

  Future<String> getOrderUser() async => (await _db.getSetting(_keyOrderUser)) ?? defaultOrderUser;

  Future<String> getOrderPassword() async => (await _db.getSetting(_keyOrderPassword)) ?? '';

  // How often the order tile asks bestell_manager for today's status - the
  // user's own trade-off between "live" and load, 5..60s.
  static const defaultOrderPollSeconds = 5;
  static const minOrderPollSeconds = 5;
  static const maxOrderPollSeconds = 60;

  Future<int> getOrderPollSeconds() async =>
      (int.tryParse(await _db.getSetting(_keyOrderPollSeconds) ?? '') ?? defaultOrderPollSeconds)
          .clamp(minOrderPollSeconds, maxOrderPollSeconds);

  Future<void> setOrderPollSeconds(int seconds) => _db.setSetting(_keyOrderPollSeconds, '$seconds');

  // How long the "Bitte abholen" overlay stays up after the last newly
  // completed order (see PickupNotifier).
  static const defaultPickupDisplaySeconds = 30;
  static const minPickupDisplaySeconds = 10;
  static const maxPickupDisplaySeconds = 300;

  Future<int> getPickupDisplaySeconds() async =>
      (int.tryParse(await _db.getSetting(_keyPickupDisplaySeconds) ?? '') ?? defaultPickupDisplaySeconds)
          .clamp(minPickupDisplaySeconds, maxPickupDisplaySeconds);

  Future<void> setPickupDisplaySeconds(int seconds) => _db.setSetting(_keyPickupDisplaySeconds, '$seconds');

  Future<bool> getPickupSound() async => (await _db.getSetting(_keyPickupSound)) != 'false';

  Future<void> setPickupSound(bool enabled) => _db.setSetting(_keyPickupSound, '$enabled');

  Future<void> setOrderApi({required String baseUrl, required String user, required String password}) async {
    await _db.setSetting(_keyOrderBaseUrl, baseUrl);
    await _db.setSetting(_keyOrderUser, user);
    await _db.setSetting(_keyOrderPassword, password);
  }
}
