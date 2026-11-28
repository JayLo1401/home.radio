import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../core/dashboard_providers.dart';
import '../../core/ha_providers.dart';
import '../../core/nas_providers.dart';
import '../../core/pictures_providers.dart';
import '../../core/providers.dart';
import '../../data/services/music_library.dart' show MusicRepeat;
import '../../data/repositories/nas_settings_repository.dart';
import '../../data/repositories/music_settings_repository.dart';
import '../../core/music_providers.dart';
import '../../core/system_providers.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/admin_server.dart';
import '../../data/services/display_service.dart';
import '../../data/services/ha_discovery.dart';
import '../../data/services/enigma2_service.dart';
import '../../data/services/launcher_service.dart';
import '../../data/services/nas_backup_service.dart';
import '../../data/services/nas_service.dart';
import '../../data/services/update_service.dart';
import '../../data/services/picture_library.dart' show SlideshowOrder;
import '../../l10n/l10n.dart';
import '../browser/browser_channel.dart';
import '../browser/browser_settings.dart';
import '../dashboard/dashboard_mini_player.dart' show dashboardPopupPositionLabel;
import '../launcher/launcher_providers.dart';
import '../settings/ha_settings_screen.dart' show haLinkStatusText;
import '../settings/settings_screen.dart' show tvListTextLabel;
import '../tv/tv_providers.dart';
import '../tv/tv_reminder_providers.dart' show tvReminderLeadProvider;
import '../tv/tv_timeshift.dart' show TvTimeshiftMode, TvTimeshiftStore, tvTimeshiftMinuteChoices, tvTimeshiftProvider;

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
    this.button,
    this.folder,
  }) : run = null;

  /// Lines of text to read (nothing to change) - e.g. "Dieses Gerät".
  _Setting.info({required this.id, required this.label, required List<String> lines})
      : type = 'info',
        get = (() => lines),
        set = _readOnly,
        help = null,
        options = const [],
        min = null,
        max = null,
        button = null,
        run = null,
        folder = null;

  /// A button ([button]) that does something on the device and says how it
  /// went - test the NAS, backup to the NAS, look for updates ...
  _Setting.action({required this.id, required this.label, required String this.button, required this.run, this.help})
      : type = 'action',
        get = (() => null),
        set = _readOnly,
        options = const [],
        min = null,
        max = null,
        folder = null;

  static Future<String?> _readOnly(Object? _) async => l10n.adminInvalidValue;

  final String id;
  final String label;

  /// bool, int, choice, text, secret (write-only: never sent to the page),
  /// info (lines to read), action (a button), folder (a NAS folder: the
  /// page browses the NAS through AdminSettings.browse).
  final String type;
  final String? button;
  final Future<AdminResult> Function()? run;
  final NasFolder? folder;
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
        'button': ?button,
        'value': type == 'secret' ? '' : get(),
      };
}

/// A group of settings on one area's page, like the headings on the
/// device's settings pages.
typedef _Group = ({String area, String title, String? help, List<_Setting> items});

_Group _group(String area, String title, List<_Setting> items, {String? help}) =>
    (area: area, title: title, help: help, items: items);

/// The settings the admin page (`http://<ip>:1401/`) can change - through
/// the same providers the app's own settings use, so the device follows at
/// once. Not everything: what needs the device itself (receiver search,
/// camera permission, the Home key) stays on the device.
class AdminSettings implements AdminSettingsSource {
  AdminSettings(this._c);

  final ProviderContainer _c;

  static bool? _bool(Object? v) => v is bool ? v : (v is String ? v == 'true' : null);
  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

  Future<List<_Group>> _groups() async {
    final l = l10n;
    final parts = _c.read(systemPartsProvider);
    final launcher = _c.read(launcherSettingsProvider);
    final weather = _c.read(weatherDisplaySettingsProvider);
    // From the database, not the providers: those that the device hasn't
    // needed yet (TV not opened) still hold their defaults.
    final repo = _c.read(settingsRepositoryProvider);
    final tv = await repo.getEnigma2Config();
    final nextUp = await repo.getTvNextUp();
    final timeshift = await TvTimeshiftStore(_c.read(databaseProvider)).load();
    final tvView = await repo.getTvView();
    Future<String?> setTvView(TvViewSettings Function(TvViewSettings v) f) async {
      await _c.read(tvViewProvider.notifier).set(f(await repo.getTvView()));
      return null;
    }
    final startApp = await repo.getStartApp();
    final apps = LauncherService.supported ? await _c.read(launcherServiceProvider).listApps() : const <InstalledApp>[];
    final dashboardUrl = await repo.getDashboardUrl();
    final display = await repo.getDashboardDisplay();
    final popup = await repo.getDashboardPopup();
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
    final showVideos = await repo.getPicturesShowVideos();
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
      _group('system', l.settingsPartsHeading, [
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
      ]),
      _group('system', l.settingsDeviceHeading, [
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
      ]),
      _group('system', l.adminStartScreen, [
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
      ]),
      _group('system', l.settingsDisplayHeading, [
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
      ]),
      ...await _systemExtras(),
      if (parts.radio)
        (
          area: 'radio',
          help: null,
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
          area: 'tv',
          help: null,
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
              id: 'tvReminderLead',
              label: l.tvReminderLead,
              help: l.tvReminderSettingsHelp,
              type: 'choice',
              options: [for (final m in SettingsRepository.tvReminderLeadChoices) ('$m', l.settingsMinutesShort(m))],
              get: () => '${_c.read(tvReminderLeadProvider)}',
              set: (v) async {
                final m = _int(v);
                if (m == null || !SettingsRepository.tvReminderLeadChoices.contains(m)) return l.adminInvalidValue;
                await _c.read(tvReminderLeadProvider.notifier).set(m);
                return null;
              },
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
            _Setting(
              id: 'tvTimeshiftMode',
              label: l.tvShiftTitle,
              help: l.tvShiftSettingsHelp,
              type: 'choice',
              options: [
                (TvTimeshiftMode.off.name, l.tvShiftModeOff),
                (TvTimeshiftMode.memory.name, l.tvShiftModeMemory),
                (TvTimeshiftMode.local.name, l.tvShiftModeLocal),
                (TvTimeshiftMode.nas.name, l.tvShiftModeNas),
              ],
              get: () => timeshift.mode.name,
              set: (v) async {
                final mode = TvTimeshiftMode.values.where((m) => m.name == v).firstOrNull;
                if (mode == null) return l.adminInvalidValue;
                final now = await TvTimeshiftStore(_c.read(databaseProvider)).load();
                await _c.read(tvTimeshiftProvider.notifier).set((mode: mode, minutes: now.minutes));
                return null;
              },
            ),
            _Setting(
              id: 'tvTimeshiftMinutes',
              label: l.tvShiftMaxMinutes,
              help: l.tvShiftMaxMinutesHelp,
              type: 'choice',
              options: [for (final m in tvTimeshiftMinuteChoices) ('$m', l.tvMinutes(m))],
              get: () => '${timeshift.minutes}',
              set: (v) async {
                final m = _int(v);
                if (m == null || !tvTimeshiftMinuteChoices.contains(m)) return l.adminInvalidValue;
                final now = await TvTimeshiftStore(_c.read(databaseProvider)).load();
                await _c.read(tvTimeshiftProvider.notifier).set((mode: now.mode, minutes: m));
                return null;
              },
            ),
            _Setting(
              id: 'tvInfoSeconds',
              label: l.settingsTvInfoSeconds,
              help: l.settingsTvViewHelp,
              type: 'choice',
              options: [for (final s in TvViewSettings.infoSecondChoices) ('$s', l.settingsTvInfoSecondsValue(s))],
              get: () => '${tvView.infoSeconds}',
              set: (v) {
                final s = _int(v);
                if (s == null || !TvViewSettings.infoSecondChoices.contains(s)) return Future.value(l.adminInvalidValue);
                return setTvView((t) => t.copyWith(infoSeconds: s));
              },
            ),
            _Setting(
              id: 'tvListText',
              label: l.settingsTvListText,
              type: 'choice',
              options: [for (final size in TvListTextSize.values) (size.name, tvListTextLabel(l, size))],
              get: () => tvView.listText.name,
              set: (v) {
                final size = TvListTextSize.values.where((s) => s.name == v).firstOrNull;
                if (size == null) return Future.value(l.adminInvalidValue);
                return setTvView((t) => t.copyWith(listText: size));
              },
            ),
            _Setting(
              id: 'tvListInfo',
              label: l.settingsTvListInfo,
              help: l.settingsTvListInfoHelp,
              type: 'bool',
              get: () => tvView.listInfo,
              set: (v) => setTvView((t) => t.copyWith(listInfo: _bool(v) ?? true)),
            ),
            if (Platform.isAndroid)
              _Setting(
                id: 'tvMatchFrameRate',
                label: l.settingsTvFrameRate,
                help: l.settingsTvFrameRateHelp,
                type: 'bool',
                get: () => tvView.matchFrameRate,
                set: (v) => setTvView((t) => t.copyWith(matchFrameRate: _bool(v) ?? true)),
              ),
          ],
        ),
      if (parts.pictures)
        (
          area: 'pictures',
          help: null,
          title: l.picturesSettingsTitle,
          items: [
            _Setting(
              id: 'picturesShowVideos',
              label: l.picturesShowVideos,
              type: 'bool',
              get: () => showVideos,
              set: (v) async {
                await _c.read(picturesShowVideosProvider.notifier).set(_bool(v) ?? false);
                return null;
              },
            ),
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
          area: 'music',
          help: null,
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
          area: 'browser',
          help: null,
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
          area: 'dashboard',
          help: null,
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
              id: 'dashboardPopup',
              label: l.dashboardPopupShow,
              type: 'bool',
              get: () => popup.show,
              set: (v) async {
                final p = await repo.getDashboardPopup();
                await _c.read(dashboardPopupProvider.notifier).set(p.copyWith(show: _bool(v) ?? true));
                return null;
              },
            ),
            _Setting(
              id: 'dashboardPopupPosition',
              label: l.dashboardPopupPosition,
              type: 'choice',
              options: [
                for (final p in DashboardPopupPosition.values) (p.name, dashboardPopupPositionLabel(l, p)),
              ],
              get: () => popup.position.name,
              set: (v) async {
                final position = DashboardPopupPosition.values.where((p) => p.name == v).firstOrNull;
                if (position == null) return l.adminInvalidValue;
                final p = await repo.getDashboardPopup();
                await _c.read(dashboardPopupProvider.notifier).set(p.copyWith(position: position));
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

  /// System's pages beyond the switches: the NAS (server, test, folders),
  /// backup to the NAS, updates and what the device is.
  Future<List<_Group>> _systemExtras() async {
    final l = l10n;
    final nasRepo = _c.read(nasSettingsRepositoryProvider);
    final nas = await nasRepo.load();
    final c = nas.config;
    Future<String?> setNas(NasConfig Function(NasConfig c) change) async {
      await _c.read(nasSettingsProvider.notifier).setConfig(change((await nasRepo.load()).config));
      return null;
    }

    final defaultPort = switch (c.protocol) {
      NasProtocol.ftp => 21,
      NasProtocol.smb => SmbClient.port,
      NasProtocol.webdav => c.https ? 443 : 80,
    };
    final hasServer = c.isConfigured;
    final updates = _c.read(updateServiceProvider);
    final version = await updates.currentVersion();
    final device = await updates.deviceInfo();
    final settingsRepo = _c.read(settingsRepositoryProvider);
    final auto = await settingsRepo.getAutoUpdate();
    final ha = await settingsRepo.getHaLink();
    final haLink = _c.read(haMqttLinkProvider);
    Future<String?> setHa(HaLinkSettings Function(HaLinkSettings s) change) async {
      await _c.read(haLinkSettingsProvider.notifier).set(change(await settingsRepo.getHaLink()));
      return null;
    }

    return [
      _group('system', l.nasTitle, help: l.nasIntro, [
        _Setting(
          id: 'nasProtocol',
          label: l.adminNasProtocol,
          type: 'choice',
          help: switch (c.protocol) {
            NasProtocol.webdav => l.nasProtocolWebdavHint,
            NasProtocol.ftp => l.nasProtocolFtpHint,
            NasProtocol.smb => l.nasProtocolSmbHint,
          },
          options: [
            (NasProtocol.webdav.name, l.nasProtocolWebdav),
            (NasProtocol.ftp.name, l.nasProtocolFtp),
            (NasProtocol.smb.name, l.nasProtocolSmb),
          ],
          get: () => c.protocol.name,
          set: (v) {
            final protocol = NasProtocol.values.where((p) => p.name == v).firstOrNull;
            if (protocol == null) return Future.value(l.adminInvalidValue);
            return setNas((x) => _copyNas(x, protocol: protocol));
          },
        ),
        _Setting(
          id: 'nasHost',
          label: l.nasHost,
          help: l.nasHostHint,
          type: 'text',
          get: () => c.host,
          set: (v) => setNas((x) => _copyNas(x, host: '${v ?? ''}'.trim())),
        ),
        _Setting(
          id: 'nasPort',
          label: l.nasPort(defaultPort),
          type: 'text',
          get: () => c.port?.toString() ?? '',
          set: (v) {
            final text = '${v ?? ''}'.trim();
            final port = int.tryParse(text);
            if (text.isNotEmpty && (port == null || port < 1 || port > 65535)) {
              return Future.value(l.adminInvalidValue);
            }
            return setNas((x) => _copyNas(x, port: port, clearPort: port == null));
          },
        ),
        if (c.protocol == NasProtocol.webdav) ...[
          _Setting(
            id: 'nasHttps',
            label: l.nasHttps,
            help: l.nasHttpsHint,
            type: 'bool',
            get: () => c.https,
            set: (v) => setNas((x) => _copyNas(x, https: _bool(v) ?? false)),
          ),
          _Setting(
            id: 'nasBasePath',
            label: l.nasBasePath,
            help: l.nasBasePathHint,
            type: 'text',
            get: () => c.basePath,
            set: (v) => setNas((x) => _copyNas(x, basePath: '${v ?? ''}'.trim())),
          ),
        ],
        _Setting(
          id: 'nasUser',
          label: l.nasUser,
          type: 'text',
          get: () => c.user,
          set: (v) => setNas((x) => _copyNas(x, user: '${v ?? ''}'.trim())),
        ),
        _Setting(
          id: 'nasPassword',
          label: l.nasPassword,
          type: 'secret',
          help: l.adminSecretHelp,
          get: () => '',
          set: (v) => setNas((x) => _copyNas(x, password: '${v ?? ''}')),
        ),
        if (c.protocol == NasProtocol.smb)
          _Setting(
            id: 'nasDomain',
            label: l.nasDomain,
            help: l.nasSmbLoginHint,
            type: 'text',
            get: () => c.domain,
            set: (v) => setNas((x) => _copyNas(x, domain: '${v ?? ''}'.trim())),
          ),
        _Setting.action(
          id: 'nasTest',
          label: l.nasTest,
          button: l.nasTest,
          run: () async {
            final config = (await nasRepo.load()).config;
            if (!config.isConfigured) return (ok: false, message: l.nasNeedServer);
            final client = config.createClient();
            try {
              final entries = await client.list('/').timeout(const Duration(seconds: 30));
              return (ok: true, message: l.nasTestOk(entries.length));
            } on NasException catch (e) {
              return (ok: false, message: l.nasTestFailed(e.message));
            } on TimeoutException {
              return (ok: false, message: l.nasTestFailed(l.nasErrorTimeout));
            } catch (e) {
              return (ok: false, message: l.nasTestFailed('$e'));
            } finally {
              client.close();
            }
          },
        ),
      ]),
      _group('system', l.nasFoldersSection, help: hasServer ? l.adminNasFoldersHint : l.nasNeedServer, [
        for (final kind in singleNasFolders)
          _Setting(
            id: 'nasFolder_${kind.name}',
            label: nasFolderName(kind),
            type: 'folder',
            folder: kind,
            button: l.adminBrowse,
            get: () => nas.folders[kind] ?? '',
            set: (v) async {
              final path = '${v ?? ''}'.trim();
              await _c.read(nasSettingsProvider.notifier).setFolder(kind, path.isEmpty ? null : normalizeNasPath(path));
              return null;
            },
          ),
      ]),
      _group('system', l.nasMovieFoldersSection, help: hasServer ? l.adminMovieFoldersHint : l.nasNeedServer, [
        ..._movieFolderSettings(nas.movieFolders),
      ]),
      _group('system', l.adminNasBackupHeading, help: l.nasBackupsHint(NasBackupService.keep), [
        _Setting.action(
          id: 'nasBackupNow',
          label: l.adminNasBackupNow,
          button: l.settingsBackupCreate,
          run: () async {
            try {
              final name = await _c.read(nasBackupServiceProvider).backupNow().timeout(const Duration(minutes: 2));
              return name == null
                  ? (ok: false, message: l.adminNasBackupNoFolder)
                  : (ok: true, message: l.adminNasBackupDone(name));
            } on NasException catch (e) {
              return (ok: false, message: l.settingsBackupFailed(e.message));
            } on TimeoutException {
              return (ok: false, message: l.settingsBackupFailed(l.nasErrorTimeout));
            } catch (e) {
              return (ok: false, message: l.settingsBackupFailed('$e'));
            }
          },
        ),
      ]),
      _group('system', l.haTitle, help: l.haIntro, [
        _Setting.info(
          id: 'haStatus',
          label: haLinkStatusText(
            l,
            haLink.state.value,
            haLink.error.value,
            deviceName: _c.read(deviceNameProvider),
            hasHost: haBrokerFor(ha.copyWith(enabled: true), await settingsRepo.getDashboardUrl()) != null,
          ),
          lines: const [],
        ),
        _Setting(
          id: 'haEnabled',
          label: l.haEnabled,
          type: 'bool',
          get: () => ha.enabled,
          set: (v) => setHa((x) => x.copyWith(enabled: _bool(v) ?? false)),
        ),
        _Setting(
          id: 'haHost',
          label: l.haHost,
          help: l.haHostHelp,
          type: 'text',
          get: () => ha.host,
          set: (v) => setHa((x) => x.copyWith(host: '${v ?? ''}'.trim())),
        ),
        _Setting.action(
          id: 'haSearch',
          label: l.lanSearchHa,
          help: l.lanSearchHaAdminHelp,
          button: l.lanSearchButton,
          run: () async {
            final found = await findHomeAssistant().toList();
            if (found.isEmpty) return (ok: false, message: l.lanSearchHaNone);
            if (found.length > 1) {
              return (ok: true, message: l.lanSearchHaSeveral(found.map((f) => f.name ?? f.host).join(', ')));
            }
            final ha = found.single;
            await setHa((x) => x.copyWith(host: ha.host));
            if ((await settingsRepo.getDashboardUrl()).trim().isEmpty) {
              await _c.read(dashboardUrlProvider.notifier).set(ha.url);
            }
            return (ok: true, message: l.lanSearchHaTaken(ha.name ?? ha.host, ha.url));
          },
        ),
        _Setting(
          id: 'haPort',
          label: l.haPort(HaLinkSettings.defaultPort),
          type: 'text',
          get: () => ha.port == HaLinkSettings.defaultPort ? '' : '${ha.port}',
          set: (v) {
            final text = '${v ?? ''}'.trim();
            final port = text.isEmpty ? HaLinkSettings.defaultPort : int.tryParse(text);
            if (port == null || port < 1 || port > 65535) return Future.value(l.adminInvalidValue);
            return setHa((x) => x.copyWith(port: port));
          },
        ),
        _Setting(
          id: 'haUser',
          label: l.haUser,
          help: l.haLoginHint,
          type: 'text',
          get: () => ha.user,
          set: (v) => setHa((x) => x.copyWith(user: '${v ?? ''}'.trim())),
        ),
        _Setting(
          id: 'haPassword',
          label: l.nasPassword,
          type: 'secret',
          help: l.adminSecretHelp,
          get: () => '',
          set: (v) => setHa((x) => x.copyWith(password: '${v ?? ''}')),
        ),
        if (DisplayService.supported)
          _Setting(
            id: 'haShareCamera',
            label: l.haShareCamera,
            help: l.haShareCameraHelp,
            type: 'bool',
            get: () => ha.shareCamera,
            set: (v) async {
              final on = _bool(v) ?? false;
              // The camera permission can only be granted on the device.
              if (on && !await _c.read(displayServiceProvider).hasCameraPermission()) return l.adminCameraOnDevice;
              return setHa((x) => x.copyWith(shareCamera: on));
            },
          ),
      ]),
      _group('system', l.miscUpdatesTitle, [
        _Setting.info(id: 'updateVersion', label: l.miscUpdateInstalledVersion(version), lines: [
          if (!UpdateService.supported) l.miscUpdateLocalBuild,
        ]),
        if (UpdateService.supported) ...[
          _Setting(
            id: 'updateAuto',
            label: l.miscUpdateAuto,
            help: l.miscUpdateAutoHint,
            type: 'bool',
            get: () => auto,
            set: (v) async {
              await settingsRepo.setAutoUpdate(_bool(v) ?? true);
              return null;
            },
          ),
          _Setting.action(
            id: 'updateCheck',
            label: l.adminUpdateCheck,
            button: l.miscUpdateCheckAgain,
            run: () async {
              final update = await updates.check();
              return (ok: true, message: update == null ? l.miscUpdateUpToDate : l.miscUpdateAvailable(update.version));
            },
          ),
          _Setting.action(
            id: 'updateInstall',
            label: l.adminUpdateInstall,
            help: l.adminUpdateInstallHelp,
            button: l.miscUpdateNow,
            run: () async {
              final update = await updates.check();
              if (update == null) return (ok: true, message: l.miscUpdateUpToDate);
              // Downloading takes a while - the page doesn't wait.
              unawaited(() async {
                try {
                  await updates.install(update, beforeInstall: () async {
                    try {
                      await _c.read(nasBackupServiceProvider).backupNow().timeout(const Duration(seconds: 30));
                    } catch (e) {
                      debugPrint('admin update: NAS backup: $e');
                    }
                  });
                } catch (e) {
                  debugPrint('admin update: $e');
                }
              }());
              return (ok: true, message: l.adminUpdateStarted(update.version));
            },
          ),
        ],
      ]),
      if (device != null)
        _group('system', l.miscDeviceTitle, [
          _Setting.info(id: 'deviceInfo', label: device.name, lines: _deviceLines(device, version)),
          _Setting.info(id: 'apkVariants', label: l.miscDeviceVariantsTitle, lines: [
            l.miscDeviceVariantArmv7,
            l.miscDeviceVariantArm64,
            l.miscDeviceVariantX86,
            l.miscDeviceVariantUniversal,
            l.miscDeviceMinAndroid(apkMinAndroid),
          ]),
        ]),
    ];
  }

  /// "Dieses Gerät" as on the device (Settings → Updates).
  static List<String> _deviceLines(DeviceAppInfo d, String version) {
    final l = l10n;
    final abi = d.abis.isEmpty ? '?' : d.abis.first;
    final ram = d.ramBytes;
    final installed = d.installed;
    return [
      l.miscDeviceAndroid(d.release, d.sdk),
      d.system64 ? l.miscDeviceSystem64(abi) : l.miscDeviceSystem32(abi),
      if (!d.system64 && d.cpu64) l.miscDeviceCpu64On32,
      if (d.chip != null) l.miscDeviceChip(d.chip!),
      if (ram != null && ram > 0) l.miscDeviceRam(NumberFormat('0.0', l.localeName).format(ram / (1 << 30))),
      if (installed != null) l.miscDeviceInstalled(installed),
      l.miscDeviceRecommended('home_system-$version-${d.recommended}.apk'),
      if (installed != null)
        d.installedFits
            ? l.miscDeviceFits
            : installed == 'universal'
                ? l.miscDeviceUniversal
                : l.miscDeviceOther,
    ];
  }

  static NasConfig _copyNas(
    NasConfig c, {
    NasProtocol? protocol,
    String? host,
    int? port,
    bool clearPort = false,
    bool? https,
    String? basePath,
    String? user,
    String? password,
    String? domain,
  }) =>
      NasConfig(
        protocol: protocol ?? c.protocol,
        host: host ?? c.host,
        port: clearPort ? null : (port ?? c.port),
        https: https ?? c.https,
        basePath: basePath ?? c.basePath,
        user: user ?? c.user,
        password: password ?? c.password,
        domain: domain ?? c.domain,
      );

  /// Settings → NAS → Film-Ordner: per folder its place on the NAS
  /// (Durchsuchen, × removes it), its name and its place in the list; then
  /// a row to add one.
  List<_Setting> _movieFolderSettings(List<MovieFolder> folders) {
    final l = l10n;
    final nas = _c.read(nasSettingsProvider.notifier);
    return [
      for (final (i, folder) in folders.indexed) ...[
        _Setting(
          id: 'movieFolder_$i',
          label: folder.label,
          type: 'folder',
          button: l.adminBrowse,
          get: () => folder.path,
          set: (v) async {
            final path = '${v ?? ''}'.trim();
            path.isEmpty ? await nas.removeMovieFolder(i) : await nas.setMovieFolderPath(i, path);
            return null;
          },
        ),
        _Setting(
          id: 'movieFolderName_$i',
          label: l.adminMovieFolderName,
          help: l.adminMovieFolderNameHelp,
          type: 'text',
          get: () => folder.name,
          set: (v) async {
            await nas.renameMovieFolder(i, '${v ?? ''}');
            return null;
          },
        ),
        if (folders.length > 1)
          _Setting(
            id: 'movieFolderPosition_$i',
            label: l.adminMovieFolderPosition,
            type: 'choice',
            options: [for (var p = 0; p < folders.length; p++) ('$p', '${p + 1}')],
            get: () => '$i',
            set: (v) async {
              final to = _int(v);
              if (to == null || to < 0 || to >= folders.length) return l.adminInvalidValue;
              await nas.moveMovieFolder(i, to);
              return null;
            },
          ),
      ],
      _Setting(
        id: 'movieFolderAdd',
        label: l.adminMovieFolderAdd,
        help: l.adminMovieFolderAddHelp,
        type: 'folder',
        button: l.adminBrowse,
        get: () => '',
        set: (v) async {
          final path = '${v ?? ''}'.trim();
          if (path.isNotEmpty) await nas.addMovieFolder(path);
          return null;
        },
      ),
    ];
  }

  static String nasFolderName(NasFolder kind) => switch (kind) {
        NasFolder.backgrounds => l10n.nasFolderBackgrounds,
        NasFolder.pictures => l10n.nasFolderPictures,
        NasFolder.music => l10n.nasFolderMusic,
        NasFolder.videos => l10n.nasFolderVideos,
        NasFolder.movies => l10n.nasFolderMovies,
        NasFolder.backups => l10n.nasFolderBackups,
        NasFolder.recordings => l10n.nasFolderRecordings,
        NasFolder.timeshift => l10n.nasFolderTimeshift,
      };

  /// The areas of the overview - the same as on the device's first
  /// settings page (logo, title, what's inside; greyed when switched off).
  List<Map<String, Object?>> _areas() {
    final l = l10n;
    final parts = _c.read(systemPartsProvider);
    Map<String, Object?> area(String id, String logo, String title, String subtitle, {bool enabled = true}) =>
        {'id': id, 'logo': logo, 'title': title, 'subtitle': enabled ? subtitle : l.settingsAreaOff, 'enabled': enabled};
    return [
      area('system', 'home_system_logo', 'System',
          LauncherService.supported ? l.settingsAreaSystemSubtitle : l.settingsAreaSystemSubtitleNoHomeKey),
      area('radio', 'radio_logo', 'Radio', l.settingsAreaRadioSubtitle, enabled: parts.radio),
      area('tv', 'tv_logo', 'TV', l.settingsAreaTvSubtitle, enabled: parts.tv),
      if (DisplayService.supported)
        area('dashboard', 'dashboard_logo', l.dashboardTitle, l.dashboardAreaSubtitle, enabled: parts.dashboard),
      area('pictures', 'pictures_logo', l.picturesTitle, l.picturesAreaSubtitle, enabled: parts.pictures),
      area('music', 'music_logo', l.musicTitle, l.musicAreaSubtitle, enabled: parts.music),
      if (BrowserChannel.supported)
        area('browser', 'browser_logo', l.browserTitle, l.browserAreaSubtitle, enabled: parts.browser),
    ];
  }

  @override
  Future<Map<String, Object?>> describe() async => {
        'areas': _areas(),
        'groups': [
          for (final g in await _groups())
            {
              'area': g.area,
              'title': g.title,
              'help': ?g.help,
              'items': [for (final s in g.items) s.toJson()],
            },
        ],
      };

  Future<_Setting?> _find(String id) async {
    for (final g in await _groups()) {
      for (final s in g.items) {
        if (s.id == id) return s;
      }
    }
    return null;
  }

  @override
  Future<AdminResult> apply(String id, Object? value) async {
    final s = await _find(id);
    if (s == null) return (ok: false, message: l10n.adminUnknownSetting);
    final run = s.run;
    if (run != null) return run();
    final error = await s.set(value);
    return (ok: error == null, message: error);
  }

  /// The subfolders of [path] on the NAS - for choosing the folder of the
  /// folder setting [id] on the page.
  @override
  Future<Map<String, Object?>> browse(String id, String path) async {
    final l = l10n;
    final s = await _find(id);
    // Also the film folders (no NasFolder of their own).
    if (s == null || s.type != 'folder') return {'error': l.adminUnknownSetting};
    final config = (await _c.read(nasSettingsRepositoryProvider).load()).config;
    if (!config.isConfigured) return {'error': l.nasNeedServer};
    final folder = normalizeNasPath(path.isEmpty ? '/' : path);
    final client = config.createClient();
    try {
      final entries = await client.list(folder).timeout(const Duration(seconds: 30));
      final cut = folder.lastIndexOf('/');
      return {
        'path': folder,
        'parent': folder == '/' ? null : normalizeNasPath(cut <= 0 ? '/' : folder.substring(0, cut)),
        'folders': [
          for (final e in entries)
            if (e.isDirectory) {'name': e.name, 'path': e.path},
        ],
        'files': entries.where((e) => !e.isDirectory).length,
      };
    } on NasException catch (e) {
      return {'error': e.message, 'path': folder};
    } on TimeoutException {
      return {'error': l.nasErrorTimeout, 'path': folder};
    } catch (e) {
      return {'error': '$e', 'path': folder};
    } finally {
      client.close();
    }
  }
}
