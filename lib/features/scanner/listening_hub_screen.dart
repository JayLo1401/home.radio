import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart' show TvFocusHighlight;
import '../../data/models/band_plan.dart';
import 'acars_screen.dart';
import 'adsb_screen.dart';
import 'ism_screen.dart';
import 'scanner_screen.dart';

/// "Funk": all listening bands in one place - CB radio, PMR446, amateur
/// radio, military airband (those switched on in the settings), the
/// "Flugzeuge" group (airband voice, ACARS, ADS-B radar), wireless sensors
/// and the free band scan over the stick's whole range.
class ListeningHubScreen extends ConsumerWidget {
  const ListeningHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bands = ref.watch(listeningBandsProvider);
    void open(Widget Function() screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen()));
    return _TileGrid(
      title: 'Funk',
      footer: !(bands.cb || bands.ham || bands.mil)
          ? 'CB-Funk, Amateurfunk und Militärfunk lassen sich in den Einstellungen einschalten.'
          : null,
      tiles: [
        if (bands.cb)
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
        if (bands.ham)
          _Tile(
            icon: Icons.cell_tower,
            title: 'Amateurfunk',
            subtitle: '10 m · 6 m · 2 m · 70 cm · 23 cm mit Bandplan',
            onTap: () => open(() => ScannerScreen(plan: hamBandPlans.first, variants: hamBandPlans)),
          ),
        _Tile(
          icon: Icons.flight,
          title: 'Flugzeuge',
          subtitle: 'Flugfunk · ACARS · Radar (ADS-B)',
          onTap: () => open(() => const AircraftHubScreen()),
        ),
        if (bands.mil)
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
          subtitle: '24–1766 MHz frei abstimmen, Bänder eingezeichnet',
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

class _Tile {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _Tile({required this.icon, required this.title, required this.subtitle, required this.onTap});
}

/// A page of tiles; the first one has the focus (remote).
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
              child: Text(text, style: const TextStyle(color: Colors.white54)),
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
