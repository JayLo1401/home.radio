import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart' show TvFocusHighlight;
import '../../data/models/band_plan.dart';
import '../../data/repositories/settings_repository.dart';
import 'acars_screen.dart';
import 'adsb_screen.dart';
import 'ism_screen.dart';
import 'scanner_screen.dart';

/// "Funk": all listening bands in one place - CB radio, PMR446, amateur
/// radio, the "Kurzwelle" group, military airband, the "Flugzeuge" group
/// (airband voice, ACARS, ADS-B radar), wireless sensors and the free band
/// scan over the stick's whole range. Reachable while "Funk anzeigen" is on
/// in the settings.
class ListeningHubScreen extends StatelessWidget {
  const ListeningHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget Function() screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen()));
    return _TileGrid(
      title: 'Funk',
      tiles: [
        _Tile(
          icon: Icons.forum,
          title: 'CB-Funk',
          subtitle: '26,965–27,405 MHz · Kanal 1–40 (80)',
          onTap: () => open(() => ScannerScreen(plan: cbBandPlan())),
        ),
        _Tile(
          icon: Icons.settings_remote,
          title: 'PMR446',
          subtitle: '446,00625–446,19375 MHz · Kanal 1–16',
          onTap: () => open(() => ScannerScreen(plan: pmrBandPlan)),
        ),
        _Tile(
          icon: Icons.cell_tower,
          title: 'Amateurfunk',
          subtitle: '160 m bis 23 cm mit Bandplan',
          onTap: () => open(() => ScannerScreen(plan: hamBandPlans.first, variants: allHamBandPlans)),
        ),
        _Tile(
          icon: Icons.public,
          title: 'Kurzwelle',
          subtitle: 'KW-Rundfunk · Amateurfunk KW · Zeitzeichen & Flugwetter',
          onTap: () => open(() => const ShortwaveHubScreen()),
        ),
        _Tile(
          icon: Icons.flight,
          title: 'Flugzeuge',
          subtitle: 'Flugfunk · ACARS · Radar (ADS-B)',
          onTap: () => open(() => const AircraftHubScreen()),
        ),
        _Tile(
          icon: Icons.shield_outlined,
          title: 'Militärfunk',
          subtitle: '225–400 MHz · AM',
          onTap: () => open(() => ScannerScreen(plan: milBandPlan)),
        ),
        _Tile(
          icon: Icons.sensors,
          title: 'Funksensoren',
          subtitle: '433/868 MHz · Thermometer, Wetterstationen, Schalter',
          onTap: () => open(() => const IsmScreen()),
        ),
        _Tile(
          icon: Icons.manage_search,
          title: 'Freier Band-Scan',
          subtitle: '0,5–1766 MHz frei abstimmen, Bänder eingezeichnet',
          onTap: () => open(() => ScannerScreen(plan: worldBandPlan)),
        ),
      ],
    );
  }
}

/// "Flugzeuge": airband voice, ACARS text messages and the ADS-B radar.
class AircraftHubScreen extends StatelessWidget {
  const AircraftHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget Function() screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen()));
    return _TileGrid(
      title: 'Flugzeuge',
      tiles: [
        _Tile(
          icon: Icons.headset_mic,
          title: 'Flugfunk',
          subtitle: '118–137 MHz · Sprechfunk (AM)',
          onTap: () => open(() => ScannerScreen(plan: airBandPlan)),
        ),
        _Tile(
          icon: Icons.textsms_outlined,
          title: 'ACARS',
          subtitle: '131,5–131,9 MHz · Textmeldungen von Flugzeugen',
          onTap: () => open(() => const AcarsScreen()),
        ),
        _Tile(
          icon: Icons.radar,
          title: 'Radar (ADS-B)',
          subtitle: '1090 MHz · Flugnummer, Höhe, Position auf der Karte',
          onTap: () => open(() => const AdsbScreen()),
        ),
      ],
    );
  }
}

/// "Kurzwelle" (below 30 MHz): the shortwave amateur bands and utility
/// stations (broadcasting has its own entry, see AmRadio in home_screen) -
/// and how the stick gets there (see hf.h): by itself with direct sampling
/// (RTL-SDR Blog V3) or the RTL-SDR Blog V4's upconverter, or through an
/// external upconverter set here.
class ShortwaveHubScreen extends ConsumerStatefulWidget {
  const ShortwaveHubScreen({super.key});

  @override
  ConsumerState<ShortwaveHubScreen> createState() => _ShortwaveHubScreenState();
}

class _ShortwaveHubScreenState extends ConsumerState<ShortwaveHubScreen> {
  int? _upconverterHz;

  @override
  void initState() {
    super.initState();
    ref.read(settingsRepositoryProvider).getHfUpconverterHz().then((hz) {
      if (mounted) setState(() => _upconverterHz = hz);
    });
  }

  static String _upconverterLabel(int hz) => switch (hz) {
    0 => 'Keiner – Direct Sampling oder RTL-SDR Blog V4',
    125000000 => '125 MHz (Ham It Up)',
    120000000 => '120 MHz (SpyVerter)',
    _ => '${formatMhzAuto(hz)} MHz',
  };

  Future<void> _pickUpconverter() async {
    final current = _upconverterHz ?? 0;
    final hz = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Aufwärtsmischer vor dem Stick'),
        children: [
          for (final choice in SettingsRepository.hfUpconverterChoices)
            ListTile(
              autofocus: choice == current,
              selected: choice == current,
              onTap: () => Navigator.of(context).pop(choice),
              title: Text(_upconverterLabel(choice)),
            ),
        ],
      ),
    );
    if (hz == null || !mounted) return;
    setState(() => _upconverterHz = hz);
    await ref.read(settingsRepositoryProvider).setHfUpconverterHz(hz);
  }

  @override
  Widget build(BuildContext context) {
    void open(Widget Function() screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen()));
    final upconverter = _upconverterHz;
    return _TileGrid(
      title: 'Kurzwelle',
      tiles: [
        _Tile(
          icon: Icons.cell_tower,
          title: 'Amateurfunk KW',
          subtitle: '160 m bis 10 m · SSB, CW, FT8',
          onTap: () => open(() => ScannerScreen(plan: hfHamBandPlans.first, variants: [...hfHamBandPlans, hamBandPlans.first])),
        ),
        _Tile(
          icon: Icons.schedule,
          title: 'KW-Funkdienste',
          subtitle: 'Zeitzeichen · VOLMET · Shanwick · Wetterfax',
          onTap: () => open(() => ScannerScreen(plan: hfUtilityBandPlan)),
        ),
        _Tile(
          icon: Icons.settings_input_antenna,
          title: 'Aufwärtsmischer',
          subtitle: upconverter == null ? '…' : _upconverterLabel(upconverter),
          onTap: _pickUpconverter,
        ),
      ],
      footer: 'Kurzwelle braucht einen Stick mit Kurzwelleneingang: RTL-SDR Blog V3 (Direct Sampling, '
          'schaltet unter 24 MHz automatisch um), RTL-SDR Blog V4 (eingebauter Aufwärtsmischer; über '
          'rtl_tcp nur, wenn der Server ihn unterstützt) – oder einen beliebigen Stick mit einem '
          'Aufwärtsmischer wie dem Ham It Up. Gewöhnliche Sticks (z. B. NooElec NESDR) haben keinen. '
          'Dazu eine Antenne für Kurzwelle – eine Langdraht- oder Aktivantenne. '
          'Rundfunk auf Lang-, Mittel- und Kurzwelle: eigener Punkt „LW/MW/KW“ oben.',
    );
  }
}

class _Tile {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _Tile({required this.icon, required this.title, required this.subtitle, required this.onTap});
}

/// A page of tiles; the first one has the focus (remote). [footer]: a note
/// under them.
class _TileGrid extends StatelessWidget {
  final String title;
  final List<_Tile> tiles;
  final String? footer;

  const _TileGrid({required this.title, required this.tiles, this.footer});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final (i, t) in tiles.indexed) _HubTile(tile: t, autofocus: i == 0),
            ],
          ),
          if (footer case final text?)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 16)),
            ),
        ],
      ),
    );
  }
}

/// A tile to open - with the remote: D-Pad to it (framed while focused),
/// OK opens it.
class _HubTile extends StatefulWidget {
  final _Tile tile;
  final bool autofocus;

  const _HubTile({required this.tile, this.autofocus = false});

  @override
  State<_HubTile> createState() => _HubTileState();
}

class _HubTileState extends State<_HubTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tile;
    return SizedBox(
      width: 340,
      height: 130,
      child: TvFocusHighlight(
        focused: _focused,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            autofocus: widget.autofocus,
            focusColor: Colors.transparent,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: t.onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(t.icon, size: 44, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.title, style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(t.subtitle, style: const TextStyle(color: Colors.white60)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
