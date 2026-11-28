import 'dart:convert';

import '../db/database.dart';
import '../models/launcher_group.dart';
import '../models/launcher_tile.dart';
import '../services/enigma2_service.dart' show Enigma2Config;
import '../services/picture_library.dart' show SlideshowOrder;
import '../services/secret_store.dart';
import '../services/tv_reminders.dart';

/// One configured rtl_tcp server (Settings → Radio-Empfänger).
class RtlTcpServer {
  const RtlTcpServer({required this.host, required this.port});

  final String host;
  final int port;

  Map<String, dynamic> toJson() => {'host': host, 'port': port};

  static RtlTcpServer? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'];
    final port = json['port'];
    if (host is! String || host.trim().isEmpty || port is! int) return null;
    return RtlTcpServer(host: host.trim(), port: port);
  }

  @override
  bool operator ==(Object other) => other is RtlTcpServer && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// All configured rtl_tcp servers; the receiver (DAB+/FM) uses
/// [defaultServer].
class RtlTcpServers {
  const RtlTcpServers(this.servers, this.defaultIndex);

  final List<RtlTcpServer> servers;
  final int defaultIndex;

  RtlTcpServer get defaultServer => servers[defaultIndex];
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
  static const _keyLanguage = 'language';
  static const _keyFtpHost = 'ftp_host';
  static const _keyFtpUser = 'ftp_user';
  static const _keyFtpPass = 'ftp_pass';
  static const _keyFtpDir = 'ftp_dir';
  static const _keyRtlSdrHost = 'rtl_sdr_host';
  static const _keyRtlSdrPort = 'rtl_sdr_port';
  static const _keyRtlTcpServers = 'rtl_tcp_servers'; // JSON [{host, port}], see getRtlTcpServers
  static const _keyRtlSdrMode = 'rtl_sdr_mode'; // 'own' | 'external'
  static const _keyDabSortMode = 'dab_sort_mode'; // 'grouped' | 'ensemble' | 'alphabet'
  static const _keyShowClockDate = 'show_clock_date';
  // Before "Funk anzeigen": one toggle each for CB, amateur and military
  // radio - only read once more, to carry them over (see getFunkEnabled).
  static const _keyCbEnabled = 'cb_enabled';
  static const _keyHamEnabled = 'ham_enabled';
  static const _keyMilEnabled = 'mil_enabled';
  static const _keyFunkEnabled = 'funk_enabled';
  static const _keyDabEnabled = 'dab_enabled';
  static const _keyFmEnabled = 'fm_enabled';
  static const _keyAmEnabled = 'am_enabled';
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

  Future<void> setAutostartMode(AutostartMode mode) =>
      _db.setSetting(_keyAutostartMode, mode == AutostartMode.fixedStation ? 'fixed' : 'last');

  Future<int?> getFixedProgramNumber() async {
    final v = await _db.getSetting(_keyFixedProgramNumber);
    return v == null ? null : int.tryParse(v);
  }

  Future<void> setFixedProgramNumber(int programNumber) => _db.setSetting(_keyFixedProgramNumber, '$programNumber');

  Future<int?> getLastProgramNumber() async {
    final v = await _db.getSetting(_keyLastProgramNumber);
    return v == null ? null : int.tryParse(v);
  }

  Future<void> setLastProgramNumber(int programNumber) => _db.setSetting(_keyLastProgramNumber, '$programNumber');

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

  Future<bool> getWeatherEnabled() async => (await _db.getSetting(_keyWeatherEnabled)) != 'false';

  Future<void> setWeatherEnabled(bool enabled) => _db.setSetting(_keyWeatherEnabled, '$enabled');

  Future<bool> getRadarEnabled() async => (await _db.getSetting(_keyRadarEnabled)) != 'false';

  Future<void> setRadarEnabled(bool enabled) => _db.setSetting(_keyRadarEnabled, '$enabled');

  static const defaultLat = 47.0707;
  static const defaultLon = 15.4395; // Graz
  static const defaultLocationName = 'Graz';

  Future<double> getWeatherLat() async => double.tryParse(await _db.getSetting(_keyWeatherLat) ?? '') ?? defaultLat;

  Future<double> getWeatherLon() async => double.tryParse(await _db.getSetting(_keyWeatherLon) ?? '') ?? defaultLon;

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

  Future<double> getUiScale() async => double.tryParse(await _db.getSetting(_keyUiScale) ?? '') ?? defaultUiScale;

  Future<void> setUiScale(double scale) => _db.setSetting(_keyUiScale, '$scale');

  /// The app's language - "system" (the device's: German if it's German,
  /// English otherwise), "de" or "en".
  Future<String> getLanguage() async => await _db.getSetting(_keyLanguage) ?? 'system';
  Future<void> setLanguage(String value) => _db.setSetting(_keyLanguage, value);

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

  Future<int> getRtlSdrPort() async => int.tryParse(await _db.getSetting(_keyRtlSdrPort) ?? '') ?? defaultRtlSdrPort;

  /// Every configured rtl_tcp server. rtl_sdr_host/rtl_sdr_port keep holding
  /// the default one (what the receiver connects to); the list adds the
  /// others. Before the list existed there was only that one server.
  Future<RtlTcpServers> getRtlTcpServers() async {
    final current = RtlTcpServer(host: await getRtlSdrHost(), port: await getRtlSdrPort());
    var servers = <RtlTcpServer>[];
    try {
      final decoded = jsonDecode(await _db.getSetting(_keyRtlTcpServers) ?? '[]');
      if (decoded is List) servers = decoded.map(RtlTcpServer.fromJson).whereType<RtlTcpServer>().toList();
    } catch (_) {}
    var index = servers.indexOf(current);
    if (index < 0) {
      servers.insert(0, current);
      index = 0;
    }
    return RtlTcpServers(servers, index);
  }

  Future<void> setRtlTcpServers(RtlTcpServers value) async {
    await _db.setSetting(_keyRtlTcpServers, jsonEncode([for (final s in value.servers) s.toJson()]));
    await _db.setSetting(_keyRtlSdrHost, value.defaultServer.host);
    await _db.setSetting(_keyRtlSdrPort, '${value.defaultServer.port}');
  }

  /// Removes what earlier versions stored for the rtl_tcp server: the
  /// protocol choice (now negotiated on every connect) and the login
  /// (rtltcp.server and rtl.over.internet do that now, home.radio only
  /// connects inside the local network). Runs on every start - it only
  /// costs a delete when nothing is left, and also cleans up settings that
  /// come back with an old backup.
  Future<void> removeRtlTcpLogin() async {
    await _db.deleteSettings(const ['rtl_tcp_protocol', 'rtl_tcp_login', 'rtl_tcp_user']);
    await _secrets.delete('rtl_tcp_password');
  }

  /// How DAB+ reaches its receiver (see [ReceiverMode]). Unset counts as
  /// [ReceiverMode.tcp], which was the default before "no receiver" existed.
  Future<ReceiverMode> getReceiverMode() async => switch (await _db.getSetting(_keyRtlSdrMode)) {
    'own' => ReceiverMode.usb,
    'none' => ReceiverMode.none,
    _ => ReceiverMode.tcp,
  };

  Future<void> setReceiverMode(ReceiverMode mode) => _db.setSetting(_keyRtlSdrMode, switch (mode) {
    ReceiverMode.usb => 'own',
    ReceiverMode.none => 'none',
    ReceiverMode.tcp => 'external',
  });

  /// Whether DAB+ uses the RTL-SDR stick directly over USB ('own',
  /// "RTL-SDR-USB" on RtlSdrTestScreen) rather than an rtl_tcp server
  /// ('external').
  Future<bool> getRtlSdrAutoStartOwnService() async => await getReceiverMode() == ReceiverMode.usb;

  Future<DabSortMode> getDabSortMode() async => switch (await _db.getSetting(_keyDabSortMode)) {
    'alphabet' => DabSortMode.byAlphabet,
    'grouped' => DabSortMode.groupedByEnsemble,
    _ => DabSortMode.byEnsembleThenAlphabet,
  };

  Future<void> setDabSortMode(DabSortMode mode) => _db.setSetting(_keyDabSortMode, switch (mode) {
    DabSortMode.byAlphabet => 'alphabet',
    DabSortMode.groupedByEnsemble => 'grouped',
    DabSortMode.byEnsembleThenAlphabet => 'ensemble',
  });

  Future<bool> getShowClockDate() async => (await _db.getSetting(_keyShowClockDate)) == 'true';

  Future<void> setShowClockDate(bool value) => _db.setSetting(_keyShowClockDate, '$value');

  /// "Funk anzeigen": the listening bands, aircraft, sensors and band scan
  /// (the top bar's "Funk" window) - off by default, they're for the
  /// curious, not everyday radio. Until it's set, on if one of the former
  /// CB/amateur/military radio toggles was.
  Future<bool> getFunkEnabled() async {
    final value = await _db.getSetting(_keyFunkEnabled);
    if (value != null) return value == 'true';
    for (final key in const [_keyCbEnabled, _keyHamEnabled, _keyMilEnabled]) {
      if (await _db.getSetting(key) == 'true') return true;
    }
    return false;
  }

  Future<void> setFunkEnabled(bool value) => _db.setSetting(_keyFunkEnabled, '$value');

  /// "DAB anzeigen" / "FM anzeigen": the DAB+ resp. FM parts of the app
  /// (station search, sidebar tab) - on by default.
  Future<bool> getDabEnabled() async => (await _db.getSetting(_keyDabEnabled)) != 'false';
  Future<void> setDabEnabled(bool value) => _db.setSetting(_keyDabEnabled, '$value');
  Future<bool> getFmEnabled() async => (await _db.getSetting(_keyFmEnabled)) != 'false';
  Future<void> setFmEnabled(bool value) => _db.setSetting(_keyFmEnabled, '$value');

  /// "LW/MW/KW anzeigen": AM broadcasting on long, medium and short wave as
  /// its own entry in the top bar - on by default.
  Future<bool> getAmEnabled() async => (await _db.getSetting(_keyAmEnabled)) != 'false';
  Future<void> setAmEnabled(bool value) => _db.setSetting(_keyAmEnabled, '$value');

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

  /// Shortwave: LO of an external upconverter in front of the stick (e.g.
  /// 125 MHz for a Ham It Up), 0 = none - then direct sampling or the
  /// RTL-SDR Blog V4's own upconverter.
  static const hfUpconverterChoices = [0, 125000000, 120000000, 100000000];

  Future<int> getHfUpconverterHz() async => int.tryParse(await _db.getSetting('hf_upconverter_hz') ?? '') ?? 0;
  Future<void> setHfUpconverterHz(int hz) => _db.setSetting('hf_upconverter_hz', '$hz');

  /// Install new versions from the update server on start (default on).
  Future<bool> getAutoUpdate() async => (await _db.getSetting(_keyAutoUpdate)) != 'false';
  Future<void> setAutoUpdate(bool value) => _db.setSetting(_keyAutoUpdate, '$value');

  /// Home Assistant over MQTT (see HaMqttLink); the password in the
  /// [SecretStore].
  Future<HaLinkSettings> getHaLink() async => HaLinkSettings(
        enabled: await _db.getSetting('ha_enabled') == 'true',
        host: await _db.getSetting('ha_host') ?? '',
        port: int.tryParse(await _db.getSetting('ha_port') ?? '') ?? HaLinkSettings.defaultPort,
        user: await _db.getSetting('ha_user') ?? '',
        password: await _secrets.read(SecretStore.haMqttPasswordKey) ?? '',
        shareCamera: await _db.getSetting('ha_share_camera') == 'true',
      );

  Future<void> setHaLink(HaLinkSettings value) async {
    await _db.setSetting('ha_enabled', '${value.enabled}');
    await _db.setSetting('ha_host', value.host.trim());
    await _db.setSetting('ha_port', '${value.port}');
    await _db.setSetting('ha_user', value.user.trim());
    await _secrets.write(SecretStore.haMqttPasswordKey, value.password);
    await _db.setSetting('ha_share_camera', '${value.shareCamera}');
  }

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

  Future<void> setNbFilters(
    String band, {
    required int bandwidthHz,
    required bool noiseBlanker,
    required bool voiceFilter,
    required String agc,
  }) => _db.setSetting('nb_filters_$band', '$bandwidthHz|$noiseBlanker|$voiceFilter|$agc');

  /// Tuner gain per listening band: a gain step, -1 = automatic (default).
  Future<int> getNbGain(String band) async => int.tryParse(await _db.getSetting('nb_gain_$band') ?? '') ?? -1;
  Future<void> setNbGain(String band, int gainIndex) => _db.setSetting('nb_gain_$band', '$gainIndex');

  /// ISM sensors: own names and hidden devices (device key -> name, or
  /// [ismHidden]), as "key\tname" lines.
  static const ismHidden = '␀';
  Future<Map<String, String>> getIsmNames() async {
    final raw = await _db.getSetting('ism_names') ?? '';
    return {
      for (final line in raw.split('\n'))
        if (line.contains('\t')) line.substring(0, line.indexOf('\t')): line.substring(line.indexOf('\t') + 1),
    };
  }

  Future<void> setIsmNames(Map<String, String> names) =>
      _db.setSetting('ism_names', names.entries.map((e) => '${e.key}\t${e.value}').join('\n'));

  /// ISM sensors: last frequency (433920000 / 868300000).
  Future<int> getIsmFrequency() async => int.tryParse(await _db.getSetting('ism_freq') ?? '') ?? 433920000;
  Future<void> setIsmFrequency(int hz) => _db.setSetting('ism_freq', '$hz');

  /// ADS-B: a map under the radar picture (default on).
  Future<bool> getAdsbMap() async => (await _db.getSetting('adsb_map')) != 'false';
  Future<void> setAdsbMap(bool value) => _db.setSetting('adsb_map', '$value');

  /// Listening bands: switch modulation and filter width to the band plan's
  /// recommendation when tuning into another part of a band (default on).
  Future<bool> getNbBandPlanAuto() async => (await _db.getSetting('nb_bandplan_auto')) != 'false';
  Future<void> setNbBandPlanAuto(bool value) => _db.setSetting('nb_bandplan_auto', '$value');

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

  // --- Device and setup ---

  /// The device's own name ("Terrassen-Media", "Wohnzimmer-TV") - shown on
  /// the admin page (`http://<ip>:1401/`) and in the backup's file name.
  Future<String> getDeviceName() async => (await _db.getSetting('device_name'))?.trim() ?? '';
  Future<void> setDeviceName(String name) => _db.setSetting('device_name', name.trim());

  /// The setup wizard ran (or a backup was restored). Installations from
  /// before the wizard count as set up as soon as they have any settings -
  /// see [isConfigured].
  Future<void> setSetupDone() => _db.setSetting('setup_done', 'true');

  /// Whether the app is set up - false only on a fresh installation (no
  /// settings and no favorites yet), which then gets the setup wizard.
  Future<bool> isConfigured() async {
    if (await _db.getSetting('setup_done') == 'true') return true;
    final anySetting = await (_db.select(_db.settings)..limit(1)).getSingleOrNull();
    final anyFavorite = await (_db.select(_db.favorites)..limit(1)).getSingleOrNull();
    if (anySetting == null && anyFavorite == null) return false;
    await setSetupDone();
    return true;
  }

  /// Home System's parts Radio and TV can be switched off (System
  /// settings) - their tiles, start options and settings are gone then.
  Future<bool> getRadioEnabled() async => await _db.getSetting('part_radio_enabled') != 'false';
  Future<void> setRadioEnabled(bool value) => _db.setSetting('part_radio_enabled', '$value');
  Future<bool> getTvEnabled() async => await _db.getSetting('part_tv_enabled') != 'false';
  Future<void> setTvEnabled(bool value) => _db.setSetting('part_tv_enabled', '$value');

  /// The Haussteuerung (Home Assistant dashboard) - off until switched on,
  /// most devices don't need it.
  Future<bool> getDashboardEnabled() async => await _db.getSetting('part_dashboard_enabled') == 'true';
  Future<void> setDashboardEnabled(bool value) => _db.setSetting('part_dashboard_enabled', '$value');

  /// Bilder (the NAS's pictures, slideshows) - null while never switched
  /// on or off: then it's on as soon as a NAS pictures folder is chosen
  /// (see SystemPartsNotifier).
  Future<bool?> getPicturesEnabled() async => switch (await _db.getSetting('part_pictures_enabled')) {
        'true' => true,
        'false' => false,
        _ => null,
      };
  Future<void> setPicturesEnabled(bool value) => _db.setSetting('part_pictures_enabled', '$value');

  /// Filme (the NAS's films and videos) - null while never switched on or
  /// off: then it's on as soon as a NAS films or videos folder is chosen.
  Future<bool?> getMoviesEnabled() async => switch (await _db.getSetting('part_movies_enabled')) {
        'true' => true,
        'false' => false,
        _ => null,
      };
  Future<void> setMoviesEnabled(bool value) => _db.setSetting('part_movies_enabled', '$value');

  /// Musik (the NAS's music) - null while never switched on or off: then
  /// it's on as soon as a NAS music folder is chosen.
  Future<bool?> getMusicEnabled() async => switch (await _db.getSetting('part_music_enabled')) {
        'true' => true,
        'false' => false,
        _ => null,
      };
  Future<void> setMusicEnabled(bool value) => _db.setSetting('part_music_enabled', '$value');

  /// The Browser (Android) - on until switched off.
  Future<bool> getBrowserEnabled() async => await _db.getSetting('part_browser_enabled') != 'false';
  Future<void> setBrowserEnabled(bool value) => _db.setSetting('part_browser_enabled', '$value');

  // --- Bilder ---

  /// Seconds a slideshow shows each picture.
  static const slideshowIntervals = [5, 8, 12, 20, 30, 60];
  static const defaultSlideshowInterval = 8;

  Future<SlideshowSettings> getSlideshowSettings() async {
    final interval = int.tryParse(await _db.getSetting('slideshow_interval') ?? '');
    final order = await _db.getSetting('slideshow_order');
    return SlideshowSettings(
      intervalSeconds: slideshowIntervals.contains(interval) ? interval! : defaultSlideshowInterval,
      order: SlideshowOrder.values.firstWhere((o) => o.name == order, orElse: () => SlideshowOrder.folders),
      blurredBackground: await _db.getSetting('slideshow_blur') != 'false',
    );
  }

  Future<void> setSlideshowSettings(SlideshowSettings value) async {
    await _db.setSetting('slideshow_interval', '${value.intervalSeconds}');
    await _db.setSetting('slideshow_order', value.order.name);
    await _db.setSetting('slideshow_blur', '${value.blurredBackground}');
  }

  // --- Haussteuerung ---

  /// The dashboard's address, e.g. http://homeassistant.local:8123/lovelace/0
  Future<String> getDashboardUrl() async => await _db.getSetting('dashboard_url') ?? '';
  Future<void> setDashboardUrl(String value) => _db.setSetting('dashboard_url', value.trim());

  Future<DashboardDisplaySettings> getDashboardDisplay() async => DashboardDisplaySettings(
    motion: await _db.getSetting('motion_enabled') == 'true',
    sensitivity: int.tryParse(await _db.getSetting('motion_sensitivity') ?? '') ?? 5,
    timeoutMinutes: int.tryParse(await _db.getSetting('motion_timeout_min') ?? '') ?? 5,
    webhookUrl: await _db.getSetting('motion_webhook') ?? '',
    dimOnly: await _db.getSetting('motion_dim_only') == 'true',
  );

  Future<DisplayBrightness> getDisplayBrightness() async {
    final mode = await _db.getSetting('brightness_mode');
    return DisplayBrightness(
      mode: BrightnessMode.values.firstWhere((m) => m.name == mode, orElse: () => BrightnessMode.system),
      level: int.tryParse(await _db.getSetting('brightness_level') ?? '') ?? 60,
      min: int.tryParse(await _db.getSetting('brightness_min') ?? '') ?? 10,
      max: int.tryParse(await _db.getSetting('brightness_max') ?? '') ?? 100,
      luxForMax: int.tryParse(await _db.getSetting('brightness_lux_max') ?? '') ?? 100,
    );
  }

  Future<void> setDisplayBrightness(DisplayBrightness value) async {
    await _db.setSetting('brightness_mode', value.mode.name);
    await _db.setSetting('brightness_level', '${value.level}');
    await _db.setSetting('brightness_min', '${value.min}');
    await _db.setSetting('brightness_max', '${value.max}');
    await _db.setSetting('brightness_lux_max', '${value.luxForMax}');
  }

  Future<void> setDashboardDisplay(DashboardDisplaySettings value) async {
    await _db.setSetting('motion_enabled', '${value.motion}');
    await _db.setSetting('motion_sensitivity', '${value.sensitivity}');
    await _db.setSetting('motion_timeout_min', '${value.timeoutMinutes}');
    await _db.setSetting('motion_webhook', value.webhookUrl.trim());
    await _db.setSetting('motion_dim_only', '${value.dimOnly}');
  }

  /// The playback popup over the Haussteuerung (on by default, bottom
  /// centre).
  Future<DashboardPopupSettings> getDashboardPopup() async => DashboardPopupSettings(
    show: await _db.getSetting('dashboard_popup') != 'false',
    position: DashboardPopupPosition.parse(await _db.getSetting('dashboard_popup_position')),
    loaded: true,
  );

  Future<void> setDashboardPopup(DashboardPopupSettings value) async {
    await _db.setSetting('dashboard_popup', '${value.show}');
    await _db.setSetting('dashboard_popup_position', value.position.name);
  }

  /// The remote hint of the playback popup was shown once.
  Future<bool> getDashboardPopupHintShown() async => await _db.getSetting('dashboard_popup_hint') == 'true';
  Future<void> setDashboardPopupHintShown() => _db.setSetting('dashboard_popup_hint', 'true');

  // --- Home (the launcher) ---

  /// What shows on start (see [StartScreen]) - Radio by default, as
  /// before the launcher existed (new setups get Home, see the wizard).
  Future<StartScreen> getStartScreen() async {
    final v = await _db.getSetting('start_screen');
    return StartScreen.values.firstWhere((s) => s.name == v, orElse: () => StartScreen.radio);
  }

  Future<void> setStartScreen(StartScreen value) => _db.setSetting('start_screen', value.name);

  /// The app started with [StartScreen.app] (its package name), '' = none.
  Future<String> getStartApp() async => await _db.getSetting('start_app') ?? '';
  Future<void> setStartApp(String package) => _db.setSetting('start_app', package);

  /// The launcher's row; null until it was first set up (see
  /// LauncherTilesNotifier - then the installed streaming apps go in).
  Future<List<LauncherTile>?> getLauncherTiles() async {
    final raw = await _db.getSetting('launcher_tiles');
    return raw == null ? null : decodeLauncherTiles(raw);
  }

  Future<void> setLauncherTiles(List<LauncherTile> tiles) =>
      _db.setSetting('launcher_tiles', encodeLauncherTiles(tiles));

  /// The launcher's groups - rows of apps under the favourites (see
  /// LauncherGroup); none until the first one is made.
  Future<List<LauncherGroup>> getLauncherGroups() async => decodeLauncherGroups(await _db.getSetting('launcher_groups'));

  Future<void> setLauncherGroups(List<LauncherGroup> groups) =>
      _db.setSetting('launcher_groups', encodeLauncherGroups(groups));

  /// TV's tile was put into an existing row once (rows from before
  /// TV) - afterwards removing it stays removed.
  Future<bool> getLauncherTvAdded() async => await _db.getSetting('launcher_tv_added') == 'true';
  Future<void> setLauncherTvAdded() => _db.setSetting('launcher_tv_added', 'true');

  /// Own tiles were put in front, by media type, once (see ownTilesToFront).
  Future<bool> getLauncherOwnTilesMoved() async => await _db.getSetting('launcher_own_tiles_sorted') == 'true';
  Future<void> setLauncherOwnTilesMoved() => _db.setSetting('launcher_own_tiles_sorted', 'true');

  Future<LauncherBackgroundSource> getLauncherBackgroundSource() async {
    final v = await _db.getSetting('launcher_bg_source');
    return LauncherBackgroundSource.values.firstWhere(
      (s) => s.name == v,
      orElse: () => LauncherBackgroundSource.builtin,
    );
  }

  Future<void> setLauncherBackgroundSource(LauncherBackgroundSource value) =>
      _db.setSetting('launcher_bg_source', value.name);

  /// The own server's address (see LauncherBackgroundService).
  Future<String> getLauncherBackgroundUrl() async => await _db.getSetting('launcher_bg_url') ?? '';
  Future<void> setLauncherBackgroundUrl(String url) => _db.setSetting('launcher_bg_url', url);

  /// Minutes until the next background picture.
  static const launcherBackgroundIntervals = [1, 5, 10, 15, 30, 60];
  static const defaultLauncherBackgroundInterval = 10;

  Future<int> getLauncherBackgroundInterval() async {
    final v = int.tryParse(await _db.getSetting('launcher_bg_interval') ?? '');
    return v != null && launcherBackgroundIntervals.contains(v) ? v : defaultLauncherBackgroundInterval;
  }

  Future<void> setLauncherBackgroundInterval(int minutes) => _db.setSetting('launcher_bg_interval', '$minutes');

  /// How solid the band behind the launcher's tiles is (0 = none).
  static const launcherBandOpacities = [0.0, 0.2, 0.4, 0.6, 0.8];
  static const defaultLauncherBandOpacity = 0.4;

  Future<double> getLauncherBandOpacity() async =>
      double.tryParse(await _db.getSetting('launcher_band_opacity') ?? '') ?? defaultLauncherBandOpacity;
  Future<void> setLauncherBandOpacity(double value) => _db.setSetting('launcher_band_opacity', '$value');

  /// The icon pack for app tiles (package), null = none.
  Future<String?> getLauncherIconPack() async {
    final v = await _db.getSetting('launcher_icon_pack');
    return v == null || v.isEmpty ? null : v;
  }

  Future<void> setLauncherIconPack(String? package) => _db.setSetting('launcher_icon_pack', package ?? '');

  // --- TV (Enigma2 receiver) ---

  /// The receiver; its password is kept in the [SecretStore].
  Future<Enigma2Config> getEnigma2Config() async {
    Object? json;
    try {
      json = jsonDecode(await _db.getSetting('enigma2') ?? 'null');
    } catch (_) {}
    return Enigma2Config.fromJson(json, password: await _secrets.read(SecretStore.enigma2PasswordKey) ?? '');
  }

  Future<void> setEnigma2Config(Enigma2Config config) async {
    await _db.setSetting('enigma2', jsonEncode(config.toJson()));
    await _secrets.write(SecretStore.enigma2PasswordKey, config.password);
  }

  /// The bouquet TV shows (service reference).
  Future<String?> getTvBouquet() => _db.getSetting('tv_bouquet');
  Future<void> setTvBouquet(String ref) => _db.setSetting('tv_bouquet', ref);

  /// The channel TV always starts with (service reference); null = the
  /// one last watched.
  Future<String?> getTvStartChannel() async {
    final v = await _db.getSetting('tv_start_channel');
    return v == null || v.isEmpty ? null : v;
  }

  Future<void> setTvStartChannel(String? ref) => _db.setSetting('tv_start_channel', ref ?? '');

  /// TV's "Als Nächstes" note: on/off, how many minutes before the next
  /// programme, and for how many seconds it shows.
  static const tvNextLeadChoices = [1, 2, 5, 10, 15];
  static const tvNextShowChoices = [10, 20, 30, 60];

  Future<({bool enabled, int leadMinutes, int showSeconds})> getTvNextUp() async {
    final lead = int.tryParse(await _db.getSetting('tv_next_lead') ?? '');
    final show = int.tryParse(await _db.getSetting('tv_next_show') ?? '');
    return (
      enabled: await _db.getSetting('tv_next_enabled') != 'false',
      leadMinutes: tvNextLeadChoices.contains(lead) ? lead! : 5,
      showSeconds: tvNextShowChoices.contains(show) ? show! : 30,
    );
  }

  Future<void> setTvNextUp({required bool enabled, required int leadMinutes, required int showSeconds}) async {
    await _db.setSetting('tv_next_enabled', '$enabled');
    await _db.setSetting('tv_next_lead', '$leadMinutes');
    await _db.setSetting('tv_next_show', '$showSeconds');
  }

  /// Programmes marked in the guide (TvReminder, as JSON).
  Future<List<TvReminder>> getTvReminders() async {
    try {
      final list = jsonDecode(await _db.getSetting('tv_reminders') ?? '[]');
      if (list is! List) return const [];
      return [for (final j in list) ?TvReminder.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> setTvReminders(List<TvReminder> reminders) =>
      _db.setSetting('tv_reminders', jsonEncode([for (final r in reminders) r.toJson()]));

  /// How long before a marked programme the note shows (minutes).
  static const tvReminderLeadChoices = [1, 2, 3, 5, 10];

  Future<int> getTvReminderLead() async {
    final v = int.tryParse(await _db.getSetting('tv_reminder_lead') ?? '');
    return tvReminderLeadChoices.contains(v) ? v! : 2;
  }

  Future<void> setTvReminderLead(int minutes) => _db.setSetting('tv_reminder_lead', '$minutes');

  /// Encrypted channels: switch the receiver itself to them first (its CI
  /// module / card descrambles only the channel it shows). On by default.
  Future<bool> getTvZapEncrypted() async => await _db.getSetting('tv_zap_encrypted') != 'false';
  Future<void> setTvZapEncrypted(bool value) => _db.setSetting('tv_zap_encrypted', '$value');

  /// The remote's keys per action (see RemoteKeys): action name -> logical
  /// key ids; an action not in there has its standard keys.
  Future<Map<String, List<int>>> getRemoteKeys() async {
    try {
      final map = jsonDecode(await _db.getSetting('remote_keys') ?? '{}') as Map<String, dynamic>;
      return {
        for (final e in map.entries) e.key: [for (final k in e.value as List) k as int],
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> setRemoteKeys(Map<String, List<int>> keys) => _db.setSetting('remote_keys', jsonEncode(keys));

  /// Channels (service references) whose stream came scrambled - TV
  /// switches the receiver to them right away.
  Future<Set<String>> getTvEncryptedChannels() async {
    try {
      final list = jsonDecode(await _db.getSetting('tv_encrypted_channels') ?? '[]');
      return {for (final e in list as List) '$e'};
    } catch (_) {
      return {};
    }
  }

  Future<void> setTvEncryptedChannels(Set<String> refs) =>
      _db.setSetting('tv_encrypted_channels', jsonEncode(refs.toList()));

  /// The channel last watched (service reference) - TV starts with it.
  Future<String?> getTvLastChannel() => _db.getSetting('tv_last_channel');
  Future<void> setTvLastChannel(String ref) => _db.setSetting('tv_last_channel', ref);
}

/// Bilder: how a slideshow runs (Einstellungen → Bilder).
class SlideshowSettings {
  const SlideshowSettings({
    this.intervalSeconds = SettingsRepository.defaultSlideshowInterval,
    this.order = SlideshowOrder.folders,
    this.blurredBackground = true,
  });

  /// Seconds per picture, one of [SettingsRepository.slideshowIntervals].
  final int intervalSeconds;
  final SlideshowOrder order;

  /// The free space beside a picture shows it once more, blurred and
  /// darkened (from a tiny copy - cheap, also on the Fire TV Stick).
  final bool blurredBackground;

  SlideshowSettings copyWith({int? intervalSeconds, SlideshowOrder? order, bool? blurredBackground}) =>
      SlideshowSettings(
        intervalSeconds: intervalSeconds ?? this.intervalSeconds,
        order: order ?? this.order,
        blurredBackground: blurredBackground ?? this.blurredBackground,
      );
}

/// The Haussteuerung's display: on/off by motion in front of the camera.
class DashboardDisplaySettings {
  const DashboardDisplaySettings({
    this.motion = false,
    this.sensitivity = 5,
    this.timeoutMinutes = 5,
    this.webhookUrl = '',
    this.dimOnly = false,
  });

  /// Display by motion (camera) on.
  final bool motion;

  /// 1 (only big movements) .. 10 (the slightest).
  final int sensitivity;

  /// Display off after this long without motion (0 = never).
  final int timeoutMinutes;

  /// Home Assistant webhook for motion on/off, '' = none.
  final String webhookUrl;

  /// "Off" only darkens the display (black, lowest brightness - the
  /// backlight stays on) instead of switching it off. For devices where the
  /// accessibility service can't switch it off; otherwise really off is
  /// better (a lock screen without PIN is swiped away when it comes back).
  final bool dimOnly;

  DashboardDisplaySettings copyWith({
    bool? motion,
    int? sensitivity,
    int? timeoutMinutes,
    String? webhookUrl,
    bool? dimOnly,
  }) => DashboardDisplaySettings(
    motion: motion ?? this.motion,
    sensitivity: sensitivity ?? this.sensitivity,
    timeoutMinutes: timeoutMinutes ?? this.timeoutMinutes,
    webhookUrl: webhookUrl ?? this.webhookUrl,
    dimOnly: dimOnly ?? this.dimOnly,
  );
}

/// Where the playback popup sits over the Haussteuerung.
enum DashboardPopupPosition {
  bottomCenter,
  bottomLeft,
  bottomRight,
  topCenter,
  topLeft,
  topRight;

  /// At the top edge (else at the bottom).
  bool get atTop => this == topCenter || this == topLeft || this == topRight;

  /// The saved name; unknown or none: [bottomCenter].
  static DashboardPopupPosition parse(String? name) =>
      values.where((p) => p.name == name).firstOrNull ?? DashboardPopupPosition.bottomCenter;
}

/// The playback popup over the Haussteuerung: Home, and while radio or
/// music plays what plays and its controls.
class DashboardPopupSettings {
  const DashboardPopupSettings({
    this.show = true,
    this.position = DashboardPopupPosition.bottomCenter,
    this.loaded = false,
  });

  final bool show;
  final DashboardPopupPosition position;

  /// Read from the database (until then the popup waits, so that a switched
  /// off one doesn't flash up).
  final bool loaded;

  DashboardPopupSettings copyWith({bool? show, DashboardPopupPosition? position}) =>
      DashboardPopupSettings(show: show ?? this.show, position: position ?? this.position, loaded: true);
}

/// The display's brightness (Haussteuerung, wall tablets): Android's own,
/// fixed, or from the light sensor between [min] and [max] (%), full from
/// [luxForMax] on - see BrightnessController.kt.
enum BrightnessMode { system, fixed, adaptive }

class DisplayBrightness {
  const DisplayBrightness({
    this.mode = BrightnessMode.system,
    this.level = 60,
    this.min = 10,
    this.max = 100,
    this.luxForMax = 100,
  });

  final BrightnessMode mode;

  /// Percent, [BrightnessMode.fixed].
  final int level;

  /// Percent, [BrightnessMode.adaptive].
  final int min;
  final int max;
  final int luxForMax;

  DisplayBrightness copyWith({BrightnessMode? mode, int? level, int? min, int? max, int? luxForMax}) =>
      DisplayBrightness(
        mode: mode ?? this.mode,
        level: level ?? this.level,
        min: min ?? this.min,
        max: max ?? this.max,
        luxForMax: luxForMax ?? this.luxForMax,
      );
}

/// The link to Home Assistant over MQTT (Settings → System → Home
/// Assistant): the broker - usually the Mosquitto add-on on the Home
/// Assistant machine - and its login (a Home Assistant user works there).
class HaLinkSettings {
  const HaLinkSettings({
    this.enabled = false,
    this.host = '',
    this.port = defaultPort,
    this.user = '',
    this.password = '',
    this.shareCamera = false,
  });

  static const defaultPort = 1883;

  final bool enabled;

  /// '' = the Haussteuerung's Home Assistant address.
  final String host;
  final int port;
  /// The Home Assistant login - for the broker (Mosquitto takes Home
  /// Assistant users) and for logging in to the dashboard by itself.
  final String user;
  final String password;

  /// The camera's picture as a camera in Home Assistant (while
  /// display-by-motion runs).
  final bool shareCamera;

  HaLinkSettings copyWith({bool? enabled, String? host, int? port, String? user, String? password, bool? shareCamera}) =>
      HaLinkSettings(
        enabled: enabled ?? this.enabled,
        host: host ?? this.host,
        port: port ?? this.port,
        user: user ?? this.user,
        password: password ?? this.password,
        shareCamera: shareCamera ?? this.shareCamera,
      );

  @override
  bool operator ==(Object other) =>
      other is HaLinkSettings &&
      other.enabled == enabled &&
      other.host == host &&
      other.port == port &&
      other.user == user &&
      other.password == password &&
      other.shareCamera == shareCamera;

  @override
  int get hashCode => Object.hash(enabled, host, port, user, password, shareCamera);
}
