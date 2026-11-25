import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/dashboard_providers.dart';
import '../../core/display_mode.dart';
import '../../core/ha_providers.dart';
import '../../core/providers.dart';
import '../../core/system_providers.dart';
import '../../core/theme.dart';
import '../../data/services/admin_server.dart';
import '../../core/nas_providers.dart';
import '../../core/pictures_providers.dart';
import '../../data/services/display_service.dart';
import '../../data/services/permissions_service.dart';
import '../../data/services/nas_service.dart' show NasFolder;
import '../../data/services/picture_library.dart' show SlideshowOrder;
import '../../l10n/l10n.dart';
import '../music/music_settings_screen.dart';
import '../setup/permissions_screen.dart';
import '../setup/setup_wizard_screen.dart' show deviceNameSuggestions;
import '../../data/models/favorite_channel.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/desktop/hrdab_desktop.dart';
import '../../data/services/launcher_service.dart';
import '../launcher/launcher_providers.dart';
import '../rtlsdr/rtl_sdr_test_screen.dart';
import 'restore_backup_screen.dart';
import '../tv/tv_providers.dart';
import '../tv/tv_reminder_providers.dart' show tvReminderLeadProvider;
import '../tv/iptv_providers.dart';
import 'ha_settings_screen.dart';
import 'iptv_settings_screen.dart';
import '../browser/browser_channel.dart';
import '../browser/browser_settings_screen.dart';
import 'language_picker.dart';
import 'launcher_settings_screens.dart';
import 'remote_keys_settings_screen.dart';
import 'tv_settings_screen.dart';
import 'update_settings_screen.dart';
import 'location_settings_screen.dart';
import 'nas_settings_screen.dart';
import 'radar_source_settings_screen.dart';

/// The settings' areas - one page each, reached from the overview.
/// [system]: the device itself - which parts are on, its name, start, Home
/// (the launcher), display, backup, updates.
enum SettingsSection { system, radio, tv, dashboard, pictures }

/// Settings: without [section] the overview of the areas (System, Radio,
/// TV), with it that area's page - Radio's gear opens its own area right
/// away.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.section, this.fromOverview = false});

  final SettingsSection? section;

  /// Opened from the overview - "Alle Einstellungen" just goes back there.
  final bool fromOverview;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  AutostartMode _mode = AutostartMode.lastStation;
  int? _fixedProgramNumber;
  // TV's start channel (null = last watched); "Festen Sender" picked
  // but no channel yet.
  String? _tvStartChannel;
  bool _tvFixedChosen = false;
  bool _showClockDate = false;
  bool _weatherEnabled = true;
  bool _radarEnabled = true;
  double _uiScale = 1.0;
  double _weatherScale = 1.0;
  double _weatherContentScale = 1.0;
  bool _weatherSpanTwoTiles = true;
  double _radarScale = 1.0;
  int _radarRadiusKm = SettingsRepository.defaultRadarRadiusKm;
  double _radarDimming = 0.0;
  bool _sunEnabled = true;
  double _sunScale = 1.0;
  bool _fullscreen = false;
  int _monitor = 1;
  int _monitors = 1;
  // The admin page's addresses (by IP and, if known, by host name).
  List<String> _adminUrls = const [];
  // The app started with StartScreen.app ('' = none) and its name.
  String _startApp = '';
  String? _startAppLabel;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(settingsRepositoryProvider);
    final mode = await repo.getAutostartMode();
    final fixed = await repo.getFixedProgramNumber();
    final showClockDate = await repo.getShowClockDate();
    final weather = await repo.getWeatherEnabled();
    final radar = await repo.getRadarEnabled();
    final weatherScale = await repo.getWeatherTileScale();
    final weatherContentScale = await repo.getWeatherContentScale();
    final weatherSpanTwoTiles = await repo.getWeatherSpanTwoTiles();
    final radarScale = await repo.getRadarTileScale();
    final radarRadiusKm = await repo.getRadarRadiusKm();
    final radarDimming = await repo.getRadarDimming();
    final sunEnabled = await repo.getSunEnabled();
    final sunScale = await repo.getSunTileScale();
    final fullscreen = await repo.getFullscreen();
    final monitor = await repo.getFullscreenMonitor();
    final monitors = await monitorCount();
    final tvStartChannel = await repo.getTvStartChannel();
    final startApp = await repo.getStartApp();
    final startAppLabel = startApp.isEmpty
        ? null
        : (await ref.read(launcherServiceProvider).listApps()).where((a) => a.package == startApp).firstOrNull?.label;
    final adminUrls = await AdminServer.urls();
    final scale = ref.read(uiScaleProvider);
    if (!mounted) return;
    setState(() {
      _adminUrls = adminUrls;
      _startApp = startApp;
      _startAppLabel = startAppLabel;
      _mode = mode;
      _fixedProgramNumber = fixed;
      _showClockDate = showClockDate;
      _weatherEnabled = weather;
      _radarEnabled = radar;
      _uiScale = scale;
      _weatherScale = weatherScale;
      _weatherContentScale = weatherContentScale;
      _weatherSpanTwoTiles = weatherSpanTwoTiles;
      _radarScale = radarScale;
      _radarRadiusKm = radarRadiusKm;
      _radarDimming = radarDimming;
      _sunEnabled = sunEnabled;
      _sunScale = sunScale;
      _fullscreen = fullscreen;
      _monitor = monitor;
      _monitors = monitors;
      _tvStartChannel = tvStartChannel;
      _loaded = true;
    });
  }

  /// Switches a part on/off (SystemPartsNotifier stops the radio and moves
  /// the start to Home when needed).
  Future<void> _setPart({
    bool? radio,
    bool? tv,
    bool? dashboard,
    bool? pictures,
    bool? movies,
    bool? music,
    bool? browser,
  }) async {
    final parts = ref.read(systemPartsProvider.notifier);
    if (radio != null) await parts.setRadio(radio);
    if (tv != null) await parts.setTv(tv);
    if (dashboard != null) await parts.setDashboard(dashboard);
    if (pictures != null) await parts.setPictures(pictures);
    if (movies != null) await parts.setMovies(movies);
    if (music != null) await parts.setMusic(music);
    if (browser != null) await parts.setBrowser(browser);
  }

  void _openOverview() {
    final nav = Navigator.of(context);
    if (widget.fromOverview) {
      nav.pop();
    } else {
      nav.pushReplacement(MaterialPageRoute(builder: (_) => const SettingsScreen()));
    }
  }

  /// Another app as what starts with Home System (e.g. a TV that should
  /// simply open the streaming app) - picked from the installed ones.
  Future<void> _pickStartApp() async {
    final apps = [...await ref.read(launcherServiceProvider).listApps()]
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    if (!mounted) return;
    final l = context.l10n;
    final picked = await showDialog<InstalledApp>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.systemStartAppPick),
        children: [
          for (final (i, a) in apps.indexed)
            ListTile(
              autofocus: a.package == _startApp || (i == 0 && _startApp.isEmpty),
              title: Text(a.label, style: const TextStyle(fontSize: 18)),
              onTap: () => Navigator.of(context).pop(a),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(settingsRepositoryProvider).setStartApp(picked.package);
    setState(() {
      _startApp = picked.package;
      _startAppLabel = picked.label;
    });
    await ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.app);
  }

  /// Display by motion on/off - on asks for the camera first and says when
  /// the display can't be switched off (no accessibility service).
  Future<void> _setMotion(bool on) async {
    final display = ref.read(displayServiceProvider);
    final notifier = ref.read(dashboardDisplayProvider.notifier);
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    if (on) {
      if (!await display.hasCamera()) {
        messenger.showSnackBar(SnackBar(content: Text(l.dashboardNoCamera)));
        return;
      }
      if (!await display.requestCameraPermission()) {
        messenger.showSnackBar(SnackBar(content: Text(l.dashboardCameraDenied)));
        return;
      }
      if (!await display.canSwitchOff()) messenger.showSnackBar(SnackBar(content: Text(l.dashboardNoAccessibility)));
    }
    await notifier.set(ref.read(dashboardDisplayProvider).copyWith(motion: on));
  }

  Future<void> _editDashboardUrl() async {
    final l = context.l10n;
    final controller = TextEditingController(text: ref.read(dashboardUrlProvider));
    final url = await _textDialog(title: l.dashboardAddress, hint: l.dashboardAddressHint, controller: controller);
    if (url != null) await ref.read(dashboardUrlProvider.notifier).set(url);
  }

  Future<void> _editWebhook() async {
    final l = context.l10n;
    final controller = TextEditingController(text: ref.read(dashboardDisplayProvider).webhookUrl);
    final url = await _textDialog(title: l.dashboardWebhook, hint: l.dashboardWebhookHint, controller: controller);
    if (url == null) return;
    final notifier = ref.read(dashboardDisplayProvider.notifier);
    await notifier.set(ref.read(dashboardDisplayProvider).copyWith(webhookUrl: url));
  }

  /// One line of text (an address) - OK takes it, Back cancels.
  Future<String?> _textDialog({required String title, required String hint, required TextEditingController controller}) {
    final l = context.l10n;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 640,
          child: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text(l.commonSave)),
        ],
      ),
    );
  }

  Future<void> _editDeviceName() async {
    final l = context.l10n;
    final controller = TextEditingController(text: ref.read(deviceNameProvider));
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.adminDeviceName),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.settingsDeviceNameHelp, style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, s) in deviceNameSuggestions(l).indexed)
                    // The remote starts on the first suggestion.
                    OutlinedButton(autofocus: i == 0, onPressed: () => Navigator.of(context).pop(s), child: Text(s)),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(labelText: l.settingsDeviceNameOwn, border: const OutlineInputBorder()),
                onSubmitted: (v) => Navigator.of(context).pop(v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text(l.miscApply)),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await ref.read(deviceNameProvider.notifier).set(name);
  }

  Future<void> _setFullscreen({bool? fullscreen, int? monitor}) async {
    final repo = ref.read(settingsRepositoryProvider);
    setState(() {
      _fullscreen = fullscreen ?? _fullscreen;
      _monitor = monitor ?? _monitor;
    });
    await repo.setFullscreen(_fullscreen);
    await repo.setFullscreenMonitor(_monitor);
    await applyDisplayMode(fullscreen: _fullscreen, monitor: _monitor);
  }

  Future<void> _changeUiScale(double delta) async {
    final next = (_uiScale + delta).clamp(0.4, 1.4);
    setState(() => _uiScale = next);
    await ref.read(uiScaleProvider.notifier).set(next);
  }

  Future<void> _changeWeatherScale(double delta) async {
    final next = (_weatherScale + delta).clamp(0.5, 2.0);
    setState(() => _weatherScale = next);
    await ref.read(weatherDisplaySettingsProvider.notifier).setWeatherScale(next);
  }

  Future<void> _changeWeatherContentScale(double delta) async {
    final next = (_weatherContentScale + delta).clamp(0.5, 2.0);
    setState(() => _weatherContentScale = next);
    await ref.read(weatherDisplaySettingsProvider.notifier).setWeatherContentScale(next);
  }

  Future<void> _changeRadarScale(double delta) async {
    final next = (_radarScale + delta).clamp(0.5, 2.0);
    setState(() => _radarScale = next);
    await ref.read(weatherDisplaySettingsProvider.notifier).setRadarScale(next);
  }

  Future<void> _changeRadarRadius(int direction) async {
    const steps = SettingsRepository.radarRadiusSteps;
    final i = (steps.indexOf(_radarRadiusKm) + direction).clamp(0, steps.length - 1);
    final next = steps[i];
    setState(() => _radarRadiusKm = next);
    await ref.read(weatherDisplaySettingsProvider.notifier).setRadarRadiusKm(next);
  }

  Future<void> _changeRadarDimming(double delta) async {
    final next = (_radarDimming + delta).clamp(0.0, 0.9);
    setState(() => _radarDimming = next);
    await ref.read(weatherDisplaySettingsProvider.notifier).setRadarDimming(next);
  }

  Future<void> _changeSunScale(double delta) async {
    final next = (_sunScale + delta).clamp(0.5, 2.0);
    setState(() => _sunScale = next);
    await ref.read(weatherDisplaySettingsProvider.notifier).setSunScale(next);
  }

  /// Settings → Haussteuerung: the dashboard's address, display by motion,
  /// Home Assistant's side.
  List<Widget> _dashboardSection(
    BuildContext context,
    double Function() nextOrder,
    Widget Function(String, bool, void Function(bool)) tileToggle,
  ) {
    final l = context.l10n;
    final url = ref.watch(dashboardUrlProvider);
    final display = ref.watch(dashboardDisplayProvider);
    final notifier = ref.read(dashboardDisplayProvider.notifier);
    const help = TextStyle(color: Colors.white60);
    Widget stepper(String label, String value, void Function(int) onChange) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              SizedBox(width: 260, child: Text(label, style: Theme.of(context).textTheme.bodyLarge)),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvIconButton(icon: Icons.remove, onTap: () => onChange(-1)),
              ),
              SizedBox(
                width: 140,
                child: Text(value, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvIconButton(icon: Icons.add, onTap: () => onChange(1)),
              ),
            ],
          ),
        );
    const timeouts = [0, 1, 2, 5, 10, 15, 30, 60];
    final timeoutIndex = timeouts.indexOf(display.timeoutMinutes).clamp(0, timeouts.length - 1);
    return [
      FocusTraversalOrder(
        order: NumericFocusOrder(nextOrder()),
        child: _TvNavTile(
          label: l.dashboardAddress,
          value: url.isEmpty ? l.dashboardNotSet : url,
          configured: url.isNotEmpty,
          icon: Icons.link,
          onTap: _editDashboardUrl,
        ),
      ),
      FocusTraversalOrder(
        order: NumericFocusOrder(nextOrder()),
        child: _TvNavTile(
          label: l.lanSearchHa,
          value: l.lanSearchHaHint,
          icon: Icons.travel_explore,
          onTap: () async {
            final found = await searchHomeAssistant(context);
            if (found != null) await ref.read(dashboardUrlProvider.notifier).set(found.url);
          },
        ),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), child: Text(l.dashboardAddressHelp, style: help)),
      const Divider(height: 32),
      Text(l.dashboardDisplayHeading, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      tileToggle(l.dashboardMotion, display.motion, _setMotion),
      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), child: Text(l.dashboardMotionHelp, style: help)),
      if (display.motion) ...[
        tileToggle(l.dashboardDimOnly, display.dimOnly, (v) => notifier.set(display.copyWith(dimOnly: v))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), child: Text(l.dashboardDimOnlyHelp, style: help)),
        stepper(l.dashboardSensitivity, l.dashboardSensitivityValue(display.sensitivity), (d) {
          notifier.set(display.copyWith(sensitivity: (display.sensitivity + d).clamp(1, 10)));
        }),
        stepper(
          l.dashboardTimeout,
          display.timeoutMinutes == 0 ? l.dashboardTimeoutNever : l.dashboardTimeoutMinutes(display.timeoutMinutes),
          (d) => notifier.set(
            display.copyWith(timeoutMinutes: timeouts[(timeoutIndex + d).clamp(0, timeouts.length - 1)]),
          ),
        ),
        // The camera's view of motion right now - to try out the sensitivity.
        StreamBuilder(
          stream: _motionLevels,
          builder: (context, snapshot) {
            final v = snapshot.data;
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
              child: Text(
                v == null
                    ? ''
                    : v.motion
                        ? l.dashboardLevelMotion
                        : l.dashboardLevel((v.level * 100).round()),
                style: TextStyle(fontSize: 18, color: v?.motion == true ? Colors.greenAccent : Colors.white70),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: FocusTraversalOrder(
            order: NumericFocusOrder(nextOrder()),
            child: _TvNavTile(
              label: l.dashboardTestOff,
              icon: Icons.power_settings_new,
              onTap: () async {
                if (!await ref.read(displayServiceProvider).screenOff() && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.dashboardNoAccessibility)));
                }
              },
            ),
          ),
        ),
      ],
      ..._brightnessSection(context, nextOrder, stepper, help),
      const Divider(height: 32),
      Text(l.dashboardHaHeading, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      FocusTraversalOrder(
        order: NumericFocusOrder(nextOrder()),
        child: _TvNavTile(
          label: l.dashboardWebhook,
          value: display.webhookUrl.isEmpty ? l.dashboardNotSet : display.webhookUrl,
          configured: display.webhookUrl.isNotEmpty,
          icon: Icons.webhook,
          onTap: _editWebhook,
        ),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), child: Text(l.dashboardWebhookHelp, style: help)),
      if (_adminUrls.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Text(l.dashboardRemoteHelp(_adminUrls.first), style: help),
        ),
    ];
  }

  /// Settings → Bilder: where the pictures are, how the slideshow runs.
  List<Widget> _picturesSection(
    BuildContext context,
    double Function() nextOrder,
    Widget Function(String, bool, void Function(bool)) tileToggle,
  ) {
    final l = context.l10n;
    final folder = ref.watch(nasSettingsProvider).value?.folder(NasFolder.pictures);
    final slideshow = ref.watch(slideshowSettingsProvider);
    final notifier = ref.read(slideshowSettingsProvider.notifier);
    const help = TextStyle(color: Colors.white60);
    Widget order(String label, SlideshowOrder value) => FocusTraversalOrder(
          order: NumericFocusOrder(nextOrder()),
          child: _TvChoiceTile(
            label: label,
            selected: slideshow.order == value,
            onTap: () => notifier.set(slideshow.copyWith(order: value)),
          ),
        );
    return [
      FocusTraversalOrder(
        order: NumericFocusOrder(nextOrder()),
        child: _TvNavTile(
          label: l.picturesFolder,
          value: folder ?? l.settingsNotSetUp,
          configured: folder != null,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NasSettingsScreen())),
        ),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), child: Text(l.picturesMusicHelp, style: help)),
      const Divider(height: 32),
      Text(l.picturesSlideshowHeading, style: Theme.of(context).textTheme.titleLarge),
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          children: [
            SizedBox(width: 260, child: Text(l.picturesInterval, style: Theme.of(context).textTheme.bodyLarge)),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvIconButton(icon: Icons.remove, onTap: () => notifier.stepInterval(-1)),
            ),
            SizedBox(
              width: 140,
              child: Text(
                l.picturesIntervalSeconds(slideshow.intervalSeconds),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvIconButton(icon: Icons.add, onTap: () => notifier.stepInterval(1)),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Text(l.picturesOrder, style: Theme.of(context).textTheme.bodyLarge),
      order(l.picturesOrderFolders, SlideshowOrder.folders),
      order(l.picturesOrderShuffled, SlideshowOrder.shuffled),
      const SizedBox(height: 8),
      tileToggle(l.picturesBlur, slideshow.blurredBackground,
          (v) => notifier.set(slideshow.copyWith(blurredBackground: v))),
    ];
  }

  /// Settings → Haussteuerung → Helligkeit.
  List<Widget> _brightnessSection(
    BuildContext context,
    double Function() nextOrder,
    Widget Function(String, String, void Function(int)) stepper,
    TextStyle help,
  ) {
    final l = context.l10n;
    final b = ref.watch(displayBrightnessProvider);
    final notifier = ref.read(displayBrightnessProvider.notifier);
    Widget choice(String label, BrightnessMode mode) => FocusTraversalOrder(
          order: NumericFocusOrder(nextOrder()),
          child: _TvChoiceTile(label: label, selected: b.mode == mode, onTap: () => notifier.set(b.copyWith(mode: mode))),
        );
    const luxSteps = [5, 10, 20, 50, 100, 200, 500, 1000, 2000];
    final luxIndex = luxSteps.indexWhere((x) => x >= b.luxForMax).clamp(0, luxSteps.length - 1);
    return [
      const Divider(height: 32),
      Text(l.dashboardBrightnessHeading, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      choice(l.dashboardBrightnessSystem, BrightnessMode.system),
      choice(l.dashboardBrightnessFixed, BrightnessMode.fixed),
      choice(l.dashboardBrightnessAdaptive, BrightnessMode.adaptive),
      if (b.mode == BrightnessMode.fixed)
        stepper(l.dashboardBrightnessLevel, '${b.level} %',
            (d) => notifier.set(b.copyWith(level: (b.level + d * 5).clamp(5, 100)))),
      if (b.mode == BrightnessMode.adaptive) ...[
        stepper(l.dashboardBrightnessMin, '${b.min} %',
            (d) => notifier.set(b.copyWith(min: (b.min + d * 5).clamp(1, b.max)))),
        stepper(l.dashboardBrightnessMax, '${b.max} %',
            (d) => notifier.set(b.copyWith(max: (b.max + d * 5).clamp(b.min, 100)))),
        stepper(l.dashboardBrightnessLuxForMax, '${luxSteps[luxIndex]} lx',
            (d) => notifier.set(b.copyWith(luxForMax: luxSteps[(luxIndex + d).clamp(0, luxSteps.length - 1)]))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text(l.dashboardBrightnessHelp, style: help)),
        // The sensor now - to find the room's "bright" value.
        StreamBuilder<double?>(
          stream: _ambientLight,
          builder: (context, snapshot) => Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Text(
              !snapshot.hasData && snapshot.connectionState == ConnectionState.done
                  ? l.dashboardBrightnessNoSensor
                  : snapshot.data == null
                      ? ''
                      : l.dashboardBrightnessLux(snapshot.data! < 0 ? '–' : snapshot.data!.toStringAsFixed(0)),
              style: const TextStyle(fontSize: 18, color: Colors.white70),
            ),
          ),
        ),
      ],
    ];
  }

  late final Stream<double?> _ambientLight = Stream.periodic(const Duration(seconds: 1))
      .asyncMap((_) => ref.read(displayServiceProvider).ambientLight());

  /// The camera's motion level for the test display - one subscription per page.
  late final Stream<({double level, bool motion})> _motionLevels =
      ref.read(displayServiceProvider).motionLevels();

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    final locationName = ref.watch(weatherDisplaySettingsProvider).locationName;
    final receiverMode = ref.watch(receiverModeProvider);
    final receiverSections = ref.watch(receiverSectionsProvider);
    // Only the kind of source, not its address - the settings list
    // shouldn't advertise whichever third-party radar is set up.
    final radarSettings = ref.watch(weatherDisplaySettingsProvider);
    final l = context.l10n;
    final radarSourceLabel = radarSettings.radarUrl.trim().isEmpty
        ? l.settingsNotSetUp
        : (radarSettings.radarIsWebPage ? l.miscRadarWebPage : l.miscRadarImage);
    final repo = ref.read(settingsRepositoryProvider);
    final launcher = ref.watch(launcherSettingsProvider);
    final parts = ref.watch(systemPartsProvider);
    final deviceName = ref.watch(deviceNameProvider);
    final nasConfig = ref.watch(nasSettingsProvider).value?.config;
    final adminUrl = _adminUrls.isEmpty ? null : _adminUrls.join(' ${l.settingsOr} ');

    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: Text(l.systemTileSettingsShort)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Explicit traversal order: D-Pad down must reliably move through every
    // control top-to-bottom, regardless of how Flutter would otherwise guess
    // the geometric "nearest" focusable widget.
    var order = 0.0;
    double nextOrder() => order += 1;

    // A +/- scale/zoom control, e.g. "Größe der Wetter-Kachel: 100%" - was
    // repeated seven times with only the label/value/callbacks differing.
    Widget scaleRow({required String label, required String valueLabel, required void Function(int direction) onChange}) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvIconButton(icon: Icons.remove, onTap: () => onChange(-1)),
                ),
                SizedBox(
                  width: 90,
                  child: Text(valueLabel, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
                ),
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvIconButton(icon: Icons.add, onTap: () => onChange(1)),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // A tile's own "<Name> anzeigen" on/off toggle.
    Widget tileToggle(String label, bool selected, void Function(bool) onChanged) {
      return FocusTraversalOrder(
        order: NumericFocusOrder(nextOrder()),
        child: _TvChoiceTile(
          label: label,
          selected: selected,
          asToggle: true,
          onTap: () => onChanged(!selected),
        ),
      );
    }

    // One tile's settings, sub-headed under the "Kacheln" section below -
    // was previously just flatly listed one after another under a single
    // "Anzeige" heading together with everything else, which stopped being
    // readable once there were three tiles' worth of settings to scroll
    // past. The on/off switch *is* the group header (left-aligned, like
    // every other control here) rather than a separate indented row under
    // a plain title - and the rest of the group only shows up while it's
    // actually relevant, i.e. while the tile is enabled.
    Widget tileGroup({
      required String title,
      required bool enabled,
      required void Function(bool) onToggleEnabled,
      required List<Widget> children,
    }) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 4, height: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 4),
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvChoiceTile(
                    label: title,
                    selected: enabled,
                    asToggle: true,
                    bold: true,
                    onTap: () => onToggleEnabled(!enabled),
                  ),
                ),
              ],
            ),
            if (enabled)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
              ),
          ],
        ),
      );
    }

    final section = widget.section;
    if (section == null) return const _SettingsOverview();

    return Scaffold(
      appBar: AppBar(
        title: Text(switch (section) {
          SettingsSection.system => context.l10n.systemSettingsTitleSystem,
          SettingsSection.radio => context.l10n.systemSettingsTitleRadio,
          SettingsSection.tv => context.l10n.systemSettingsTitleTv,
          SettingsSection.dashboard => context.l10n.dashboardSettingsTitle,
          SettingsSection.pictures => context.l10n.picturesSettingsTitle,
        }),
      ),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Up to all settings - also when this page was opened straight
            // from Radio or TV.
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(label: context.l10n.systemSettingsAll, icon: Icons.apps, onTap: _openOverview),
            ),
            const SizedBox(height: 8),
            if (section == SettingsSection.dashboard) ..._dashboardSection(context, nextOrder, tileToggle),
            if (section == SettingsSection.pictures) ..._picturesSection(context, nextOrder, tileToggle),
            if (section == SettingsSection.radio) ...[
            // First, since it decides whether DAB+ shows up anywhere at all.
            Text(l.settingsReception, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              // "Kein Empfänger" is a valid choice too, not a missing setup.
              child: _TvNavTile(
                label: l.scannerRtlReceiverTitle,
                value: switch (receiverMode) {
                  ReceiverMode.none => l.settingsReceiverNone,
                  ReceiverMode.usb => l.settingsReceiverUsb,
                  ReceiverMode.tcp => l.settingsReceiverTcp,
                },
                configured: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RtlSdrTestScreen()),
                ),
              ),
            ),
            // Which parts of the receiver side the app shows: DAB+ and FM
            // (station search, sidebar tab) and the top bar's "Funk" window.
            if (receiverMode != ReceiverMode.none) ...[
              tileToggle(l.settingsShowDab, receiverSections.dab, (v) {
                ref.read(receiverSectionsProvider.notifier).setDab(v);
              }),
              tileToggle(l.settingsShowFm, receiverSections.fm, (v) {
                ref.read(receiverSectionsProvider.notifier).setFm(v);
              }),
              tileToggle(l.settingsShowAm, receiverSections.am, (v) {
                ref.read(receiverSectionsProvider.notifier).setAm(v);
              }),
              tileToggle(l.settingsShowFunk, receiverSections.funk, (v) {
                ref.read(receiverSectionsProvider.notifier).setFunk(v);
              }),
            ],
            ],
            if (section == SettingsSection.system) ...[
              // At the very top: the Home key - lit up when it doesn't work.
              if (LauncherService.supported) ...[
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: const _HomeKeyTile(),
                ),
                const SizedBox(height: 16),
              ],
              // First: which parts there are decides about everything else.
              Text(l.settingsPartsHeading, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(l.settingsPartsHelp, style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 8),
              tileToggle('Radio', parts.radio, (v) => _setPart(radio: v)),
              tileToggle('TV', parts.tv, (v) => _setPart(tv: v)),
              if (DisplayService.supported)
                tileToggle(context.l10n.dashboardTitle, parts.dashboard, (v) => _setPart(dashboard: v)),
              tileToggle(context.l10n.picturesTitle, parts.pictures, (v) => _setPart(pictures: v)),
              tileToggle(context.l10n.moviesTitle, parts.movies, (v) => _setPart(movies: v)),
              tileToggle(context.l10n.musicTitle, parts.music, (v) => _setPart(music: v)),
              if (BrowserChannel.supported)
                tileToggle(context.l10n.browserTitle, parts.browser, (v) => _setPart(browser: v)),
              const Divider(height: 32),
              Text(l.settingsDeviceHeading, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: l.adminDeviceName,
                  value: deviceName.isEmpty ? l.settingsDeviceNameNotSet : deviceName,
                  configured: deviceName.isNotEmpty,
                  onTap: _editDeviceName,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Text(
                  adminUrl == null ? l.settingsAdminPageOffline : l.settingsAdminPageAt(adminUrl),
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
              // What the device allows Home System (Android only).
              if (PermissionsService.supported)
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvNavTile(
                    label: l.permissionsTitle,
                    value: switch (ref.watch(permissionEntriesProvider).value?.entries) {
                      final entries? => l.permissionsSummary(
                          permissionsCount(entries).granted,
                          permissionsCount(entries).total,
                        ),
                      null => null,
                    },
                    icon: Icons.verified_user_outlined,
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PermissionsScreen()));
                      ref.invalidate(permissionEntriesProvider);
                    },
                  ),
                ),
              // Backups before updates, Home's background pictures.
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: l.settingsNas,
                  value: (nasConfig?.isConfigured ?? false) ? nasConfig!.host : l.settingsNotSetUp,
                  configured: nasConfig?.isConfigured ?? false,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const NasSettingsScreen()),
                  ),
                ),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: Consumer(
                  builder: (context, ref, _) {
                    final ha = ref.watch(haLinkSettingsProvider);
                    return _TvNavTile(
                      label: l.haTitle,
                      value: ha.enabled ? l.commonOn : l.commonOff,
                      configured: ha.enabled,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const HaSettingsScreen()),
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 32),
              Text(l.adminStartScreen, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvChoiceTile(
                  label: l.settingsStartShowHome,
                  selected: launcher.startScreen == StartScreen.launcher ||
                      (launcher.startScreen == StartScreen.radio && !parts.radio) ||
                      (launcher.startScreen == StartScreen.tv && !parts.tv) ||
                      (launcher.startScreen == StartScreen.dashboard && !parts.dashboard) ||
                      (launcher.startScreen == StartScreen.app && _startApp.isEmpty),
                  onTap: () => ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.launcher),
                ),
              ),
              if (parts.radio)
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvChoiceTile(
                    label: l.settingsStartRadio,
                    selected: launcher.startScreen == StartScreen.radio,
                    onTap: () => ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.radio),
                  ),
                ),
              if (parts.tv)
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvChoiceTile(
                    label: l.settingsStartTv,
                    selected: launcher.startScreen == StartScreen.tv,
                    onTap: () => ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.tv),
                  ),
                ),
              if (parts.dashboard)
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvChoiceTile(
                    label: context.l10n.systemStartDashboard,
                    selected: launcher.startScreen == StartScreen.dashboard,
                    onTap: () => ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.dashboard),
                  ),
                ),
              if (LauncherService.supported)
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvChoiceTile(
                    label: _startApp.isEmpty
                        ? context.l10n.systemStartAppNone
                        : context.l10n.systemStartApp(_startAppLabel ?? _startApp),
                    selected: launcher.startScreen == StartScreen.app && _startApp.isNotEmpty,
                    onTap: _pickStartApp,
                  ),
                ),
              const Divider(height: 32),
              Text('Home', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: l.settingsBackground,
                  value: switch (launcher.backgroundSource) {
                    LauncherBackgroundSource.builtin => l.settingsBackgroundGradients,
                    LauncherBackgroundSource.photos => l.settingsBackgroundPhotos,
                    LauncherBackgroundSource.server => l.settingsBackgroundServer,
                  },
                  icon: Icons.wallpaper,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LauncherBackgroundSettingsScreen()),
                  ),
                ),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: l.miscRemoteKeysTitle,
                  icon: Icons.keyboard_outlined,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RemoteKeysSettingsScreen()),
                  ),
                ),
              ),
              // App tiles and the Home key exist on Android only.
              if (LauncherService.supported) ...[
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: l.settingsIconPack,
                  value: launcher.iconPack == null
                      ? l.settingsIconPackNone
                      : (ref.watch(iconPacksProvider).value ?? const [])
                              .where((p) => p.package == launcher.iconPack)
                              .firstOrNull
                              ?.label ??
                          launcher.iconPack,
                  icon: Icons.palette_outlined,
                  onTap: () => chooseIconPack(context, ref),
                ),
              ),
              ],
            ],
            if (section == SettingsSection.tv) ...[
              Text(l.settingsReceiverHeading, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: l.settingsSatReceiver,
                value: (ref.watch(enigma2ConfigProvider)?.configured ?? false)
                    ? ref.watch(enigma2ConfigProvider)!.host
                    : l.settingsNotSetUp,
                configured: ref.watch(enigma2ConfigProvider)?.configured ?? false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TvSettingsScreen()),
                ),
              ),
            ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: l.iptvSettingsTitle,
                  value: (ref.watch(iptvProvider)?.enabled ?? false) ? l.commonOn : l.commonOff,
                  configured: ref.watch(iptvProvider)?.enabled ?? false,
                  icon: Icons.public,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const IptvSettingsScreen()),
                  ),
                ),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: l.miscRemoteKeysTitle,
                  value: l.settingsTvKeysValue,
                  icon: Icons.keyboard_outlined,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RemoteKeysSettingsScreen()),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              tileToggle(l.settingsTvZapEncrypted, ref.watch(tvZapEncryptedProvider), (v) {
                ref.read(tvZapEncryptedProvider.notifier).set(v);
              }),
              Text(l.settingsTvZapEncryptedHelp, style: const TextStyle(color: Colors.white60)),
              const Divider(height: 32),
              Text(l.settingsTvStartHeading, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvChoiceTile(
                  label: l.settingsTvStartLast,
                  selected: _tvStartChannel == null,
                  onTap: () async {
                    setState(() => _tvStartChannel = null);
                    await repo.setTvStartChannel(null);
                  },
                ),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvChoiceTile(
                  label: l.settingsTvStartFixed,
                  selected: _tvStartChannel != null || _tvFixedChosen,
                  onTap: () => setState(() => _tvFixedChosen = true),
                ),
              ),
              if (_tvStartChannel != null || _tvFixedChosen)
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 8),
                  child: ref.watch(tvChannelsProvider).when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => Text(l.settingsTvChannelsError('$e'), style: const TextStyle(color: Colors.amber)),
                        data: (channels) => channels.isEmpty
                            ? Text(l.settingsTvSetUpReceiverFirst, style: const TextStyle(color: Colors.white60))
                            : Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final c in channels)
                                    FocusTraversalOrder(
                                      order: NumericFocusOrder(nextOrder()),
                                      child: _TvChoiceTile(
                                        compact: true,
                                        label: '${c.number} · ${c.name}',
                                        selected: _tvStartChannel == c.ref,
                                        onTap: () async {
                                          setState(() => _tvStartChannel = c.ref);
                                          await repo.setTvStartChannel(c.ref);
                                        },
                                      ),
                                    ),
                                ],
                              ),
                      ),
                ),
              const Divider(height: 32),
              Text(l.settingsTvNextUpHeading, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(l.settingsTvNextUpHelp, style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 8),
              tileToggle(l.settingsTvNextUpToggle, ref.watch(tvNextUpProvider).enabled, (v) {
                final s = ref.read(tvNextUpProvider);
                ref.read(tvNextUpProvider.notifier).set((enabled: v, leadMinutes: s.leadMinutes, showSeconds: s.showSeconds));
              }),
              if (ref.watch(tvNextUpProvider).enabled) ...[
                const SizedBox(height: 8),
                Text(l.settingsTvNextUpLead, style: Theme.of(context).textTheme.bodyLarge),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in SettingsRepository.tvNextLeadChoices)
                      FocusTraversalOrder(
                        order: NumericFocusOrder(nextOrder()),
                        child: _TvChoiceTile(
                          compact: true,
                          label: l.settingsMinutesShort(m),
                          selected: ref.watch(tvNextUpProvider).leadMinutes == m,
                          onTap: () {
                            final s = ref.read(tvNextUpProvider);
                            ref.read(tvNextUpProvider.notifier).set((enabled: s.enabled, leadMinutes: m, showSeconds: s.showSeconds));
                          },
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(l.settingsTvNextUpShow, style: Theme.of(context).textTheme.bodyLarge),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final sec in SettingsRepository.tvNextShowChoices)
                      FocusTraversalOrder(
                        order: NumericFocusOrder(nextOrder()),
                        child: _TvChoiceTile(
                          compact: true,
                          label: sec == 60 ? l.settingsMinutesShort(1) : l.settingsSecondsShort(sec),
                          selected: ref.watch(tvNextUpProvider).showSeconds == sec,
                          onTap: () {
                            final s = ref.read(tvNextUpProvider);
                            ref.read(tvNextUpProvider.notifier).set((enabled: s.enabled, leadMinutes: s.leadMinutes, showSeconds: sec));
                          },
                        ),
                      ),
                  ],
                ),
              ],
              const Divider(height: 32),
              Text(l.tvReminderSettingsHeading, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(l.tvReminderSettingsHelp, style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 8),
              Text(l.tvReminderLead, style: Theme.of(context).textTheme.bodyLarge),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in SettingsRepository.tvReminderLeadChoices)
                    FocusTraversalOrder(
                      order: NumericFocusOrder(nextOrder()),
                      child: _TvChoiceTile(
                        compact: true,
                        label: l.settingsMinutesShort(m),
                        selected: ref.watch(tvReminderLeadProvider) == m,
                        onTap: () => ref.read(tvReminderLeadProvider.notifier).set(m),
                      ),
                    ),
                ],
              ),
            ],
            if (section == SettingsSection.radio) ...[
            const Divider(height: 32),
            Text(l.settingsAutostartHeading, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: l.settingsAutostartLast,
                selected: _mode == AutostartMode.lastStation,
                onTap: () async {
                  setState(() => _mode = AutostartMode.lastStation);
                  await repo.setAutostartMode(AutostartMode.lastStation);
                },
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: l.settingsAutostartFixed,
                selected: _mode == AutostartMode.fixedStation,
                onTap: () async {
                  setState(() => _mode = AutostartMode.fixedStation);
                  await repo.setAutostartMode(AutostartMode.fixedStation);
                },
              ),
            ),
            if (_mode == AutostartMode.fixedStation && favorites.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: favorites.map((c) {
                    return FocusTraversalOrder(
                      order: NumericFocusOrder(nextOrder()),
                      child: _TvChoiceTile(
                        compact: true,
                        label: '${c.programNumber} · ${c.displayName}',
                        selected: _fixedProgramNumber == c.programNumber,
                        onTap: () async {
                          setState(() => _fixedProgramNumber = c.programNumber);
                          await repo.setFixedProgramNumber(c.programNumber);
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            const Divider(height: 32),
            Text(l.settingsDisplayHeading, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            tileToggle(l.settingsShowClockDate, _showClockDate, (v) async {
              setState(() => _showClockDate = v);
              await ref.read(showClockDateProvider.notifier).set(v);
            }),
            ],
            if (section == SettingsSection.system) ...[
            const Divider(height: 32),
            Text(l.settingsDisplayHeading, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: context.l10n.commonLanguage,
                value: languageLabel(context.l10n, ref.watch(languageProvider)),
                icon: Icons.translate,
                onTap: () => pickLanguage(context, ref),
              ),
            ),
            tileToggle(l.settingsFullscreen, _fullscreen, (v) => _setFullscreen(fullscreen: v)),
            if (Platform.isWindows && _fullscreen)
              scaleRow(
                label: l.settingsFullscreenMonitor,
                valueLabel: l.settingsMonitorOf(_monitor, _monitors),
                onChange: (d) => _setFullscreen(monitor: (_monitor + d).clamp(1, _monitors < 1 ? 1 : _monitors)),
              ),
            scaleRow(
              label: l.settingsUiScale,
              valueLabel: l.settingsPercent((_uiScale * 100).round()),
              onChange: (d) => _changeUiScale(d * 0.1),
            ),
            ],
            if (section == SettingsSection.radio) ...[
            const Divider(height: 32),
            Text(l.settingsTilesHeading, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            // Its own sub-page, not inline text fields here (see
            // LocationSettingsScreen's own doc comment for why: D-Pad down
            // couldn't get past a focused TextField to reach the tile
            // groups below).
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: l.settingsLocation,
                value: locationName,
                configured: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LocationSettingsScreen()),
                ),
              ),
            ),
            tileGroup(
              title: l.settingsWeatherForecast,
              enabled: _weatherEnabled,
              onToggleEnabled: (v) async {
                setState(() => _weatherEnabled = v);
                await ref.read(weatherDisplaySettingsProvider.notifier).setWeatherEnabled(v);
              },
              children: [
                tileToggle(l.settingsWeatherSpanTwoTiles, _weatherSpanTwoTiles, (v) async {
                  setState(() => _weatherSpanTwoTiles = v);
                  await ref.read(weatherDisplaySettingsProvider.notifier).setWeatherSpanTwoTiles(v);
                }),
                scaleRow(
                  label: l.settingsTileSize,
                  valueLabel: l.settingsPercent((_weatherScale * 100).round()),
                  onChange: (d) => _changeWeatherScale(d * 0.1),
                ),
                scaleRow(
                  // Separate from the tile size above - this scales the
                  // forecast content (icon/text/badges) inside the tile,
                  // independently of how big the tile itself is.
                  label: l.settingsContentSize,
                  valueLabel: l.settingsPercent((_weatherContentScale * 100).round()),
                  onChange: (d) => _changeWeatherContentScale(d * 0.1),
                ),
              ],
            ),
            tileGroup(
              title: l.settingsWeatherRadar,
              enabled: _radarEnabled,
              onToggleEnabled: (v) async {
                setState(() => _radarEnabled = v);
                await ref.read(weatherDisplaySettingsProvider.notifier).setRadarEnabled(v);
              },
              children: [
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvNavTile(
                    label: l.settingsRadarSource,
                    value: radarSourceLabel,
                    configured: radarSettings.radarUrl.trim().isNotEmpty,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const RadarSourceSettingsScreen()),
                    ),
                  ),
                ),
                scaleRow(
                  label: l.settingsTileSize,
                  valueLabel: l.settingsPercent((_radarScale * 100).round()),
                  onChange: (d) => _changeRadarScale(d * 0.1),
                ),
                scaleRow(
                  // Not the tile size above - how much of the map around the
                  // location is shown (distance to the top/bottom edge).
                  // Only takes effect if the source URL uses {r}.
                  label: l.settingsRadarRadius('{r}'),
                  valueLabel: '$_radarRadiusKm km',
                  onChange: (d) => _changeRadarRadius(d),
                ),
                scaleRow(
                  label: l.settingsRadarDimming,
                  valueLabel: l.settingsPercent((_radarDimming * 100).round()),
                  onChange: (d) => _changeRadarDimming(d * 0.1),
                ),
              ],
            ),
            tileGroup(
              title: l.settingsSunMoon,
              enabled: _sunEnabled,
              onToggleEnabled: (v) async {
                setState(() => _sunEnabled = v);
                await ref.read(weatherDisplaySettingsProvider.notifier).setSunEnabled(v);
              },
              children: [
                scaleRow(
                  label: l.settingsTileSize,
                  valueLabel: l.settingsPercent((_sunScale * 100).round()),
                  onChange: (d) => _changeSunScale(d * 0.1),
                ),
              ],
            ),
            // Radio's gear opens its own area; the others from here.
            const Divider(height: 32),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: l.settingsMoreSettings,
                icon: Icons.settings_outlined,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ),
            ],
            // Favorites are renamed/reordered/removed right in the home
            // screen's sidebar ("Bearbeiten"), the DAB+ station order is set
            // on the DAB+ stations screen - neither lives here anymore.
            if (section == SettingsSection.system) ...[
            const Divider(height: 32),
            Text(l.settingsMoreHeading, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: l.settingsBackupCreate,
                icon: Icons.save_outlined,
                onTap: () => createBackupWithFeedback(context, ref),
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: l.settingsBackupRestore,
                value: l.settingsBackupRestoreHint,
                icon: Icons.restore,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RestoreBackupScreen()),
                ),
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: l.miscUpdatesTitle,
                icon: Icons.system_update_outlined,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const UpdateSettingsScreen()),
                ),
              ),
            ),
            const Divider(height: 32),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: l.settingsQuit,
                icon: Icons.power_settings_new,
                onTap: _quitApp,
              ),
            ),
            const Divider(height: 32),
            Text(l.settingsAboutHeading, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            // Focusable so the D-Pad can scroll down to it (plain text after
            // the last focusable control would stay out of reach on a TV).
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: const _AboutBlock(),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: l.settingsOpenSourceLicenses,
                icon: Icons.description_outlined,
                onTap: _showLicenses,
              ),
            ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// Flutter's licence page: every package's licence plus the extra texts
  /// registered in main.dart (third_party_licenses.dart).
  Future<void> _showLicenses() async {
    String? version;
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    if (!mounted) return;
    showLicensePage(
      context: context,
      applicationName: 'Home System',
      applicationVersion: version,
      applicationIcon: Image.asset('assets/icon/home_system_logo.png', width: 64, height: 64),
    );
  }

  /// Closes the app after asking ("Abbrechen" focused - an OK pressed by
  /// mistake on the remote doesn't end it). Playback and the receiver are
  /// stopped first; on desktop the receiver is shut down so rtl_tcp is free
  /// for the next start.
  Future<void> _quitApp() async {
    final l = context.l10n;
    final quit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.settingsQuitConfirm),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: Text(l.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l.settingsQuitButton)),
        ],
      ),
    );
    if (quit != true) return;
    try {
      await ref.read(dabRtlSdrServiceProvider).stopPlayback();
    } catch (_) {}
    try {
      await (await ref.read(radioAudioHandlerProvider.future)).stop();
    } catch (_) {}
    if (Platform.isAndroid) {
      await SystemNavigator.pop();
    } else {
      HrdabDesktop.shutdownIfStarted();
    }
    // Also ends the media session's foreground service on Android.
    exit(0);
  }
}

/// The settings' first page: one entry per area, each with its logo.
class _SettingsOverview extends ConsumerWidget {
  const _SettingsOverview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = ref.watch(systemPartsProvider);
    final l = context.l10n;
    void open(SettingsSection s) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(section: s, fromOverview: true)));
    // A switched-off part stays in the list (greyed) - OK says where it's
    // switched on.
    void off(String part) => ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.settingsPartOff(part))),
        );
    return Scaffold(
      appBar: AppBar(title: Text(l.systemTileSettingsShort)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _AreaTile(
            logo: 'assets/icon/home_system_logo.png',
            title: 'System',
            subtitle: LauncherService.supported
                ? l.settingsAreaSystemSubtitle
                : l.settingsAreaSystemSubtitleNoHomeKey,
            autofocus: true,
            onTap: () => open(SettingsSection.system),
          ),
          _AreaTile(
            logo: 'assets/icon/radio_logo.png',
            title: 'Radio',
            subtitle: l.settingsAreaRadioSubtitle,
            enabled: parts.radio,
            onTap: () => parts.radio ? open(SettingsSection.radio) : off('Radio'),
          ),
          _AreaTile(
            logo: 'assets/icon/tv_logo.png',
            title: 'TV',
            subtitle: l.settingsAreaTvSubtitle,
            enabled: parts.tv,
            onTap: () => parts.tv ? open(SettingsSection.tv) : off('TV'),
          ),
          if (DisplayService.supported)
            _AreaTile(
              logo: 'assets/icon/dashboard_logo.png',
              title: l.dashboardTitle,
              subtitle: l.dashboardAreaSubtitle,
              enabled: parts.dashboard,
              onTap: () => parts.dashboard ? open(SettingsSection.dashboard) : off(l.dashboardTitle),
            ),
          _AreaTile(
            logo: 'assets/icon/pictures_logo.png',
            title: l.picturesTitle,
            subtitle: l.picturesAreaSubtitle,
            enabled: parts.pictures,
            onTap: () => parts.pictures ? open(SettingsSection.pictures) : off(l.picturesTitle),
          ),
          _AreaTile(
            logo: 'assets/icon/music_logo.png',
            title: l.musicTitle,
            subtitle: l.musicAreaSubtitle,
            enabled: parts.music,
            onTap: () => parts.music
                ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MusicSettingsScreen()))
                : off(l.musicTitle),
          ),
          if (BrowserChannel.supported)
            _AreaTile(
              logo: 'assets/icon/browser_logo.png',
              title: l.browserTitle,
              subtitle: l.browserAreaSubtitle,
              enabled: parts.browser,
              onTap: () => parts.browser
                  ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BrowserSettingsScreen()))
                  : off(l.browserTitle),
            ),
        ],
      ),
    );
  }
}

class _AreaTile extends StatefulWidget {
  const _AreaTile({
    required this.logo,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.autofocus = false,
    this.enabled = true,
  });

  final String logo;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool autofocus;

  /// False: greyed out, "ausgeschaltet" instead of the subtitle.
  final bool enabled;

  @override
  State<_AreaTile> createState() => _AreaTileState();
}

class _AreaTileState extends State<_AreaTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TvFocusHighlight(
        focused: _focused,
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(12),
          focusColor: Colors.transparent,
          onFocusChange: (v) => setState(() => _focused = v),
          onTap: widget.onTap,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.4,
            child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(widget.logo, width: 64, height: 64, filterQuality: FilterQuality.medium),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        widget.enabled ? widget.subtitle : context.l10n.settingsAreaOff,
                        style: const TextStyle(color: Colors.white60, fontSize: 15),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white38),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}

/// App licence and the attributions the open data sources require
/// (GeoSphere Austria and Open-Meteo are CC BY 4.0).
class _AboutBlock extends StatefulWidget {
  const _AboutBlock();

  @override
  State<_AboutBlock> createState() => _AboutBlockState();
}

class _AboutBlockState extends State<_AboutBlock> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60);
    final l = context.l10n;
    Widget line(String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: body?.copyWith(fontWeight: FontWeight.w600)),
              Text(text, style: small),
            ],
          ),
        );
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _focused ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            line('Home System', l.settingsAboutLicense),
            line(l.settingsWeatherForecast, l.settingsAboutWeatherData),
            line(l.settingsAboutUvIndex, l.settingsAboutUvData),
            line(l.settingsAboutInternetRadio, l.settingsAboutInternetRadioData),
            line(l.settingsAboutInternetTv, l.settingsAboutInternetTvData),
            line(l.settingsAboutMaps, l.settingsAboutMapsData),
            line(l.settingsAboutAircraft, l.settingsAboutAircraftData),
            line(l.settingsAboutAdblock, l.settingsAboutAdblockData),
            line(l.settingsAboutPlaceSearch, l.settingsAboutPlaceSearchData),
            line(l.settingsAboutBackgroundPhotos, l.settingsAboutBackgroundPhotosData),
            line(l.settingsWeatherRadar, l.settingsAboutRadarData),
          ],
        ),
      ),
    );
  }
}

/// A plain, fully custom focusable row (no built-in Radio/Switch keyboard
/// handling that would otherwise intercept D-Pad up/down for its own
/// selection logic and block traversal to the next setting).
class _TvChoiceTile extends StatefulWidget {
  final String label;
  final bool selected;
  final bool asToggle;
  final bool compact;
  final bool bold;
  final VoidCallback onTap;

  const _TvChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.asToggle = false,
    this.compact = false,
    this.bold = false,
  });

  @override
  State<_TvChoiceTile> createState() => _TvChoiceTileState();
}

class _TvChoiceTileState extends State<_TvChoiceTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final icon = widget.asToggle
        ? (widget.selected ? Icons.toggle_on : Icons.toggle_off)
        : (widget.selected ? Icons.radio_button_checked : Icons.radio_button_off);
    return TvFocusHighlight(
      focused: _focused,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // We draw our own focus indicator (TvFocusHighlight's border) below;
        // without this, Material's default focus/hover overlay stacks a
        // second, much brighter wash on top that washes out the text.
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.04),
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: widget.compact ? 8 : 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: widget.selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white54,
              ),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white,
                  fontWeight: widget.bold ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row that opens a sub-page - unlike [_TvChoiceTile] not a choice, so no
/// radio circle that would read as "not selected/not set up". Shows whether
/// it's set up ([configured]: green tick / amber hint; null = neither, with
/// [icon] instead), the current [value] and a chevron.
/// The Home key's entry: "funktioniert" - or, when it doesn't, amber and
/// framed so it catches the eye at once. Checked again every few seconds
/// and when coming back to the app.
class _HomeKeyTile extends ConsumerStatefulWidget {
  const _HomeKeyTile();

  @override
  ConsumerState<_HomeKeyTile> createState() => _HomeKeyTileState();
}

class _HomeKeyTileState extends ConsumerState<_HomeKeyTile> with WidgetsBindingObserver {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => ref.invalidate(homeKeyWorkingProvider));
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(homeKeyWorkingProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // Unknown yet: shown neutral, not as an error.
    final working = ref.watch(homeKeyWorkingProvider).value;
    final tile = _TvNavTile(
      label: l.settingsHomeKey,
      value: working == null ? null : (working ? l.settingsHomeKeyWorking : l.settingsHomeKeyBroken),
      configured: working,
      icon: Icons.home_outlined,
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HomeButtonSettingsScreen()));
        ref.invalidate(homeKeyWorkingProvider);
        ref.invalidate(permissionEntriesProvider);
      },
    );
    if (working != false) return tile;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber, width: 2),
      ),
      child: tile,
    );
  }
}

class _TvNavTile extends StatefulWidget {
  final String label;
  final String? value;
  final bool? configured;
  final IconData? icon;
  final VoidCallback onTap;

  const _TvNavTile({required this.label, this.value, this.configured, this.icon, required this.onTap});

  @override
  State<_TvNavTile> createState() => _TvNavTileState();
}

class _TvNavTileState extends State<_TvNavTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (widget.configured) {
      true => (Icons.check_circle, Theme.of(context).colorScheme.primary),
      false => (Icons.error_outline, Colors.amber),
      null => (widget.icon ?? Icons.settings_outlined, Colors.white70),
    };
    return TvFocusHighlight(
      focused: _focused,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.04),
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Text(widget.label, style: const TextStyle(fontSize: 16, color: Colors.white)),
              if (widget.value != null) ...[
                const SizedBox(width: 12),
                Text(
                  widget.value!,
                  style: TextStyle(fontSize: 16, color: widget.configured == false ? Colors.amber : Colors.white60),
                ),
              ],
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _TvIconButton({required this.icon, required this.onTap});

  @override
  State<_TvIconButton> createState() => _TvIconButtonState();
}

class _TvIconButtonState extends State<_TvIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.04),
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(widget.icon, color: widget.onTap == null ? Colors.white24 : null),
        ),
      ),
    );
  }
}
