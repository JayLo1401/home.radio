import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/settings_repository.dart';
import '../data/services/admin_server.dart';
import '../data/services/display_service.dart';
import '../data/services/ha_mqtt_link.dart';
import 'package:audio_service/audio_service.dart' show AudioProcessingState;

import '../data/models/favorite_channel.dart';
import '../features/dashboard/dashboard_screen.dart' show DashboardScreen, dashboardReloadProvider;
import '../features/launcher/launcher_navigation.dart' show hideLauncherWith, showLauncherWith;
import '../features/launcher/launcher_providers.dart' show RadioCommand, appNavigatorKey, radioCommandProvider;
import '../features/music/music_screen.dart' show MusicScreen;
import '../features/tv/tv_screen.dart' show TvScreen;
import 'music_providers.dart' show musicPlayerProvider;
import '../l10n/l10n.dart';
import 'dashboard_providers.dart';
import 'native_errors.dart' show appMessengerKey;
import 'providers.dart';
import 'system_providers.dart';

/// Settings → System → Home Assistant (loaded from the database).
class HaLinkNotifier extends Notifier<HaLinkSettings> {
  @override
  HaLinkSettings build() {
    ref.read(settingsRepositoryProvider).getHaLink().then((v) => state = v);
    return const HaLinkSettings();
  }

  Future<void> set(HaLinkSettings value) async {
    state = value;
    await ref.read(settingsRepositoryProvider).setHaLink(value);
  }
}

final haLinkSettingsProvider = NotifierProvider<HaLinkNotifier, HaLinkSettings>(HaLinkNotifier.new);

/// The broker for [s]: its host, or else the Haussteuerung's Home Assistant
/// (the Mosquitto add-on runs on the same machine). Null: switched off or
/// no address known.
HaBroker? haBrokerFor(HaLinkSettings s, String dashboardUrl) {
  if (!s.enabled) return null;
  var host = mqttHostOf(s.host);
  var port = s.port;
  // "192.168.1.5:1884" or "mqtt://...:1884": the port given with it counts
  // (an http(s) one is Home Assistant's web page, not the broker's).
  final given = _portOf(s.host);
  if (given != null && port == HaLinkSettings.defaultPort) port = given;
  if (host.isEmpty) host = mqttHostOf(dashboardUrl);
  if (host.isEmpty) return null;
  return HaBroker(host: host, port: port, user: s.user.trim(), password: s.password);
}

/// The broker's host from what was typed: a plain name or IP, but also
/// Home Assistant's address pasted as it is ("http://192.168.1.5:8123/")
/// or "host:port" - only the host.
String mqttHostOf(String text) {
  final t = text.trim();
  if (t.isEmpty) return '';
  final uri = Uri.tryParse(t.contains('://') ? t : 'mqtt://$t');
  final host = uri?.host ?? '';
  return host.isNotEmpty ? host : t.split(RegExp('[/:]')).first;
}

int? _portOf(String text) {
  final t = text.trim();
  if (t.isEmpty || t.startsWith('http://') || t.startsWith('https://')) return null;
  final uri = Uri.tryParse(t.contains('://') ? t : 'mqtt://$t');
  return uri != null && uri.hasPort ? uri.port : null;
}

/// The link itself (one for the app's lifetime).
final haMqttLinkProvider = Provider<HaMqttLink>((ref) {
  final link = HaMqttLink(_AppHaDevice(ref));
  ref.onDispose(link.dispose);
  return link;
});

/// Runs the link as set up and sends changes at once (app.dart watches it).
final haLinkControllerProvider = Provider<void>((ref) {
  final link = ref.read(haMqttLinkProvider);
  final settings = ref.watch(haLinkSettingsProvider);
  final url = ref.watch(dashboardUrlProvider);
  unawaited(link.setBroker(haBrokerFor(settings, url)));
  // The camera switch, the login: the entities may differ.
  unawaited(link.rediscover());
  // The device's name, the parts: the entities and their names change.
  ref.listen(deviceNameProvider, (_, _) => unawaited(link.rediscover()));
  ref.listen(systemPartsProvider, (_, _) => unawaited(link.rediscover()));
  // States that change on the device: out at once, not only every minute.
  ref.listen(dashboardDisplayProvider, (_, _) => unawaited(link.refresh()));
  ref.listen(displayBrightnessProvider, (_, _) => unawaited(link.refresh()));
  final display = ref.read(displayServiceProvider);
  // The camera in Home Assistant: pictures only while switched on.
  final sharing = settings.enabled && settings.shareCamera;
  unawaited(display.setCameraSharing(sharing));
  final frames = sharing ? display.cameraFrames.listen((jpeg) => link.publishImage(HaKeys.camera, jpeg)) : null;
  void changed() => unawaited(link.refresh());
  display.motion.addListener(changed);
  display.screenIsOn.addListener(changed);
  display.dimmed.addListener(changed);
  final lifecycle = AppLifecycleListener(onStateChange: (_) => changed());
  // What plays (radio, music): title, state, the station.
  StreamSubscription<Object?>? item;
  StreamSubscription<Object?>? playback;
  // Only with the link on - the media session isn't started for nothing.
  if (settings.enabled) {
    ref.listen(radioAudioHandlerProvider, (_, handler) {
      final h = handler.value;
      if (h == null || item != null) return;
      item = h.mediaItem.listen((_) => changed());
      playback = h.playbackState.map((s) => (s.playing, s.processingState)).distinct().listen((_) => changed());
    }, fireImmediately: true);
  }
  ref.listen(currentProgramNumberProvider, (_, _) => changed());
  // New or renamed favourites: the station list in Home Assistant.
  ref.listen(favoritesStreamProvider, (_, _) => unawaited(link.rediscover()));
  ref.onDispose(() {
    unawaited(item?.cancel());
    unawaited(playback?.cancel());
    unawaited(frames?.cancel());
    display.motion.removeListener(changed);
    display.screenIsOn.removeListener(changed);
    display.dimmed.removeListener(changed);
    lifecycle.dispose();
  });
});

/// The keys of the entities (topics, unique ids) - never change them, Home
/// Assistant would see new entities.
abstract final class HaKeys {
  static const screen = 'screen';
  static const camera = 'camera';
  static const motionDetection = 'motion_detection';
  static const brightnessMode = 'brightness_mode';
  static const brightness = 'brightness';
  static const screenOffTimer = 'screen_off_timer';
  static const reload = 'reload_dashboard';
  static const toFront = 'bring_to_front';
  static const message = 'message';
  static const speak = 'tts';
  static const motion = 'motion';
  static const battery = 'battery';
  static const plugged = 'plugged';
  static const batteryTemperature = 'battery_temperature';
  static const light = 'light';
  static const foreground = 'foreground';
  static const freeMemory = 'free_memory';
  static const freeStorage = 'free_storage';
  static const ip = 'ip';
  static const playback = 'playback';
  static const title = 'media_title';
  static const artist = 'media_artist';
  static const source = 'media_source';
  static const playPause = 'play_pause';
  static const stop = 'stop';
  static const next = 'next';
  static const previous = 'previous';
  static const station = 'station';
  static const volume = 'volume';
  static const openHome = 'open_home';
  static const openRadio = 'open_radio';
  static const openTv = 'open_tv';
  static const openMusic = 'open_music';
  static const openDashboard = 'open_dashboard';
  static const version = 'version';
}

/// Home System as Home Assistant sees it - with what this device has (a
/// TV box: no battery, no camera; the PC: no display control).
class _AppHaDevice implements HaDevice {
  _AppHaDevice(this._ref);

  final Ref _ref;

  DisplayService get _display => _ref.read(displayServiceProvider);
  bool get _android => DisplayService.supported;

  Map<String, Object?>? _status;
  DateTime _statusAt = DateTime(2000);

  /// The native status, at most every few seconds.
  Future<Map<String, Object?>> _deviceStatus() async {
    if (_status != null && DateTime.now().difference(_statusAt) < const Duration(seconds: 5)) return _status!;
    _status = await _display.deviceStatus();
    _statusAt = DateTime.now();
    return _status!;
  }

  List<String> _modeOptions() {
    final l = l10n;
    return [l.dashboardBrightnessSystem, l.dashboardBrightnessFixed, l.dashboardBrightnessAdaptive];
  }

  @override
  Future<HaDeviceInfo> info() async {
    final name = _ref.read(deviceNameProvider).trim();
    final updates = _ref.read(updateServiceProvider);
    final device = await updates.deviceInfo();
    final url = await AdminServer.url();
    return HaDeviceInfo(
      name: name.isNotEmpty ? name : (device?.name ?? (await AdminServer.hostname()) ?? 'Home System'),
      manufacturer: device?.manufacturer.isNotEmpty == true ? device!.manufacturer : null,
      model: device != null ? device.model : Platform.operatingSystem,
      version: await updates.currentVersion(),
      configurationUrl: url,
    );
  }

  @override
  Future<List<HaEntity>> entities() async {
    final l = l10n;
    final status = await _deviceStatus();
    final hasBattery = status['hasBattery'] == true;
    final hasLight = status['hasLight'] == true;
    final hasCamera = status['hasCamera'] == true;
    // Brightness, the timer and the dashboard belong to the Haussteuerung
    // (a wall tablet) - not to a TV box.
    final wall = _ref.read(systemPartsProvider).dashboard;
    const diagnostic = {'entity_category': 'diagnostic'};
    const config = {'entity_category': 'config'};
    return [
      if (_android) ...[
        HaEntity(component: 'switch', key: HaKeys.screen, name: l.haScreen, config: const {'icon': 'mdi:tablet'}),
        if (hasCamera)
          HaEntity(
            component: 'switch',
            key: HaKeys.motionDetection,
            name: l.haMotionDetection,
            config: const {'icon': 'mdi:motion-sensor', ...config},
          ),
        if (wall) ...[
          HaEntity(
            component: 'select',
            key: HaKeys.brightnessMode,
            name: l.haBrightnessMode,
            config: {'options': _modeOptions(), 'icon': 'mdi:brightness-auto', ...config},
          ),
          HaEntity(
            component: 'number',
            key: HaKeys.brightness,
            name: l.haBrightness,
            config: const {
              'min': 1,
              'max': 100,
              'step': 1,
              'unit_of_measurement': '%',
              'icon': 'mdi:brightness-6',
              ...config,
            },
          ),
          HaEntity(
            component: 'number',
            key: HaKeys.screenOffTimer,
            name: l.haScreenOffTimer,
            config: const {
              'min': 0,
              'max': 240,
              'step': 1,
              'unit_of_measurement': 'min',
              'icon': 'mdi:timer-outline',
              'mode': 'box',
              ...config,
            },
          ),
          HaEntity(
            component: 'button',
            key: HaKeys.reload,
            name: l.haReloadDashboard,
            config: const {'icon': 'mdi:reload'},
          ),
        ],
        HaEntity(
          component: 'button',
          key: HaKeys.toFront,
          name: l.haBringToFront,
          config: const {'icon': 'mdi:application-import'},
        ),
        HaEntity(component: 'notify', key: HaKeys.speak, name: l.haSpeak, config: const {'icon': 'mdi:account-voice'}),
        if (hasCamera)
          HaEntity(
            component: 'binary_sensor',
            key: HaKeys.motion,
            name: l.haMotion,
            config: const {'device_class': 'motion'},
          ),
        if (hasCamera && _ref.read(haLinkSettingsProvider).shareCamera)
          HaEntity(component: 'camera', key: HaKeys.camera, name: l.haCamera, config: const {'icon': 'mdi:webcam'}),
        if (hasBattery) ...[
          HaEntity(
            component: 'sensor',
            key: HaKeys.battery,
            name: l.haBattery,
            config: const {'device_class': 'battery', 'unit_of_measurement': '%', 'state_class': 'measurement'},
          ),
          HaEntity(
            component: 'binary_sensor',
            key: HaKeys.plugged,
            name: l.haPlugged,
            config: const {'device_class': 'plug'},
          ),
          HaEntity(
            component: 'sensor',
            key: HaKeys.batteryTemperature,
            name: l.haBatteryTemperature,
            config: const {
              'device_class': 'temperature',
              'unit_of_measurement': '°C',
              'state_class': 'measurement',
              ...diagnostic,
            },
          ),
        ],
        if (hasLight)
          HaEntity(
            component: 'sensor',
            key: HaKeys.light,
            name: l.haLight,
            config: const {'device_class': 'illuminance', 'unit_of_measurement': 'lx', 'state_class': 'measurement'},
          ),
        HaEntity(
          component: 'sensor',
          key: HaKeys.freeMemory,
          name: l.haFreeMemory,
          config: const {
            'device_class': 'data_size',
            'unit_of_measurement': 'MB',
            'state_class': 'measurement',
            ...diagnostic,
          },
        ),
        HaEntity(
          component: 'sensor',
          key: HaKeys.freeStorage,
          name: l.haFreeStorage,
          config: const {
            'device_class': 'data_size',
            'unit_of_measurement': 'GB',
            'state_class': 'measurement',
            ...diagnostic,
          },
        ),
      ],
      ...await _mediaEntities(status),
      HaEntity(component: 'notify', key: HaKeys.message, name: l.haMessage, config: const {'icon': 'mdi:message-text'}),
      HaEntity(
        component: 'binary_sensor',
        key: HaKeys.foreground,
        name: l.haForeground,
        config: const {'icon': 'mdi:application', ...diagnostic},
      ),
      HaEntity(
        component: 'sensor',
        key: HaKeys.ip,
        name: l.haIpAddress,
        config: const {'icon': 'mdi:ip-network', ...diagnostic},
      ),
      HaEntity(
        component: 'sensor',
        key: HaKeys.version,
        name: l.haVersion,
        config: const {'icon': 'mdi:information-outline', ...diagnostic},
      ),
    ];
  }

  @override
  Future<Map<String, String>> states() async {
    final status = await _deviceStatus();
    final display = _ref.read(dashboardDisplayProvider);
    final brightness = _ref.read(displayBrightnessProvider);
    String onOff(bool on) => on ? 'ON' : 'OFF';
    final screen = _display.dimmed.value ? false : (_display.screenIsOn.value ?? status['screenOn'] == true);
    final lux = (status['lux'] as num?)?.toDouble() ?? -1;
    final battery = status['battery'] as num?;
    final temperature = status['batteryTemperature'] as num?;
    final freeMemory = status['freeMemory'] as num?;
    final freeStorage = status['freeStorage'] as num?;
    final ip = (await AdminServer.addresses()).firstOrNull;
    final resumed = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    return {
      if (_android) ...{
        HaKeys.screen: onOff(screen),
        HaKeys.motionDetection: onOff(display.motion),
        HaKeys.brightnessMode: _modeOptions()[brightness.mode.index],
        HaKeys.brightness: '${brightness.level}',
        HaKeys.screenOffTimer: '${display.timeoutMinutes}',
        HaKeys.motion: onOff(_display.motion.value),
        if (battery != null) HaKeys.battery: '${battery.round()}',
        HaKeys.plugged: onOff(status['plugged'] == true),
        if (temperature != null) HaKeys.batteryTemperature: temperature.toStringAsFixed(1),
        if (lux >= 0) HaKeys.light: lux.round().toString(),
        if (freeMemory != null) HaKeys.freeMemory: '${(freeMemory / (1 << 20)).round()}',
        if (freeStorage != null) HaKeys.freeStorage: (freeStorage / (1 << 30)).toStringAsFixed(1),
      },
      ...await _mediaStates(status),
      HaKeys.foreground: onOff(resumed),
      HaKeys.ip: ip ?? '',
      HaKeys.version: await _ref.read(updateServiceProvider).currentVersion(),
    };
  }

  @override
  Future<void> command(String key, String payload) async {
    final value = payload.trim();
    switch (key) {
      case HaKeys.screen:
        if (value == 'ON') {
          await _display.screenOn();
        } else if (value == 'OFF') {
          await _display.screenOff();
        }
      case HaKeys.motionDetection:
        final on = value == 'ON';
        // The camera permission can only be granted on the device.
        if (on && !await _display.hasCameraPermission()) return;
        final repo = _ref.read(settingsRepositoryProvider);
        final d = await repo.getDashboardDisplay();
        await _ref.read(dashboardDisplayProvider.notifier).set(d.copyWith(motion: on));
      case HaKeys.brightnessMode:
        final index = _modeOptions().indexOf(value);
        if (index < 0) return;
        await _setBrightness((b) => b.copyWith(mode: BrightnessMode.values[index]));
      case HaKeys.brightness:
        final level = double.tryParse(value)?.round();
        if (level == null || level < 1 || level > 100) return;
        // A level means a fixed brightness (the system's and the light
        // sensor's would ignore it).
        await _setBrightness(
          (b) => b.copyWith(level: level, mode: b.mode == BrightnessMode.adaptive ? b.mode : BrightnessMode.fixed),
        );
      case HaKeys.screenOffTimer:
        final minutes = double.tryParse(value)?.round();
        if (minutes == null || minutes < 0 || minutes > 240) return;
        final repo = _ref.read(settingsRepositoryProvider);
        final d = await repo.getDashboardDisplay();
        await _ref.read(dashboardDisplayProvider.notifier).set(d.copyWith(timeoutMinutes: minutes));
      case HaKeys.reload:
        _ref.read(dashboardReloadProvider.notifier).reload();
      case HaKeys.toFront:
        await _display.bringToFront();
      case HaKeys.speak:
        if (value.isNotEmpty) await _display.speak(value);
      case HaKeys.message:
        if (value.isEmpty) return;
        appMessengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(value, style: const TextStyle(fontSize: 22)),
              duration: const Duration(seconds: 15),
              behavior: SnackBarBehavior.floating,
            ),
          );
      case HaKeys.playPause || HaKeys.stop || HaKeys.next || HaKeys.previous:
        final handler = _ref.read(radioAudioHandlerProvider).value;
        if (handler == null) return;
        switch (key) {
          case HaKeys.playPause:
            await (handler.playbackState.value.playing ? handler.pause() : handler.play());
          case HaKeys.stop:
            await handler.stop();
          case HaKeys.next:
            await handler.skipToNext();
          case HaKeys.previous:
            await handler.skipToPrevious();
        }
      case HaKeys.station:
        if (value == _noStation) {
          _ref.read(radioCommandProvider.notifier).send(RadioCommand.stop);
          return;
        }
        final favorites = _ref.read(favoritesStreamProvider).value ?? const [];
        final channel = favorites.where((c) => _stationLabel(c) == value).firstOrNull;
        if (channel != null) _ref.read(playRequestProvider.notifier).favorite(channel);
      case HaKeys.volume:
        final percent = double.tryParse(value)?.round();
        if (percent != null) await _display.setVolume(percent.clamp(0, 100));
      case HaKeys.openHome:
        showLauncherWith(_ref.read);
      case HaKeys.openRadio:
        if (!_ref.read(systemPartsProvider).radio) return;
        appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
        hideLauncherWith(_ref.read);
      case HaKeys.openTv || HaKeys.openMusic || HaKeys.openDashboard:
        await _openOverLauncher(key);
      default:
        debugPrint('Home Assistant: unknown command $key');
    }
  }

  static const _noStation = '–';

  /// "3 Ö1" - a favourite as the station list shows it.
  static String _stationLabel(FavoriteChannel c) => '${c.programNumber} ${c.displayName}';

  /// Playback (radio and music share the media session) and the views -
  /// what a media box offers Home Assistant.
  Future<List<HaEntity>> _mediaEntities(Map<String, Object?> status) async {
    final l = l10n;
    final parts = _ref.read(systemPartsProvider);
    if (!parts.radio && !parts.music) return const [];
    final favorites = parts.radio ? (_ref.read(favoritesStreamProvider).value ?? const []) : const <FavoriteChannel>[];
    final playStates = [l.haPlaybackPlaying, l.haPlaybackPaused, l.haPlaybackIdle];
    return [
      HaEntity(
        component: 'sensor',
        key: HaKeys.playback,
        name: l.haPlayback,
        config: {'device_class': 'enum', 'options': playStates, 'icon': 'mdi:play-pause'},
      ),
      HaEntity(component: 'sensor', key: HaKeys.title, name: l.haMediaTitle, config: const {'icon': 'mdi:music-note'}),
      HaEntity(component: 'sensor', key: HaKeys.artist, name: l.haMediaArtist, config: const {'icon': 'mdi:account-music'}),
      HaEntity(component: 'sensor', key: HaKeys.source, name: l.haMediaSource, config: const {'icon': 'mdi:radio'}),
      HaEntity(component: 'button', key: HaKeys.playPause, name: l.haPlayPause, config: const {'icon': 'mdi:play-pause'}),
      HaEntity(component: 'button', key: HaKeys.stop, name: l.haStop, config: const {'icon': 'mdi:stop'}),
      HaEntity(component: 'button', key: HaKeys.next, name: l.haNext, config: const {'icon': 'mdi:skip-next'}),
      HaEntity(component: 'button', key: HaKeys.previous, name: l.haPrevious, config: const {'icon': 'mdi:skip-previous'}),
      if (favorites.isNotEmpty)
        HaEntity(
          component: 'select',
          key: HaKeys.station,
          name: l.haStation,
          config: {
            'options': [_noStation, for (final c in favorites) _stationLabel(c)],
            'icon': 'mdi:radio-tower',
          },
        ),
      if (_android && status['volume'] != null)
        HaEntity(
          component: 'number',
          key: HaKeys.volume,
          name: l.haVolume,
          config: const {'min': 0, 'max': 100, 'step': 5, 'unit_of_measurement': '%', 'icon': 'mdi:volume-high'},
        ),
      HaEntity(component: 'button', key: HaKeys.openHome, name: l.haOpenHome, config: const {'icon': 'mdi:home'}),
      if (parts.radio)
        HaEntity(component: 'button', key: HaKeys.openRadio, name: l.haOpenRadio, config: const {'icon': 'mdi:radio'}),
      if (parts.tv) HaEntity(component: 'button', key: HaKeys.openTv, name: l.haOpenTv, config: const {'icon': 'mdi:television'}),
      if (parts.music)
        HaEntity(component: 'button', key: HaKeys.openMusic, name: l.haOpenMusic, config: const {'icon': 'mdi:music'}),
      if (_android && parts.dashboard)
        HaEntity(
          component: 'button',
          key: HaKeys.openDashboard,
          name: l.haOpenDashboard,
          config: const {'icon': 'mdi:view-dashboard'},
        ),
    ];
  }

  Future<Map<String, String>> _mediaStates(Map<String, Object?> status) async {
    final l = l10n;
    final parts = _ref.read(systemPartsProvider);
    if (!parts.radio && !parts.music) return const {};
    final handler = _ref.read(radioAudioHandlerProvider).value;
    final item = handler?.mediaItem.value;
    final state = handler?.playbackState.value;
    final active = item != null && state != null && state.processingState != AudioProcessingState.idle;
    final playback = !active
        ? l.haPlaybackIdle
        : state.playing
            ? l.haPlaybackPlaying
            : l.haPlaybackPaused;
    String? station;
    if (parts.radio) {
      final program = _ref.read(currentProgramNumberProvider);
      final favorites = _ref.read(favoritesStreamProvider).value ?? const [];
      final channel = program == null || (handler?.hasGuest ?? false) || !active
          ? null
          : favorites.where((c) => c.programNumber == program).firstOrNull;
      station = channel == null ? _noStation : _stationLabel(channel);
    }
    final volume = status['volume'] as num?;
    return {
      HaKeys.playback: playback,
      HaKeys.title: active ? _cut(item.title) : '',
      HaKeys.artist: active ? _cut(item.artist ?? '') : '',
      HaKeys.source: !active ? '' : ((handler?.hasGuest ?? false) ? l.musicTitle : 'Radio'),
      HaKeys.station: ?station,
      if (volume != null) HaKeys.volume: '${volume.round()}',
    };
  }

  /// Home Assistant keeps at most 255 characters of a state.
  static String _cut(String text) => text.length <= 250 ? text : '${text.substring(0, 249)}…';

  /// TV, Musik or the Haussteuerung over the launcher - as its tiles open
  /// them (Back leads to the launcher).
  Future<void> _openOverLauncher(String key) async {
    final parts = _ref.read(systemPartsProvider);
    final allowed = switch (key) {
      HaKeys.openTv => parts.tv,
      HaKeys.openMusic => parts.music,
      _ => parts.dashboard && _android,
    };
    if (!allowed) return;
    showLauncherWith(_ref.read);
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    // TV and the Haussteuerung take the speakers (as from the launcher).
    if (key != HaKeys.openMusic) {
      _ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
      if (key == HaKeys.openTv) await _ref.read(musicPlayerProvider).pauseForApp();
    }
    final Widget page = switch (key) {
      HaKeys.openTv => const TvScreen(),
      HaKeys.openMusic => const MusicScreen(),
      _ => const DashboardScreen(),
    };
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => page)));
  }

  Future<void> _setBrightness(DisplayBrightness Function(DisplayBrightness b) change) async {
    final repo = _ref.read(settingsRepositoryProvider);
    await _ref.read(displayBrightnessProvider.notifier).set(change(await repo.getDisplayBrightness()));
  }
}
