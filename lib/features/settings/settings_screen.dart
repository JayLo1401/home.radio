import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/settings_repository.dart';
import '../dab_stations/dab_stations_screen.dart';
import '../rtlsdr/rtl_sdr_test_screen.dart';
import '../shared/rename_dialog.dart';
import 'backup_settings_screen.dart';
import 'location_settings_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  AutostartMode _mode = AutostartMode.lastStation;
  int? _fixedProgramNumber;
  DabSortMode _dabSortMode = DabSortMode.byEnsembleThenAlphabet;
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
    final dabSortMode = await repo.getDabSortMode();
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
    final scale = ref.read(uiScaleProvider);
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _fixedProgramNumber = fixed;
      _dabSortMode = dabSortMode;
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
      _loaded = true;
    });
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

  Future<void> _renameFavorite(FavoriteChannel channel) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => RenameDialog(
        title: 'Favorit umbenennen',
        initialValue: channel.displayName,
      ),
    );
    if (newName == null || newName.isEmpty) return;
    await ref.read(favoritesRepositoryProvider).rename(channel.programNumber, newName);
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    final locationName = ref.watch(weatherDisplaySettingsProvider).locationName;
    final repo = ref.read(settingsRepositoryProvider);

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

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
            scaleRow(
              label: 'Größe der Oberfläche',
              valueLabel: '${(_uiScale * 100).round()} %',
              onChange: (d) => _changeUiScale(d * 0.1),
            ),
            const Divider(height: 32),
            Text('Kacheln', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            // Its own sub-page, not inline text fields here (see
            // LocationSettingsScreen's own doc comment for why: D-Pad down
            // couldn't get past a focused TextField to reach the tile
            // groups below).
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Standort einrichten ($locationName)',
                selected: false,
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
              title: 'Regenradar',
              enabled: _radarEnabled,
              onToggleEnabled: (v) async {
                setState(() => _radarEnabled = v);
                await ref.read(weatherDisplaySettingsProvider.notifier).setRadarEnabled(v);
              },
              children: [
                scaleRow(
                  label: 'Größe der Kachel',
                  valueLabel: '${(_radarScale * 100).round()} %',
                  onChange: (d) => _changeRadarScale(d * 0.1),
                ),
                scaleRow(
                  // Not the tile size above - how much of the map around the
                  // location is shown (distance to the top/bottom edge).
                  label: 'Umkreis um den Standort',
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
            const Divider(height: 32),
            Text('Favoriten verwalten', style: Theme.of(context).textTheme.titleLarge),
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                'Mit den Pfeilen die Reihenfolge (Sendernummer) ändern.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
            for (final (index, c) in favorites.indexed)
              FocusTraversalOrder(
                order: NumericFocusOrder(nextOrder()),
                child: ListTile(
                  leading: CircleAvatar(child: Text('${c.programNumber}')),
                  title: Text(c.displayName),
                  subtitle:
                      Text(c.sourceType == FavoriteSourceType.dab ? 'DAB+' : 'Internetradio'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _TvIconButton(
                        icon: Icons.keyboard_arrow_up,
                        onTap: index == 0
                            ? null
                            : () => ref
                                .read(favoritesRepositoryProvider)
                                .swapProgramNumbers(c.programNumber, favorites[index - 1].programNumber),
                      ),
                      _TvIconButton(
                        icon: Icons.keyboard_arrow_down,
                        onTap: index == favorites.length - 1
                            ? null
                            : () => ref
                                .read(favoritesRepositoryProvider)
                                .swapProgramNumbers(c.programNumber, favorites[index + 1].programNumber),
                      ),
                      _TvIconButton(
                        icon: Icons.edit_outlined,
                        onTap: () => _renameFavorite(c),
                      ),
                      _TvIconButton(
                        icon: Icons.delete_outline,
                        onTap: () => ref.read(favoritesRepositoryProvider).remove(c.programNumber),
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 32),
            Text('DAB+ Sender sortieren', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Nach Sendern und Alphabet',
                selected: _dabSortMode == DabSortMode.byEnsembleThenAlphabet,
                onTap: () async {
                  setState(() => _dabSortMode = DabSortMode.byEnsembleThenAlphabet);
                  await ref.read(dabSortModeProvider.notifier).set(DabSortMode.byEnsembleThenAlphabet);
                },
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Nach Alphabet',
                selected: _dabSortMode == DabSortMode.byAlphabet,
                onTap: () async {
                  setState(() => _dabSortMode = DabSortMode.byAlphabet);
                  await ref.read(dabSortModeProvider.notifier).set(DabSortMode.byAlphabet);
                },
              ),
            ),
            const Divider(height: 32),
            Text('Technik', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'DAB+ RTL-SDR Einrichtung',
                selected: false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RtlSdrTestScreen()),
                ),
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'DAB+ Sender verwalten',
                selected: false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DabStationsScreen()),
                ),
              ),
            ),
            FocusTraversalOrder(
              order: NumericFocusOrder(nextOrder()),
              child: _TvChoiceTile(
                label: 'Backup & Wiederherstellung',
                selected: false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BackupSettingsScreen()),
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
          ],
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
              'Home Radio',
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
              'Wetterradar',
              'Niederschlag, Niederschlagsart und Böen: © GeoSphere Austria, Nowcast (INCA), '
                  'lizenziert unter CC BY 4.0. '
                  'Wolken und Blitze: © EUMETSAT (MSG Cloud Mask, MTG FCI IR 10.5, MTG Lightning Imager; EUMETView). '
                  'Grenzen, Seen, Flüsse, Orte: Natural Earth (gemeinfrei). '
                  'Relief: produced using Copernicus WorldDEM-90 © DLR e.V. 2010-2014 and © Airbus Defence '
                  'and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; '
                  'all rights reserved.',
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
