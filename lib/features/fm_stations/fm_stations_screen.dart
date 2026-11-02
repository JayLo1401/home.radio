import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../data/db/database.dart' show FmStation;
import '../../data/models/favorite_channel.dart';
import '../../data/repositories/fm_stations_repository.dart';
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;
import '../shared/logo_picker_dialog.dart';
import '../shared/program_number_dialog.dart';
import '../shared/station_edit_dialog.dart';

/// FM (UKW) reception over the same RTL-SDR receiver as DAB+: a band scan,
/// manual tuning with seek, and the saved stations - which, like DAB+
/// stations, can be played from the sidebar's FM tab or saved as favorites
/// with a program number.
class FmStationsScreen extends ConsumerWidget {
  const FmStationsScreen({super.key});

  Future<void> _clearAll(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alle UKW-Sender löschen?'),
        content: const Text(
          'Entfernt alle gespeicherten UKW-Sender aus der Liste. UKW-Favoriten bleiben erhalten.',
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed == true) await ref.read(fmStationsRepositoryProvider).clearAll();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stations = ref.watch(fmStationsStreamProvider).value ?? const <FmStation>[];
    final favorites = ref.watch(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    return Scaffold(
      appBar: AppBar(title: const Text('UKW-Sender (FM)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Sender suchen', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const _FmScanDialog(),
                ),
                icon: const Icon(Icons.radar),
                label: const Text('Sendersuchlauf starten'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => _FmTuneDialog(
                    initialFreqKhz: ref.read(currentFmStationProvider) ??
                        (stations.isEmpty ? 98000 : stations.first.freqKhz),
                  ),
                ),
                icon: const Icon(Icons.tune),
                label: const Text('Manuell einstellen'),
              ),
            ],
          ),
          const Divider(height: 32),
          Row(
            children: [
              Expanded(child: Text('Alle UKW-Sender', style: Theme.of(context).textTheme.titleLarge)),
              if (stations.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _clearAll(context, ref),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Alle löschen'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (stations.isEmpty)
            const Text(
              'Noch keine UKW-Sender. Suchlauf starten oder einen Sender manuell einstellen und speichern.',
              style: TextStyle(color: Colors.white54),
            )
          else
            // By frequency, like the scan found them; a station also on
            // another frequency says so (and which one is stronger).
            for (final s in stations)
              _FmStationRow(
                station: s,
                sameProgrammeHint: sameProgrammeHint(s, stations),
                favorite: favorites
                    .where((c) => c.sourceType == FavoriteSourceType.fm && c.fmFreqKhz == s.freqKhz)
                    .firstOrNull,
              ),
        ],
      ),
    );
  }
}

class _FmStationRow extends ConsumerWidget {
  final FmStation station;
  final FavoriteChannel? favorite;

  /// E.g. "auch auf 105,0 MHz (schwächer)", see sameProgrammeHint.
  final String? sameProgrammeHint;

  const _FmStationRow({required this.station, this.favorite, this.sameProgrammeHint});

  Future<void> _addFavorite(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(favoritesRepositoryProvider);
    final suggested = await repo.nextFreeProgramNumber() ?? 1;
    if (!context.mounted) return;
    final programNumber = await showDialog<int>(
      context: context,
      builder: (context) => ProgramNumberDialog(initial: suggested),
    );
    if (programNumber == null) return;
    await repo.addFmStation(
      programNumber: programNumber,
      displayName: station.displayLabel,
      freqKhz: station.freqKhz,
      pi: station.pi,
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
    final path = station.logoLocalPath, url = station.logoUrl;
    final ImageProvider? image =
        path != null ? FileImage(File(path)) : (url != null ? CachedNetworkImageProvider(url) : null);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(backgroundImage: image, child: image == null ? const Icon(Icons.graphic_eq) : null),
      title: Text(station.displayLabel),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(
          text: [
            station.frequencyLabel,
            if (station.psName != null && station.psName != station.displayLabel) 'RDS: ${station.psName}',
            if (station.stereo) 'Stereo',
          ].join(' · '),
        ),
        if (station.levelLabel case final level?) ...[
          const TextSpan(text: ' · '),
          TextSpan(text: 'Signal $level', style: TextStyle(color: fmLevelColor(station.levelDb!))),
        ],
        if (sameProgrammeHint case final hint?) TextSpan(text: ' · $hint'),
      ])),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Anhören',
            onPressed: () => ref.read(playRequestProvider.notifier).fm(station),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Bearbeiten (Name, Logo)',
            onPressed: () => editFmStation(context, ref, station),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Sender entfernen',
            onPressed: () => ref.read(fmStationsRepositoryProvider).delete(station.freqKhz),
          ),
          if (favorite != null)
            Chip(label: Text('Nr. ${favorite!.programNumber}'))
          else
            FilledButton.tonal(onPressed: () => _addFavorite(context, ref), child: const Text('Favorit hinzufügen')),
        ],
      ),
    );
  }
}

/// FM band scan in a modal dialog with "Abbrechen" (see the DAB+ scan
/// dialog for why not inline): found stations are saved as they come in.
class _FmScanDialog extends ConsumerStatefulWidget {
  const _FmScanDialog();

  @override
  ConsumerState<_FmScanDialog> createState() => _FmScanDialogState();
}

class _FmScanDialogState extends ConsumerState<_FmScanDialog> {
  // Kept from the start: ref can't be used safely in dispose().
  late final DabRtlSdrService _rx;
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _scanning = false;
  bool _failed = false;
  int _index = 0;
  int _total = 0;
  int? _currentKhz;
  bool _surveying = true;
  final List<_Found> _found = [];
  int _imagesRemoved = 0;

  @override
  void initState() {
    super.initState();
    _rx = ref.read(dabRtlSdrServiceProvider);
    _sub = _rx.events.listen(_onEvent);
    _start();
  }

  @override
  void dispose() {
    if (_scanning) _rx.stopFmScan();
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'fmScanProgress':
        // Two passes, each counting from 0: "survey" measures the band in
        // wide windows, "probe" then checks each candidate for pilot/RDS.
        setState(() {
          _surveying = event['phase'] != 'probe';
          _index = event['index'] as int;
          _total = event['total'] as int;
          _currentKhz = event['freqKhz'] as int;
        });
      case 'fmStationFound':
        final freqKhz = event['freqKhz'] as int;
        final ps = event['ps'] as String?;
        final stereo = event['stereo'] as bool? ?? false;
        final pi = event['pi'] as int?;
        final levelDb = (event['levelDb'] as num?)?.toDouble();
        final name = ps?.trim();
        setState(() => _found.add((
              freqKhz: freqKhz,
              ps: name == null || name.isEmpty ? null : name,
              stereo: stereo,
              pi: pi,
              levelDb: levelDb,
            )));
        ref
            .read(fmStationsRepositoryProvider)
            .upsert(freqKhz: freqKhz, pi: pi, psName: ps, stereo: stereo, levelDb: levelDb);
      case 'fmScanFinished':
        setState(() => _scanning = false);
        _removeImages();
    }
  }

  /// Drops likely spurious receptions: a weak copy of a station - same RDS
  /// PI as one at least 10 dB stronger, but no stereo and no name. The
  /// stick produces those when overloaded by a strong transmitter (seen in
  /// Graz: 'VM1 on 90.3 MHz also at 105.0, 16 dB weaker). Stations the user
  /// named or made a favorite are kept.
  Future<void> _removeImages() async {
    final images = [
      for (final f in _found)
        if (f.pi != null &&
            f.ps == null &&
            !f.stereo &&
            f.levelDb != null &&
            _found.any((o) => o.pi == f.pi && o.levelDb != null && o.levelDb! - f.levelDb! >= 10))
          f,
    ];
    if (images.isEmpty) return;
    final stations = await ref.read(fmStationsRepositoryProvider).watchAll().first;
    final favorites = ref.read(favoritesStreamProvider).value ?? const <FavoriteChannel>[];
    var removed = 0;
    for (final f in images) {
      final saved = stations.where((s) => s.freqKhz == f.freqKhz).firstOrNull;
      if (saved?.customLabel != null || favorites.any((c) => c.fmFreqKhz == f.freqKhz)) continue;
      await ref.read(fmStationsRepositoryProvider).delete(f.freqKhz);
      removed++;
      _found.remove(f);
    }
    if (mounted) setState(() => _imagesRemoved = removed);
  }

  Future<void> _start() async {
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) return;
    setState(() => _scanning = true);
    await _rx.fmScan();
  }

  @override
  Widget build(BuildContext context) {
    const hint = TextStyle(color: Colors.white70);
    return PopScope(
      child: AlertDialog(
        title: const Text('UKW-Sendersuchlauf'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_failed)
                const Text('Empfänger konnte nicht gestartet werden.', style: hint)
              else if (_scanning) ...[
                Text(
                  _currentKhz == null
                      ? 'Suche…'
                      : _surveying
                          ? 'Schritt 1/2: Band wird vermessen (${formatFmFrequency(_currentKhz!)})…'
                          : 'Schritt 2/2: Prüfe Sender ${_index + 1} von $_total '
                              '(${formatFmFrequency(_currentKhz!)})…',
                  style: hint,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _total > 0 ? (_index + 1) / _total : null),
              ] else
                Text(
                  'Fertig: ${_found.length} Sender gefunden und gespeichert.'
                  '${_imagesRemoved > 0 ? ' $_imagesRemoved schwache Störfrequenz(en) aussortiert.' : ''}',
                  style: hint,
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    for (final f in _found)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.graphic_eq),
                        title: Text(f.ps?.isNotEmpty == true ? f.ps! : formatFmFrequency(f.freqKhz)),
                        subtitle: Text.rich(TextSpan(children: [
                          TextSpan(text: [formatFmFrequency(f.freqKhz), if (f.stereo) 'Stereo'].join(' · ')),
                          if (f.levelDb != null) ...[
                            const TextSpan(text: ' · '),
                            TextSpan(
                              text: 'Signal ${f.levelDb!.round()} dB',
                              style: TextStyle(color: fmLevelColor(f.levelDb!)),
                            ),
                          ],
                        ])),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(_scanning ? 'Abbrechen' : 'Schließen')),
        ],
      ),
    );
  }
}

/// Manual FM tuning: plays while tuning, in 50 kHz steps or by seeking to
/// the next station up/down, with live RDS name/radiotext, stereo and
/// signal - and saves what's tuned as a station or straight as a favorite.
/// Closing it stops FM playback (the home screen plays saved stations).
class _FmTuneDialog extends ConsumerStatefulWidget {
  final int initialFreqKhz;
  const _FmTuneDialog({required this.initialFreqKhz});

  @override
  ConsumerState<_FmTuneDialog> createState() => _FmTuneDialogState();
}

class _FmTuneDialogState extends ConsumerState<_FmTuneDialog> {
  // Kept from the start: ref can't be used safely in dispose().
  late final DabRtlSdrService _rx;
  StreamSubscription<Map<String, dynamic>>? _sub;
  late int _freqKhz = widget.initialFreqKhz;
  bool _playing = false;
  bool _failed = false;
  bool _seeking = false;
  bool _stereo = false;
  double? _snrDb;
  int? _pi;
  String? _ps;
  String? _rt;

  @override
  void initState() {
    super.initState();
    _rx = ref.read(dabRtlSdrServiceProvider);
    _sub = _rx.events.listen(_onEvent);
    _start();
  }

  @override
  void dispose() {
    _rx.fmStop();
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'fmStatus' when event['freqKhz'] == _freqKhz:
        setState(() {
          _snrDb = (event['snrDb'] as num?)?.toDouble();
          _stereo = event['stereo'] as bool? ?? false;
        });
      case 'fmRds' when event['freqKhz'] == _freqKhz:
        setState(() {
          _pi = event['pi'] as int?;
          _ps = (event['ps'] as String?)?.trim();
          _rt = (event['rt'] as String?)?.trim();
        });
      case 'fmSeekResult':
        final found = event['freqKhz'] as int?;
        setState(() {
          _seeking = false;
          if (found != null) _setFreq(found);
        });
        if (found == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kein weiterer Sender gefunden.')));
        }
    }
  }

  void _setFreq(int freqKhz) {
    _freqKhz = freqKhz;
    _pi = null;
    _ps = null;
    _rt = null;
    _stereo = false;
    _snrDb = null;
  }

  Future<void> _start() async {
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final ok = await _rx.fmPlay(_freqKhz);
    if (mounted) setState(() => _playing = ok);
  }

  Future<void> _tune(int freqKhz) async {
    final clamped = freqKhz.clamp(DabRtlSdrService.fmMinKhz, DabRtlSdrService.fmMaxKhz);
    setState(() => _setFreq(clamped));
    await (_playing ? _rx.fmTune(clamped) : _rx.fmPlay(clamped));
  }

  Future<void> _seek(bool up) async {
    setState(() => _seeking = true);
    await _rx.fmSeek(fromKhz: _freqKhz, up: up);
  }

  Future<void> _enterFrequency() async {
    final text = await showTextInputDialog(
      context,
      title: 'Frequenz in MHz',
      initialValue: (_freqKhz / 1000).toString().replaceAll('.', ','),
      hint: 'z. B. 99,9',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    final mhz = double.tryParse(text?.replaceAll(',', '.') ?? '');
    if (mhz == null) return;
    // To the 50 kHz raster.
    await _tune((mhz * 1000 / DabRtlSdrService.fmStepKhz).round() * DabRtlSdrService.fmStepKhz);
  }

  Future<void> _saveStation() async {
    await ref.read(fmStationsRepositoryProvider).upsert(freqKhz: _freqKhz, pi: _pi, psName: _ps, stereo: _stereo);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_ps ?? formatFmFrequency(_freqKhz)} gespeichert.')),
      );
    }
  }

  Future<void> _saveFavorite() async {
    await ref.read(fmStationsRepositoryProvider).upsert(freqKhz: _freqKhz, pi: _pi, psName: _ps, stereo: _stereo);
    final repo = ref.read(favoritesRepositoryProvider);
    final suggested = await repo.nextFreeProgramNumber() ?? 1;
    if (!mounted) return;
    final programNumber = await showDialog<int>(
      context: context,
      builder: (context) => ProgramNumberDialog(initial: suggested),
    );
    if (programNumber == null) return;
    final name = _ps?.isNotEmpty == true ? _ps! : formatFmFrequency(_freqKhz);
    await repo.addFmStation(programNumber: programNumber, displayName: name, freqKhz: _freqKhz, pi: _pi);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"$name" als Nr. $programNumber gespeichert.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    const step = DabRtlSdrService.fmStepKhz;
    final busy = _seeking || _failed;
    // Rough signal bar: ~30 dB counts as full.
    final signal = ((_snrDb ?? 0) / 30).clamp(0.0, 1.0);
    return PopScope(
      child: AlertDialog(
        title: const Text('UKW manuell einstellen'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (_failed)
                const Text('Empfänger konnte nicht gestartet werden.', style: TextStyle(color: Colors.white70)),
              Text(formatFmFrequency(_freqKhz), style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 4),
              Text(
                _seeking ? 'Suche…' : (_ps ?? 'kein RDS-Name'),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(color: _ps == null ? Colors.white38 : null),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 40,
                child: Text(
                  _rt ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              Row(
                children: [
                  Text(_stereo ? 'Stereo' : 'Mono', style: const TextStyle(color: Colors.white70)),
                  const SizedBox(width: 12),
                  // Carrier-to-noise here, not the scan's level: >= 20 dB
                  // clean, >= 12 dB usable, below that noisy.
                  Expanded(
                    child: LinearProgressIndicator(
                      value: _snrDb == null ? 0 : signal,
                      color: _snrDb == null
                          ? null
                          : (_snrDb! >= 20 ? Colors.greenAccent : (_snrDb! >= 12 ? Colors.amberAccent : Colors.redAccent)),
                    ),
                  ),
                  if (_snrDb != null) ...[
                    const SizedBox(width: 8),
                    Text('${_snrDb!.round()} dB', style: const TextStyle(color: Colors.white70)),
                  ],
                ],
              ),
              const SizedBox(height: 20),
              // Left/right with the remote moves between these.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _TuneButton(icon: Icons.fast_rewind, label: 'Suchen', onPressed: busy ? null : () => _seek(false)),
                  _TuneButton(icon: Icons.remove, label: '−0,05', onPressed: busy ? null : () => _tune(_freqKhz - step)),
                  _TuneButton(
                    icon: Icons.add,
                    label: '+0,05',
                    autofocus: true,
                    onPressed: busy ? null : () => _tune(_freqKhz + step),
                  ),
                  _TuneButton(icon: Icons.fast_forward, label: 'Suchen', onPressed: busy ? null : () => _seek(true)),
                ],
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: busy ? null : _enterFrequency,
                icon: const Icon(Icons.dialpad),
                label: const Text('Frequenz eingeben'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _failed ? null : _saveStation, child: const Text('Als Sender speichern')),
          TextButton(onPressed: _failed ? null : _saveFavorite, child: const Text('Als Favorit speichern')),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Schließen')),
        ],
      ),
    );
  }
}

class _TuneButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool autofocus;

  const _TuneButton({required this.icon, required this.label, required this.onPressed, this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: FilledButton.tonal(
        autofocus: autofocus,
        onPressed: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon), Text(label)]),
        ),
      ),
    );
  }
}

typedef _Found = ({int freqKhz, String? ps, bool stereo, int? pi, double? levelDb});

/// Signal level as traffic light (relative dB from the scan, see
/// FmStation.levelDb): green good, yellow usable, red weak - thresholds
/// from a real scan in Graz (strong stations -4..-30 dB, weak ones -43 and
/// below).
Color fmLevelColor(double levelDb) =>
    levelDb >= -32 ? Colors.greenAccent : (levelDb >= -42 ? Colors.amberAccent : Colors.redAccent);
