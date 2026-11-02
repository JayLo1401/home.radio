import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../data/models/internet_radio_station.dart';
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;

/// Points the receiver at the configured RTL-SDR source (USB stick or
/// rtl_tcp server) - needed before anything that tunes on its own: DAB+ or
/// FM scans, logo capture, manual FM tuning.
Future<bool> connectDecoder(WidgetRef ref) async {
  final settings = ref.read(settingsRepositoryProvider);
  final dab = ref.read(dabRtlSdrServiceProvider);
  return await settings.getRtlSdrAutoStartOwnService()
      ? await dab.useDirectUsb()
      : await dab.setServer(host: await settings.getRtlSdrHost(), port: await settings.getRtlSdrPort());
}

/// What the user picked in [_LogoPickerDialog]: an image URL, or a received
/// broadcast image (local file).
typedef LogoChoice = ({String? url, String? localPath});

/// "Logo wählen" for one station: internet candidates from Radio-Browser,
/// a direct image URL, and for DAB+ stations "DAB-Logo holen", which tunes
/// just this station and waits for its broadcast image. Every candidate is
/// listed with name and country - a same-named station elsewhere (e.g.
/// "Radio Aktual" from Slovenia for "Aktual Rock") is recognisable instead
/// of being taken silently, which the former automatic first-hit lookup did.
/// Returns the choice, or null if cancelled.
class _LogoPickerDialog extends ConsumerStatefulWidget {
  final String stationName;
  final ({int freqKhz, int serviceId})? dabStation;

  const _LogoPickerDialog({required this.stationName, this.dabStation});

  @override
  ConsumerState<_LogoPickerDialog> createState() => _LogoPickerDialogState();
}

enum _DabLogoState { idle, waiting, found, none, failed }

class _LogoPickerDialogState extends ConsumerState<_LogoPickerDialog> {
  late final _queryController = TextEditingController(text: widget.stationName);
  final _urlController = TextEditingController();
  List<InternetRadioStation> _results = [];
  bool _loading = false;
  bool _searched = false;

  // Kept from the start: ref can't be used safely in dispose().
  late final DabRtlSdrService _dab;
  _DabLogoState _dabState = _DabLogoState.idle;
  String? _dabPath;
  StreamSubscription<Map<String, dynamic>>? _dabSub;

  @override
  void initState() {
    super.initState();
    _dab = ref.read(dabRtlSdrServiceProvider);
    _search();
  }

  @override
  void dispose() {
    if (_dabState == _DabLogoState.waiting) _dab.stopLogoFetch();
    _dabSub?.cancel();
    _queryController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() => _loading = true);
    final results = await _logoCandidates(ref, query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
      _searched = true;
    });
  }

  Future<void> _fetchDabLogo() async {
    final station = widget.dabStation!;
    setState(() => _dabState = _DabLogoState.waiting);
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _dabState = _DabLogoState.failed);
      return;
    }
    await _dabSub?.cancel();
    _dabSub = ref.read(dabRtlSdrServiceProvider).events.listen((event) {
      if (!mounted) return;
      switch (event['type']) {
        case 'logoFound' when event['freqKhz'] == station.freqKhz && event['serviceId'] == station.serviceId:
          setState(() {
            _dabPath = event['path'] as String;
            _dabState = _DabLogoState.found;
          });
        case 'logoScanFinished':
          _dabSub?.cancel();
          _dabSub = null;
          if (_dabState == _DabLogoState.waiting) setState(() => _dabState = _DabLogoState.none);
      }
    });
    await ref.read(dabRtlSdrServiceProvider).fetchLogos([station]);
  }

  Widget _dabSection() {
    const hint = TextStyle(color: Colors.white54, fontSize: 13);
    final status = switch (_dabState) {
      _DabLogoState.idle => const Text('Holt das Bild, das der Sender selbst ausstrahlt.', style: hint),
      _DabLogoState.waiting => const Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Expanded(child: Text('Warte auf ein Bild vom Sender (bis etwa 30 s)…', style: hint)),
          ],
        ),
      _DabLogoState.found => Row(
          children: [
            CircleAvatar(radius: 22, backgroundImage: FileImage(File(_dabPath!))),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop((url: null, localPath: _dabPath) as LogoChoice),
              child: const Text('Dieses Bild übernehmen'),
            ),
          ],
        ),
      _DabLogoState.none => const Text('Der Sender hat in der Zeit kein Bild gesendet.', style: hint),
      _DabLogoState.failed => const Text('DAB+-Decoder konnte nicht gestartet werden.', style: hint),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _dabState == _DabLogoState.waiting ? null : _fetchDabLogo,
          icon: const Icon(Icons.settings_input_antenna),
          label: const Text('DAB-Logo holen'),
        ),
        const SizedBox(height: 8),
        status,
        const Divider(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Logo wählen'),
      content: SizedBox(
        width: 460,
        height: widget.dabStation != null ? 540 : 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.dabStation != null) _dabSection(),
            PopupTextField(
              controller: _queryController,
              label: 'Im Internet suchen (Sendername)',
              icon: Icons.search,
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                      ? Center(
                          child: Text(
                            _searched ? 'Keine Treffer mit Logo.' : '',
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
                              onTap: () => Navigator.of(context).pop((url: station.favicon, localPath: null) as LogoChoice),
                            );
                          },
                        ),
            ),
            const Divider(height: 24),
            // Entering an address takes it right away.
            PopupTextField(
              controller: _urlController,
              label: 'oder eigene Bild-Adresse (URL)',
              hint: 'https://…',
              keyboardType: TextInputType.url,
              onSubmitted: (url) {
                if (url.isNotEmpty) Navigator.of(context).pop((url: url, localPath: null) as LogoChoice);
              },
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

Future<LogoChoice?> showLogoPicker(
  BuildContext context, {
  required String stationName,
  ({int freqKhz, int serviceId})? dabStation,
}) {
  return showDialog<LogoChoice>(
    context: context,
    builder: (context) => _LogoPickerDialog(stationName: stationName, dabStation: dabStation),
  );
}

/// Radio-Browser stations with a logo for [stationName], from every search
/// variant at once - deliberately broad, since an exact name rarely matches
/// a DAB+ label: labels carry decorative padding ("*GRUEN-WEISS*", stray
/// pipes/dashes), so the name is cleaned up first; then "Radio" + name (many
/// labels drop that word) and every single word of it ("Aktual Rock" finds
/// nothing as a whole). All hits are returned, de-duplicated by logo, with
/// Austrian, German and Swiss stations first - the user picks, the list is
/// never cut down to one guess.
Future<List<InternetRadioStation>> _logoCandidates(WidgetRef ref, String stationName) async {
  final cleaned = stationName.replaceAll(RegExp(r'[^\w\säöüÄÖÜß]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return const [];
  final words = cleaned.split(' ').where((w) => w.length >= 3 && w.toLowerCase() != 'radio');
  final queries = {
    cleaned,
    if (!cleaned.toLowerCase().startsWith('radio ')) 'Radio $cleaned',
    ...words,
  };
  final api = ref.read(radioBrowserApiServiceProvider);
  final results = await Future.wait(queries.map((query) async {
    try {
      return await api.search(name: query, limit: 40);
    } catch (_) {
      return const <InternetRadioStation>[]; // a failed variant just adds nothing
    }
  }));
  final seen = <String>{};
  final out = <InternetRadioStation>[
    for (final list in results)
      for (final s in list)
        if (s.favicon case final favicon? when seen.add(favicon)) s,
  ];
  const nearby = {'AT', 'DE', 'CH'};
  // Stable: keeps the variant order (closest name match first) within each group.
  return [
    ...out.where((s) => nearby.contains(s.countryCode.toUpperCase())),
    ...out.where((s) => !nearby.contains(s.countryCode.toUpperCase())),
  ];
}

