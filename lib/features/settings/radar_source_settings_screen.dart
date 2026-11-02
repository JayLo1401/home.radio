import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../core/providers.dart';

/// Where the weather radar tile comes from: an image URL (PNG/JPG, e.g. a
/// private radar server, optionally with a token) or a web page such as an
/// interactive radar map, shown in an embedded browser.
///
/// Its own sub-page rather than inline in the settings list, like
/// LocationSettingsScreen - text fields don't belong in a D-Pad-driven list.
class RadarSourceSettingsScreen extends ConsumerStatefulWidget {
  const RadarSourceSettingsScreen({super.key});

  @override
  ConsumerState<RadarSourceSettingsScreen> createState() => _RadarSourceSettingsScreenState();
}

class _RadarSourceSettingsScreenState extends ConsumerState<RadarSourceSettingsScreen> {
  late final _settings = ref.read(weatherDisplaySettingsProvider);
  late final _urlController = TextEditingController(text: _settings.radarUrl);
  late final _tokenController = TextEditingController(text: _settings.radarToken);
  late final _cssController = TextEditingController(text: _settings.radarWebCss);
  late bool _isWebPage = _settings.radarIsWebPage;
  late bool _authEnabled = _settings.radarAuthEnabled;

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    _cssController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    final uri = Uri.tryParse(url);
    if (url.isNotEmpty && (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte eine vollständige Adresse mit http:// oder https:// eingeben.')),
      );
      return;
    }
    await ref.read(weatherDisplaySettingsProvider.notifier).setRadarSource(
          url: url,
          isWebPage: _isWebPage,
          webCss: _cssController.text.trim(),
          authEnabled: _authEnabled,
          token: _tokenController.text.trim(),
        );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Widget _typeOption({required String title, required String subtitle, required bool webPage}) {
    final selected = _isWebPage == webPage;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? Theme.of(context).colorScheme.primary : Colors.white54,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      focusColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
      onTap: () => setState(() => _isWebPage = webPage),
    );
  }

  @override
  Widget build(BuildContext context) {
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    return Scaffold(
      appBar: AppBar(title: const Text('Wetterradar einrichten')),
      body: FocusTraversalGroup(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Art der Quelle', style: Theme.of(context).textTheme.titleMedium),
            _typeOption(
              title: 'Bild',
              subtitle: 'PNG oder JPG, z. B. vom eigenen Radar-Server - wird alle 2½ Minuten neu geladen.',
              webPage: false,
            ),
            _typeOption(
              title: 'Webseite',
              subtitle: 'Eine Radar-Webseite, z. B. eine interaktive Karte. Braucht mehr Speicher und '
                  'Grafikleistung als ein Bild - auf schwachen TV-Boxen besser ein Bild verwenden.',
              webPage: true,
            ),
            const SizedBox(height: 16),
            PopupTextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              label: _isWebPage ? 'Adresse der Webseite (URL)' : 'Bild-Adresse (URL)',
              hint: 'https://…',
            ),
            const SizedBox(height: 8),
            const Text(
              'Platzhalter werden automatisch ersetzt: {lat} {lon} = Standort, {r} = Umkreis in km, '
              '{zoom} = Kartenzoom passend zum Umkreis, {w} {h} = Kachelgröße in Pixeln, '
              '{scale} = Bildschirmdichte.\n'
              'Bild: https://example.org/radar.png?lat={lat}&lon={lon}&r={r}&w={w}&h={h}&scale={scale}\n'
              'Webseite: https://example.org/radar?lat={lat}&lon={lon}&zoom={zoom}',
              style: help,
            ),
            const SizedBox(height: 8),
            const Text(
              'Die App bringt selbst keine Radarquelle mit. Rechte und Nutzungsbedingungen liegen beim '
              'jeweiligen Anbieter - bitte nur Quellen eintragen, die so genutzt werden dürfen.',
              style: help,
            ),
            if (_isWebPage) ...[
              const SizedBox(height: 20),
              PopupTextField(
                controller: _cssController,
                label: 'Eigenes CSS für die Webseite (optional)',
              ),
              const SizedBox(height: 8),
              const Text(
                'Wird nach jedem Laden in die Seite eingefügt, wie ein eigenes Stylesheet im Browser - '
                'z. B. um Teile der Seite für die eigene Anzeige auszublenden.',
                style: help,
              ),
            ],
            const SizedBox(height: 20),
            SwitchListTile(
              title: const Text('Mit Anmeldung (Token)'),
              subtitle: const Text('Wird als „Authorization: Bearer …“ mitgeschickt.'),
              value: _authEnabled,
              onChanged: (v) => setState(() => _authEnabled = v),
            ),
            if (_authEnabled)
              PopupTextField(
                controller: _tokenController,
                obscureText: true,
                label: 'Token',
              ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check),
                label: const Text('Speichern'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
