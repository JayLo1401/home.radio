import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/place_search_service.dart';

/// Location used by the weather forecast, radar and sun/moon tiles: search a
/// place by name (OpenStreetMap / Nominatim) and pick it from the results -
/// its coordinates are taken over automatically.
///
/// Its own sub-page rather than inline in the settings list: arrow keys in a
/// focused TextField move the text cursor, not traversal focus, which would
/// trap the D-Pad there. After a search, focus jumps to the first result.
class LocationSettingsScreen extends ConsumerStatefulWidget {
  const LocationSettingsScreen({super.key});

  @override
  ConsumerState<LocationSettingsScreen> createState() => _LocationSettingsScreenState();
}

class _LocationSettingsScreenState extends ConsumerState<LocationSettingsScreen> {
  final _service = PlaceSearchService();
  final _queryController = TextEditingController();
  final _firstResultFocus = FocusNode();
  List<PlaceResult>? _results;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _queryController.dispose();
    _firstResultFocus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_searching || _queryController.text.trim().isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await _service.search(_queryController.text);
      if (!mounted) return;
      setState(() => _results = results);
      if (results.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _firstResultFocus.requestFocus());
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Suche fehlgeschlagen - Internetverbindung prüfen.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _pick(PlaceResult p) async {
    await ref.read(weatherDisplaySettingsProvider.notifier).setLocation(p.lat, p.lon, p.name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Standort: ${p.name}')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(weatherDisplaySettingsProvider);
    final results = _results;
    return Scaffold(
      appBar: AppBar(title: const Text('Standort einrichten')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Gemeinsamer Standort für Wetterprognose, Wetterradar und Sonne & Mond.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(
            'Aktuell: ${current.locationName} '
            '(${current.lat.toStringAsFixed(4)}, ${current.lon.toStringAsFixed(4)})',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(labelText: 'Ort suchen, z. B. Graz oder Gleisdorf'),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _searching ? null : _search,
                icon: _searching
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: const Text('Suchen'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          if (results != null && results.isEmpty)
            const Text('Kein Ort gefunden.', style: TextStyle(color: Colors.white54)),
          if (results != null)
            for (var i = 0; i < results.length; i++)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  focusNode: i == 0 ? _firstResultFocus : null,
                  // Clearly visible on a TV when selected with the D-Pad.
                  focusColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: const Icon(Icons.place_outlined),
                  title: Text(results[i].name),
                  subtitle: Text(
                    '${results[i].region.isEmpty ? '' : '${results[i].region} · '}'
                    '${results[i].lat.toStringAsFixed(3)}, ${results[i].lon.toStringAsFixed(3)}',
                  ),
                  onTap: () => _pick(results[i]),
                ),
              ),
          const SizedBox(height: 12),
          const Text(
            'Ortssuche: © OpenStreetMap-Mitwirkende (ODbL), über Nominatim.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
