import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/models/favorite_channel.dart';
import '../data/repositories/dab_stations_repository.dart';
import '../data/repositories/favorites_repository.dart';
import '../data/repositories/fm_stations_repository.dart';
import '../data/repositories/settings_repository.dart' show DabSortMode, ReceiverMode, SettingsRepository;
import '../data/services/audio_player_service.dart';
import '../data/services/backup_service.dart';
import '../data/services/dab_rtlsdr_service.dart';
import '../data/services/radio_audio_handler.dart';
import '../data/services/radio_browser_api_service.dart';
import '../data/services/rtl_sdr_service.dart';
import '../data/services/rtl_sdr_usb_service.dart';
import '../data/services/update_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final favoritesRepositoryProvider = Provider<FavoritesRepository>((ref) {
  return FavoritesRepository(ref.watch(databaseProvider));
});

final dabStationsRepositoryProvider = Provider<DabStationsRepository>((ref) {
  return DabStationsRepository(ref.watch(databaseProvider));
});

final dabStationsStreamProvider = StreamProvider<List<DabStation>>((ref) {
  return ref.watch(dabStationsRepositoryProvider).watchAll();
});

final fmStationsRepositoryProvider = Provider<FmStationsRepository>((ref) {
  return FmStationsRepository(ref.watch(databaseProvider));
});

/// All saved FM stations, by frequency.
final fmStationsStreamProvider = StreamProvider<List<FmStation>>((ref) {
  return ref.watch(fmStationsRepositoryProvider).watchAll();
});

/// The FM station (kHz) currently played straight from the sidebar's FM tab
/// - the FM counterpart of [currentDabStationProvider]; mutually exclusive
/// with it and with [currentProgramNumberProvider].
class CurrentFmStation extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? freqKhz) => state = freqKhz;
}

final currentFmStationProvider = NotifierProvider<CurrentFmStation, int?>(CurrentFmStation.new);

/// What another screen wants played - playback itself lives in HomeScreen,
/// which stays mounted underneath pushed screens and acts on this (e.g. the
/// "Anhören" buttons of the DAB+/FM station lists). Exactly one is set.
typedef PlayRequest = ({FavoriteChannel? favorite, DabStation? dab, FmStation? fm});

class PlayRequestNotifier extends Notifier<PlayRequest?> {
  @override
  PlayRequest? build() => null;

  void favorite(FavoriteChannel channel) => state = (favorite: channel, dab: null, fm: null);
  void dab(DabStation station) => state = (favorite: null, dab: station, fm: null);
  void fm(FmStation station) => state = (favorite: null, dab: null, fm: station);
  void clear() => state = null;
}

final playRequestProvider = NotifierProvider<PlayRequestNotifier, PlayRequest?>(PlayRequestNotifier.new);

/// Set while a screen has taken the receiver over on its own (scan, manual
/// FM tuning, logo capture) - HomeScreen then tunes its station in again
/// once back. Not set by plain playback via [playRequestProvider].
class ReceiverInterrupted extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final receiverInterruptedProvider = NotifierProvider<ReceiverInterrupted, bool>(ReceiverInterrupted.new);

/// The current DAB+ station's live slideshow image (a local file), null if
/// none - offered as "Aktuelles Senderbild übernehmen" when editing that
/// station from the home screen.
class LiveStationImage extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? path) => state = path;
}

final liveStationImageProvider = NotifierProvider<LiveStationImage, String?>(LiveStationImage.new);

/// While set, the remote's next/previous and channel keys step through
/// this instead of the radio stations - a listening band's channels while
/// its ScannerScreen is open. Those keys reach the app through Android's
/// media session, which HomeScreen owns regardless of the open screen.
class RemoteStepOverride extends Notifier<void Function(int direction)?> {
  @override
  void Function(int direction)? build() => null;

  void set(void Function(int direction)? step) => state = step;
}

final remoteStepOverrideProvider =
    NotifierProvider<RemoteStepOverride, void Function(int direction)?>(RemoteStepOverride.new);

class DabSortModeNotifier extends Notifier<DabSortMode> {
  @override
  DabSortMode build() {
    final repo = ref.watch(settingsRepositoryProvider);
    repo.getDabSortMode().then((v) => state = v);
    return DabSortMode.byEnsembleThenAlphabet;
  }

  Future<void> set(DabSortMode mode) async {
    state = mode;
    await ref.read(settingsRepositoryProvider).setDabSortMode(mode);
  }
}

final dabSortModeProvider = NotifierProvider<DabSortModeNotifier, DabSortMode>(DabSortModeNotifier.new);

/// Whether the top bar's clock also shows the current weekday+date next to
/// the time (see _Clock in home_screen.dart).
class ShowClockDateNotifier extends Notifier<bool> {
  @override
  bool build() {
    final repo = ref.watch(settingsRepositoryProvider);
    repo.getShowClockDate().then((v) => state = v);
    return false;
  }

  Future<void> set(bool value) async {
    state = value;
    await ref.read(settingsRepositoryProvider).setShowClockDate(value);
  }
}

final showClockDateProvider = NotifierProvider<ShowClockDateNotifier, bool>(ShowClockDateNotifier.new);

/// Which extra listening bands are switched on in the settings (CB radio,
/// airband) - each gets a button in the top bar.
typedef ListeningBands = ({bool cb, bool ham, bool airband, bool mil});

class ListeningBandsNotifier extends Notifier<ListeningBands> {
  @override
  ListeningBands build() {
    final repo = ref.watch(settingsRepositoryProvider);
    () async {
      state = (
        cb: await repo.getCbEnabled(),
        ham: await repo.getHamEnabled(),
        airband: await repo.getAirbandEnabled(),
        mil: await repo.getMilEnabled(),
      );
    }();
    return (cb: false, ham: false, airband: false, mil: false);
  }

  SettingsRepository get _repo => ref.read(settingsRepositoryProvider);

  Future<void> setCb(bool value) async {
    state = (cb: value, ham: state.ham, airband: state.airband, mil: state.mil);
    await _repo.setCbEnabled(value);
  }

  Future<void> setHam(bool value) async {
    state = (cb: state.cb, ham: value, airband: state.airband, mil: state.mil);
    await _repo.setHamEnabled(value);
  }

  Future<void> setAirband(bool value) async {
    state = (cb: state.cb, ham: state.ham, airband: value, mil: state.mil);
    await _repo.setAirbandEnabled(value);
  }

  Future<void> setMil(bool value) async {
    state = (cb: state.cb, ham: state.ham, airband: state.airband, mil: value);
    await _repo.setMilEnabled(value);
  }
}

final listeningBandsProvider = NotifierProvider<ListeningBandsNotifier, ListeningBands>(ListeningBandsNotifier.new);

/// [dabStationsStreamProvider], sorted per [dabSortModeProvider] - what
/// FavoritesSidebar's DAB-Sender tab and DabStationsScreen actually display,
/// so both stay consistent with each other and with the user's setting.
final sortedDabStationsProvider = Provider<AsyncValue<List<DabStation>>>((ref) {
  final sortMode = ref.watch(dabSortModeProvider);
  final stationsAsync = ref.watch(dabStationsStreamProvider);
  return stationsAsync.whenData((stations) => sortDabStations(stations, sortMode));
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  final repo = SettingsRepository(ref.watch(databaseProvider));
  // Leftovers of the rtl_tcp login from earlier versions.
  repo.removeRtlTcpLogin().catchError((Object e) => debugPrint('removeRtlTcpLogin: $e'));
  return repo;
});

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(ref.watch(databaseProvider));
});

final updateServiceProvider = Provider<UpdateService>((ref) => UpdateService());

final radioBrowserApiServiceProvider = Provider<RadioBrowserApiService>((ref) {
  return RadioBrowserApiService();
});

final audioPlayerServiceProvider = Provider<AudioPlayerService>((ref) {
  final service = AudioPlayerService();
  ref.onDispose(service.dispose);
  return service;
});

/// Lazily calls `AudioService.init` on first read rather than blocking
/// `runApp` in `main()` on it - registering the Android MediaSession/
/// notification involves starting a foreground service, which is slow
/// enough on this TV to noticeably delay the very first Flutter frame (and
/// therefore how long the native launch screen stays up) if awaited first.
/// Windows/Linux have no media session for audio_service - the handler then
/// works on its own.
final radioAudioHandlerProvider = FutureProvider<RadioAudioHandler>((ref) async {
  final player = ref.watch(audioPlayerServiceProvider);
  if (!Platform.isAndroid) return RadioAudioHandler(player);
  return AudioService.init(
    builder: () => RadioAudioHandler(player),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'at.jaycloud.home.radio.audio',
      androidNotificationChannelName: 'Home Radio Wiedergabe',
      androidNotificationOngoing: true,
    ),
  );
});

final dabRtlSdrServiceProvider = Provider<DabRtlSdrService>((ref) {
  final service = DabRtlSdrService();
  ref.onDispose(service.dispose);
  return service;
});

final rtlSdrServiceProvider = Provider<RtlSdrService>((ref) {
  final service = RtlSdrService();
  ref.onDispose(service.dispose);
  return service;
});

final rtlSdrUsbServiceProvider = Provider<RtlSdrUsbService>((ref) {
  final service = RtlSdrUsbService();
  ref.onDispose(service.dispose);
  return service;
});

final favoritesStreamProvider = StreamProvider<List<FavoriteChannel>>((ref) {
  return ref.watch(favoritesRepositoryProvider).watchFavorites();
});

/// The currently tuned favorite program number (null = nothing playing).
class CurrentProgramNumber extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? programNumber) => state = programNumber;
}

final currentProgramNumberProvider = NotifierProvider<CurrentProgramNumber, int?>(CurrentProgramNumber.new);

/// How DAB+ reaches its receiver (see [ReceiverMode]), reactive so choosing
/// "Kein Empfänger" hides the DAB+ parts of the home screen right away.
/// Starts as [ReceiverMode.tcp] (the stored default) until loaded.
class ReceiverModeNotifier extends Notifier<ReceiverMode> {
  @override
  ReceiverMode build() {
    final repo = ref.watch(settingsRepositoryProvider);
    repo.getReceiverMode().then((mode) => state = mode);
    return ReceiverMode.tcp;
  }

  Future<void> set(ReceiverMode mode) async {
    state = mode;
    await ref.read(settingsRepositoryProvider).setReceiverMode(mode);
  }
}

final receiverModeProvider = NotifierProvider<ReceiverModeNotifier, ReceiverMode>(ReceiverModeNotifier.new);

enum SidebarCategory { favorites, dabStations, fmStations }

/// The user's explicit tab choice in FavoritesSidebar, if they've made one -
/// null means "follow whatever's currently playing" (see
/// [effectiveSidebarCategoryProvider]). Shared here rather than kept as that
/// widget's private State since HomeScreen's remote-control channel-up/down
/// handling needs to know which list "next/previous station" steps through,
/// same as the sidebar itself.
class SidebarCategoryNotifier extends Notifier<SidebarCategory?> {
  @override
  SidebarCategory? build() => null;

  void set(SidebarCategory? category) => state = category;
}

final sidebarCategoryProvider = NotifierProvider<SidebarCategoryNotifier, SidebarCategory?>(
  SidebarCategoryNotifier.new,
);

/// The tab actually shown/stepped-through right now: the user's explicit
/// choice if any, otherwise whichever list the currently playing station
/// came from - currentDabStationProvider is only ever non-null for a
/// station played straight from the DAB-Sender tab (a favorite match uses
/// currentProgramNumberProvider instead), including by autostart restoring
/// last session's pick before the user has touched either tab.
final effectiveSidebarCategoryProvider = Provider<SidebarCategory>((ref) {
  // Without a receiver there are no DAB+/FM tabs at all.
  if (ref.watch(receiverModeProvider) == ReceiverMode.none) return SidebarCategory.favorites;
  final manual = ref.watch(sidebarCategoryProvider);
  if (manual != null) return manual;
  if (ref.watch(currentDabStationProvider) != null) return SidebarCategory.dabStations;
  if (ref.watch(currentFmStationProvider) != null) return SidebarCategory.fmStations;
  return SidebarCategory.favorites;
});

/// The DAB+ station currently tuned via the sidebar's "DAB-Sender" category
/// (see FavoritesSidebar) - i.e. played directly, without being a favorite
/// and therefore without a program number of its own. Mutually exclusive
/// with [currentProgramNumberProvider]: playing one clears the other.
class CurrentDabStation extends Notifier<({int freqKhz, int serviceId})?> {
  @override
  ({int freqKhz, int serviceId})? build() => null;

  void set(({int freqKhz, int serviceId})? value) => state = value;
}

final currentDabStationProvider = NotifierProvider<CurrentDabStation, ({int freqKhz, int serviceId})?>(
  CurrentDabStation.new,
);

/// Global UI scale factor (1.0 = 100%), persisted and applied app-wide via a
/// MediaQuery/Transform wrapper in [HomeRadioApp] so every screen respects
/// the user's chosen size without each widget needing its own scaling logic.
class UiScale extends Notifier<double> {
  @override
  double build() {
    final repo = ref.watch(settingsRepositoryProvider);
    // Kick off the async load; the synchronous initial value is the default
    // until it resolves, avoiding a flash of unscaled content in most cases.
    repo.getUiScale().then((v) => state = v);
    return SettingsRepository.defaultUiScale;
  }

  Future<void> set(double scale) async {
    state = scale;
    await ref.read(settingsRepositoryProvider).setUiScale(scale);
  }
}

final uiScaleProvider = NotifierProvider<UiScale, double>(UiScale.new);

class WeatherDisplaySettings {
  const WeatherDisplaySettings({
    required this.weatherEnabled,
    required this.radarEnabled,
    required this.lat,
    required this.lon,
    required this.locationName,
    required this.weatherScale,
    required this.weatherContentScale,
    required this.weatherSpanTwoTiles,
    required this.radarScale,
    required this.radarRadiusKm,
    required this.radarDimming,
    required this.radarUrl,
    required this.radarIsWebPage,
    required this.radarWebCss,
    required this.radarAuthEnabled,
    required this.radarToken,
    required this.sunEnabled,
    required this.sunScale,
  });

  final bool weatherEnabled;
  final bool radarEnabled;
  final double lat;
  final double lon;
  final String locationName;
  final double weatherScale;
  // Independent of weatherScale (the tile's own box size) - scales the
  // forecast content within it instead, so the tile size and how
  // large/dense its content looks can be tuned separately. See
  // SettingsRepository.getWeatherContentScale's own doc comment.
  final double weatherContentScale;
  // Whether the weather tile spans the full height of radar+sun stacked
  // next to it, or is just a single normal-height tile itself - see
  // SettingsRepository.getWeatherSpanTwoTiles's own doc comment.
  final bool weatherSpanTwoTiles;
  final double radarScale;
  // How much of the map the radar shows - see SettingsRepository.getRadarRadiusKm.
  final int radarRadiusKm;
  final double radarDimming;
  // The radar image's source - see SettingsRepository.getRadarUrl.
  final String radarUrl;
  final bool radarIsWebPage;
  final String radarWebCss;
  final bool radarAuthEnabled;
  final String radarToken;
  final bool sunEnabled;
  final double sunScale;

  WeatherDisplaySettings copyWith({
    bool? weatherEnabled,
    bool? radarEnabled,
    double? lat,
    double? lon,
    String? locationName,
    double? weatherScale,
    double? weatherContentScale,
    bool? weatherSpanTwoTiles,
    double? radarScale,
    int? radarRadiusKm,
    double? radarDimming,
    String? radarUrl,
    bool? radarIsWebPage,
    String? radarWebCss,
    bool? radarAuthEnabled,
    String? radarToken,
    bool? sunEnabled,
    double? sunScale,
  }) {
    return WeatherDisplaySettings(
      weatherEnabled: weatherEnabled ?? this.weatherEnabled,
      radarEnabled: radarEnabled ?? this.radarEnabled,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      locationName: locationName ?? this.locationName,
      weatherScale: weatherScale ?? this.weatherScale,
      weatherContentScale: weatherContentScale ?? this.weatherContentScale,
      weatherSpanTwoTiles: weatherSpanTwoTiles ?? this.weatherSpanTwoTiles,
      radarScale: radarScale ?? this.radarScale,
      radarRadiusKm: radarRadiusKm ?? this.radarRadiusKm,
      radarDimming: radarDimming ?? this.radarDimming,
      radarUrl: radarUrl ?? this.radarUrl,
      radarIsWebPage: radarIsWebPage ?? this.radarIsWebPage,
      radarWebCss: radarWebCss ?? this.radarWebCss,
      radarAuthEnabled: radarAuthEnabled ?? this.radarAuthEnabled,
      radarToken: radarToken ?? this.radarToken,
      sunEnabled: sunEnabled ?? this.sunEnabled,
      sunScale: sunScale ?? this.sunScale,
    );
  }
}

/// Weather/radar visibility, location and tile size, reactive so
/// [SettingsScreen] changes show up on [HomeScreen] immediately without
/// needing an app restart. Tile sizes are a scale factor on top of a base
/// size (see WeatherPanel/RadarPanel) - combined with the app-wide UI scale
/// (see HomeRadioApp), this is what keeps the tiles reasonable from a 22"
/// to a 65" screen: the base size assumes a typical TV viewing distance,
/// the two scale factors are for the user's own fine-tuning on top of that.
class WeatherDisplaySettingsNotifier extends Notifier<WeatherDisplaySettings> {
  @override
  WeatherDisplaySettings build() {
    final repo = ref.watch(settingsRepositoryProvider);
    _load(repo);
    return WeatherDisplaySettings(
      weatherEnabled: true,
      radarEnabled: true,
      lat: SettingsRepository.defaultLat,
      lon: SettingsRepository.defaultLon,
      locationName: SettingsRepository.defaultLocationName,
      weatherScale: SettingsRepository.defaultTileScale,
      weatherContentScale: SettingsRepository.defaultTileScale,
      weatherSpanTwoTiles: true,
      radarScale: SettingsRepository.defaultTileScale,
      radarRadiusKm: SettingsRepository.defaultRadarRadiusKm,
      radarDimming: SettingsRepository.defaultRadarDimming,
      radarUrl: '',
      radarIsWebPage: false,
      radarWebCss: '',
      radarAuthEnabled: false,
      radarToken: '',
      sunEnabled: true,
      sunScale: SettingsRepository.defaultTileScale,
    );
  }

  Future<void> _load(SettingsRepository repo) async {
    state = WeatherDisplaySettings(
      weatherEnabled: await repo.getWeatherEnabled(),
      radarEnabled: await repo.getRadarEnabled(),
      lat: await repo.getWeatherLat(),
      lon: await repo.getWeatherLon(),
      locationName: await repo.getWeatherLocationName(),
      weatherScale: await repo.getWeatherTileScale(),
      weatherContentScale: await repo.getWeatherContentScale(),
      weatherSpanTwoTiles: await repo.getWeatherSpanTwoTiles(),
      radarScale: await repo.getRadarTileScale(),
      radarRadiusKm: await repo.getRadarRadiusKm(),
      sunEnabled: await repo.getSunEnabled(),
      sunScale: await repo.getSunTileScale(),
      radarDimming: await repo.getRadarDimming(),
      radarUrl: await repo.getRadarUrl(),
      radarIsWebPage: await repo.getRadarIsWebPage(),
      radarWebCss: await repo.getRadarWebCss(),
      radarAuthEnabled: await repo.getRadarAuthEnabled(),
      radarToken: await repo.getRadarToken(),
    );
  }


  Future<void> setWeatherEnabled(bool enabled) async {
    state = state.copyWith(weatherEnabled: enabled);
    await ref.read(settingsRepositoryProvider).setWeatherEnabled(enabled);
  }

  Future<void> setRadarEnabled(bool enabled) async {
    state = state.copyWith(radarEnabled: enabled);
    await ref.read(settingsRepositoryProvider).setRadarEnabled(enabled);
  }

  Future<void> setLocation(double lat, double lon, String name) async {
    state = state.copyWith(lat: lat, lon: lon, locationName: name);
    await ref.read(settingsRepositoryProvider).setWeatherLocation(lat, lon, name);
  }

  Future<void> setWeatherScale(double scale) async {
    state = state.copyWith(weatherScale: scale);
    await ref.read(settingsRepositoryProvider).setWeatherTileScale(scale);
  }

  Future<void> setWeatherContentScale(double scale) async {
    state = state.copyWith(weatherContentScale: scale);
    await ref.read(settingsRepositoryProvider).setWeatherContentScale(scale);
  }

  Future<void> setWeatherSpanTwoTiles(bool span) async {
    state = state.copyWith(weatherSpanTwoTiles: span);
    await ref.read(settingsRepositoryProvider).setWeatherSpanTwoTiles(span);
  }

  Future<void> setRadarScale(double scale) async {
    state = state.copyWith(radarScale: scale);
    await ref.read(settingsRepositoryProvider).setRadarTileScale(scale);
  }

  Future<void> setRadarRadiusKm(int km) async {
    state = state.copyWith(radarRadiusKm: km);
    await ref.read(settingsRepositoryProvider).setRadarRadiusKm(km);
  }

  Future<void> setRadarDimming(double dimming) async {
    state = state.copyWith(radarDimming: dimming);
    await ref.read(settingsRepositoryProvider).setRadarDimming(dimming);
  }

  Future<void> setRadarSource({
    required String url,
    required bool isWebPage,
    required String webCss,
    required bool authEnabled,
    required String token,
  }) async {
    state = state.copyWith(
      radarUrl: url,
      radarIsWebPage: isWebPage,
      radarWebCss: webCss,
      radarAuthEnabled: authEnabled,
      radarToken: token,
    );
    await ref
        .read(settingsRepositoryProvider)
        .setRadarSource(url: url, isWebPage: isWebPage, webCss: webCss, authEnabled: authEnabled, token: token);
  }

  Future<void> setSunEnabled(bool enabled) async {
    state = state.copyWith(sunEnabled: enabled);
    await ref.read(settingsRepositoryProvider).setSunEnabled(enabled);
  }

  Future<void> setSunScale(double scale) async {
    state = state.copyWith(sunScale: scale);
    await ref.read(settingsRepositoryProvider).setSunTileScale(scale);
  }
}

final weatherDisplaySettingsProvider = NotifierProvider<WeatherDisplaySettingsNotifier, WeatherDisplaySettings>(
  WeatherDisplaySettingsNotifier.new,
);
