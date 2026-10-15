import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/models/favorite_channel.dart';
import '../data/repositories/dab_stations_repository.dart';
import '../data/repositories/favorites_repository.dart';
import '../data/repositories/settings_repository.dart' show DabSortMode, SettingsRepository;
import '../data/services/audio_player_service.dart';
import '../data/services/chime_service.dart';
import '../data/services/dab_rtlsdr_service.dart';
import '../data/services/dab_usb_service.dart';
import '../data/services/order_service.dart';
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

/// [dabStationsStreamProvider], sorted per [dabSortModeProvider] - what
/// FavoritesSidebar's DAB-Sender tab and DabStationsScreen actually display,
/// so both stay consistent with each other and with the user's setting.
final sortedDabStationsProvider = Provider<AsyncValue<List<DabStation>>>((ref) {
  final sortMode = ref.watch(dabSortModeProvider);
  final stationsAsync = ref.watch(dabStationsStreamProvider);
  return stationsAsync.whenData((stations) => sortDabStations(stations, sortMode));
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

final currentProgramNumberProvider = NotifierProvider<CurrentProgramNumber, int?>(CurrentProgramNumber.new);

enum SidebarCategory { favorites, dabStations }

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
  final manual = ref.watch(sidebarCategoryProvider);
  if (manual != null) return manual;
  return ref.watch(currentDabStationProvider) != null ? SidebarCategory.dabStations : SidebarCategory.favorites;
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
    required this.radarZoom,
    required this.radarDimming,
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
  // How far the embedded radar map is zoomed in by default - see
  // SettingsRepository.getRadarZoom's own doc comment.
  final int radarZoom;
  final double radarDimming;
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
    int? radarZoom,
    double? radarDimming,
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
      radarZoom: radarZoom ?? this.radarZoom,
      radarDimming: radarDimming ?? this.radarDimming,
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
      radarZoom: SettingsRepository.defaultRadarZoom,
      radarDimming: SettingsRepository.defaultRadarDimming,
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
      radarZoom: await repo.getRadarZoom(),
      sunEnabled: await repo.getSunEnabled(),
      sunScale: await repo.getSunTileScale(),
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

  Future<void> setRadarZoom(int zoom) async {
    state = state.copyWith(radarZoom: zoom);
    await ref.read(settingsRepositoryProvider).setRadarZoom(zoom);
  }

  Future<void> setRadarDimming(double dimming) async {
    state = state.copyWith(radarDimming: dimming);
    await ref.read(settingsRepositoryProvider).setRadarDimming(dimming);
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

/// bestell_manager connection for the order tile (see OrderService/
/// orderDayProvider) - [loaded] is false until the persisted values are
/// actually in, so nothing gets polled with the placeholder defaults first.
class OrderSettings {
  const OrderSettings({
    required this.enabled,
    required this.baseUrl,
    required this.user,
    required this.password,
    required this.pollSeconds,
    required this.pickupDisplaySeconds,
    required this.pickupSound,
    this.loaded = true,
  });

  final bool enabled;
  final String baseUrl;
  final String user;
  final String password;
  final int pollSeconds;

  /// How long the "Bitte abholen" overlay stays up after the last newly
  /// completed order, and whether a chime plays for each new batch - see
  /// PickupNotifier.
  final int pickupDisplaySeconds;
  final bool pickupSound;
  final bool loaded;

  bool get isConfigured =>
      loaded && enabled && baseUrl.trim().isNotEmpty && user.trim().isNotEmpty && password.isNotEmpty;

  /// Everything that decides *what* gets polled - deliberately excludes
  /// [pollSeconds], so changing only the interval doesn't restart
  /// orderDayProvider (and briefly drop the tile).
  ({bool configured, String baseUrl, String user, String password}) get connection =>
      (configured: isConfigured, baseUrl: baseUrl, user: user, password: password);

  OrderSettings copyWith({
    bool? enabled,
    String? baseUrl,
    String? user,
    String? password,
    int? pollSeconds,
    int? pickupDisplaySeconds,
    bool? pickupSound,
  }) {
    return OrderSettings(
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      user: user ?? this.user,
      password: password ?? this.password,
      pollSeconds: pollSeconds ?? this.pollSeconds,
      pickupDisplaySeconds: pickupDisplaySeconds ?? this.pickupDisplaySeconds,
      pickupSound: pickupSound ?? this.pickupSound,
      loaded: loaded,
    );
  }
}

class OrderSettingsNotifier extends Notifier<OrderSettings> {
  @override
  OrderSettings build() {
    final repo = ref.watch(settingsRepositoryProvider);
    _load(repo);
    return const OrderSettings(
      enabled: true,
      baseUrl: SettingsRepository.defaultOrderBaseUrl,
      user: SettingsRepository.defaultOrderUser,
      password: '',
      pollSeconds: SettingsRepository.defaultOrderPollSeconds,
      pickupDisplaySeconds: SettingsRepository.defaultPickupDisplaySeconds,
      pickupSound: true,
      loaded: false,
    );
  }

  Future<void> _load(SettingsRepository repo) async {
    state = OrderSettings(
      enabled: await repo.getOrderEnabled(),
      baseUrl: await repo.getOrderBaseUrl(),
      user: await repo.getOrderUser(),
      password: await repo.getOrderPassword(),
      pollSeconds: await repo.getOrderPollSeconds(),
      pickupDisplaySeconds: await repo.getPickupDisplaySeconds(),
      pickupSound: await repo.getPickupSound(),
    );
  }

  Future<void> setPickupDisplaySeconds(int seconds) async {
    final clamped = seconds.clamp(
      SettingsRepository.minPickupDisplaySeconds,
      SettingsRepository.maxPickupDisplaySeconds,
    );
    state = state.copyWith(pickupDisplaySeconds: clamped);
    await ref.read(settingsRepositoryProvider).setPickupDisplaySeconds(clamped);
  }

  Future<void> setPickupSound(bool enabled) async {
    state = state.copyWith(pickupSound: enabled);
    await ref.read(settingsRepositoryProvider).setPickupSound(enabled);
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await ref.read(settingsRepositoryProvider).setOrderEnabled(enabled);
  }

  Future<void> setApi({required String baseUrl, required String user, required String password}) async {
    state = state.copyWith(baseUrl: baseUrl, user: user, password: password);
    await ref.read(settingsRepositoryProvider).setOrderApi(baseUrl: baseUrl, user: user, password: password);
  }

  Future<void> setPollSeconds(int seconds) async {
    final clamped = seconds.clamp(SettingsRepository.minOrderPollSeconds, SettingsRepository.maxOrderPollSeconds);
    state = state.copyWith(pollSeconds: clamped);
    await ref.read(settingsRepositoryProvider).setOrderPollSeconds(clamped);
  }
}

final orderSettingsProvider = NotifierProvider<OrderSettingsNotifier, OrderSettings>(OrderSettingsNotifier.new);

final orderServiceProvider = Provider<OrderService>((ref) => OrderService());

/// Today's order day (null = none, not configured, or unreachable), polled
/// at the user's chosen interval (OrderSettings.pollSeconds, 5-60s) while
/// configured - the kitchen's status changes over the evening as courses
/// are switched, and creating/deleting the order day should show up
/// near-live. Cheap: one small request, and the state is only replaced when
/// something actually changed (see OrderDay's ==), so an unchanged poll
/// doesn't rebuild the tiles. A failed request (e.g. no network yet right
/// after boot) retries after 15s, and keeps showing the last known order
/// day meanwhile rather than flickering the tile away.
class OrderDayNotifier extends Notifier<OrderDay?> {
  static const _errorRetryInterval = Duration(seconds: 15);

  Timer? _timer;

  @override
  OrderDay? build() {
    final connection = ref.watch(orderSettingsProvider.select((s) => s.connection));
    ref.onDispose(() => _timer?.cancel());
    if (!connection.configured) return null;
    Future.microtask(() => _poll(connection));
    return null;
  }

  Future<void> _poll(({bool configured, String baseUrl, String user, String password}) connection) async {
    _timer?.cancel();
    final result = await ref
        .read(orderServiceProvider)
        .fetchToday(baseUrl: connection.baseUrl, user: connection.user, password: connection.password, previous: state);
    // Connection settings changed while this request was in flight -
    // build() has already started a fresh poll loop for the new ones.
    final settings = ref.read(orderSettingsProvider);
    if (settings.connection != connection) return;
    if (result.status == OrderFetchStatus.error) {
      _timer = Timer(_errorRetryInterval, () => _poll(connection));
      return;
    }
    if (result.day != state) state = result.day;
    // Read fresh each round, so a changed interval applies from the next
    // poll on without restarting anything.
    _timer = Timer(Duration(seconds: settings.pollSeconds), () => _poll(connection));
  }
}

final orderDayProvider = NotifierProvider<OrderDayNotifier, OrderDay?>(OrderDayNotifier.new);

final chimeServiceProvider = Provider<ChimeService>((ref) => ChimeService(ref.watch(audioPlayerServiceProvider)));

/// What the "Bitte abholen" overlay currently shows - every order newly
/// completed since it last appeared, oldest first.
class PickupAnnouncement {
  const PickupAnnouncement(this.items);

  final List<ReadyItem> items;
}

/// Drives the "Bitte abholen" overlay from bestell_manager's
/// `/api/v1/ready`: polled at the same interval as the order tile, but only
/// while there actually is an order day today (see orderDayProvider) -
/// otherwise not at all.
///
/// Each completion has a unique key; keys already seen are remembered so
/// every completion is announced exactly once. One first seen with an age
/// beyond the display duration (e.g. right after the app started) is only
/// marked as seen, not announced - per the server's own clock, so the
/// radio's clock being off doesn't matter. New completions are added to an
/// overlay that's already up (many soups often finish at once) and restart
/// its display duration; the chime plays once per batch of new entries,
/// not once per entry.
class PickupNotifier extends Notifier<PickupAnnouncement?> {
  final _seenKeys = <String>{};
  Timer? _pollTimer;
  Timer? _hideTimer;

  @override
  PickupAnnouncement? build() {
    final connection = ref.watch(orderSettingsProvider.select((s) => s.connection));
    final hasOrderDay = ref.watch(orderDayProvider.select((day) => day != null));
    ref.onDispose(() {
      _pollTimer?.cancel();
      _hideTimer?.cancel();
    });
    if (!connection.configured || !hasOrderDay) return null;
    Future.microtask(() => _poll(connection));
    return null;
  }

  Future<void> _poll(({bool configured, String baseUrl, String user, String password}) connection) async {
    _pollTimer?.cancel();
    final displaySeconds = ref.read(orderSettingsProvider).pickupDisplaySeconds;
    final items = await ref
        .read(orderServiceProvider)
        .fetchReady(
          baseUrl: connection.baseUrl,
          user: connection.user,
          password: connection.password,
          // Must cover at least the display duration, so nothing that
          // should still be announced has already dropped out of the list.
          seconds: math.max(120, displaySeconds),
        );
    final settings = ref.read(orderSettingsProvider);
    if (settings.connection != connection) return;
    if (items != null) _handle(items, settings);
    _pollTimer = Timer(Duration(seconds: settings.pollSeconds), () => _poll(connection));
  }

  void _handle(List<ReadyItem> items, OrderSettings settings) {
    final fresh = <ReadyItem>[];
    for (final item in items) {
      if (!_seenKeys.add(item.key)) continue;
      if (item.ageSeconds <= settings.pickupDisplaySeconds) fresh.add(item);
    }
    // A key only ever leaves the response by aging out of its time window,
    // and never comes back (a re-completion gets a new key) - so only the
    // keys still in the response need remembering, which keeps this set
    // bounded no matter how long the evening runs.
    _seenKeys.retainAll(items.map((i) => i.key));
    if (fresh.isEmpty) return;
    _announce(fresh, settings);
  }

  void _announce(List<ReadyItem> fresh, OrderSettings settings) {
    state = PickupAnnouncement([...?state?.items, ...fresh]);
    _hideTimer?.cancel();
    _hideTimer = Timer(Duration(seconds: settings.pickupDisplaySeconds), () => state = null);
    if (settings.pickupSound) ref.read(chimeServiceProvider).play();
  }

  /// The user closed the popup themselves - drop the current announcement
  /// (its entries stay marked as seen); the next new completion opens a
  /// fresh one.
  void dismiss() {
    _hideTimer?.cancel();
    state = null;
  }

  /// Settings' "Anzeige testen" - shows the overlay with made-up entries
  /// (including a batch of identical soups) so it can be checked on the TV
  /// without a real order day.
  void showDemo() {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    const soups = ['Anna · Tisch 3', 'Ben', 'Carla', 'David', 'Eva', 'Franz', 'Gabi', 'Hans', 'Ida', 'Jakob'];
    _announce([
      for (final (i, guest) in soups.indexed)
        ReadyItem(
          key: 'demo-$stamp-$i',
          number: i + 1,
          guest: guest,
          itemName: 'Kürbiscremesuppe',
          itemIcon: '🎃',
          options: '',
          ageSeconds: 0,
        ),
      ReadyItem(
        key: 'demo-$stamp-ice',
        number: 11,
        guest: 'Lena',
        itemName: 'Eisbecher',
        itemIcon: '🍨',
        options: 'Erdbeereis, mit Schokosauce',
        ageSeconds: 0,
      ),
      ReadyItem(
        key: 'demo-$stamp-ice2',
        number: 12,
        guest: 'Max',
        itemName: 'Eisbecher',
        itemIcon: '🍨',
        options: 'Vanilleeis, ohne Sauce',
        ageSeconds: 0,
      ),
    ], ref.read(orderSettingsProvider));
  }
}

final pickupProvider = NotifierProvider<PickupNotifier, PickupAnnouncement?>(PickupNotifier.new);
