import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/country_names_de.dart';
import '../../core/country_regions.dart';
import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../data/models/internet_radio_station.dart';
import '../../l10n/l10n.dart';
import '../shared/program_number_dialog.dart';

/// Country names in German from our own table, otherwise Radio-Browser's
/// English name.
String _countryName(Map<String, String> c, String localeName) => localeName == 'de'
    ? germanCountryName(c['code'] ?? '', c['name'] ?? '')
    : ((c['name'] ?? '').isNotEmpty ? c['name']! : c['code'] ?? '');

String _regionLabel(AppLocalizations l10n, WorldRegion region) => switch (region) {
      WorldRegion.europe => l10n.radioRegionEurope,
      WorldRegion.northAmerica => l10n.radioRegionNorthAmerica,
      WorldRegion.southAmerica => l10n.radioRegionSouthAmerica,
      WorldRegion.asia => l10n.radioRegionAsia,
      WorldRegion.africa => l10n.radioRegionAfrica,
      WorldRegion.oceania => l10n.radioRegionOceania,
      WorldRegion.other => l10n.radioRegionOther,
    };

/// Sender search screen. Genre/country filtering uses ordinary dropdowns
/// (alphabetically sorted; countries shown in German), and the free-text
/// name is a [PopupTextField] - typed in a dialog, so the remote's arrow
/// keys never get stuck in an inline text field.
class InternetRadioSearchScreen extends ConsumerStatefulWidget {
  const InternetRadioSearchScreen({super.key});

  @override
  ConsumerState<InternetRadioSearchScreen> createState() =>
      _InternetRadioSearchScreenState();
}

class _InternetRadioSearchScreenState
    extends ConsumerState<InternetRadioSearchScreen> {
  final _nameController = TextEditingController();
  String? _selectedTag;
  String? _selectedCountryCode;
  // Narrows the country dropdown (null = all regions).
  WorldRegion? _region = WorldRegion.europe;
  List<String> _tags = const [];
  List<Map<String, String>> _countries = const [];
  List<InternetRadioStation> _results = const [];
  bool _loading = false;
  String? _error;

  String? _previewingUrl;
  bool _previewPlaying = false;

  @override
  void initState() {
    super.initState();
    _loadFilters();
    _runSearch();
    ref.read(audioPlayerServiceProvider).playerStateStream.listen((s) {
      if (mounted) setState(() => _previewPlaying = s.playing);
    });
  }

  Future<void> _loadFilters() async {
    final api = ref.read(radioBrowserApiServiceProvider);
    final tags = await api.topTags(limit: 150);
    final countries = await api.countries(limit: 250);
    tags.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final localeName = l10n.localeName;
    countries.sort((a, b) => _countryName(a, localeName).compareTo(_countryName(b, localeName)));
    if (mounted) {
      setState(() {
        _tags = tags;
        _countries = countries;
      });
    }
  }

  Future<void> _runSearch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(radioBrowserApiServiceProvider);
      final results = await api.search(
        name: _nameController.text.trim().isEmpty ? null : _nameController.text.trim(),
        tag: _selectedTag,
        countryCode: _selectedCountryCode,
      );
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _togglePreview(InternetRadioStation station) async {
    final audio = ref.read(audioPlayerServiceProvider);
    if (_previewingUrl == station.streamUrl && _previewPlaying) {
      await audio.stop();
      setState(() => _previewingUrl = null);
      return;
    }
    setState(() => _previewingUrl = station.streamUrl);
    await audio.playStream(station.streamUrl);
  }

  Future<void> _addToFavorites(InternetRadioStation station) async {
    final repo = ref.read(favoritesRepositoryProvider);
    final suggested = await repo.nextFreeProgramNumber() ?? 1;
    if (!mounted) return;
    final programNumber = await showDialog<int>(
      context: context,
      builder: (context) => ProgramNumberDialog(initial: suggested),
    );
    if (programNumber == null) return;
    await repo.addInternetStation(programNumber: programNumber, station: station);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.radioSavedAsNumber(station.name, programNumber))),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    // Only stop playback if *we* started a preview - otherwise this would
    // cut off a favorite the user had playing before opening this screen.
    if (_previewingUrl != null) {
      ref.read(audioPlayerServiceProvider).stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // D-Pad down must move reliably through: genre row -> country row ->
    // each result row (preview, then favorite) top to bottom. Explicit order
    // avoids Flutter's geometric guess picking the wrong next widget.
    var order = 0.0;
    double nextOrder() => order += 1;
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.radioSearchInternetTitle)),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 280,
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(nextOrder()),
                      child: PopupTextField(
                        controller: _nameController,
                        label: l10n.radioSearchStationName,
                        icon: Icons.search,
                        onSubmitted: (_) => _runSearch(),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(nextOrder()),
                      child: DropdownButtonFormField<String>(
                        initialValue: _selectedTag,
                        decoration:
                            InputDecoration(labelText: l10n.radioSearchGenre, border: const OutlineInputBorder()),
                        isExpanded: true,
                        items: [
                          DropdownMenuItem(value: null, child: Text(l10n.radioSearchAllGenres)),
                          ..._tags.map((t) => DropdownMenuItem(value: t, child: Text(t))),
                        ],
                        onChanged: (v) {
                          setState(() => _selectedTag = v);
                          _runSearch();
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(nextOrder()),
                      child: DropdownButtonFormField<WorldRegion?>(
                        initialValue: _region,
                        decoration:
                            InputDecoration(labelText: l10n.radioSearchRegion, border: const OutlineInputBorder()),
                        isExpanded: true,
                        items: [
                          DropdownMenuItem(value: null, child: Text(l10n.radioSearchAllRegions)),
                          for (final r in WorldRegion.values)
                            DropdownMenuItem(value: r, child: Text(_regionLabel(l10n, r))),
                        ],
                        onChanged: (r) {
                          final keep = _selectedCountryCode != null && (r == null || regionOf(_selectedCountryCode!) == r);
                          setState(() {
                            _region = r;
                            if (!keep) _selectedCountryCode = null;
                          });
                          if (!keep) _runSearch();
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 260,
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(nextOrder()),
                      child: DropdownButtonFormField<String>(
                        // Rebuilt per region, so a reset selection shows.
                        key: ValueKey(_region),
                        initialValue: _selectedCountryCode,
                        decoration:
                            InputDecoration(labelText: l10n.radioSearchCountry, border: const OutlineInputBorder()),
                        isExpanded: true,
                        items: [
                          DropdownMenuItem(value: null, child: Text(l10n.radioSearchAllCountries)),
                          ..._countries.where((c) => _region == null || regionOf(c['code'] ?? '') == _region).map(
                            (c) => DropdownMenuItem(
                              value: c['code'],
                              child: Text(_countryName(c, l10n.localeName)),
                            ),
                          ),
                        ],
                        onChanged: (v) {
                          setState(() => _selectedCountryCode = v);
                          _runSearch();
                        },
                      ),
                    ),
                  ),
                  FocusTraversalOrder(
                    order: NumericFocusOrder(nextOrder()),
                    child: FilledButton.icon(
                      onPressed: _loading ? null : _runSearch,
                      icon: const Icon(Icons.search),
                      label: Text(l10n.radioSearchButton),
                    ),
                  ),
                ],
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
            const Divider(height: 24),
            Expanded(
              child: _results.isEmpty && !_loading
                  ? Center(child: Text(l10n.radioSearchNoResults))
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final station = _results[index];
                        final isPreviewing =
                            _previewingUrl == station.streamUrl && _previewPlaying;
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: station.favicon != null
                                ? CachedNetworkImage(
                                    imageUrl: station.favicon!,
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, _, _) => const Icon(Icons.radio),
                                  )
                                : const Icon(Icons.radio, size: 40),
                          ),
                          title: Text(station.name),
                          subtitle: Text(
                            [
                              if (station.countryCode.isNotEmpty) station.countryCode,
                              if (station.tags.isNotEmpty) station.tags.take(3).join(', '),
                              if (station.bitrateKbps > 0) '${station.bitrateKbps} kbps',
                            ].join(' · '),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FocusTraversalOrder(
                                order: NumericFocusOrder(nextOrder()),
                                child: IconButton(
                                  tooltip: isPreviewing ? l10n.radioStop : l10n.radioSearchPreview,
                                  onPressed: () => _togglePreview(station),
                                  icon: Icon(
                                    isPreviewing ? Icons.stop_circle : Icons.play_circle_outline,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              FocusTraversalOrder(
                                order: NumericFocusOrder(nextOrder()),
                                child: FilledButton.tonalIcon(
                                  onPressed: () => _addToFavorites(station),
                                  icon: const Icon(Icons.star_border),
                                  label: Text(l10n.radioSearchAddFavorite),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

