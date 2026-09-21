import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Location used by the weather forecast, radar and sun/moon tiles - split
/// out from the main settings list (previously three TextFields inline
/// there) because D-Pad down couldn't get past them: arrow keys inside a
/// focused TextField move the text cursor, not traversal focus, so once
/// focus landed in one of these fields the rest of the settings list below
/// it became unreachable. A dedicated sub-page (reached like "DAB+ RTL-SDR
/// Einrichtung" already is) keeps the main list itself free of text fields
/// entirely.
class LocationSettingsScreen extends ConsumerStatefulWidget {
  const LocationSettingsScreen({super.key});

  @override
  ConsumerState<LocationSettingsScreen> createState() => _LocationSettingsScreenState();
}

class _LocationSettingsScreenState extends ConsumerState<LocationSettingsScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _latController;
  late final TextEditingController _lonController;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(weatherDisplaySettingsProvider);
    _nameController = TextEditingController(text: settings.locationName);
    _latController = TextEditingController(text: settings.lat.toString());
    _lonController = TextEditingController(text: settings.lon.toString());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _latController.dispose();
    _lonController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final lat = double.tryParse(_latController.text.replaceAll(',', '.'));
    final lon = double.tryParse(_lonController.text.replaceAll(',', '.'));
    if (lat == null || lon == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Breiten-/Längengrad ungültig.')),
      );
      return;
    }
    final name = _nameController.text.trim();
    await ref.read(weatherDisplaySettingsProvider.notifier).setLocation(lat, lon, name.isEmpty ? 'Standort' : name);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Standort gespeichert.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Standort einrichten')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Gemeinsamer Standort für Wetterprognose, Regenradar und Sonne & Mond.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Ortsname'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _latController,
            decoration: const InputDecoration(labelText: 'Breitengrad'),
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _lonController,
            decoration: const InputDecoration(labelText: 'Längengrad'),
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: const Text('Speichern'),
          ),
        ],
      ),
    );
  }
}
