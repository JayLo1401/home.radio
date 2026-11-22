import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/display_mode.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models/favorite_channel.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/desktop/hrdab_desktop.dart';
import '../../data/services/launcher_service.dart';
import '../launcher/launcher_providers.dart';
import '../rtlsdr/rtl_sdr_test_screen.dart';
import 'backup_settings_screen.dart';
import '../tv/tv_providers.dart';
import 'launcher_settings_screens.dart';
import 'tv_settings_screen.dart';
import 'update_settings_screen.dart';
import 'location_settings_screen.dart';
import 'radar_source_settings_screen.dart';

/// The settings' areas - one page each, reached from the overview.
enum SettingsSection { launcher, radio, tv, general }

/// Settings: without [section] the overview of the areas (Launcher, Home
/// Radio, Home TV, Allgemein), with it that area's page - Home Radio's gear
/// opens its own area right away.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.section});

  final SettingsSection? section;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  AutostartMode _mode = AutostartMode.lastStation;
  int? _fixedProgramNumber;
  // Home TV's start channel (null = last watched); "Festen Sender" picked
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
    final scale = ref.read(uiScaleProvider);
    if (!mounted) return;
    setState(() {
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

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    final locationName = ref.watch(weatherDisplaySettingsProvider).locationName;
    final receiverMode = ref.watch(receiverModeProvider);
    final receiverSections = ref.watch(receiverSectionsProvider);
    // Only the kind of source, not its address - the settings list
    // shouldn't advertise whichever third-party radar is set up.
    final radarSettings = ref.watch(weatherDisplaySettingsProvider);
    final radarSourceLabel = radarSettings.radarUrl.trim().isEmpty
        ? 'nicht eingerichtet'
        : (radarSettings.radarIsWebPage ? 'Webseite' : 'Bild');
    final repo = ref.read(settingsRepositoryProvider);
    final launcher = ref.watch(launcherSettingsProvider);

    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Einstellungen')),
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
          SettingsSection.launcher => 'Einstellungen: Launcher',
          SettingsSection.radio => 'Einstellungen: Home Radio',
          SettingsSection.tv => 'Einstellungen: Home TV',
          SettingsSection.general => 'Einstellungen: Allgemein',
        }),
      ),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (section == SettingsSection.radio) ...[
            // First, since it decides whether DAB+ shows up anywhere at all.
            Text('Empfang', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              // "Kein Empfänger" is a valid choice too, not a missing setup.
              child: _TvNavTile(
                label: 'Radio-Empfänger (DAB+ & UKW)',
                value: switch (receiverMode) {
                  ReceiverMode.none => 'Kein Empfänger',
                  ReceiverMode.usb => 'RTL-SDR per USB',
                  ReceiverMode.tcp => 'RTL-SDR über Netzwerk',
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
              tileToggle('DAB anzeigen', receiverSections.dab, (v) {
                ref.read(receiverSectionsProvider.notifier).setDab(v);
              }),
              tileToggle('FM anzeigen', receiverSections.fm, (v) {
                ref.read(receiverSectionsProvider.notifier).setFm(v);
              }),
              tileToggle('LW/MW/KW anzeigen', receiverSections.am, (v) {
                ref.read(receiverSectionsProvider.notifier).setAm(v);
              }),
              tileToggle('Funk anzeigen', receiverSections.funk, (v) {
                ref.read(receiverSectionsProvider.notifier).setFunk(v);
              }),
            ],
            ],
            if (section == SettingsSection.launcher) ...[
              Text('Beim Start der App', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvChoiceTile(
                  label: 'Launcher anzeigen',
                  selected: launcher.startScreen == StartScreen.launcher,
                  onTap: () => ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.launcher),
                ),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvChoiceTile(
                  label: 'Home Radio mit Sender starten (Home Radio → Autostart)',
                  selected: launcher.startScreen == StartScreen.radio,
                  onTap: () => ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.radio),
                ),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvChoiceTile(
                  label: 'Home TV mit Sender starten (Home TV → Sender beim Start)',
                  selected: launcher.startScreen == StartScreen.tv,
                  onTap: () => ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.tv),
                ),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: 'Hintergrund',
                  value: switch (launcher.backgroundSource) {
                    LauncherBackgroundSource.builtin => 'Farbverläufe',
                    LauncherBackgroundSource.photos => 'Landschaftsfotos',
                    LauncherBackgroundSource.server => 'Eigener Server',
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
                  label: 'Icon-Paket',
                  value: launcher.iconPack == null
                      ? 'Original-Logos'
                      : (ref.watch(iconPacksProvider).value ?? const [])
                              .where((p) => p.package == launcher.iconPack)
                              .firstOrNull
                              ?.label ??
                          launcher.iconPack,
                  icon: Icons.palette_outlined,
                  onTap: () => chooseIconPack(context, ref),
                ),
              ),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvNavTile(
                  label: 'Home-Taste',
                  icon: Icons.home_outlined,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HomeButtonSettingsScreen()),
                  ),
                ),
              ),
            ],
            if (section == SettingsSection.tv) ...[
              Text('Receiver', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: 'Sat-Receiver (Enigma2)',
                value: (ref.watch(enigma2ConfigProvider)?.configured ?? false)
                    ? ref.watch(enigma2ConfigProvider)!.host
                    : 'nicht eingerichtet',
                configured: ref.watch(enigma2ConfigProvider)?.configured ?? false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TvSettingsScreen()),
                ),
              ),
            ),
              const Divider(height: 32),
              Text('Sender beim Start von Home TV', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: _TvChoiceTile(
                  label: 'Zuletzt gesehenen Sender',
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
                  label: 'Festen Sender',
                  selected: _tvStartChannel != null || _tvFixedChosen,
                  onTap: () => setState(() => _tvFixedChosen = true),
                ),
              ),
              if (_tvStartChannel != null || _tvFixedChosen)
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 8),
                  child: ref.watch(tvChannelsProvider).when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => Text('Senderliste nicht erreichbar: $e', style: const TextStyle(color: Colors.amber)),
                        data: (channels) => channels.isEmpty
                            ? const Text('Erst den Receiver einrichten.', style: TextStyle(color: Colors.white60))
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
              Text('Als Nächstes', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text(
                'Kurz bevor auf dem laufenden Sender die nächste Sendung beginnt, zeigt Home TV, was als Nächstes kommt.',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 8),
              tileToggle('Hinweis auf die nächste Sendung', ref.watch(tvNextUpProvider).enabled, (v) {
                final s = ref.read(tvNextUpProvider);
                ref.read(tvNextUpProvider.notifier).set((enabled: v, leadMinutes: s.leadMinutes, showSeconds: s.showSeconds));
              }),
              if (ref.watch(tvNextUpProvider).enabled) ...[
                const SizedBox(height: 8),
                Text('Wie lange vorher', style: Theme.of(context).textTheme.bodyLarge),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in SettingsRepository.tvNextLeadChoices)
                      FocusTraversalOrder(
                        order: NumericFocusOrder(nextOrder()),
                        child: _TvChoiceTile(
                          compact: true,
                          label: '$m Min.',
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
                Text('Wie lange anzeigen', style: Theme.of(context).textTheme.bodyLarge),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final sec in SettingsRepository.tvNextShowChoices)
                      FocusTraversalOrder(
                        order: NumericFocusOrder(nextOrder()),
                        child: _TvChoiceTile(
                          compact: true,
                          label: sec == 60 ? '1 Min.' : '$sec Sek.',
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
            ],
            if (section == SettingsSection.radio) ...[
            const Divider(height: 32),
            Text('Autostart', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Zuletzt gehörten Sender starten',
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
                label: 'Festen Sender starten',
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
            Text('Anzeige', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            tileToggle('Datum neben der Uhrzeit anzeigen', _showClockDate, (v) async {
              setState(() => _showClockDate = v);
              await ref.read(showClockDateProvider.notifier).set(v);
            }),
            ],
            if (section == SettingsSection.general) ...[
            Text('Anzeige', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            tileToggle('Vollbild', _fullscreen, (v) => _setFullscreen(fullscreen: v)),
            if (Platform.isWindows && _fullscreen)
              scaleRow(
                label: 'Monitor für Vollbild',
                valueLabel: '$_monitor von $_monitors',
                onChange: (d) => _setFullscreen(monitor: (_monitor + d).clamp(1, _monitors < 1 ? 1 : _monitors)),
              ),
            scaleRow(
              label: 'Größe der Oberfläche',
              valueLabel: '${(_uiScale * 100).round()} %',
              onChange: (d) => _changeUiScale(d * 0.1),
            ),
            ],
            if (section == SettingsSection.radio) ...[
            const Divider(height: 32),
            Text('Kacheln', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            // Its own sub-page, not inline text fields here (see
            // LocationSettingsScreen's own doc comment for why: D-Pad down
            // couldn't get past a focused TextField to reach the tile
            // groups below).
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: 'Standort',
                value: locationName,
                configured: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LocationSettingsScreen()),
                ),
              ),
            ),
            tileGroup(
              title: 'Wetterprognose',
              enabled: _weatherEnabled,
              onToggleEnabled: (v) async {
                setState(() => _weatherEnabled = v);
                await ref.read(weatherDisplaySettingsProvider.notifier).setWeatherEnabled(v);
              },
              children: [
                tileToggle('Über 2 Kacheln (volle Höhe)', _weatherSpanTwoTiles, (v) async {
                  setState(() => _weatherSpanTwoTiles = v);
                  await ref.read(weatherDisplaySettingsProvider.notifier).setWeatherSpanTwoTiles(v);
                }),
                scaleRow(
                  label: 'Größe der Kachel',
                  valueLabel: '${(_weatherScale * 100).round()} %',
                  onChange: (d) => _changeWeatherScale(d * 0.1),
                ),
                scaleRow(
                  // Separate from the tile size above - this scales the
                  // forecast content (icon/text/badges) inside the tile,
                  // independently of how big the tile itself is.
                  label: 'Größe des Inhalts',
                  valueLabel: '${(_weatherContentScale * 100).round()} %',
                  onChange: (d) => _changeWeatherContentScale(d * 0.1),
                ),
              ],
            ),
            tileGroup(
              title: 'Wetterradar',
              enabled: _radarEnabled,
              onToggleEnabled: (v) async {
                setState(() => _radarEnabled = v);
                await ref.read(weatherDisplaySettingsProvider.notifier).setRadarEnabled(v);
              },
              children: [
                FocusTraversalOrder(
                  order: NumericFocusOrder(nextOrder()),
                  child: _TvNavTile(
                    label: 'Quelle',
                    value: radarSourceLabel,
                    configured: radarSettings.radarUrl.trim().isNotEmpty,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const RadarSourceSettingsScreen()),
                    ),
                  ),
                ),
                scaleRow(
                  label: 'Größe der Kachel',
                  valueLabel: '${(_radarScale * 100).round()} %',
                  onChange: (d) => _changeRadarScale(d * 0.1),
                ),
                scaleRow(
                  // Not the tile size above - how much of the map around the
                  // location is shown (distance to the top/bottom edge).
                  // Only takes effect if the source URL uses {r}.
                  label: 'Umkreis um den Standort ({r} in der Adresse)',
                  valueLabel: '$_radarRadiusKm km',
                  onChange: (d) => _changeRadarRadius(d),
                ),
                scaleRow(
                  label: 'Abdunkeln (für abends)',
                  valueLabel: '${(_radarDimming * 100).round()} %',
                  onChange: (d) => _changeRadarDimming(d * 0.1),
                ),
              ],
            ),
            tileGroup(
              title: 'Sonne & Mond',
              enabled: _sunEnabled,
              onToggleEnabled: (v) async {
                setState(() => _sunEnabled = v);
                await ref.read(weatherDisplaySettingsProvider.notifier).setSunEnabled(v);
              },
              children: [
                scaleRow(
                  label: 'Größe der Kachel',
                  valueLabel: '${(_sunScale * 100).round()} %',
                  onChange: (d) => _changeSunScale(d * 0.1),
                ),
              ],
            ),
            // Home Radio's gear opens its own area; the others from here.
            const Divider(height: 32),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: 'Weitere Einstellungen (Launcher, Home TV, Allgemein)',
                icon: Icons.settings_outlined,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ),
            ],
            // Favorites are renamed/reordered/removed right in the home
            // screen's sidebar ("Bearbeiten"), the DAB+ station order is set
            // on the DAB+ stations screen - neither lives here anymore.
            if (section == SettingsSection.general) ...[
            const Divider(height: 32),
            Text('Weiteres', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: 'Backup & Wiederherstellung',
                icon: Icons.backup_outlined,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BackupSettingsScreen()),
                ),
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: 'Updates',
                icon: Icons.system_update_outlined,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const UpdateSettingsScreen()),
                ),
              ),
            ),
            const Divider(height: 32),
            Text('Über', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            // Focusable so the D-Pad can scroll down to it (plain text after
            // the last focusable control would stay out of reach on a TV).
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: const _AboutBlock(),
            ),
            const Divider(height: 32),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvNavTile(
                label: 'Programm beenden',
                icon: Icons.power_settings_new,
                onTap: _quitApp,
              ),
            ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// Closes the app after asking ("Abbrechen" focused - an OK pressed by
  /// mistake on the remote doesn't end it). Playback and the receiver are
  /// stopped first; on desktop the receiver is shut down so rtl_tcp is free
  /// for the next start.
  Future<void> _quitApp() async {
    final quit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Programm beenden?'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Beenden')),
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
class _SettingsOverview extends StatelessWidget {
  const _SettingsOverview();

  @override
  Widget build(BuildContext context) {
    void open(SettingsSection s) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(section: s)));
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (LauncherService.supported)
            _AreaTile(
              logo: 'assets/icon/home_media_logo.png',
              title: 'Launcher',
              subtitle: 'Start der App, Hintergrund, Icon-Paket, Home-Taste',
              autofocus: true,
              onTap: () => open(SettingsSection.launcher),
            ),
          _AreaTile(
            logo: 'assets/icon/home_radio_logo.png',
            title: 'Home Radio',
            subtitle: 'Empfänger (DAB+, UKW, Funk), Autostart-Sender, Wetter, Radar, Sonne & Mond',
            autofocus: !LauncherService.supported,
            onTap: () => open(SettingsSection.radio),
          ),
          _AreaTile(
            logo: 'assets/icon/home_tv_logo.png',
            title: 'Home TV',
            subtitle: 'Sat-Receiver (Enigma2, z. B. GigaBlue)',
            onTap: () => open(SettingsSection.tv),
          ),
          _AreaTile(
            icon: Icons.tune,
            title: 'Allgemein',
            subtitle: 'Größe der Oberfläche, Vollbild, Backup, Updates, Über, Programm beenden',
            onTap: () => open(SettingsSection.general),
          ),
        ],
      ),
    );
  }
}

class _AreaTile extends StatefulWidget {
  const _AreaTile({this.logo, this.icon, required this.title, required this.subtitle, required this.onTap, this.autofocus = false});

  final String? logo;
  final IconData? icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool autofocus;

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
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: widget.logo != null
                      ? Image.asset(widget.logo!, width: 64, height: 64, filterQuality: FilterQuality.medium)
                      : Container(
                          width: 64,
                          height: 64,
                          color: const Color(0xFF1E2326),
                          child: Icon(widget.icon, color: Colors.white, size: 34),
                        ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(widget.subtitle, style: const TextStyle(color: Colors.white60, fontSize: 15)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white38),
              ],
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
            line(
              'Home Media',
              'PolyForm Noncommercial 1.0.0 - frei für private und nicht-kommerzielle Nutzung. '
                  '© 2026 Jürgen Laschak, github.com/JayLo1401/home.radio',
            ),
            line(
              'Wetterprognose',
              'Daten: © GeoSphere Austria, lizenziert unter CC BY 4.0 (data.hub.geosphere.at)',
            ),
            line(
              'UV-Index',
              'Weather data by Open-Meteo.com, lizenziert unter CC BY 4.0',
            ),
            line(
              'Internetradio',
              'Sendersuche und Logos über das Community-Verzeichnis Radio Browser (radio-browser.info)',
            ),
            line(
              'Ortssuche',
              '© OpenStreetMap-Mitwirkende, Daten unter der Open Database License (ODbL), über Nominatim.',
            ),
            line(
              'Hintergrundfotos des Launchers',
              'Bing-Bilder des Tages, © bei den jeweiligen Fotografen (nur wenn „Landschaftsfotos aus dem '
                  'Internet“ gewählt ist).',
            ),
            line(
              'Wetterradar',
              'Das Radarbild kommt von der selbst eingetragenen Quelle; Rechte und Quellenangaben '
                  'liegen beim jeweiligen Anbieter.',
            ),
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
