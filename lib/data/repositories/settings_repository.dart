import '../db/database.dart';
import '../services/secret_store.dart';

/// Protocol and login settings of the rtl_tcp server (see
/// SettingsRepository.getRtlTcpAuth).
class RtlTcpAuth {
  final bool v2;
  final bool login; // only meaningful with v2
  final String user;
  final String password;

  const RtlTcpAuth({this.v2 = false, this.login = false, this.user = '', this.password = ''});

  RtlTcpAuth copyWith({bool? v2, bool? login, String? user, String? password}) => RtlTcpAuth(
        v2: v2 ?? this.v2,
        login: login ?? this.login,
        user: user ?? this.user,
        password: password ?? this.password,
      );
}

enum AutostartMode { lastStation, fixedStation }

/// How "Alle DAB+ Sender" (FavoritesSidebar's DAB-Sender tab and
/// DabStationsScreen) is ordered - grouped by ensemble/multiplex first (the
/// previous, only behaviour) so stations sharing one transmitter/frequency
/// stay together, or purely alphabetically across all of them regardless of
/// ensemble. Applied client-side (see DabStationsRepository.sortDabStations)
/// rather than in SQL, since the "ignore a leading */space/!" comparison it
/// uses isn't expressible as a plain SQL ORDER BY.
/// [groupedByEnsemble] is the same order as [byEnsembleThenAlphabet], but
/// the lists show a heading per ensemble.
enum DabSortMode { groupedByEnsemble, byEnsembleThenAlphabet, byAlphabet }

/// How DAB+ reaches its RTL-SDR receiver - or [none]: internet radio only,
/// with everything DAB+ (station search, the DAB-Sender tab) hidden.
/// - [usb]: this app drives the stick directly over USB (cpp/hrdab's own
///   RTL2832U/R820T driver).
/// - [tcp]: an rtl_tcp server - an external driver app on this device
///   (127.0.0.1) or a network service (e.g. a Raspberry Pi).
enum ReceiverMode { none, usb, tcp }

/// Either a favorite's program number or a DAB+ station played directly from
/// "Alle DAB+ Sender" without being favorited (see FavoritesSidebar) - the
/// latter has no program number of its own, so [AutostartMode.lastStation]
/// needs to remember which kind it was. See [SettingsRepository.getLastPlayed].
class LastPlayed {
  final int? favoriteProgramNumber;
  final int? dabFreqKhz;
  final int? dabServiceId;
  final int? fmFreqKhz;

  const LastPlayed.favorite(int programNumber)
      : favoriteProgramNumber = programNumber,
        dabFreqKhz = null,
        dabServiceId = null,
        fmFreqKhz = null;

  const LastPlayed.dabStation({required int freqKhz, required int serviceId})
      : favoriteProgramNumber = null,
        dabFreqKhz = freqKhz,
        dabServiceId = serviceId,
        fmFreqKhz = null;

  const LastPlayed.fmStation(int freqKhz)
      : favoriteProgramNumber = null,
        dabFreqKhz = null,
        dabServiceId = null,
        fmFreqKhz = freqKhz;
}

class SettingsRepository {
  static const _keyAutostartMode = 'autostart_mode';
  static const _keyFixedProgramNumber = 'autostart_fixed_program_number';
  static const _keyLastProgramNumber = 'last_played_program_number';
  static const _keyLastPlayedKind = 'last_played_kind'; // 'favorite' | 'dab' | 'fm'
  static const _keyLastFmFreqKhz = 'last_played_fm_freq_khz';
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
  static const _keyRadarRadius = 'radar_radius_km';
  static const _keyRadarDimming = 'radar_dimming';
  static const _keyRadarUrl = 'radar_url';
  static const _keyRadarAuthEnabled = 'radar_auth_enabled';
  static const _keyRadarToken = 'radar_token';
  static const _keyRadarIsWebPage = 'radar_is_web_page';
  static const _keyRadarWebCss = 'radar_web_css';
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
  static const _keyRtlTcpProtocol = 'rtl_tcp_protocol'; // 'v1' | 'v2'
  static const _keyRtlTcpLogin = 'rtl_tcp_login';
  static const _keyRtlTcpUser = 'rtl_tcp_user';
  static const _secretRtlTcpPassword = 'rtl_tcp_password'; // SecretStore, not the settings table
  static const _keyDabSortMode = 'dab_sort_mode'; // 'grouped' | 'ensemble' | 'alphabet'
  static const _keyShowClockDate = 'show_clock_date';
  static const _keyCbEnabled = 'cb_enabled';
  static const _keyAirbandEnabled = 'airband_enabled';
  static const _keyHamEnabled = 'ham_enabled';
  static const _keyMilEnabled = 'mil_enabled';
  static const _keyNbSampleRate = 'nb_sample_rate';
  static const _keyCbAll80 = 'cb_all_80';
  static const _keyAutoUpdate = 'auto_update';
  static const _keyFullscreen = 'fullscreen';
  static const _keyFullscreenMonitor = 'fullscreen_monitor';
  static const _keyNbPrefix = 'nb_last_'; // + band id: "freqHz|mode|squelchDb"

  final AppDatabase _db;
  final SecretStore _secrets;
  SettingsRepository(this._db) : _secrets = SecretStore(_db);

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

  Future<void> setLastPlayedFmStation(int freqKhz) async {
    await _db.setSetting(_keyLastFmFreqKhz, '$freqKhz');
    await _db.setSetting(_keyLastPlayedKind, 'fm');
  }

  /// Whatever was last played, regardless of whether it's still a saved
  /// favorite - see [LastPlayed].
  Future<LastPlayed?> getLastPlayed() async {
    final kind = await _db.getSetting(_keyLastPlayedKind);
    if (kind == 'fm') {
      final freqKhz = int.tryParse(await _db.getSetting(_keyLastFmFreqKhz) ?? '');
      if (freqKhz != null) return LastPlayed.fmStation(freqKhz);
    }
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

  /// How much of the map the weather radar shows: the distance (km) from the
  /// location to the tile's top/bottom edge (the wider sides show more).
  static const radarRadiusSteps = [10, 20, 30, 50, 75, 100, 150, 200, 300, 500];
  static const defaultRadarRadiusKm = 50;

  Future<int> getRadarRadiusKm() async {
    final v = int.tryParse(await _db.getSetting(_keyRadarRadius) ?? '');
    return v != null && radarRadiusSteps.contains(v) ? v : defaultRadarRadiusKm;
  }

  Future<void> setRadarRadiusKm(int km) => _db.setSetting(_keyRadarRadius, '$km');

  static const defaultRadarDimming = 0.0;

  /// 0.0 = no dimming, 1.0 = fully black - a plain dark overlay over the
  /// radar rather than a colour-invert dark mode, which would distort the
  /// precipitation-intensity colour coding.
  Future<double> getRadarDimming() async =>
      double.tryParse(await _db.getSetting(_keyRadarDimming) ?? '') ?? defaultRadarDimming;

  Future<void> setRadarDimming(double dimming) => _db.setSetting(_keyRadarDimming, '$dimming');

  /// Where the radar tile's image comes from - see RadarPanel for the
  /// placeholders it may contain. Empty = not set up yet.
  Future<String> getRadarUrl() async => (await _db.getSetting(_keyRadarUrl)) ?? '';

  /// Whether [getRadarToken] is sent along (as a Bearer token) - kept apart
  /// from the token itself so it can be switched off without retyping it.
  Future<bool> getRadarAuthEnabled() async => (await _db.getSetting(_keyRadarAuthEnabled)) == 'true';

  Future<String> getRadarToken() async => (await _db.getSetting(_keyRadarToken)) ?? '';

  /// Whether [getRadarUrl] is a web page (e.g. an interactive radar map,
  /// shown in an embedded browser) rather than a plain image.
  Future<bool> getRadarIsWebPage() async => (await _db.getSetting(_keyRadarIsWebPage)) == 'true';

  /// The user's own CSS, added to a web-page radar after every load - like a
  /// user stylesheet in a browser. Empty = none.
  Future<String> getRadarWebCss() async => (await _db.getSetting(_keyRadarWebCss)) ?? '';

  Future<void> setRadarSource({
    required String url,
    required bool isWebPage,
    required String webCss,
    required bool authEnabled,
    required String token,
  }) async {
    await _db.setSetting(_keyRadarUrl, url);
    await _db.setSetting(_keyRadarIsWebPage, '$isWebPage');
    await _db.setSetting(_keyRadarWebCss, webCss);
    await _db.setSetting(_keyRadarAuthEnabled, '$authEnabled');
    await _db.setSetting(_keyRadarToken, token);
  }

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
  /// and the DAB+ receiver in TCP mode - an external driver app or a
  /// network service (e.g. a Raspberry Pi), see RtlSdrTestScreen.
  Future<String> getRtlSdrHost() async => (await _db.getSetting(_keyRtlSdrHost)) ?? defaultRtlSdrHost;

  Future<int> getRtlSdrPort() async =>
      int.tryParse(await _db.getSetting(_keyRtlSdrPort) ?? '') ?? defaultRtlSdrPort;

  Future<void> setRtlSdrServer(String host, int port) async {
    await _db.setSetting(_keyRtlSdrHost, host);
    await _db.setSetting(_keyRtlSdrPort, '$port');
  }

  /// Protocol and login of the rtl_tcp server - set by hand, no
  /// auto-detection: v1 = classic rtl_tcp (the old behaviour), v2 =
  /// rtltcp_v2 (rtltcp.server: status messages, optional login).
  Future<RtlTcpAuth> getRtlTcpAuth() async => RtlTcpAuth(
        v2: (await _db.getSetting(_keyRtlTcpProtocol)) == 'v2',
        login: (await _db.getSetting(_keyRtlTcpLogin)) == 'true',
        user: (await _db.getSetting(_keyRtlTcpUser)) ?? '',
        password: await _secrets.read(_secretRtlTcpPassword) ?? '',
      );

  Future<void> setRtlTcpAuth(RtlTcpAuth auth) async {
    await _db.setSetting(_keyRtlTcpProtocol, auth.v2 ? 'v2' : 'v1');
    await _db.setSetting(_keyRtlTcpLogin, '${auth.login}');
    await _db.setSetting(_keyRtlTcpUser, auth.user);
    await _secrets.write(_secretRtlTcpPassword, auth.password);
  }

  /// How DAB+ reaches its receiver (see [ReceiverMode]). Unset counts as
  /// [ReceiverMode.tcp], which was the default before "no receiver" existed.
  Future<ReceiverMode> getReceiverMode() async => switch (await _db.getSetting(_keyRtlSdrMode)) {
        'own' => ReceiverMode.usb,
        'none' => ReceiverMode.none,
        _ => ReceiverMode.tcp,
      };

  Future<void> setReceiverMode(ReceiverMode mode) => _db.setSetting(
        _keyRtlSdrMode,
        switch (mode) {
          ReceiverMode.usb => 'own',
          ReceiverMode.none => 'none',
          ReceiverMode.tcp => 'external',
        },
      );

  /// Whether DAB+ uses the RTL-SDR stick directly over USB ('own',
  /// "RTL-SDR-USB" on RtlSdrTestScreen) rather than an rtl_tcp server
  /// ('external').
  Future<bool> getRtlSdrAutoStartOwnService() async => await getReceiverMode() == ReceiverMode.usb;

  Future<DabSortMode> getDabSortMode() async => switch (await _db.getSetting(_keyDabSortMode)) {
        'alphabet' => DabSortMode.byAlphabet,
        'grouped' => DabSortMode.groupedByEnsemble,
        _ => DabSortMode.byEnsembleThenAlphabet,
      };

  Future<void> setDabSortMode(DabSortMode mode) => _db.setSetting(
        _keyDabSortMode,
        switch (mode) {
          DabSortMode.byAlphabet => 'alphabet',
          DabSortMode.groupedByEnsemble => 'grouped',
          DabSortMode.byEnsembleThenAlphabet => 'ensemble',
        },
      );

  Future<bool> getShowClockDate() async => (await _db.getSetting(_keyShowClockDate)) == 'true';

  Future<void> setShowClockDate(bool value) => _db.setSetting(_keyShowClockDate, '$value');

  /// Extra listening bands (see ScannerScreen) - off by default, they're
  /// for the curious, not everyday radio.
  Future<bool> getCbEnabled() async => (await _db.getSetting(_keyCbEnabled)) == 'true';
  Future<void> setCbEnabled(bool value) => _db.setSetting(_keyCbEnabled, '$value');
  Future<bool> getAirbandEnabled() async => (await _db.getSetting(_keyAirbandEnabled)) == 'true';
  Future<void> setAirbandEnabled(bool value) => _db.setSetting(_keyAirbandEnabled, '$value');
  Future<bool> getHamEnabled() async => (await _db.getSetting(_keyHamEnabled)) == 'true';
  Future<void> setHamEnabled(bool value) => _db.setSetting(_keyHamEnabled, '$value');
  Future<bool> getMilEnabled() async => (await _db.getSetting(_keyMilEnabled)) == 'true';
  Future<void> setMilEnabled(bool value) => _db.setSetting(_keyMilEnabled, '$value');

  /// Which band of a multi-band listening screen was last open (amateur
  /// radio: "ham2" etc.), keyed by the screen's first band.
  Future<String?> getNbVariant(String screen) => _db.getSetting('nb_variant_$screen');
  Future<void> setNbVariant(String screen, String band) => _db.setSetting('nb_variant_$screen', band);

  /// Sample rate (= visible bandwidth) for the listening bands. Over rtl_tcp
  /// it's 2 bytes per sample on the network - lower it for weak WiFi.
  static const nbSampleRates = [960000, 1440000, 2048000];
  static const defaultNbSampleRate = 1440000;

  Future<int> getNbSampleRate() async {
    final v = int.tryParse(await _db.getSetting(_keyNbSampleRate) ?? '');
    return v != null && nbSampleRates.contains(v) ? v : defaultNbSampleRate;
  }

  Future<void> setNbSampleRate(int rate) => _db.setSetting(_keyNbSampleRate, '$rate');

  /// CB channels 1-40 only (Austria, default) or 1-80 (Germany).
  Future<bool> getCbAll80() async => (await _db.getSetting(_keyCbAll80)) == 'true';
  Future<void> setCbAll80(bool value) => _db.setSetting(_keyCbAll80, '$value');

  /// Install new versions from the update server on start (default on).
  Future<bool> getAutoUpdate() async => (await _db.getSetting(_keyAutoUpdate)) != 'false';
  Future<void> setAutoUpdate(bool value) => _db.setSetting(_keyAutoUpdate, '$value');

  /// Full screen (see applyDisplayMode); off by default.
  Future<bool> getFullscreen() async => (await _db.getSetting(_keyFullscreen)) == 'true';
  Future<void> setFullscreen(bool value) => _db.setSetting(_keyFullscreen, '$value');

  /// Monitor for full screen on Windows, 1-based.
  Future<int> getFullscreenMonitor() async => int.tryParse(await _db.getSetting(_keyFullscreenMonitor) ?? '') ?? 1;
  Future<void> setFullscreenMonitor(int value) => _db.setSetting(_keyFullscreenMonitor, '$value');

  /// Signal filters per listening band: bandwidth (0 = automatic), noise
  /// blanker, voice filter, AGC - defaults: automatic, on, on, automatic.
  Future<({int bandwidthHz, bool noiseBlanker, bool voiceFilter, String agc})> getNbFilters(String band) async {
    final p = (await _db.getSetting('nb_filters_$band'))?.split('|');
    if (p == null || p.length != 4) return (bandwidthHz: 0, noiseBlanker: true, voiceFilter: true, agc: 'auto');
    return (bandwidthHz: int.tryParse(p[0]) ?? 0, noiseBlanker: p[1] == 'true', voiceFilter: p[2] == 'true', agc: p[3]);
  }

  Future<void> setNbFilters(String band, {required int bandwidthHz, required bool noiseBlanker, required bool voiceFilter, required String agc}) =>
      _db.setSetting('nb_filters_$band', '$bandwidthHz|$noiseBlanker|$voiceFilter|$agc');

  /// Last channel, modulation and squelch per listening band.
  Future<({int freqHz, String mode, double squelchDb})?> getNbLast(String band) async {
    final parts = (await _db.getSetting('$_keyNbPrefix$band'))?.split('|');
    if (parts == null || parts.length != 3) return null;
    final freq = int.tryParse(parts[0]), squelch = double.tryParse(parts[2]);
    if (freq == null || squelch == null) return null;
    return (freqHz: freq, mode: parts[1], squelchDb: squelch);
  }

  Future<void> setNbLast(String band, {required int freqHz, required String mode, required double squelchDb}) =>
      _db.setSetting('$_keyNbPrefix$band', '$freqHz|$mode|$squelchDb');
}
