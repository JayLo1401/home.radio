import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/system_providers.dart';
import '../../core/theme.dart';
import '../../data/models/launcher_tile.dart' show StartScreen;
import '../../data/services/admin_server.dart';
import '../../data/services/launcher_service.dart';
import '../launcher/launcher_providers.dart';
import '../settings/launcher_settings_screens.dart' show HomeButtonSettingsScreen;
import '../settings/restore_backup_screen.dart';

/// Suggestions for the device's name - picked with the remote, no typing.
const deviceNameSuggestions = ['Terrassen-Media', 'Wohnzimmer-TV', 'Schlafzimmer-TV', 'Küchen-Tablet'];

enum _Step { welcome, name, homeKey, done }

/// First start without any settings: restore a backup (on the device or via
/// the admin page) or set up anew - device name, the Home key (optional,
/// Android only), and Home as what shows on start. [onFinished] then opens
/// the app as usual; a restored backup restarts the app by itself.
class SetupWizardScreen extends ConsumerStatefulWidget {
  const SetupWizardScreen({super.key, required this.onFinished});

  /// Gets the wizard's ref (the screen that opened it is gone by then).
  final void Function(WidgetRef ref) onFinished;

  @override
  ConsumerState<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends ConsumerState<SetupWizardScreen> {
  _Step _step = _Step.welcome;
  final _name = TextEditingController();
  final _nextFocus = FocusNode(debugLabel: 'weiter');
  String? _url;

  @override
  void initState() {
    super.initState();
    // By IP and, if the network knows it, by host name.
    AdminServer.urls().then((u) {
      if (mounted) setState(() => _url = u.isEmpty ? null : u.join(' oder '));
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _nextFocus.dispose();
    super.dispose();
  }

  List<_Step> get _steps => [_Step.welcome, _Step.name, if (LauncherService.supported) _Step.homeKey, _Step.done];

  void _go(int direction) {
    final i = (_steps.indexOf(_step) + direction).clamp(0, _steps.length - 1);
    setState(() => _step = _steps[i]);
  }

  Future<void> _finish() async {
    final repo = ref.read(settingsRepositoryProvider);
    await ref.read(deviceNameProvider.notifier).set(_name.text);
    await ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.launcher);
    await repo.setSetupDone();
    if (mounted) widget.onFinished(ref);
  }

  @override
  Widget build(BuildContext context) {
    final index = _steps.indexOf(_step);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && index > 0) _go(-1);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF05070A),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset('assets/icon/home_system_logo.png', width: 56, height: 56),
                        ),
                        const SizedBox(width: 16),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Home System einrichten',
                              style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Powered by jaycloud.at',
                              style: TextStyle(color: Colors.green, fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (index > 0)
                          Text(
                            'Schritt $index von ${_steps.length - 1}',
                            style: const TextStyle(color: Colors.white54, fontSize: 15),
                          ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Expanded(
                      child: FocusTraversalGroup(
                        // A new step's widgets - autofocus picks them up.
                        key: ValueKey(_step),
                        child: SingleChildScrollView(child: _content()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    const lead = TextStyle(color: Colors.white, fontSize: 20);
    const hint = TextStyle(color: Colors.white60, fontSize: 15);
    switch (_step) {
      case _Step.welcome:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Willkommen! Gibt es schon ein Backup von Home System?', style: lead),
            const SizedBox(height: 16),
            ActionTile(
              icon: Icons.restore,
              label: 'Backup wiederherstellen',
              subtitle:
                  'Von diesem Gerät, vom USB-Stick oder über die Verwaltungsseite'
                  '${_url == null ? '' : ' ($_url)'}',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RestoreBackupScreen())),
            ),
            ActionTile(icon: Icons.add_circle_outline, label: 'Neu einrichten', autofocus: true, onTap: () => _go(1)),
          ],
        );
      case _Step.name:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Wie soll dieses Gerät heißen?', style: lead),
            const SizedBox(height: 4),
            const Text(
              'Ein eindeutiger Name, damit man die Geräte unterscheiden kann - auf der Verwaltungsseite und bei Backups.',
              style: hint,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (i, s) in deviceNameSuggestions.indexed)
                  _ChoiceChip(
                    label: s,
                    autofocus: i == 0 && _name.text.isEmpty,
                    selected: _name.text == s,
                    onTap: () {
                      setState(() => _name.text = s);
                      // Straight on to "Weiter" - past the text field.
                      WidgetsBinding.instance.addPostFrameCallback((_) => _nextFocus.requestFocus());
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 480,
              child: TextField(
                controller: _name,
                textInputAction: TextInputAction.done,
                style: const TextStyle(fontSize: 18),
                decoration: const InputDecoration(labelText: 'Oder eigener Name', border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) _go(1);
                },
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                OutlinedButton(onPressed: () => _go(-1), child: const Text('Zurück')),
                const SizedBox(width: 12),
                FilledButton(
                  focusNode: _nextFocus,
                  autofocus: _name.text.isNotEmpty,
                  onPressed: _name.text.trim().isEmpty ? null : () => _go(1),
                  child: const Text('Weiter'),
                ),
              ],
            ),
          ],
        );
      case _Step.homeKey:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Home-Taste der Fernbedienung (freiwillig)', style: lead),
            const SizedBox(height: 4),
            const Text(
              'Wer möchte, dass die Home-Taste der Fernbedienung Home System öffnet, richtet das hier ein - Home System '
              'wird dafür Standard-Launcher, oder eine Bedienungshilfe wird eingeschaltet. Wer das nicht will, geht '
              'einfach weiter; es lässt sich jederzeit unter Einstellungen → System → Home-Taste nachholen.',
              style: hint,
            ),
            const SizedBox(height: 16),
            ActionTile(
              icon: Icons.home_outlined,
              label: 'Home-Taste einrichten',
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HomeButtonSettingsScreen())),
            ),
            ActionTile(
              icon: Icons.skip_next_outlined,
              label: 'Weiter (ohne bzw. nach dem Einrichten)',
              autofocus: true,
              onTap: () => _go(1),
            ),
          ],
        );
      case _Step.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fertig - „${_name.text.trim()}“ ist eingerichtet.', style: lead),
            const SizedBox(height: 8),
            const Text(
              'Home System startet mit Home: Radio, TV und die Apps als Kacheln. Weiteres (Radio-Empfänger, '
              'Sat-Receiver, Hintergrund …) unter Einstellungen.',
              style: hint,
            ),
            if (_url != null) ...[
              const SizedBox(height: 8),
              Text('Backups gibt es jederzeit auf der Verwaltungsseite: $_url', style: hint),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                OutlinedButton(onPressed: () => _go(-1), child: const Text('Zurück')),
                const SizedBox(width: 12),
                FilledButton(autofocus: true, onPressed: _finish, child: const Text('Los geht\'s')),
              ],
            ),
          ],
        );
    }
  }
}

class _ChoiceChip extends StatefulWidget {
  const _ChoiceChip({required this.label, required this.selected, required this.onTap, this.autofocus = false});

  final String label;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  State<_ChoiceChip> createState() => _ChoiceChipState();
}

class _ChoiceChipState extends State<_ChoiceChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return TvFocusHighlight(
      focused: _focused,
      child: InkWell(
        autofocus: widget.autofocus,
        borderRadius: BorderRadius.circular(10),
        focusColor: Colors.transparent,
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: widget.selected ? primary : Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.selected) ...[Icon(Icons.check, color: primary, size: 20), const SizedBox(width: 8)],
              Text(widget.label, style: const TextStyle(fontSize: 17, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}
