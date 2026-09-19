import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/models/favorite_channel.dart';
import '../data/repositories/dab_stations_repository.dart';
import '../data/repositories/favorites_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/services/audio_player_service.dart';
import '../data/services/dab_rtlsdr_service.dart';
import '../data/services/dab_usb_service.dart';
import '../data/services/radio_audio_handler.dart';
import '../data/services/radio_browser_api_service.dart';
import '../data/services/rtl_sdr_service.dart';
import '../data/services/rtl_sdr_usb_service.dart';

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

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(databaseProvider));
});

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
final radioAudioHandlerProvider = FutureProvider<RadioAudioHandler>((ref) async {
  final player = ref.watch(audioPlayerServiceProvider);
  return AudioService.init(
    builder: () => RadioAudioHandler(player),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'org.lotzapp.home_radio.audio',
      androidNotificationChannelName: 'Home Radio Wiedergabe',
      androidNotificationOngoing: true,
    ),
  );
});

final dabUsbServiceProvider = Provider<DabUsbService>((ref) {
  final service = DabUsbService();
  ref.onDispose(service.dispose);
  return service;
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

final currentProgramNumberProvider =
    NotifierProvider<CurrentProgramNumber, int?>(CurrentProgramNumber.new);

/// The DAB+ station currently tuned via the sidebar's "DAB-Sender" category
/// (see FavoritesSidebar) - i.e. played directly, without being a favorite
/// and therefore without a program number of its own. Mutually exclusive
/// with [currentProgramNumberProvider]: playing one clears the other.
class CurrentDabStation extends Notifier<({int freqKhz, int serviceId})?> {
  @override
  ({int freqKhz, int serviceId})? build() => null;

  void set(({int freqKhz, int serviceId})? value) => state = value;
}

final currentDabStationProvider =
    NotifierProvider<CurrentDabStation, ({int freqKhz, int serviceId})?>(CurrentDabStation.new);

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
    required this.radarScale,
    required this.radarDimming,
  });

  final bool weatherEnabled;
  final bool radarEnabled;
  final double lat;
  final double lon;
  final String locationName;
  final double weatherScale;
  final double radarScale;
  final double radarDimming;

  WeatherDisplaySettings copyWith({
    bool? weatherEnabled,
    bool? radarEnabled,
    double? lat,
    double? lon,
    String? locationName,
    double? weatherScale,
    double? radarScale,
    double? radarDimming,
  }) {
    return WeatherDisplaySettings(
      weatherEnabled: weatherEnabled ?? this.weatherEnabled,
      radarEnabled: radarEnabled ?? this.radarEnabled,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      locationName: locationName ?? this.locationName,
      weatherScale: weatherScale ?? this.weatherScale,
      radarScale: radarScale ?? this.radarScale,
      radarDimming: radarDimming ?? this.radarDimming,
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
      radarScale: SettingsRepository.defaultTileScale,
      radarDimming: SettingsRepository.defaultRadarDimming,
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
      radarScale: await repo.getRadarTileScale(),
      radarDimming: await repo.getRadarDimming(),
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

  Future<void> setRadarScale(double scale) async {
    state = state.copyWith(radarScale: scale);
    await ref.read(settingsRepositoryProvider).setRadarTileScale(scale);
  }

  Future<void> setRadarDimming(double dimming) async {
    state = state.copyWith(radarDimming: dimming);
    await ref.read(settingsRepositoryProvider).setRadarDimming(dimming);
  }
}

final weatherDisplaySettingsProvider =
    NotifierProvider<WeatherDisplaySettingsNotifier, WeatherDisplaySettings>(WeatherDisplaySettingsNotifier.new);
