import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/launcher_service.dart';
import '../launcher/launcher_background.dart';
import '../launcher/launcher_providers.dart';

/// A radio-style choice row (ListTile, like RadarSourceSettingsScreen).
Widget _choice(BuildContext context, {required String title, String? subtitle, required bool selected, required VoidCallback onTap, bool autofocus = false}) {
  return ListTile(
    autofocus: autofocus,
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_off,
      color: selected ? Theme.of(context).colorScheme.primary : Colors.white54,
    ),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    focusColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
    onTap: onTap,
  );
}

/// The launcher's background: built-in gradients, random photos, or the own
/// server - and how often it changes.
class LauncherBackgroundSettingsScreen extends ConsumerStatefulWidget {
  const LauncherBackgroundSettingsScreen({super.key});

  @override
  ConsumerState<LauncherBackgroundSettingsScreen> createState() => _LauncherBackgroundSettingsScreenState();
}

class _LauncherBackgroundSettingsScreenState extends ConsumerState<LauncherBackgroundSettingsScreen> {
  late final _settings = ref.read(launcherSettingsProvider);
  late LauncherBackgroundSource _source = _settings.backgroundSource;
  late final _url = TextEditingController(text: _settings.backgroundUrl);
  late int _interval = _settings.backgroundInterval;
  String? _testResult;
  bool _testing = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  bool get _urlValid {
    final uri = Uri.tryParse(_url.text.trim());
    return uri != null && uri.scheme.startsWith('http') && uri.host.isNotEmpty;
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    String result;
    try {
      final bytes = await ref.read(launcherBackgroundServiceProvider).fromServer(_url.text);
      result = bytes == null
          ? 'Kein Bild gefunden - liefert die Adresse ein Bild, eine JSON-Liste oder eine Seite mit Bild-Links?'
          : 'OK - Bild geladen (${(bytes.length / 1024).round()} KB).';
    } catch (e) {
      result = 'Fehler: $e';
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  Future<void> _save() async {
    if (_source == LauncherBackgroundSource.server && !_urlValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte eine vollständige Adresse mit http:// oder https:// eingeben.')),
      );
      return;
    }
    await ref.read(launcherSettingsProvider.notifier).setBackground(source: _source, url: _url.text.trim(), interval: _interval);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    return Scaffold(
      appBar: AppBar(title: const Text('Hintergrund des Launchers')),
      body: FocusTraversalGroup(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _choice(
              context,
              title: 'Farbverläufe',
              subtitle: 'Mitgelieferte Farbverläufe (Nordlicht, Abendrot, Ozean, …) - ohne Internet.',
              selected: _source == LauncherBackgroundSource.builtin,
              autofocus: true,
              onTap: () => setState(() => _source = LauncherBackgroundSource.builtin),
            ),
            _choice(
              context,
              title: 'Landschaftsfotos aus dem Internet',
              subtitle: 'Landschafts- und Naturfotos - die Bing-Bilder des Tages der letzten zwei Wochen, '
                  'abwechselnd. Ort und Fotograf stehen klein rechts oben.',
              selected: _source == LauncherBackgroundSource.photos,
              onTap: () => setState(() => _source = LauncherBackgroundSource.photos),
            ),
            _choice(
              context,
              title: 'Eigener Server',
              subtitle: 'Bilder von einem Server im eigenen Netz, z. B. ein Ordner mit Hintergrundbildern auf dem NAS.',
              selected: _source == LauncherBackgroundSource.server,
              onTap: () => setState(() => _source = LauncherBackgroundSource.server),
            ),
            if (_source == LauncherBackgroundSource.server) ...[
              const SizedBox(height: 12),
              PopupTextField(
                controller: _url,
                keyboardType: TextInputType.url,
                label: 'Adresse (URL)',
                hint: 'http://nas.local/wallpapers/',
                onSubmitted: (_) => setState(() => _testResult = null),
              ),
              const SizedBox(height: 8),
              const Text(
                'Die Adresse darf liefern:\n'
                '• ein Bild (z. B. ein Skript, das jedes Mal ein anderes Bild schickt),\n'
                '• eine JSON-Liste von Bild-Adressen: ["bild1.jpg", "bild2.jpg"] oder {"images": [...]},\n'
                '• eine Seite mit Links auf Bilder - z. B. die Ordneransicht von nginx, Apache oder '
                '„python -m http.server“ in einem Bilderordner.\n'
                'Davon wird jedes Mal ein zufälliges Bild genommen.',
                style: help,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _testing || !_urlValid ? null : _test,
                    icon: const Icon(Icons.network_check),
                    label: const Text('Testen'),
                  ),
                  const SizedBox(width: 12),
                  if (_testing) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  if (_testResult != null) Expanded(child: Text(_testResult!, style: help)),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Text('Band hinter den Favoriten', style: Theme.of(context).textTheme.titleMedium),
            const Text('Wie stark das Band das Bild abdeckt - wirkt sofort.', style: help),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final opacity in SettingsRepository.launcherBandOpacities)
                  ChoiceChip(
                    label: Text(opacity == 0 ? 'Keines' : '${(opacity * 100).round()} %'),
                    selected: (ref.watch(launcherSettingsProvider).bandOpacity - opacity).abs() < 0.01,
                    onSelected: (_) => ref.read(launcherSettingsProvider.notifier).setBandOpacity(opacity),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Neues Bild alle', style: Theme.of(context).textTheme.titleMedium),
            Wrap(
              spacing: 8,
              children: [
                for (final minutes in SettingsRepository.launcherBackgroundIntervals)
                  ChoiceChip(
                    label: Text(minutes == 60 ? '1 Stunde' : '$minutes Min.'),
                    selected: _interval == minutes,
                    onSelected: (_) => setState(() => _interval = minutes),
                  ),
              ],
            ),
            if (_source == LauncherBackgroundSource.builtin) ...[
              const SizedBox(height: 20),
              SizedBox(
                height: 90,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final b in builtinBackdrops)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(width: 112, height: 63, child: BuiltinBackdrop(backdrop: b)),
                            ),
                            const SizedBox(height: 4),
                            Text(b.name, style: help),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Speichern')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks the icon pack for app tiles (or none).
Future<void> chooseIconPack(BuildContext context, WidgetRef ref) async {
  ref.invalidate(iconPacksProvider);
  final packs = await ref.read(iconPacksProvider.future);
  if (!context.mounted) return;
  final current = ref.read(launcherSettingsProvider).iconPack;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Icon-Paket für die App-Kacheln'),
      children: [
        _choice(
          context,
          title: 'Keines - Original-Logos der Apps',
          selected: current == null,
          autofocus: current == null,
          onTap: () => Navigator.of(context).pop(''),
        ),
        for (final p in packs)
          _choice(
            context,
            title: p.label,
            subtitle: p.package,
            selected: current == p.package,
            autofocus: current == p.package,
            onTap: () => Navigator.of(context).pop(p.package),
          ),
        if (packs.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text(
              'Kein Icon-Paket installiert. Icon-Pakete für Android-Launcher (ADW-/Nova-Format) werden '
              'unterstützt - als App installieren, dann hier auswählen.\n'
              'Einzelne Kacheln bekommen ein eigenes Bild über ☰ auf der Kachel → „Bild ändern“.',
              style: TextStyle(color: Colors.white60),
            ),
          ),
      ],
    ),
  );
  if (choice == null) return;
  await ref.read(launcherSettingsProvider.notifier).setIconPack(choice.isEmpty ? null : choice);
}

/// The Home key: as the device's launcher (Android TV boxes) or via the
/// accessibility service (Fire TV, see HomeButtonService.kt).
class HomeButtonSettingsScreen extends ConsumerStatefulWidget {
  const HomeButtonSettingsScreen({super.key});

  @override
  ConsumerState<HomeButtonSettingsScreen> createState() => _HomeButtonSettingsScreenState();
}

class _HomeButtonSettingsScreenState extends ConsumerState<HomeButtonSettingsScreen> with WidgetsBindingObserver {
  bool _loaded = false;
  bool _fireTv = false;
  bool _defaultHome = false;
  HomeButtonStatus _status = const HomeButtonStatus(serviceEnabled: false, canEnable: false, redirect: true);

  LauncherService get _service => ref.read(launcherServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from the system's settings: show what changed there.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final fireTv = await _service.isFireTv();
    final defaultHome = await _service.isDefaultHome();
    final status = await _service.homeButtonStatus();
    if (!mounted) return;
    setState(() {
      _fireTv = fireTv;
      _defaultHome = defaultHome;
      _status = status;
      _loaded = true;
    });
  }

  /// Switched on, but Android dropped it again (restricted settings).
  bool _blocked = false;

  Future<void> _enable() async {
    final ok = await _service.enableHomeButtonService();
    if (!ok) {
      await _service.openAccessibilitySettings();
      await _refresh();
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await _refresh();
    if (mounted) setState(() => _blocked = !_status.serviceEnabled);
  }

  @override
  Widget build(BuildContext context) {
    const help = TextStyle(color: Colors.white60, fontSize: 14);
    const mono = TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'monospace');
    Widget state(bool ok, String yes, String no) => Row(
          children: [
            Icon(ok ? Icons.check_circle : Icons.error_outline, color: ok ? Theme.of(context).colorScheme.primary : Colors.amber),
            const SizedBox(width: 10),
            Expanded(child: Text(ok ? yes : no, style: const TextStyle(fontSize: 16))),
          ],
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Home-Taste')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : FocusTraversalGroup(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Mit der Home-Taste der Fernbedienung öffnet sich der Launcher von Home Media.',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  if (!_fireTv) ...[
                    state(_defaultHome, 'Home Media ist der Standard-Launcher.', 'Home Media ist noch nicht der Standard-Launcher.'),
                    const SizedBox(height: 8),
                    const Text(
                      'Auf Android-TV-Boxen Home Media als Startbildschirm („Home-App“) wählen. Fragt das Gerät '
                      'beim Drücken der Home-Taste nach, „Home Media“ und „Immer“ wählen.',
                      style: help,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        autofocus: true,
                        onPressed: () async {
                          await _service.openHomeSettings();
                        },
                        icon: const Icon(Icons.home_outlined),
                        label: const Text('Standard-Launcher wählen'),
                      ),
                    ),
                    const Divider(height: 32),
                    const Text(
                      'Lässt das Gerät keinen anderen Launcher zu (z. B. Google TV), hilft der Dienst unten - wie beim Fire TV.',
                      style: help,
                    ),
                    const SizedBox(height: 12),
                  ],
                  state(
                    _status.serviceEnabled,
                    'Dienst „Home Media: Home-Taste“ ist eingeschaltet.',
                    'Dienst „Home Media: Home-Taste“ ist ausgeschaltet.',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _fireTv
                        ? 'Der Fire TV zeigt mit der Home-Taste immer den Amazon-Startbildschirm. Der Dienst (eine '
                            'Bedienungshilfe) holt Home Media dann sofort nach vorne. Er sieht nur, welche App im '
                            'Vordergrund ist - keine Inhalte, keine Tasten und keine Eingaben.'
                        : 'Der Dienst (eine Bedienungshilfe) holt Home Media nach vorne, sobald der Startbildschirm '
                            'des Geräts erscheint. Er sieht nur, welche App im Vordergrund ist.',
                    style: help,
                  ),
                  const SizedBox(height: 12),
                  if (!_status.serviceEnabled)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        autofocus: _fireTv,
                        onPressed: _enable,
                        icon: const Icon(Icons.power_settings_new),
                        label: Text(_status.canEnable ? 'Dienst einschalten' : 'Bedienungshilfen öffnen'),
                      ),
                    ),
                  if (!_status.serviceEnabled && (!_status.canEnable || _blocked)) ...[
                    const SizedBox(height: 12),
                    Text(
                      _blocked
                          ? 'Android hat den Dienst gesperrt („eingeschränkte Einstellungen“ - ab Android 13 bei '
                              'Apps, die nicht aus einem App-Store kommen). Einmalig vom Computer aus per adb erlauben, '
                              'dann noch einmal „Dienst einschalten“:'
                          : 'Dort „Home Media: Home-Taste“ einschalten. Zeigt das Gerät den Dienst nicht an oder ist er '
                              'ausgegraut, einmalig vom Computer aus per adb freischalten - danach schaltet ihn dieser '
                              'Knopf selbst ein:',
                      style: help,
                    ),
                    const SizedBox(height: 6),
                    const SelectableText(
                      'adb shell pm grant at.jaycloud.home.radio android.permission.WRITE_SECURE_SETTINGS\n'
                      'adb shell appops set at.jaycloud.home.radio ACCESS_RESTRICTED_SETTINGS allow',
                      style: mono,
                    ),
                  ],
                  if (_status.serviceEnabled)
                    SwitchListTile(
                      autofocus: _fireTv,
                      title: const Text('Home-Taste öffnet Home Media'),
                      subtitle: const Text('Aus: der Startbildschirm des Geräts bleibt, Home Media öffnet man wie jede App.'),
                      value: _status.redirect,
                      onChanged: (v) async {
                        await _service.setHomeRedirect(v);
                        await _refresh();
                      },
                    ),
                ],
              ),
            ),
    );
  }
}

/// Labels for the settings list.
String startScreenLabel(StartScreen s) => switch (s) {
      StartScreen.launcher => 'Launcher',
      StartScreen.radio => 'Home Radio',
    };
