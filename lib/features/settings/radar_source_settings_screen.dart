import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.miscRadarInvalidUrl)));
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
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.miscRadarTitle)),
      body: FocusTraversalGroup(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l.miscRadarSourceType, style: Theme.of(context).textTheme.titleMedium),
            _typeOption(title: l.miscRadarImage, subtitle: l.miscRadarImageHint, webPage: false),
            _typeOption(title: l.miscRadarWebPage, subtitle: l.miscRadarWebPageHint, webPage: true),
            const SizedBox(height: 16),
            PopupTextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              label: _isWebPage ? l.miscRadarWebPageUrl : l.miscRadarImageUrl,
              hint: 'https://…',
            ),
            const SizedBox(height: 8),
            Text(
              // The placeholders are the literal tokens the user types into the address.
              '${l.miscRadarPlaceholders('{lat}', '{lon}', '{r}', '{zoom}', '{w}', '{h}', '{scale}')}\n'
              '${l.miscRadarImage}: https://example.org/radar.png?lat={lat}&lon={lon}&r={r}&w={w}&h={h}&scale={scale}\n'
              '${l.miscRadarWebPage}: https://example.org/radar?lat={lat}&lon={lon}&zoom={zoom}',
              style: help,
            ),
            const SizedBox(height: 8),
            Text(l.miscRadarDisclaimer, style: help),
            if (_isWebPage) ...[
              const SizedBox(height: 20),
              PopupTextField(
                controller: _cssController,
                label: l.miscRadarCssLabel,
              ),
              const SizedBox(height: 8),
              Text(l.miscRadarCssHint, style: help),
            ],
            const SizedBox(height: 20),
            SwitchListTile(
              title: Text(l.miscRadarAuth),
              subtitle: Text(l.miscRadarAuthHint),
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
                label: Text(l.commonSave),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
