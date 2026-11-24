import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/system_providers.dart';
import '../../core/theme.dart';
import '../../data/models/launcher_tile.dart' show StartScreen;
import '../../data/services/admin_server.dart';
import '../../data/services/launcher_service.dart';
import '../../data/services/permissions_service.dart' show PermissionEntry;
import '../../l10n/l10n.dart';
import '../launcher/launcher_providers.dart';
import '../settings/language_picker.dart';
import '../settings/restore_backup_screen.dart';
import 'permissions_screen.dart';

/// Suggestions for the device's name - picked with the remote, no typing.
List<String> deviceNameSuggestions(AppLocalizations l) => [
      l.settingsDeviceNameSuggestionTerrace,
      l.settingsDeviceNameSuggestionLivingRoom,
      l.settingsDeviceNameSuggestionBedroom,
      l.settingsDeviceNameSuggestionKitchen,
    ];

enum _Step { welcome, name, permissions, done }

/// First start without any settings: restore a backup (on the device or via
/// the admin page) or set up anew - device name, the permissions one by one
/// with what they're for (all optional, Android only; the Home key is the
/// first of them), and Home as what shows on start. [onFinished] then opens
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
  // The admin page's addresses (by IP and, if known, by host name).
  List<String> _urls = const [];
  // The permission shown (index into wizardPermissions - an allowed one
  // drops out of it, so the next one moves up).
  int _permission = 0;

  @override
  void initState() {
    super.initState();
    AdminServer.urls().then((u) {
      if (mounted) setState(() => _urls = u);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _nextFocus.dispose();
    super.dispose();
  }

  List<_Step> get _steps => [_Step.welcome, _Step.name, if (LauncherService.supported) _Step.permissions, _Step.done];

  void _go(int direction) {
    final i = (_steps.indexOf(_step) + direction).clamp(0, _steps.length - 1);
    setState(() => _step = _steps[i]);
  }

  List<PermissionEntry>? _permissions({bool watch = false}) {
    final provider = permissionEntriesProvider;
    final state = watch ? ref.watch(provider).value : ref.read(provider).value;
    return state == null ? null : wizardPermissions(state);
  }

  /// Back on the permissions step: the previous permission, before the
  /// first one the previous step.
  void _back() {
    final count = _permissions()?.length ?? 0;
    if (_step == _Step.permissions && _permission.clamp(0, count) > 0) {
      setState(() => _permission = _permission.clamp(0, count) - 1);
    } else {
      _go(-1);
    }
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
        if (!didPop && index > 0) _back();
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
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.settingsWizardTitle,
                              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                            ),
                            const Text(
                              'Powered by jaycloud.at',
                              style: TextStyle(color: Colors.green, fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (index > 0)
                          Text(
                            context.l10n.settingsWizardStep(index, _steps.length - 1),
                            style: const TextStyle(color: Colors.white54, fontSize: 15),
                          ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Expanded(
                      child: FocusTraversalGroup(
                        // A new step's (permission's) widgets - autofocus
                        // picks them up.
                        key: ValueKey(_pageKey),
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

  Object get _pageKey {
    if (_step != _Step.permissions) return _step;
    final list = _permissions(watch: true);
    final i = _permission.clamp(0, list?.length ?? 0);
    return (_step, i, list == null || i >= list.length ? null : list[i].kind);
  }

  Widget _content() {
    final l = context.l10n;
    final url = _urls.isEmpty ? null : _urls.join(' ${l.settingsOr} ');
    const lead = TextStyle(color: Colors.white, fontSize: 20);
    const hint = TextStyle(color: Colors.white60, fontSize: 15);
    switch (_step) {
      case _Step.welcome:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.settingsWizardWelcome, style: lead),
            const SizedBox(height: 16),
            ActionTile(
              icon: Icons.restore,
              label: l.settingsBackupRestore,
              subtitle: url == null ? l.settingsWizardRestoreHint : l.settingsWizardRestoreHintUrl(url),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RestoreBackupScreen())),
            ),
            ActionTile(icon: Icons.add_circle_outline, label: l.settingsWizardNew, autofocus: true, onTap: () => _go(1)),
            const SizedBox(height: 16),
            // Takes effect at once - this page then reads in the new language.
            ActionTile(
              icon: Icons.translate,
              label: l.settingsWizardLanguage(languageLabel(l, ref.watch(languageProvider))),
              onTap: () => pickLanguage(context, ref),
            ),
          ],
        );
      case _Step.name:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.settingsWizardNameQuestion, style: lead),
            const SizedBox(height: 4),
            Text(l.settingsWizardNameHint, style: hint),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (i, s) in deviceNameSuggestions(l).indexed)
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
                decoration: InputDecoration(labelText: l.settingsWizardNameOwn, border: const OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) _go(1);
                },
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                OutlinedButton(onPressed: () => _go(-1), child: Text(l.commonBack)),
                const SizedBox(width: 12),
                FilledButton(
                  focusNode: _nextFocus,
                  autofocus: _name.text.isNotEmpty,
                  onPressed: _name.text.trim().isEmpty ? null : () => _go(1),
                  child: Text(l.settingsWizardNext),
                ),
              ],
            ),
          ],
        );
      case _Step.permissions:
        return PermissionsAutoRefresh(child: _permissionsPage(lead, hint));
      case _Step.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.settingsWizardDone(_name.text.trim()), style: lead),
            const SizedBox(height: 8),
            Text(l.settingsWizardDoneHint, style: hint),
            if (url != null) ...[
              const SizedBox(height: 8),
              Text(l.settingsWizardDoneBackups(url), style: hint),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                OutlinedButton(onPressed: () => _go(-1), child: Text(l.commonBack)),
                const SizedBox(width: 12),
                FilledButton(autofocus: true, onPressed: _finish, child: Text(l.settingsWizardStart)),
              ],
            ),
          ],
        );
    }
  }

  /// One permission at a time: why it's needed, "Erlauben" and "Später" -
  /// then "that's it" with "Weiter".
  Widget _permissionsPage(TextStyle lead, TextStyle hint) {
    final l = context.l10n;
    final state = ref.watch(permissionEntriesProvider).value;
    if (state == null) return const Center(child: CircularProgressIndicator());
    final list = wizardPermissions(state);
    final i = _permission.clamp(0, list.length);
    if (i >= list.length) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.permissionsWizardNoneLeft, style: lead),
          const SizedBox(height: 4),
          Text(l.permissionsWizardNoneLeftHint, style: hint),
          const SizedBox(height: 24),
          Row(
            children: [
              OutlinedButton(onPressed: _back, child: Text(l.commonBack)),
              const SizedBox(width: 12),
              FilledButton(autofocus: true, onPressed: () => _go(1), child: Text(l.settingsWizardNext)),
            ],
          ),
        ],
      );
    }
    final entry = list[i];
    final action = permissionActionLabel(l, entry);
    void next() => setState(() => _permission = i + 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.permissionsWizardTitle, style: lead),
        const SizedBox(height: 4),
        Text(l.permissionsWizardHint, style: hint),
        const SizedBox(height: 16),
        Text(l.permissionsWizardCounter(i + 1, list.length), style: const TextStyle(color: Colors.white54, fontSize: 15)),
        const SizedBox(height: 8),
        PermissionCard(entry: entry, state: state, large: true),
        const SizedBox(height: 24),
        Row(
          children: [
            OutlinedButton(onPressed: _back, child: Text(l.commonBack)),
            const SizedBox(width: 12),
            if (action == null)
              FilledButton(autofocus: true, onPressed: next, child: Text(l.settingsWizardNext))
            else ...[
              OutlinedButton(onPressed: next, child: Text(l.permissionsLater)),
              const SizedBox(width: 12),
              FilledButton(
                autofocus: true,
                onPressed: () => askPermission(context, ref, entry),
                child: Text(action),
              ),
            ],
          ],
        ),
      ],
    );
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
