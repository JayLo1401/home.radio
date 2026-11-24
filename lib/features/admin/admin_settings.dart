import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dashboard_providers.dart';
import '../../core/pictures_providers.dart';
import '../../core/providers.dart';
import '../../data/services/music_library.dart' show MusicRepeat;
import '../../data/repositories/music_settings_repository.dart';
import '../../core/music_providers.dart';
import '../../core/system_providers.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/admin_server.dart';
import '../../data/services/display_service.dart';
import '../../data/services/enigma2_service.dart';
import '../../data/services/launcher_service.dart';
import '../../data/services/picture_library.dart' show SlideshowOrder;
import '../../l10n/l10n.dart';
import '../browser/browser_channel.dart';
import '../browser/browser_settings.dart';
import '../launcher/launcher_providers.dart';
import '../tv/tv_providers.dart';

/// One setting the admin page shows and changes.
class _Setting {
  _Setting({
    required this.id,
    required this.label,
    required this.type,
    required this.get,
    required this.set,
    this.help,
    this.options = const [],
    this.min,
    this.max,
  });

  final String id;
  final String label;

  /// bool, int, choice, text, secret (write-only: never sent to the page).
  final String type;
  final String? help;
  final List<(String, String)> options;
  final int? min;
  final int? max;
  final Object? Function() get;

  /// Returns an error message, or null when it was taken.
  final Future<String?> Function(Object? value) set;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'type': type,
        if (help != null) 'help': help,
        if (options.isNotEmpty) 'options': [for (final (v, l) in options) {'value': v, 'label': l}],
        'min': ?min,
        'max': ?max,
        'value': type == 'secret' ? '' : get(),
      };
}

/// The settings the admin page (`http://<ip>:1401/`) can change - through
/// the same providers the app's own settings use, so the device follows at
/// once. Not everything: what needs the device itself (receiver search,
/// camera permission, the Home key) stays on the device.
class AdminSettings implements AdminSettingsSource {
  AdminSettings(this._c);

  final ProviderContainer _c;

  static bool? _bool(Object? v) => v is bool ? v : (v is String ? v == 'true' : null);
  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

  Future<List<({String title, List<_Setting> items})>> _groups() async {
    final l = l10n;
    final parts = _c.read(systemPartsProvider);
    final launcher = _c.read(launcherSettingsProvider);
    final weather = _c.read(weatherDisplaySettingsProvider);
    // From the database, not the providers: those that the device hasn't
    // needed yet (TV not opened) still hold their defaults.
    final repo = _c.read(settingsRepositoryProvider);
    final tv = await repo.getEnigma2Config();
    final nextUp = await repo.getTvNextUp();
    final startApp = await repo.getStartApp();
    final apps = LauncherService.supported ? await _c.read(launcherServiceProvider).listApps() : const <InstalledApp>[];
    final dashboardUrl = await repo.getDashboardUrl();
    final display = await repo.getDashboardDisplay();
    final brightness = await repo.getDisplayBrightness();
    final music = await _c.read(musicSettingsRepositoryProvider).load();
    final browser = await _c.read(browserSettingsProvider.notifier).loaded();
    Future<String?> setBrowser(BrowserSettings Function(BrowserSettings s) f) async {
      await _c.read(browserSettingsProvider.notifier).update(f);
      return null;
    }

    Future<String?> setMusic(MusicSettings Function(MusicSettings s) f) async {
      await _c.read(musicSettingsProvider.notifier).set(f);
      return null;
    }

    final slideshow = await repo.getSlideshowSettings();
    Future<String?> setSlideshow(SlideshowSettings Function(SlideshowSettings s) change) async {
      await _c.read(slideshowSettingsProvider.notifier).set(change(await repo.getSlideshowSettings()));
      return null;
    }

    Future<String?> setBrightness(DisplayBrightness Function(DisplayBrightness b) change) async {
      await _c.read(displayBrightnessProvider.notifier).set(change(await repo.getDisplayBrightness()));
      return null;
    }

    _Setting percent(String id, String label, int value, int min, DisplayBrightness Function(DisplayBrightness, int) f) =>
        _Setting(
          id: id,
          label: label,
          type: 'int',
          help: '%',
          min: min,
          max: 100,
          get: () => value,
          set: (v) async {
            final p = _int(v);
            if (p == null || p < min || p > 100) return l.adminInvalidValue;
            return setBrightness((b) => f(b, p));
          },
        );
    final android = DisplayService.supported;

    Future<String?> setTv(Enigma2Config Function(Enigma2Config c) change) async {
      await _c.read(enigma2ConfigProvider.notifier).set(change(await repo.getEnigma2Config()));
      return null;
    }

    Enigma2Config copyTv(Enigma2Config c,
            {String? host, int? webPort, int? streamPort, bool? useHttps, String? user, String? password}) =>
        Enigma2Config(
          host: host ?? c.host,
          webPort: webPort ?? c.webPort,
          streamPort: streamPort ?? c.streamPort,
          useHttps: useHttps ?? c.useHttps,
          user: user ?? c.user,
          password: password ?? c.password,
        );

    return [
      (
        title: l.systemSettingsTitleSystem,
        items: [
          _Setting(
            id: 'deviceName',
            label: l.adminDeviceName,
            type: 'text',
            get: () => _c.read(deviceNameProvider),
            set: (v) async {
              await _c.read(deviceNameProvider.notifier).set('${v ?? ''}');
              return null;
            },
          ),
          _Setting(
            id: 'language',
            label: l.commonLanguage,
            type: 'choice',
            options: [
              ('system', l.commonLanguageSystem),
              ('de', l.commonLanguageGerman),
              ('en', l.commonLanguageEnglish),
            ],
            get: () => _c.read(languageProvider).name,
            set: (v) async {
              await _c.read(languageProvider.notifier).set(AppLanguage.parse('$v'));
              return null;
            },
          ),
          _Setting(
            id: 'partRadio',
            label: l.adminPartRadio,
            type: 'bool',
            get: () => parts.radio,
            set: (v) async {
              await _c.read(systemPartsProvider.notifier).setRadio(_bool(v) ?? true);
              return null;
            },
          ),
          _Setting(
            id: 'partTv',
            label: l.adminPartTv,
            type: 'bool',
            get: () => parts.tv,
            set: (v) async {
              await _c.read(systemPartsProvider.notifier).setTv(_bool(v) ?? true);
              return null;
            },
          ),
          if (android)
            _Setting(
              id: 'partDashboard',
              label: l.adminPartDashboard,
              type: 'bool',
              get: () => parts.dashboard,
              set: (v) async {
                await _c.read(systemPartsProvider.notifier).setDashboard(_bool(v) ?? false);
                return null;
              },
            ),
          _Setting(
            id: 'partPictures',
            label: l.picturesAdminPart,
            type: 'bool',
            get: () => parts.pictures,
            set: (v) async {
              await _c.read(systemPartsProvider.notifier).setPictures(_bool(v) ?? false);
              return null;
            },
          ),
          _Setting(
            id: 'partMovies',
            label: l.moviesAdminPart,
            type: 'bool',
            get: () => parts.movies,
            set: (v) async {
              await _c.read(systemPartsProvider.notifier).setMovies(_bool(v) ?? false);
              return null;
            },
          ),
          _Setting(
            id: 'partMusic',
            label: l.musicAdminPart,
            type: 'bool',
            get: () => parts.music,
            set: (v) async {
              await _c.read(systemPartsProvider.notifier).setMusic(_bool(v) ?? false);
              return null;
            },
          ),
          if (BrowserChannel.supported)
            _Setting(
              id: 'partBrowser',
              label: l.browserAdminPart,
              type: 'bool',
              get: () => parts.browser,
              set: (v) async {
                await _c.read(systemPartsProvider.notifier).setBrowser(_bool(v) ?? true);
                return null;
              },
            ),
          _Setting(
            id: 'startScreen',
            label: l.adminStartScreen,
            type: 'choice',
            options: [
              ('launcher', 'Home'),
              if (parts.radio) ('radio', 'Radio'),
              if (parts.tv) ('tv', 'TV'),
              if (parts.dashboard) ('dashboard', l.dashboardTitle),
              if (apps.isNotEmpty) ('app', l.adminStartScreenApp),
            ],
            get: () => launcher.startScreen.name,
            set: (v) async {
              final s = StartScreen.values.where((s) => s.name == v).firstOrNull;
              if (s == null) return l.adminInvalidValue;
              if (s == StartScreen.app && startApp.isEmpty) return l.adminStartAppFirst;
              await _c.read(launcherSettingsProvider.notifier).setStartScreen(s);
              return null;
            },
          ),
          if (apps.isNotEmpty)
            _Setting(
              id: 'startApp',
              label: l.adminStartApp,
              type: 'choice',
              options: [
                ('', '–'),
                for (final a in [...apps]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase())))
                  (a.package, a.label),
              ],
              get: () => startApp,
              set: (v) async {
                await repo.setStartApp('${v ?? ''}');
                return null;
              },
            ),
          _Setting(
            id: 'uiScale',
            label: l.adminUiScale,
            type: 'int',
            help: '%',
            min: 50,
            max: 150,
            get: () => (_c.read(uiScaleProvider) * 100).round(),
            set: (v) async {
              final p = _int(v);
              if (p == null || p < 50 || p > 150) return l.adminInvalidValue;
              await _c.read(uiScaleProvider.notifier).set(p / 100);
              return null;
            },
          ),
          _Setting(
            id: 'clockDate',
            label: l.adminClockDate,
            type: 'bool',
            get: () => _c.read(showClockDateProvider),
            set: (v) async {
              await _c.read(showClockDateProvider.notifier).set(_bool(v) ?? false);
              return null;
            },
          ),
        ],
      ),
      if (parts.radio)
        (
          title: l.systemSettingsTitleRadio,
          items: [
            _Setting(
              id: 'weather',
              label: l.adminWeather,
              type: 'bool',
              get: () => weather.weatherEnabled,
              set: (v) async {
                await _c.read(weatherDisplaySettingsProvider.notifier).setWeatherEnabled(_bool(v) ?? true);
                return null;
              },
            ),
            _Setting(
              id: 'radar',
              label: l.adminRadar,
              type: 'bool',
              get: () => weather.radarEnabled,
              set: (v) async {
                await _c.read(weatherDisplaySettingsProvider.notifier).setRadarEnabled(_bool(v) ?? true);
                return null;
              },
            ),
            _Setting(
              id: 'sun',
              label: l.adminSun,
              type: 'bool',
              get: () => weather.sunEnabled,
              set: (v) async {
                await _c.read(weatherDisplaySettingsProvider.notifier).setSunEnabled(_bool(v) ?? true);
                return null;
              },
            ),
          ],
        ),
      if (parts.tv)
        (
          title: l.systemSettingsTitleTv,
          items: [
            _Setting(
              id: 'tvHost',
              label: l.adminTvHost,
              type: 'text',
              get: () => tv.host,
              set: (v) => setTv((c) => copyTv(c, host: '${v ?? ''}'.trim())),
            ),
            _Setting(
              id: 'tvWebPort',
              label: l.adminTvWebPort,
              type: 'int',
              min: 1,
              max: 65535,
              get: () => tv.webPort,
              set: (v) async {
                final p = _int(v);
                if (p == null || p < 1 || p > 65535) return l.adminInvalidValue;
                return setTv((c) => copyTv(c, webPort: p));
              },
            ),
            _Setting(
              id: 'tvStreamPort',
              label: l.adminTvStreamPort,
              type: 'int',
              min: 1,
              max: 65535,
              get: () => tv.streamPort,
              set: (v) async {
                final p = _int(v);
                if (p == null || p < 1 || p > 65535) return l.adminInvalidValue;
                return setTv((c) => copyTv(c, streamPort: p));
              },
            ),
            _Setting(
              id: 'tvHttps',
              label: l.adminTvHttps,
              type: 'bool',
              get: () => tv.useHttps,
              set: (v) => setTv((c) => copyTv(c, useHttps: _bool(v) ?? false)),
            ),
            _Setting(
              id: 'tvUser',
              label: l.adminTvUser,
              type: 'text',
              get: () => tv.user,
              set: (v) => setTv((c) => copyTv(c, user: '${v ?? ''}')),
            ),
            _Setting(
              id: 'tvPassword',
              label: l.adminTvPassword,
              type: 'secret',
              help: l.adminSecretHelp,
              get: () => '',
              set: (v) => setTv((c) => copyTv(c, password: '${v ?? ''}')),
            ),
            _Setting(
              id: 'tvNextUp',
              label: l.adminTvNextUp,
              type: 'bool',
              get: () => nextUp.enabled,
              set: (v) async {
                final n = await repo.getTvNextUp();
                await _c.read(tvNextUpProvider.notifier)
                    .set((enabled: _bool(v) ?? true, leadMinutes: n.leadMinutes, showSeconds: n.showSeconds));
                return null;
              },
            ),
          ],
        ),
      if (parts.pictures)
        (
          title: l.picturesSettingsTitle,
          items: [
            _Setting(
              id: 'slideshowInterval',
              label: l.picturesInterval,
              type: 'choice',
              options: [
                for (final s in SettingsRepository.slideshowIntervals) ('$s', l.picturesIntervalSeconds(s)),
              ],
              get: () => '${slideshow.intervalSeconds}',
              set: (v) {
                final s = _int(v);
                if (s == null || !SettingsRepository.slideshowIntervals.contains(s)) {
                  return Future.value(l.adminInvalidValue);
                }
                return setSlideshow((x) => x.copyWith(intervalSeconds: s));
              },
            ),
            _Setting(
              id: 'slideshowOrder',
              label: l.picturesOrder,
              type: 'choice',
              options: [
                (SlideshowOrder.folders.name, l.picturesOrderFolders),
                (SlideshowOrder.shuffled.name, l.picturesOrderShuffled),
              ],
              get: () => slideshow.order.name,
              set: (v) {
                final o = SlideshowOrder.values.where((o) => o.name == v).firstOrNull;
                if (o == null) return Future.value(l.adminInvalidValue);
                return setSlideshow((x) => x.copyWith(order: o));
              },
            ),
            _Setting(
              id: 'slideshowBlur',
              label: l.picturesBlur,
              type: 'bool',
              get: () => slideshow.blurredBackground,
              set: (v) => setSlideshow((x) => x.copyWith(blurredBackground: _bool(v) ?? true)),
            ),
          ],
        ),
      if (parts.music)
        (
          title: l.musicSettingsTitle,
          items: [
            _Setting(
              id: 'musicShuffle',
              label: l.musicSettingsShuffle,
              type: 'bool',
              get: () => music.shuffle,
              set: (v) => setMusic((s) => s.copyWith(shuffle: _bool(v) ?? false)),
            ),
            _Setting(
              id: 'musicRepeat',
              label: l.musicSettingsRepeat,
              type: 'choice',
              options: [
                (MusicRepeat.off.name, l.musicRepeatOff),
                (MusicRepeat.all.name, l.musicRepeatAll),
                (MusicRepeat.one.name, l.musicRepeatOne),
              ],
              get: () => music.repeat.name,
              set: (v) {
                final r = MusicRepeat.values.where((x) => x.name == v).firstOrNull;
                return r == null ? Future.value(l.adminInvalidValue) : setMusic((s) => s.copyWith(repeat: r));
              },
            ),
            _Setting(
              id: 'musicSubfolders',
              label: l.musicWithSubfolders,
              help: l.musicWithSubfoldersHelp,
              type: 'bool',
              get: () => music.subfolders,
              set: (v) => setMusic((s) => s.copyWith(subfolders: _bool(v) ?? false)),
            ),
            _Setting(
              id: 'musicPreferTags',
              label: l.musicSettingsPreferTags,
              help: l.musicSettingsPreferTagsHelp,
              type: 'bool',
              get: () => music.preferTags,
              set: (v) => setMusic((s) => s.copyWith(preferTags: _bool(v) ?? true)),
            ),
            _Setting(
              id: 'musicVisualizer',
              label: l.musicSettingsVisualizer,
              type: 'choice',
              options: [
                (MusicVisualizerMode.off.name, l.musicVisualizerOff),
                (MusicVisualizerMode.manual.name, l.musicVisualizerManual),
                (MusicVisualizerMode.auto.name, l.musicVisualizerAuto),
              ],
              get: () => music.visualizer.name,
              set: (v) {
                final m = MusicVisualizerMode.values.where((x) => x.name == v).firstOrNull;
                return m == null ? Future.value(l.adminInvalidValue) : setMusic((s) => s.copyWith(visualizer: m));
              },
            ),
            _Setting(
              id: 'musicVisualizerInterval',
              label: l.musicSettingsInterval,
              type: 'choice',
              options: [
                for (final s in MusicSettings.visualizerIntervals)
                  ('$s', s == 0 ? l.musicIntervalManual : l.musicIntervalSeconds(s)),
              ],
              get: () => '${music.visualizerInterval}',
              set: (v) {
                final s = _int(v);
                if (s == null || !MusicSettings.visualizerIntervals.contains(s)) {
                  return Future.value(l.adminInvalidValue);
                }
                return setMusic((x) => x.copyWith(visualizerInterval: s));
              },
            ),
            _Setting(
              id: 'musicVisualizerQuality',
              label: l.musicSettingsQuality,
              type: 'choice',
              options: [
                (MusicVisualizerQuality.auto.name, l.musicQualityAuto),
                (MusicVisualizerQuality.low.name, l.musicQualityLow),
                (MusicVisualizerQuality.high.name, l.musicQualityHigh),
              ],
              get: () => music.quality.name,
              set: (v) {
                final q = MusicVisualizerQuality.values.where((x) => x.name == v).firstOrNull;
                return q == null ? Future.value(l.adminInvalidValue) : setMusic((s) => s.copyWith(quality: q));
              },
            ),
          ],
        ),
      if (BrowserChannel.supported && parts.browser)
        (
          title: l.browserSettingsTitle,
          items: [
            _Setting(
              id: 'browserBlocker',
              label: l.browserBlocker,
              type: 'bool',
              get: () => browser.blocker,
              set: (v) => setBrowser((s) => s.copyWith(blocker: _bool(v) ?? true)),
            ),
            _Setting(
              id: 'browserSearchEngine',
              label: l.browserSearchEngine,
              type: 'choice',
              options: [for (final e in SearchEngine.values) (e.name, e.label)],
              get: () => browser.searchEngine.name,
              set: (v) => setBrowser((s) => s.copyWith(searchEngine: SearchEngine.parse('$v'))),
            ),
            _Setting(
              id: 'browserHomePage',
              label: l.browserHomePage,
              type: 'text',
              get: () => browser.homePage,
              set: (v) {
                final text = '${v ?? ''}'.trim();
                return setBrowser((s) => s.copyWith(homePage: text.isEmpty ? '' : browserUrlFor(text, s.searchEngine)));
              },
            ),
            _Setting(
              id: 'browserDesktop',
              label: l.browserDesktopDefault,
              type: 'bool',
              get: () => browser.desktop,
              set: (v) => setBrowser((s) => s.copyWith(desktop: _bool(v) ?? false)),
            ),
          ],
        ),
      if (android && parts.dashboard)
        (
          title: l.dashboardSettingsTitle,
          items: [
            _Setting(
              id: 'dashboardUrl',
              label: l.dashboardAddress,
              type: 'text',
              help: l.dashboardAddressHint,
              get: () => dashboardUrl,
              set: (v) async {
                await _c.read(dashboardUrlProvider.notifier).set('${v ?? ''}');
                return null;
              },
            ),
            _Setting(
              id: 'motion',
              label: l.dashboardMotion,
              type: 'bool',
              get: () => display.motion,
              set: (v) async {
                final on = _bool(v) ?? false;
                // The camera permission can only be granted on the device.
                if (on && !await _c.read(displayServiceProvider).hasCameraPermission()) return l.adminCameraOnDevice;
                final d = await repo.getDashboardDisplay();
                await _c.read(dashboardDisplayProvider.notifier).set(d.copyWith(motion: on));
                return null;
              },
            ),
            _Setting(
              id: 'motionDimOnly',
              label: l.dashboardDimOnly,
              type: 'bool',
              help: l.dashboardDimOnlyHelp,
              get: () => display.dimOnly,
              set: (v) async {
                final d = await repo.getDashboardDisplay();
                await _c.read(dashboardDisplayProvider.notifier).set(d.copyWith(dimOnly: _bool(v) ?? false));
                return null;
              },
            ),
            _Setting(
              id: 'motionSensitivity',
              label: l.dashboardSensitivity,
              type: 'int',
              help: '1–10',
              min: 1,
              max: 10,
              get: () => display.sensitivity,
              set: (v) async {
                final s = _int(v);
                if (s == null || s < 1 || s > 10) return l.adminInvalidValue;
                final d = await repo.getDashboardDisplay();
                await _c.read(dashboardDisplayProvider.notifier).set(d.copyWith(sensitivity: s));
                return null;
              },
            ),
            _Setting(
              id: 'motionTimeout',
              label: l.adminMotionTimeout,
              type: 'int',
              help: l.adminMotionTimeoutHelp,
              min: 0,
              max: 240,
              get: () => display.timeoutMinutes,
              set: (v) async {
                final m = _int(v);
                if (m == null || m < 0 || m > 240) return l.adminInvalidValue;
                final d = await repo.getDashboardDisplay();
                await _c.read(dashboardDisplayProvider.notifier).set(d.copyWith(timeoutMinutes: m));
                return null;
              },
            ),
            _Setting(
              id: 'brightnessMode',
              label: l.dashboardBrightnessHeading,
              type: 'choice',
              options: [
                ('system', l.dashboardBrightnessSystem),
                ('fixed', l.dashboardBrightnessFixed),
                ('adaptive', l.dashboardBrightnessAdaptive),
              ],
              get: () => brightness.mode.name,
              set: (v) {
                final m = BrightnessMode.values.where((m) => m.name == v).firstOrNull;
                if (m == null) return Future.value(l.adminInvalidValue);
                return setBrightness((b) => b.copyWith(mode: m));
              },
            ),
            percent('brightnessLevel', l.dashboardBrightnessLevel, brightness.level, 5, (b, p) => b.copyWith(level: p)),
            percent('brightnessMin', l.dashboardBrightnessMin, brightness.min, 1, (b, p) => b.copyWith(min: p)),
            percent('brightnessMax', l.dashboardBrightnessMax, brightness.max, 1, (b, p) => b.copyWith(max: p)),
            _Setting(
              id: 'brightnessLuxForMax',
              label: l.dashboardBrightnessLuxForMax,
              type: 'int',
              help: 'lx',
              min: 1,
              max: 100000,
              get: () => brightness.luxForMax,
              set: (v) {
                final x = _int(v);
                if (x == null || x < 1) return Future.value(l.adminInvalidValue);
                return setBrightness((b) => b.copyWith(luxForMax: x));
              },
            ),
            _Setting(
              id: 'motionWebhook',
              label: l.dashboardWebhook,
              type: 'text',
              help: l.dashboardWebhookHint,
              get: () => display.webhookUrl,
              set: (v) async {
                final d = await repo.getDashboardDisplay();
                await _c.read(dashboardDisplayProvider.notifier).set(d.copyWith(webhookUrl: '${v ?? ''}'));
                return null;
              },
            ),
          ],
        ),
    ];
  }

  @override
  Future<List<Map<String, Object?>>> describe() async => [
        for (final g in await _groups()) {'title': g.title, 'items': [for (final s in g.items) s.toJson()]},
      ];

  @override
  Future<String?> apply(String id, Object? value) async {
    for (final g in await _groups()) {
      for (final s in g.items) {
        if (s.id == id) return s.set(value);
      }
    }
    return l10n.adminUnknownSetting;
  }
}
