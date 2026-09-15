import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/country_names_de.dart';
import '../../core/dpad_text_field.dart';
import '../../core/providers.dart';
import '../../data/models/internet_radio_station.dart';
import '../shared/program_number_dialog.dart';

/// Sender search screen. Genre/country filtering uses ordinary dropdowns
/// (alphabetically sorted; countries shown in German), and the free-text
/// name field uses [DpadTextField] so Up/Down can still leave it even
/// without a real keyboard - mouse/keyboard users can simply click in and
/// type as usual.
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
    countries.sort((a, b) => germanCountryName(a['code'] ?? '', a['name'] ?? '')
        .compareTo(germanCountryName(b['code'] ?? '', b['name'] ?? '')));
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
        SnackBar(content: Text('"${station.name}" als Nr. $programNumber gespeichert.')),
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

    return Scaffold(
      appBar: AppBar(title: const Text('Internetradio suchen')),
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
                      child: DpadTextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Sendername (Tastatur/Maus)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.search),
                        ),
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
                        decoration: const InputDecoration(
                            labelText: 'Genre', border: OutlineInputBorder()),
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(value: null, child: Text('Alle Genres')),
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
                    width: 260,
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(nextOrder()),
                      child: DropdownButtonFormField<String>(
                        initialValue: _selectedCountryCode,
                        decoration: const InputDecoration(
                            labelText: 'Land', border: OutlineInputBorder()),
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(value: null, child: Text('Alle Länder')),
                          ..._countries.map(
                            (c) => DropdownMenuItem(
                              value: c['code'],
                              child: Text(germanCountryName(c['code'] ?? '', c['name'] ?? '')),
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
                      label: const Text('Suchen'),
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
                  ? const Center(child: Text('Keine Ergebnisse.'))
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
                                  tooltip: isPreviewing ? 'Stopp' : 'Probehören',
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
                                  label: const Text('Favorit'),
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

