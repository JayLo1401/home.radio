import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/update_service.dart';

/// Downloads and installs [update] behind a progress dialog. On Windows/
/// Linux the app quits when the installer takes over; on Android the
/// system's "Update?" confirmation follows. Errors end up in a SnackBar.
Future<void> installUpdate(BuildContext context, WidgetRef ref, AvailableUpdate update) async {
  final progress = ValueNotifier<double?>(null);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: Text('Update auf ${update.version}'),
      content: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (_, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value == null ? 'Wird geladen…' : 'Wird geladen… ${(value * 100).round()} %'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value),
          ],
        ),
      ),
    ),
  );
  try {
    await ref.read(updateServiceProvider).install(update, onProgress: (v) => progress.value = v);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Update fehlgeschlagen: $e')));
  } finally {
    navigator.pop();
    progress.dispose();
  }
}

/// Settings → Weiteres → Updates: installed version, automatic updates on
/// start, check by hand.
class UpdateSettingsScreen extends ConsumerStatefulWidget {
  const UpdateSettingsScreen({super.key});

  @override
  ConsumerState<UpdateSettingsScreen> createState() => _UpdateSettingsScreenState();
}

class _UpdateSettingsScreenState extends ConsumerState<UpdateSettingsScreen> {
  String? _version;
  bool _auto = true;
  bool _checking = false;
  bool _checked = false;
  AvailableUpdate? _update;

  @override
  void initState() {
    super.initState();
    () async {
      final version = await ref.read(updateServiceProvider).currentVersion();
      final auto = await ref.read(settingsRepositoryProvider).getAutoUpdate();
      if (mounted) {
        setState(() {
          _version = version;
          _auto = auto;
        });
      }
      await _check();
    }();
  }

  Future<void> _check() async {
    if (!UpdateService.supported) return;
    setState(() => _checking = true);
    final update = await ref.read(updateServiceProvider).check();
    if (!mounted) return;
    setState(() {
      _update = update;
      _checking = false;
      _checked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    const hint = TextStyle(color: Colors.white54);
    final update = _update;
    return Scaffold(
      appBar: AppBar(title: const Text('Updates')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Installierte Version: ${_version ?? '…'}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          if (!UpdateService.supported)
            const Text('Diese Version wurde lokal gebaut und aktualisiert sich nicht selbst.', style: hint)
          else ...[
            SwitchListTile(
              autofocus: true,
              title: const Text('Beim Start automatisch aktualisieren'),
              subtitle: const Text('Neue Versionen werden beim Start geladen und installiert.', style: hint),
              value: _auto,
              onChanged: (v) {
                setState(() => _auto = v);
                ref.read(settingsRepositoryProvider).setAutoUpdate(v);
              },
            ),
            const SizedBox(height: 16),
            if (_checking)
              const Row(
                children: [
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Suche nach Updates…'),
                ],
              )
            else if (update != null)
              Row(
                children: [
                  Expanded(child: Text('Neue Version ${update.version} verfügbar.')),
                  FilledButton.icon(
                    onPressed: () => installUpdate(context, ref, update),
                    icon: const Icon(Icons.system_update),
                    label: const Text('Jetzt aktualisieren'),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(_checked ? 'Die App ist aktuell (oder der Update-Server ist nicht erreichbar).' : ''),
                  ),
                  OutlinedButton.icon(
                    onPressed: _check,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Erneut suchen'),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
