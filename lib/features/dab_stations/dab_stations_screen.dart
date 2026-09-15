import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/db/database.dart' show DabStation;
import '../../data/models/favorite_channel.dart';
import '../../data/models/usb_device_info.dart';
import '../shared/program_number_dialog.dart';

/// DAB+ adapter management: grant USB permission/open the adapter, run a
/// Band III scan (native, independent USB Host API access via
/// DabUsbPlugin/RaonTunerDriver - see their doc comments for the underlying
/// protocol/hardware details), and manage the resulting stations - every
/// station a scan has ever found is persisted (DabStationsRepository) so it
/// can be favorited (with a program number) without re-scanning, listed
/// separately from the merged favorites list ("Alle DAB+ Sender").
class DabStationsScreen extends ConsumerStatefulWidget {
  const DabStationsScreen({super.key});

  @override
  ConsumerState<DabStationsScreen> createState() => _DabStationsScreenState();
}

class _DabStationsScreenState extends ConsumerState<DabStationsScreen> {
  List<UsbDeviceInfo> _devices = const [];
  bool _loading = true;
  String? _openedDeviceName;

  @override
  void initState() {
    super.initState();
    _refresh();
    ref.read(dabUsbServiceProvider).deviceChanges.listen((_) => _refresh());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final devices = await ref.read(dabUsbServiceProvider).listDevices();
    if (mounted) {
      setState(() {
        _devices = devices;
        _loading = false;
      });
    }
  }

  Future<void> _requestPermission(UsbDeviceInfo device) async {
    final granted = await ref.read(dabUsbServiceProvider).requestPermission(device.deviceName);
    if (!mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('USB-Berechtigung wurde nicht erteilt.')),
      );
    }
    await _refresh();
  }

  Future<void> _openDevice(UsbDeviceInfo device) async {
    final service = ref.read(dabUsbServiceProvider);
    await service.openDevice(device.deviceName);
    if (!mounted) return;
    setState(() => _openedDeviceName = device.deviceName);
  }

  Future<void> _clearAllStations() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Alle DAB-Sender löschen?'),
            content: const Text(
              'Entfernt alle bisher gefundenen DAB+-Sender aus der Liste "Alle DAB+ Sender". '
              'Bereits als Favorit gespeicherte Sender bleiben erhalten.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Löschen'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await ref.read(dabStationsRepositoryProvider).clearAll();
  }

  @override
  Widget build(BuildContext context) {
    final stations = ref.watch(dabStationsStreamProvider).value ?? const <DabStation>[];
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    final dabFavorites = favorites.where((c) => c.sourceType == FavoriteSourceType.dab).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('DAB+ Sender'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Kein DAB+-USB-Adapter erkannt. Adapter anschließen und "Aktualisieren" tippen.'),
                  ),
                ..._devices.map((device) => _DeviceCard(
                      device: device,
                      opened: device.deviceName == _openedDeviceName,
                      onRequestPermission: () => _requestPermission(device),
                      onOpen: () => _openDevice(device),
                    )),
                if (dabFavorites.isNotEmpty || stations.isNotEmpty) ...[
                  const Divider(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Favoriten', style: Theme.of(context).textTheme.titleLarge),
                      ),
                      if (stations.isNotEmpty)
                        TextButton.icon(
                          onPressed: _clearAllStations,
                          icon: const Icon(Icons.delete_sweep_outlined),
                          label: const Text('Alle DAB-Sender löschen'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (dabFavorites.isEmpty)
                    const Text('Noch keine DAB+-Favoriten.', style: TextStyle(color: Colors.white54))
                  else
                    ...dabFavorites.map((c) => _FavoriteRow(channel: c)),
                  const SizedBox(height: 24),
                  Text('Alle DAB+ Sender', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  if (stations.isEmpty)
                    const Text(
                      'Noch keine Sender gefunden. Adapter öffnen und Sendersuchlauf starten.',
                      style: TextStyle(color: Colors.white54),
                    )
                  else
                    ...stations.map((s) {
                      final favorite = dabFavorites.where(
                        (c) => c.dabFreqKhz == s.freqKhz && c.dabServiceId == s.serviceId,
                      ).firstOrNull;
                      return _StationRow(station: s, favorite: favorite);
                    }),
                ],
              ],
            ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final UsbDeviceInfo device;
  final bool opened;
  final VoidCallback onRequestPermission;
  final VoidCallback onOpen;

  const _DeviceCard({
    required this.device,
    required this.opened,
    required this.onRequestPermission,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              device.productName ?? device.deviceName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (device.manufacturerName != null) Text(device.manufacturerName!),
            const SizedBox(height: 12),
            if (!opened)
              Row(
                children: [
                  if (!device.hasPermission)
                    FilledButton(onPressed: onRequestPermission, child: const Text('Berechtigung anfordern'))
                  else
                    FilledButton.tonal(onPressed: onOpen, child: const Text('Öffnen')),
                ],
              )
            else ...[
              const Divider(height: 24),
              const _ScanPanel(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Best-effort logo lookup: DAB+ itself doesn't reliably deliver a fixed
/// station logo (per the user - some players end up showing whatever
/// slideshow image happened to be running instead of a real logo, since DAB+
/// slideshow/MOT decoding isn't implemented here anyway - see the project
/// plan), so instead this matches the station name against Radio-Browser's
/// catalog (the same source used for internet-radio favicons) and takes the
/// first hit's favicon, if any. Never throws - a missing/failed lookup just
/// means no logo, not a broken favorite.
/// DAB+ station labels often carry decorative padding ("*GRUEN-WEISS*",
/// stray pipes/dashes used as visual borders in the original 16-char FIG 1/1
/// label) that a plain Radio-Browser name search won't match at all -
/// strip everything but letters/digits/spaces first, and if that finds
/// nothing, retry with just the first word (station names are frequently
/// "Name slogan/suffix").
Future<String?> _findLogoUrl(WidgetRef ref, String stationName) async {
  final cleaned = stationName.replaceAll(RegExp(r'[^\w\säöüÄÖÜß]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return null;
  final api = ref.read(radioBrowserApiServiceProvider);
  try {
    final results = await api.search(name: cleaned, limit: 5);
    final hit = results.where((s) => s.favicon != null && s.favicon!.isNotEmpty).firstOrNull;
    if (hit != null) return hit.favicon;
    final firstWord = cleaned.split(' ').first;
    if (firstWord.length >= 3 && firstWord != cleaned) {
      final broader = await api.search(name: firstWord, limit: 5);
      return broader.where((s) => s.favicon != null && s.favicon!.isNotEmpty).firstOrNull?.favicon;
    }
    return null;
  } catch (_) {
    return null;
  }
}

class _FavoriteRow extends ConsumerWidget {
  final FavoriteChannel channel;
  const _FavoriteRow({required this.channel});

  Future<void> _findLogo(BuildContext context, WidgetRef ref) async {
    final logoUrl = await _findLogoUrl(ref, channel.displayName);
    if (logoUrl != null) {
      await ref.read(favoritesRepositoryProvider).updateLogoUrl(channel.programNumber, logoUrl);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            logoUrl != null
                ? 'Logo für "${channel.displayName}" gefunden.'
                : 'Kein passendes Logo für "${channel.displayName}" gefunden.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundImage: channel.logoUrl != null ? NetworkImage(channel.logoUrl!) : null,
        child: channel.logoUrl == null ? Text('${channel.programNumber}') : null,
      ),
      title: Text(channel.displayName),
      subtitle: Text('${channel.dabFreqKhz} kHz'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (channel.logoUrl == null)
            IconButton(
              icon: const Icon(Icons.image_search),
              tooltip: 'Logo suchen',
              onPressed: () => _findLogo(context, ref),
            ),
          IconButton(
            icon: const Icon(Icons.star, color: Colors.amber),
            tooltip: 'Favorit entfernen',
            onPressed: () => ref.read(favoritesRepositoryProvider).remove(channel.programNumber),
          ),
        ],
      ),
    );
  }
}

class _StationRow extends ConsumerWidget {
  final DabStation station;
  final FavoriteChannel? favorite;
  const _StationRow({required this.station, this.favorite});

  Future<void> _addFavorite(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(favoritesRepositoryProvider);
    final suggested = await repo.nextFreeProgramNumber() ?? 1;
    if (!context.mounted) return;
    final programNumber = await showDialog<int>(
      context: context,
      builder: (context) => ProgramNumberDialog(initial: suggested),
    );
    if (programNumber == null) return;
    final logoUrl = await _findLogoUrl(ref, station.stationLabel);
    await repo.addDabService(
      programNumber: programNumber,
      displayName: station.stationLabel,
      freqKhz: station.freqKhz,
      serviceId: station.serviceId,
      logoUrl: logoUrl,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${station.stationLabel}" als Nr. $programNumber gespeichert.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(station.stationLabel),
      subtitle: Text(
        '${station.ensembleLabel ?? "Ensemble unbekannt"} · ${station.channelLabel} · ${station.freqKhz} kHz',
      ),
      trailing: favorite != null
          ? Chip(label: Text('Nr. ${favorite!.programNumber}'))
          : FilledButton.tonal(
              onPressed: () => _addFavorite(context, ref),
              child: const Text('Favorit hinzufügen'),
            ),
    );
  }
}

class _FoundChannel {
  final int index;
  final String label;
  final int freqKhz;
  final int antennaLevel;
  final String? ensembleLabel;
  final List<({int serviceId, String label})> services;
  const _FoundChannel({
    required this.index,
    required this.label,
    required this.freqKhz,
    required this.antennaLevel,
    this.ensembleLabel,
    this.services = const [],
  });
}

/// DAB Band III scan panel: triggers DabUsbPlugin.scanBand3() and shows live
/// progress; every locked ensemble's stations (label + FIC-decoded name) are
/// persisted into DabStationsRepository as they're found.
class _ScanPanel extends ConsumerStatefulWidget {
  const _ScanPanel();

  @override
  ConsumerState<_ScanPanel> createState() => _ScanPanelState();
}

class _ScanPanelState extends ConsumerState<_ScanPanel> {
  bool _scanning = false;
  String? _currentLabel;
  final List<_FoundChannel> _found = [];
  StreamSubscription<Map<String, dynamic>>? _sub;
  int? _tuningIndex;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(dabUsbServiceProvider).scanEvents.listen((event) {
      if (!mounted) return;
      switch (event['type']) {
        case 'scanProgress':
          setState(() => _currentLabel = '${event['label']} (${event['freqKhz']} kHz)');
        case 'channelLocked':
          final freqKhz = event['freqKhz'] as int;
          final channelLabel = event['label'] as String;
          final ensembleLabel = event['ensembleLabel'] as String?;
          final services = (event['services'] as List<dynamic>? ?? const [])
              .cast<Map<dynamic, dynamic>>()
              .map((m) => (serviceId: m['serviceId'] as int, label: m['label'] as String))
              .toList();
          setState(() {
            _found.add(
              _FoundChannel(
                index: event['index'] as int,
                label: channelLabel,
                freqKhz: freqKhz,
                antennaLevel: event['antennaLevel'] as int,
                ensembleLabel: ensembleLabel,
                services: services,
              ),
            );
          });
          final stationsRepo = ref.read(dabStationsRepositoryProvider);
          for (final s in services) {
            stationsRepo.upsert(
              freqKhz: freqKhz,
              serviceId: s.serviceId,
              channelLabel: channelLabel,
              stationLabel: s.label,
              ensembleLabel: ensembleLabel,
            );
          }
        case 'scanFinished':
          setState(() {
            _scanning = false;
            _currentLabel = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sendersuchlauf fertig: ${event['foundCount']} Ensemble(s) mit Empfang.')),
          );
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _found.clear();
      _currentLabel = null;
    });
    await ref.read(dabUsbServiceProvider).dabScanBand3();
  }

  Future<void> _tune(int index, _FoundChannel channel) async {
    setState(() => _tuningIndex = index);
    final ok = await ref.read(dabUsbServiceProvider).dabTuneChannel(index);
    if (!mounted) return;
    setState(() => _tuningIndex = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Auf ${channel.label} (${channel.freqKhz} kHz) getunt.'
              : 'Tuning auf ${channel.label} fehlgeschlagen.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            FilledButton.icon(
              onPressed: _scanning ? null : _startScan,
              icon: const Icon(Icons.radar),
              label: Text(_scanning ? 'Suche läuft…' : 'Sendersuchlauf starten'),
            ),
            if (_scanning) ...[
              const SizedBox(width: 12),
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              if (_currentLabel != null) Text(_currentLabel!, style: const TextStyle(color: Colors.white54)),
            ],
          ],
        ),
        const SizedBox(height: 12),
        if (_found.isEmpty)
          const Text(
            'Noch keine Ensembles in dieser Suche gefunden. Gefundene Sender aus früheren Suchen '
            'stehen weiter unten unter "Alle DAB+ Sender".',
            style: TextStyle(color: Colors.white54),
          )
        else
          ..._found.map((channel) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${channel.label} · ${channel.freqKhz} kHz · '
                          '${channel.ensembleLabel ?? "Ensemble-Name unbekannt"} · '
                          'Signal-Metrik ${channel.antennaLevel} (niedriger = besser)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: _tuningIndex != null ? null : () => _tune(channel.index, channel),
                        child: Text(_tuningIndex == channel.index ? 'Tune…' : 'Tunen'),
                      ),
                    ],
                  ),
                  if (channel.services.isEmpty)
                    const Text(
                      '  Sender in diesem Ensemble noch nicht erkannt (kurz erneut versuchen).',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text('• ${channel.services.map((s) => s.label).join('\n• ')}'),
                    ),
                ],
              ),
            );
          }),
      ],
    );
  }
}
