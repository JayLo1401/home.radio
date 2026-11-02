import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/db/database.dart' show DabStation;
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/dab_stations_repository.dart' show DabStationDisplay, dabEnsembleHeading;
import '../../data/repositories/settings_repository.dart' show DabSortMode, ReceiverMode;
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;
import '../shared/program_number_dialog.dart';
import '../shared/logo_picker_dialog.dart';
import '../shared/station_edit_dialog.dart';

/// DAB+ reception over the RTL-SDR stick (the app's own receiver, see
/// DabRtlSdrPlugin.kt/cpp/hrdab): run a Band III scan and manage the resulting stations - every station a scan
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
    final stations = ref.watch(sortedDabStationsProvider).value ?? const <DabStation>[];
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    final dabFavorites = favorites.where((c) => c.sourceType == FavoriteSourceType.dab).toList();
    final sortMode = ref.watch(dabSortModeProvider);

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
            // Also the order (and grouping) of the home screen's DAB-Sender tab.
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (mode, label) in const [
                  (DabSortMode.groupedByEnsemble, 'Nach Ensemble gruppiert'),
                  (DabSortMode.byEnsembleThenAlphabet, 'Nach Ensemble sortiert'),
                  (DabSortMode.byAlphabet, 'Nach Name'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: sortMode == mode,
                    onSelected: (_) => ref.read(dabSortModeProvider.notifier).set(mode),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (stations.isEmpty)
              const Text(
                'Noch keine Sender gefunden. Sendersuchlauf starten.',
                style: TextStyle(color: Colors.white54),
              )
            else
              for (final (i, s) in stations.indexed) ...[
                if (sortMode == DabSortMode.groupedByEnsemble &&
                    (i == 0 || dabEnsembleHeading(stations[i - 1]) != dabEnsembleHeading(s)))
                  Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 4),
                    child: Text(
                      dabEnsembleHeading(s),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white70),
                    ),
                  ),
                _StationRow(
                  station: s,
                  favorite: dabFavorites
                      .where((c) => c.dabFreqKhz == s.freqKhz && c.dabServiceId == s.serviceId)
                      .firstOrNull,
                ),
              ],
          ],
        ],
      ),
    );
  }
}

/// "Fehlende Logos per Empfang holen": tunes through every station that has
/// no logo yet, in turn, and waits for a real DAB+ MOT slideshow image (see
/// DabRtlSdrService.fetchLogos's own doc comment). Only fills gaps - a logo
/// that's already there (received, or chosen in [_LogoPickerDialog]) is
/// never replaced. Slow: some stations take 10-30s to send a slide, some
/// never do.
///
/// Runs in a modal dialog with "Abbrechen", not inline on the page: the
/// page is a scrolling list, and scrolling an inline control out of view
/// disposed it - the fetch kept running natively with nothing listening
/// anymore (no progress, no saving, no way to stop it).
class _LogoReceiveDialog extends ConsumerStatefulWidget {
  const _LogoReceiveDialog();

  @override
  ConsumerState<_LogoReceiveDialog> createState() => _LogoReceiveDialogState();
}

class _LogoReceiveDialogState extends ConsumerState<_LogoReceiveDialog> {
  late final List<DabStation> _missing = (ref.read(sortedDabStationsProvider).value ?? const <DabStation>[])
      .where((s) => s.logoLocalPath == null && s.logoUrl == null)
      .toList();
  // Kept from the start: ref can't be used safely in dispose().
  late final DabRtlSdrService _dab;
  bool _running = false;
  bool _failed = false;
  int _index = 0;
  final List<String> _foundPaths = [];
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _dab = ref.read(dabRtlSdrServiceProvider);
    if (_missing.isNotEmpty) _start();
  }

  @override
  void dispose() {
    if (_running) _dab.stopLogoFetch();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) return;
    setState(() => _running = true);
    final stationsRepo = ref.read(dabStationsRepositoryProvider);
    final favoritesRepo = ref.read(favoritesRepositoryProvider);
    _sub = ref.read(dabRtlSdrServiceProvider).events.listen((event) async {
      switch (event['type']) {
        case 'logoScanProgress':
          if (mounted) setState(() => _index = event['index'] as int);
        case 'logoFound':
          final freqKhz = event['freqKhz'] as int;
          final serviceId = event['serviceId'] as int;
          final path = event['path'] as String;
          if (mounted) setState(() => _foundPaths.add(path));
          await stationsRepo.setLogoPath(freqKhz: freqKhz, serviceId: serviceId, logoLocalPath: path);
          // The matching favorite too - unless it has a logo of its own.
          final matchingFavorite = (ref.read(favoritesStreamProvider).value ?? const <FavoriteChannel>[])
              .where((c) => c.dabFreqKhz == freqKhz && c.dabServiceId == serviceId)
              .firstOrNull;
          if (matchingFavorite != null && matchingFavorite.logoLocalPath == null && matchingFavorite.logoUrl == null) {
            await favoritesRepo.updateLogoLocalPath(matchingFavorite.programNumber, path);
          }
        case 'logoScanFinished':
          await _sub?.cancel();
          _sub = null;
          if (mounted) setState(() => _running = false);
      }
    });
    await ref.read(dabRtlSdrServiceProvider).fetchLogos(
          _missing.map((s) => (freqKhz: s.freqKhz, serviceId: s.serviceId)).toList(),
        );
  }

  @override
  Widget build(BuildContext context) {
    const hint = TextStyle(color: Colors.white70);
    final total = _missing.length;
    final Widget body;
    if (total == 0) {
      body = const Text('Alle Sender haben schon ein Logo.', style: hint);
    } else if (_failed) {
      body = const Text('DAB+-Decoder konnte nicht gestartet werden.', style: hint);
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_running) ...[
            Text('Sender ${_index + 1} von $total - warte auf ein Bild vom Sender…', style: hint),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: (_index + 1) / total),
          ] else
            Text('Fertig: ${_foundPaths.length} von $total Sendern haben ein Bild gesendet.', style: hint),
          const SizedBox(height: 12),
          if (_foundPaths.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final path in _foundPaths) CircleAvatar(radius: 18, backgroundImage: FileImage(File(path))),
              ],
            ),
        ],
      );
    }
    // Back = Abbrechen; the dialog can't be dismissed by tapping outside.
    return PopScope(
      child: AlertDialog(
        title: const Text('Fehlende Logos per Empfang'),
        content: SizedBox(width: 440, child: body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_running ? 'Abbrechen' : 'Schließen'),
          ),
        ],
      ),
    );
  }
}

class _FavoriteRow extends ConsumerWidget {
  final FavoriteChannel channel;
  const _FavoriteRow({required this.channel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localPath = channel.logoLocalPath;
    final url = channel.logoUrl;
    // A received broadcast image (logoLocalPath) takes priority over an
    // image URL - same precedence FavoritesSidebar/NowPlayingBanner use; a
    // logo chosen in _LogoPickerDialog clears the other one.
    final ImageProvider? image =
        localPath != null ? FileImage(File(localPath)) : (url != null ? CachedNetworkImageProvider(url) : null);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundImage: image,
        child: image == null ? Text('${channel.programNumber}') : null,
      ),
      title: Text(channel.displayName),
      subtitle: Text('${channel.dabFreqKhz} kHz'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Anhören',
            onPressed: () => ref.read(playRequestProvider.notifier).favorite(channel),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Bearbeiten (Name, Logo)',
            onPressed: () => editFavorite(context, ref, channel),
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
    // Takes over whatever logo the station already has - no automatic
    // internet lookup anymore: it took the first name match, often another
    // station's logo entirely ("Aktual Rock" -> a Slovenian "Radio Aktual").
    await repo.addDabService(
      programNumber: programNumber,
      displayName: station.displayLabel,
      freqKhz: station.freqKhz,
      serviceId: station.serviceId,
      logoUrl: station.logoUrl,
      logoLocalPath: station.logoLocalPath,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${station.displayLabel}" als Nr. $programNumber gespeichert.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logoUrl = station.logoUrl;
    final logoPath = station.logoLocalPath;
    // A received broadcast image (logoLocalPath) takes priority over an
    // image URL - a logo chosen in _LogoPickerDialog clears the other one.
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: logoPath != null
          ? CircleAvatar(backgroundImage: FileImage(File(logoPath)))
          : (logoUrl == null ? null : CircleAvatar(backgroundImage: CachedNetworkImageProvider(logoUrl))),
      title: Text(station.displayLabel),
      subtitle: Text(
        '${station.ensembleLabel ?? "Ensemble unbekannt"} · ${station.channelLabel} · ${station.freqKhz} kHz',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Anhören',
            onPressed: () => ref.read(playRequestProvider.notifier).dab(station),
          ),
          // Name (DAB+ labels can be garbled - see DabStation.customLabel)
          // and logo in one dialog.
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Bearbeiten (Name, Logo)',
            onPressed: () => editDabStation(context, ref, station),
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
  final double snrDb;
  final String? ensembleLabel;
  final List<({int serviceId, String label})> services;
  const _FoundChannel({
    required this.index,
    required this.label,
    required this.freqKhz,
    required this.snrDb,
    this.ensembleLabel,
    this.services = const [],
  });
}

/// The DAB+ stations screen's top section: which RTL-SDR source is used
/// (configured once, under "Radio-Empfänger" - see RtlSdrTestScreen) and the
/// actions that tune the stick on their own, each in its own modal dialog
/// ([_ScanDialog] for the whole band or one picked channel,
/// [_LogoReceiveDialog]).
class _ScanPanel extends ConsumerStatefulWidget {
  const _ScanPanel();

  @override
  ConsumerState<_ScanPanel> createState() => _ScanPanelState();
}

class _ScanPanelState extends ConsumerState<_ScanPanel> {
  (String, int) _channel = DabRtlSdrService.band3Channels.first;

  @override
  Widget build(BuildContext context) {
    final usb = ref.watch(receiverModeProvider) == ReceiverMode.usb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            usb
                ? 'Quelle: RTL-SDR-Stick per USB - siehe "Radio-Empfänger" in den Einstellungen.'
                : 'Quelle: RTL-SDR über Netzwerk - siehe "Radio-Empfänger" in den Einstellungen.',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const _ScanDialog(),
              ),
              icon: const Icon(Icons.radar),
              label: const Text('Sendersuchlauf starten'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const _LogoReceiveDialog(),
              ),
              icon: const Icon(Icons.settings_input_antenna),
              label: const Text('Fehlende Logos per Empfang holen'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Manual search of one channel - e.g. a known ensemble the full
        // scan missed, or to check reception on a specific one.
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Einzelnen Kanal suchen:', style: TextStyle(color: Colors.white70)),
            DropdownButton<(String, int)>(
              value: _channel,
              items: [
                for (final c in DabRtlSdrService.band3Channels)
                  DropdownMenuItem(value: c, child: Text('${c.$1}  (${(c.$2 / 1000).toStringAsFixed(3)} MHz)')),
              ],
              onChanged: (c) => c == null ? null : setState(() => _channel = c),
            ),
            OutlinedButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => _ScanDialog(channel: _channel),
              ),
              icon: const Icon(Icons.search),
              label: Text('${_channel.$1} suchen'),
            ),
          ],
        ),
      ],
    );
  }
}

/// DAB Band III scan in a modal dialog with "Abbrechen": points the DAB+
/// receiver (DabRtlSdrService/DabRtlSdrPlugin) at the configured RTL-SDR
/// source and shows live progress; every locked ensemble's stations are
/// persisted into DabStationsRepository as they're found, each with an
/// "Anhören" (listen) button. A dialog rather than inline on the page - see
/// [_LogoReceiveDialog] for why. Closing it stops the scan and any test
/// listening started here.
class _ScanDialog extends ConsumerStatefulWidget {
  /// Just this one channel (manual search), or the whole band if null.
  final (String, int)? channel;

  const _ScanDialog({this.channel});

  @override
  ConsumerState<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends ConsumerState<_ScanDialog> {
  // Kept from the start: ref can't be used safely in dispose().
  late final DabRtlSdrService _dab;
  bool _scanning = false;
  bool _failed = false;
  int _index = 0;
  int _total = 0;
  String? _currentLabel;
  final List<_FoundChannel> _found = [];
  StreamSubscription<Map<String, dynamic>>? _sub;
  ({int freqKhz, int serviceId})? _playing;

  @override
  void initState() {
    super.initState();
    _dab = ref.read(dabRtlSdrServiceProvider);
    _sub = ref.read(dabRtlSdrServiceProvider).events.listen(_onEvent);
    _startScan();
  }

  @override
  void dispose() {
    if (_scanning) _dab.stopScan();
    if (_playing != null) _dab.stopPlayback();
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'scanProgress':
        setState(() {
          _index = event['index'] as int;
          _total = (event['total'] as int?) ?? _total;
          _currentLabel = '${event['label']} (${event['freqKhz']} kHz)';
        });
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
              snrDb: (event['snrDb'] as num?)?.toDouble() ?? 0.0,
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
    }
  }

  Future<void> _startScan() async {
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) return;
    setState(() => _scanning = true);
    await _dab.scanBand3(onlyFreqKhz: widget.channel?.$2);
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
    const hint = TextStyle(color: Colors.white54);
    final serviceCount = _found.fold<int>(0, (n, c) => n + c.services.length);
    return PopScope(
      child: AlertDialog(
        title: Text(widget.channel == null ? 'Sendersuchlauf' : 'Kanal ${widget.channel!.$1} suchen'),
        content: SizedBox(
          width: 560,
          height: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_failed)
                const Text('DAB+-Decoder konnte nicht gestartet werden.', style: hint)
              else if (_scanning) ...[
                Text(
                  widget.channel != null
                      ? 'Suche auf ${widget.channel!.$1} (${widget.channel!.$2} kHz), bis zu 15 Sekunden…'
                      : 'Kanal ${_index + 1}${_total > 0 ? ' von $_total' : ''}: ${_currentLabel ?? '…'}',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: widget.channel == null && _total > 0 ? (_index + 1) / _total : null,
                ),
              ] else if (widget.channel != null && _found.isEmpty)
                Text(
                  'Auf ${widget.channel!.$1} wurde kein DAB+-Ensemble empfangen.',
                  style: const TextStyle(color: Colors.white70),
                )
              else
                Text(
                  'Fertig: ${_found.length} Ensemble(s) mit $serviceCount Sender(n) gefunden. '
                  'Alle gefundenen Sender stehen unter "Alle DAB+ Sender".',
                  style: const TextStyle(color: Colors.white70),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: _found.isEmpty
                    ? Text(_scanning ? 'Noch keine Ensembles gefunden…' : '', style: hint)
                    : ListView(
                        children: [
                          for (final channel in _found)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${channel.label} · ${channel.freqKhz} kHz · '
                                    '${channel.ensembleLabel ?? "Ensemble-Name unbekannt"} · '
                                    'SNR ${channel.snrDb.toStringAsFixed(1)} dB',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  if (channel.services.isEmpty)
                                    const Text(
                                      '  Sender in diesem Ensemble noch nicht erkannt (kurz erneut versuchen).',
                                      style: TextStyle(color: Colors.white54, fontSize: 12),
                                    )
                                  else
                                    for (final s in channel.services)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 8, top: 4),
                                        child: Row(
                                          children: [
                                            Expanded(child: Text(s.label)),
                                            // The tuner can't listen while it's still scanning.
                                            FilledButton.tonal(
                                              onPressed: _scanning ||
                                                      (_playing?.freqKhz == channel.freqKhz &&
                                                          _playing?.serviceId == s.serviceId)
                                                  ? null
                                                  : () => _listen(channel.freqKhz, s.serviceId, s.label),
                                              child: Text(
                                                _playing?.freqKhz == channel.freqKhz &&
                                                        _playing?.serviceId == s.serviceId
                                                    ? 'Läuft…'
                                                    : 'Anhören',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        actions: [
          if (_playing != null)
            TextButton.icon(
              onPressed: _stopListening,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Wiedergabe stoppen'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_scanning ? 'Abbrechen' : 'Schließen'),
          ),
        ],
      ),
    );
  }
}
