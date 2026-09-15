import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/models/favorite_channel.dart';
import '../data/repositories/dab_stations_repository.dart';
import '../data/repositories/favorites_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/services/audio_player_service.dart';
import '../data/services/dab_usb_service.dart';
import '../data/services/radio_audio_handler.dart';
import '../data/services/radio_browser_api_service.dart';

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
