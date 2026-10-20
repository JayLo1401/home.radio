import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/db/database.dart' show DabStation;
import '../../data/models/favorite_channel.dart';
import '../../data/models/internet_radio_station.dart';
import '../../data/repositories/dab_stations_repository.dart' show DabStationDisplay;
import '../shared/program_number_dialog.dart';
import '../shared/rename_dialog.dart';

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
            if (stations.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _LogoReceiveButton(stations: stations),
                  _LogoFetchButton(stations: stations),
                ],
              ),
            ],
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

/// Tunes through every known station in turn and waits for a real DAB+ MOT
/// slideshow image (see DabRtlSdrService.fetchLogos's own doc comment) - the
/// actual broadcast logo/cover art, not a best-effort internet name lookup
/// like [_LogoFetchButton]. Slower (some stations take 10-30s to send a
/// slide, some never do) and runs against *every* station, not just ones
/// missing a logo - a captured broadcast image is authoritative for its
/// station, so it's meant to replace whatever [_LogoFetchButton] guessed
/// from a name search, not just fill gaps. [DabStationsRepository.setLogoPath]
/// writes it to [DabStation.logoLocalPath], which every logo display in the
/// app (favorites sidebar, now-playing banner, and _StationRow/_FavoriteRow
/// below) already prefers over [DabStation.logoUrl] when both are set - that
/// precedence, not any deletion of the stored URL, is what makes a captured
/// broadcast image actually override a previously internet-sourced one.
class _LogoReceiveButton extends ConsumerStatefulWidget {
  final List<DabStation> stations;
  const _LogoReceiveButton({required this.stations});

  @override
  ConsumerState<_LogoReceiveButton> createState() => _LogoReceiveButtonState();
}

class _LogoReceiveButtonState extends ConsumerState<_LogoReceiveButton> {
  bool _running = false;
  String? _progressText;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    // Same "point the decoder at the configured RTL-SDR source first" step
    // _ScanPanelState._startScan() does - fetchLogos() needs a live tuner
    // session exactly like a scan does.
    final settings = ref.read(settingsRepositoryProvider);
    final ownUsb = await settings.getRtlSdrAutoStartOwnService();
    final connected = ownUsb
        ? await ref.read(dabRtlSdrServiceProvider).useDirectUsb()
        : await ref.read(dabRtlSdrServiceProvider).setServer(
              host: await settings.getRtlSdrHost(),
              port: await settings.getRtlSdrPort(),
            );
    if (!connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('DAB+-Decoder konnte nicht gestartet werden.')),
        );
      }
      return;
    }
    setState(() {
      _running = true;
      _progressText = null;
    });
    final stationsRepo = ref.read(dabStationsRepositoryProvider);
    final favoritesRepo = ref.read(favoritesRepositoryProvider);
    var found = 0;
    _sub = ref.read(dabRtlSdrServiceProvider).events.listen((event) async {
      if (!mounted) return;
      switch (event['type']) {
        case 'logoScanProgress':
          final index = event['index'] as int;
          final total = event['total'] as int;
          setState(() => _progressText = 'Sender ${index + 1}/$total…');
        case 'logoFound':
          found++;
          final freqKhz = event['freqKhz'] as int;
          final serviceId = event['serviceId'] as int;
          final path = event['path'] as String;
          await stationsRepo.setLogoPath(freqKhz: freqKhz, serviceId: serviceId, logoLocalPath: path);
          final matchingFavorite = (ref.read(favoritesStreamProvider).value ?? const <FavoriteChannel>[])
              .where((c) => c.dabFreqKhz == freqKhz && c.dabServiceId == serviceId)
              .firstOrNull;
          if (matchingFavorite != null) {
            await favoritesRepo.updateLogoLocalPath(matchingFavorite.programNumber, path);
          }
        case 'logoScanFinished':
          await _sub?.cancel();
          _sub = null;
          if (mounted) {
            setState(() {
              _running = false;
              _progressText = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Senderlogos per Empfang aktualisiert: $found von ${widget.stations.length} gefunden.'),
              ),
            );
          }
      }
    });
    await ref.read(dabRtlSdrServiceProvider).fetchLogos(
          widget.stations.map((s) => (freqKhz: s.freqKhz, serviceId: s.serviceId)).toList(),
        );
  }

  Future<void> _stop() async {
    await ref.read(dabRtlSdrServiceProvider).stopLogoFetch();
    await _sub?.cancel();
    _sub = null;
    if (mounted) {
      setState(() {
        _running = false;
        _progressText = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_running && _progressText != null) ...[
          Text(_progressText!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(width: 8),
        ],
        TextButton.icon(
          onPressed: _running ? _stop : _start,
          icon: Icon(_running ? Icons.stop : Icons.settings_input_antenna),
          label: Text(_running ? 'Stoppen' : 'Senderlogos per Empfang holen'),
        ),
      ],
    );
  }
}

/// Looks up a logo for every known station that doesn't have one yet, via
/// [_findLogoUrl] (Radio-Browser, matched by cleaned-up station name) - pure
/// Dart/HTTP, no tuning/USB involved at all, so this is fast even for dozens
/// of stations, and a reasonable fallback for whatever [_LogoReceiveButton]
/// couldn't get a broadcast image for (or hasn't been run yet). Only ever
/// fills in *missing* logos - never overwrites one already found (by either
/// button), unlike [_LogoReceiveButton].
class _LogoFetchButton extends ConsumerStatefulWidget {
  final List<DabStation> stations;
  const _LogoFetchButton({required this.stations});

  @override
  ConsumerState<_LogoFetchButton> createState() => _LogoFetchButtonState();
}

class _LogoFetchButtonState extends ConsumerState<_LogoFetchButton> {
  bool _running = false;
  bool _cancelled = false;
  String? _progressText;

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _start() async {
    // Skip stations that already have a logo - re-running this over and
    // over shouldn't re-query everything every time.
    final pending = widget.stations.where((s) => s.logoUrl == null).toList();
    if (pending.isEmpty) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _progressText = null;
    });
    final stationsRepo = ref.read(dabStationsRepositoryProvider);
    final favoritesRepo = ref.read(favoritesRepositoryProvider);
    var found = 0;
    for (var i = 0; i < pending.length; i++) {
      if (_cancelled) break;
      final station = pending[i];
      if (mounted) setState(() => _progressText = 'Sender ${i + 1}/${pending.length}…');
      final logoUrl = await _findLogoUrl(ref, station.displayLabel);
      if (logoUrl != null) {
        found++;
        await stationsRepo.setLogoUrl(freqKhz: station.freqKhz, serviceId: station.serviceId, logoUrl: logoUrl);
        final matchingFavorite = (ref.read(favoritesStreamProvider).value ?? const <FavoriteChannel>[])
            .where((c) => c.dabFreqKhz == station.freqKhz && c.dabServiceId == station.serviceId)
            .firstOrNull;
        if (matchingFavorite != null) {
          await favoritesRepo.updateLogoUrl(matchingFavorite.programNumber, logoUrl);
        }
      }
      // A courtesy delay between requests to the public Radio-Browser API,
      // not something this app's own responsiveness needs.
      if (!_cancelled && i < pending.length - 1) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    if (mounted) {
      setState(() {
        _running = false;
        _progressText = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Senderlogos aktualisiert: $found von ${pending.length} gefunden.')),
      );
    }
  }

  void _stop() {
    _cancelled = true;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_running && _progressText != null) ...[
          Text(_progressText!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(width: 8),
        ],
        TextButton.icon(
          onPressed: _running ? _stop : _start,
          icon: Icon(_running ? Icons.stop : Icons.image_search),
          label: Text(_running ? 'Stoppen' : 'Senderlogos aus dem Internet holen'),
        ),
      ],
    );
  }
}

/// Manual "nachbessern" for when [_findLogoUrl]'s automatic pick was wrong
/// or empty - [_findLogoUrl] only ever takes the *first* Radio-Browser hit,
/// which for a common station name/short name can easily be the wrong
/// station's logo entirely. Lets the user search themselves and pick from
/// the actual candidates (with a thumbnail preview, so no guessing from
/// names alone), or as a last resort paste a direct image URL - without
/// having to go googling for one outside the app. Returns the chosen URL,
/// or null if cancelled.
class _LogoPickerDialog extends ConsumerStatefulWidget {
  final String initialQuery;
  const _LogoPickerDialog({required this.initialQuery});

  @override
  ConsumerState<_LogoPickerDialog> createState() => _LogoPickerDialogState();
}

class _LogoPickerDialogState extends ConsumerState<_LogoPickerDialog> {
  late final _queryController = TextEditingController(text: widget.initialQuery);
  final _urlController = TextEditingController();
  List<InternetRadioStation> _results = [];
  bool _loading = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _queryController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() => _loading = true);
    try {
      final results = await ref.read(radioBrowserApiServiceProvider).search(name: query, limit: 25);
      if (mounted) setState(() => _results = results.where((s) => s.favicon != null).toList());
    } catch (_) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _searched = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Logo suchen'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    decoration: const InputDecoration(labelText: 'Sendername'),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(icon: const Icon(Icons.search), onPressed: _search),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                      ? Center(
                          child: Text(
                            _searched ? 'Keine Treffer mit Vorschaubild.' : '',
                            style: const TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _results.length,
                          itemBuilder: (context, index) {
                            final station = _results[index];
                            return ListTile(
                              leading: CircleAvatar(backgroundImage: CachedNetworkImageProvider(station.favicon!)),
                              title: Text(station.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(station.countryCode),
                              onTap: () => Navigator.of(context).pop(station.favicon),
                            );
                          },
                        ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(labelText: 'oder direkte Bild-URL', hintText: 'https://…'),
                    keyboardType: TextInputType.url,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final url = _urlController.text.trim();
                    if (url.isNotEmpty) Navigator.of(context).pop(url);
                  },
                  child: const Text('Übernehmen'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
      ],
    );
  }
}

Future<String?> _showLogoUrlDialog(BuildContext context, {required String stationName}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _LogoPickerDialog(initialQuery: stationName),
  );
}

/// A dedicated, separate action (see [_LogoFetchButton]'s own doc comment)
/// captures real DAB+ MOT slideshow images. This is the fallback/quick
/// alternative for stations that don't send one (or before that scan has
/// been run): matches the station name against Radio-Browser's catalog (the
/// same source used for internet-radio favicons) and takes the first hit's
/// favicon, if any. Never throws - a missing/failed lookup just means no
/// logo, not a broken favorite.
/// DAB+ station labels often carry decorative padding ("*GRUEN-WEISS*",
/// stray pipes/dashes used as visual borders in the original 16-char FIG 1/1
/// label) that a plain Radio-Browser name search won't match at all -
/// strip everything but letters/digits/spaces first (this also turns
/// dashes into spaces, since they're not in the allowed set either), and if
/// that finds nothing, retry prefixed with "Radio " - a lot of DAB+ labels
/// drop that word entirely (just "GRUEN-WEISS") while the station is
/// actually catalogued under "Radio Gruen-Weiss" or similar on Radio-Browser,
/// and this alone resolves most "no logo found" cases in practice. Only
/// after that still comes up empty does this fall back to just the first
/// word (station names are frequently "Name slogan/suffix").
Future<String?> _findLogoUrl(WidgetRef ref, String stationName) async {
  final cleaned = stationName.replaceAll(RegExp(r'[^\w\säöüÄÖÜß]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return null;
  final api = ref.read(radioBrowserApiServiceProvider);
  try {
    final results = await api.search(name: cleaned, limit: 5);
    final hit = results.where((s) => s.favicon != null && s.favicon!.isNotEmpty).firstOrNull;
    if (hit != null) return hit.favicon;
    if (!cleaned.toLowerCase().startsWith('radio ')) {
      final withRadio = await api.search(name: 'Radio $cleaned', limit: 5);
      final radioHit = withRadio.where((s) => s.favicon != null && s.favicon!.isNotEmpty).firstOrNull;
      if (radioHit != null) return radioHit.favicon;
    }
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

  Future<void> _setLogoManually(BuildContext context, WidgetRef ref) async {
    final url = await _showLogoUrlDialog(context, stationName: channel.displayName);
    if (url == null) return;
    await ref.read(favoritesRepositoryProvider).updateLogoUrl(channel.programNumber, url);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localPath = channel.logoLocalPath;
    final url = channel.logoUrl;
    // A captured broadcast image (logoLocalPath) takes priority over an
    // internet-guessed one (logoUrl) - same precedence FavoritesSidebar/
    // NowPlayingBanner already use, see _LogoReceiveButton's doc comment.
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
          if (channel.logoUrl == null)
            IconButton(
              icon: const Icon(Icons.image_search),
              tooltip: 'Logo suchen',
              onPressed: () => _findLogo(context, ref),
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Logo nachbessern',
            onPressed: () => _setLogoManually(context, ref),
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
    // Already have one (auto or manual, from "Alle DAB+ Sender" itself) -
    // keep it rather than looking it up again.
    final logoUrl = station.logoUrl ?? await _findLogoUrl(ref, station.displayLabel);
    await repo.addDabService(
      programNumber: programNumber,
      displayName: station.displayLabel,
      freqKhz: station.freqKhz,
      serviceId: station.serviceId,
      logoUrl: logoUrl,
    );
    if (logoUrl != null && station.logoUrl == null) {
      await ref
          .read(dabStationsRepositoryProvider)
          .setLogoUrl(freqKhz: station.freqKhz, serviceId: station.serviceId, logoUrl: logoUrl);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${station.displayLabel}" als Nr. $programNumber gespeichert.')),
      );
    }
  }

  Future<void> _findLogo(BuildContext context, WidgetRef ref) async {
    final logoUrl = await _findLogoUrl(ref, station.displayLabel);
    if (logoUrl != null) {
      await ref
          .read(dabStationsRepositoryProvider)
          .setLogoUrl(freqKhz: station.freqKhz, serviceId: station.serviceId, logoUrl: logoUrl);
      if (favorite != null) {
        await ref.read(favoritesRepositoryProvider).updateLogoUrl(favorite!.programNumber, logoUrl);
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            logoUrl != null
                ? 'Logo für "${station.displayLabel}" gefunden.'
                : 'Kein passendes Logo für "${station.displayLabel}" gefunden.',
          ),
        ),
      );
    }
  }

  Future<void> _setLogoManually(BuildContext context, WidgetRef ref) async {
    final url = await _showLogoUrlDialog(context, stationName: station.displayLabel);
    if (url == null) return;
    await ref
        .read(dabStationsRepositoryProvider)
        .setLogoUrl(freqKhz: station.freqKhz, serviceId: station.serviceId, logoUrl: url);
    if (favorite != null) {
      await ref.read(favoritesRepositoryProvider).updateLogoUrl(favorite!.programNumber, url);
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
    final logoUrl = station.logoUrl;
    final logoPath = station.logoLocalPath;
    // A captured broadcast image (logoLocalPath) takes priority over an
    // internet-guessed one (logoUrl) - see _LogoReceiveButton's doc comment.
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
          if (logoUrl == null)
            IconButton(
              icon: const Icon(Icons.image_search),
              tooltip: 'Logo suchen',
              onPressed: () => _findLogo(context, ref),
            ),
          IconButton(
            icon: const Icon(Icons.add_photo_alternate_outlined),
            tooltip: 'Logo nachbessern',
            onPressed: () => _setLogoManually(context, ref),
          ),
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

/// DAB Band III scan panel: points the DAB+ receiver (DabRtlSdrService/
/// DabRtlSdrPlugin) at the configured RTL-SDR source (USB stick or rtl_tcp
/// server - same choice as on RtlSdrTestScreen) and shows live progress;
/// every locked ensemble's stations are persisted into DabStationsRepository
/// as they're found, each with an "Anhören" (listen) button.
class _ScanPanel extends ConsumerStatefulWidget {
  const _ScanPanel();

  @override
  ConsumerState<_ScanPanel> createState() => _ScanPanelState();
}

class _ScanPanelState extends ConsumerState<_ScanPanel> {
  bool _ownUsbMode = false;
  bool _scanning = false;
  String? _currentLabel;
  final List<_FoundChannel> _found = [];
  StreamSubscription<Map<String, dynamic>>? _sub;
  ({int freqKhz, int serviceId})? _playing;

  @override
  void initState() {
    super.initState();
    _loadMode();
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sendersuchlauf fertig: ${event['foundCount']} Ensemble(s) mit Empfang.')),
          );
      }
    });
  }

  /// Which RTL-SDR source to use is now configured once, in "DAB+ RTL-SDR
  /// Einrichtung" (see RtlSdrTestScreen) - this panel used to have its own
  /// separate, editable host/port fields that duplicated that setting and
  /// could disagree with it. Just reads whatever's configured there.
  Future<void> _loadMode() async {
    final ownUsb = await ref.read(settingsRepositoryProvider).getRtlSdrAutoStartOwnService();
    if (mounted) setState(() => _ownUsbMode = ownUsb);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    // In "RTL-SDR-USB" mode there is no rtl_tcp server to probe - the stick
    // is opened directly instead.
    final connected = _ownUsbMode
        ? await ref.read(dabRtlSdrServiceProvider).useDirectUsb()
        : await () async {
            final settings = ref.read(settingsRepositoryProvider);
            final host = await settings.getRtlSdrHost();
            final port = await settings.getRtlSdrPort();
            return ref.read(dabRtlSdrServiceProvider).setServer(host: host, port: port);
          }();
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
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            _ownUsbMode
                ? 'Quelle: RTL-SDR-USB (direkt) - siehe "DAB+ RTL-SDR Einrichtung" in den Einstellungen.'
                : 'Quelle: RTL-SDR TCP - siehe "DAB+ RTL-SDR Einrichtung" in den Einstellungen.',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
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
