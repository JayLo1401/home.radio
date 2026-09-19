import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/db/database.dart' show DabStation;
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/dab_stations_repository.dart' show DabStationDisplay;
import '../shared/program_number_dialog.dart';
import '../shared/rename_dialog.dart';

/// DAB+ reception over the RTL-SDR stick (real OFDM demodulation via the
/// vendored welle.io core, see DabRtlSdrPlugin.kt/cpp/dabcore_jni.cpp): run
/// a Band III scan and manage the resulting stations - every station a scan
/// has ever found is persisted (DabStationsRepository) so it can be
/// favorited (with a program number) without re-scanning, listed separately
/// from the merged favorites list ("Alle DAB+ Sender").
class DabStationsScreen extends ConsumerStatefulWidget {
  const DabStationsScreen({super.key});

  @override
  ConsumerState<DabStationsScreen> createState() => _DabStationsScreenState();
}

class _DabStationsScreenState extends ConsumerState<DabStationsScreen> {
  Future<void> _clearAllStations() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Alle DAB-Sender löschen?'),
            content: const Text(
              'Entfernt alle bisher gefundenen DAB+-Sender aus der Liste "Alle DAB+ Sender" '
              'und alle DAB+-Favoriten. Kann nicht rückgängig gemacht werden.',
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
    final favoritesRepo = ref.read(favoritesRepositoryProvider);
    final dabFavorites = (ref.read(favoritesStreamProvider).value ?? const <FavoriteChannel>[])
        .where((c) => c.sourceType == FavoriteSourceType.dab);
    for (final favorite in dabFavorites) {
      await favoritesRepo.remove(favorite.programNumber);
    }
    await ref.read(dabStationsRepositoryProvider).clearAll();
  }

  @override
  Widget build(BuildContext context) {
    final stations = ref.watch(dabStationsStreamProvider).value ?? const <DabStation>[];
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    final dabFavorites = favorites.where((c) => c.sourceType == FavoriteSourceType.dab).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('DAB+ Sender')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Sendersuchlauf', style: Theme.of(context).textTheme.titleLarge),
              ),
              if (dabFavorites.isNotEmpty || stations.isNotEmpty)
                TextButton.icon(
                  onPressed: _clearAllStations,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Alle DAB-Sender löschen'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const _ScanPanel(),
          if (dabFavorites.isNotEmpty || stations.isNotEmpty) ...[
            const Divider(height: 32),
            Text('Favoriten', style: Theme.of(context).textTheme.titleLarge),
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
                'Noch keine Sender gefunden. Sendersuchlauf starten.',
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
    final logoUrl = await _findLogoUrl(ref, station.displayLabel);
    await repo.addDabService(
      programNumber: programNumber,
      displayName: station.displayLabel,
      freqKhz: station.freqKhz,
      serviceId: station.serviceId,
      logoUrl: logoUrl,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${station.displayLabel}" als Nr. $programNumber gespeichert.')),
      );
    }
  }

  /// DAB+ FIG labels sometimes carry genuinely-real but garbled-looking
  /// special characters (confirmed real-world AT ensembles, not a decode
  /// bug) - lets the user override this station's name with something
  /// readable. An empty result reverts back to the decoded label.
  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => RenameDialog(
        title: 'Sender umbenennen',
        initialValue: station.displayLabel,
      ),
    );
    if (newName == null) return;
    await ref.read(dabStationsRepositoryProvider).setCustomLabel(
          freqKhz: station.freqKhz,
          serviceId: station.serviceId,
          customLabel: newName,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(station.displayLabel),
      subtitle: Text(
        '${station.ensembleLabel ?? "Ensemble unbekannt"} · ${station.channelLabel} · ${station.freqKhz} kHz',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Umbenennen',
            onPressed: () => _rename(context, ref),
          ),
          if (favorite != null)
            Chip(label: Text('Nr. ${favorite!.programNumber}'))
          else
            FilledButton.tonal(
              onPressed: () => _addFavorite(context, ref),
              child: const Text('Favorit hinzufügen'),
            ),
        ],
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

/// DAB Band III scan panel: points the rtl_tcp-based DAB+ decoder
/// (DabRtlSdrService/DabRtlSdrPlugin) at the configured RTL-SDR source (own
/// USB-TCP service / external app / network service - same source
/// RtlSdrTestScreen uses) and shows live progress; every locked ensemble's
/// stations are persisted into DabStationsRepository as they're found. Each
/// found service has a real "Anhören" (listen) button now - the vendored
/// welle.io core actually decodes DAB+ audio, unlike the old Raontech-only
/// pipeline where "Tunen" only did RF tuning without decoding.
class _ScanPanel extends ConsumerStatefulWidget {
  const _ScanPanel();

  @override
  ConsumerState<_ScanPanel> createState() => _ScanPanelState();
}

class _ScanPanelState extends ConsumerState<_ScanPanel> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  bool _scanning = false;
  String? _currentLabel;
  final List<_FoundChannel> _found = [];
  StreamSubscription<Map<String, dynamic>>? _sub;
  ({int freqKhz, int serviceId})? _playing;

  @override
  void initState() {
    super.initState();
    _loadServer();
    _sub = ref.read(dabRtlSdrServiceProvider).events.listen((event) {
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

  Future<void> _loadServer() async {
    final settings = ref.read(settingsRepositoryProvider);
    final host = await settings.getRtlSdrHost();
    final port = await settings.getRtlSdrPort();
    if (!mounted) return;
    setState(() {
      _hostController.text = host;
      _portController.text = '$port';
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text) ?? 1234;
    await ref.read(settingsRepositoryProvider).setRtlSdrServer(host, port);
    final connected = await ref.read(dabRtlSdrServiceProvider).setServer(host: host, port: port);
    if (!connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('DAB+-Decoder konnte nicht gestartet werden.')),
        );
      }
      return;
    }
    setState(() {
      _scanning = true;
      _found.clear();
      _currentLabel = null;
    });
    await ref.read(dabRtlSdrServiceProvider).scanBand3();
  }

  Future<void> _stopScan() async {
    await ref.read(dabRtlSdrServiceProvider).stopScan();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _listen(int freqKhz, int serviceId, String label) async {
    setState(() => _playing = (freqKhz: freqKhz, serviceId: serviceId));
    final ok = await ref.read(dabRtlSdrServiceProvider).playService(freqKhz: freqKhz, serviceId: serviceId);
    if (!mounted) return;
    if (!ok) {
      setState(() => _playing = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wiedergabe von "$label" fehlgeschlagen.')),
      );
    }
  }

  Future<void> _stopListening() async {
    await ref.read(dabRtlSdrServiceProvider).stopPlayback();
    if (mounted) setState(() => _playing = null);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _hostController,
                enabled: !_scanning,
                decoration: const InputDecoration(labelText: 'RTL-SDR Host (IP)'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _portController,
                enabled: !_scanning,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _scanning ? _stopScan : _startScan,
              icon: Icon(_scanning ? Icons.stop : Icons.radar),
              label: Text(_scanning ? 'Suche stoppen' : 'Sendersuchlauf starten'),
            ),
            if (_playing != null) ...[
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: _stopListening,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Wiedergabe stoppen'),
              ),
            ],
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
                  Text(
                    '${channel.label} · ${channel.freqKhz} kHz · '
                    '${channel.ensembleLabel ?? "Ensemble-Name unbekannt"}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (channel.services.isEmpty)
                    const Text(
                      '  Sender in diesem Ensemble noch nicht erkannt (kurz erneut versuchen).',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    )
                  else
                    ...channel.services.map((s) {
                      final isPlaying = _playing?.freqKhz == channel.freqKhz && _playing?.serviceId == s.serviceId;
                      return Padding(
                        padding: const EdgeInsets.only(left: 8, top: 4),
                        child: Row(
                          children: [
                            Expanded(child: Text(s.label)),
                            FilledButton.tonal(
                              onPressed: isPlaying ? null : () => _listen(channel.freqKhz, s.serviceId, s.label),
                              child: Text(isPlaying ? 'Läuft…' : 'Anhören'),
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            );
          }),
      ],
    );
  }
}
