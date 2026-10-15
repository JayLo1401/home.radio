import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/services/backup_service.dart';

/// Create a backup into Download/HomeRadio or restore one (see
/// BackupService). The backup list is reloaded whenever the app comes back
/// to the foreground, so it picks up "All files access" right after the user
/// granted it in the system settings.
class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  ConsumerState<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends ConsumerState<BackupSettingsScreen> with WidgetsBindingObserver {
  List<BackupFile> _backups = const [];
  bool _canRequestAllFilesAccess = false;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _reload();
  }

  Future<void> _reload() async {
    final service = ref.read(backupServiceProvider);
    try {
      final backups = await service.listBackups();
      final canRequest = await service.canRequestAllFilesAccess();
      if (!mounted) return;
      setState(() {
        _backups = backups;
        _canRequestAllFilesAccess = canRequest;
        _loadError = null;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _backups = const [];
        _loadError = e.code == 'PERMISSION_DENIED'
            ? 'Ohne Speicher-Berechtigung können keine Backups gelesen werden.'
            : 'Backups konnten nicht gelesen werden (${e.message}).';
        _loading = false;
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createBackup() async {
    setState(() => _busy = true);
    try {
      final location = await ref.read(backupServiceProvider).createBackup();
      _snack('Backup gespeichert: $location');
    } on PlatformException catch (e) {
      _snack(e.code == 'PERMISSION_DENIED'
          ? 'Ohne Speicher-Berechtigung kann kein Backup gespeichert werden.'
          : 'Backup fehlgeschlagen: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  Future<bool> _confirmRestore(String what) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backup wiederherstellen?'),
        content: Text(
          '$what\n\nAlle aktuellen Favoriten, DAB+ Sender und Einstellungen werden ersetzt. '
          'Danach startet die App neu.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Wiederherstellen'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _runRestore(Future<bool> Function() restore) async {
    setState(() => _busy = true);
    try {
      if (!await restore()) return;
      _snack('Backup wiederhergestellt - App startet neu …');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await ref.read(backupServiceProvider).restartApp();
    } on BackupFormatException catch (e) {
      _snack(e.message);
    } on PlatformException catch (e) {
      _snack(e.code == 'NO_PICKER'
          ? 'Dieses Gerät hat keine Dateiauswahl. Bitte stattdessen „Zugriff auf alle Dateien“ erlauben.'
          : 'Wiederherstellen fehlgeschlagen: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(BackupFile file) async {
    if (!await _confirmRestore(file.name)) return;
    await _runRestore(() async {
      await ref.read(backupServiceProvider).restore(file);
      return true;
    });
  }

  Future<void> _restoreFromPicker() async {
    if (!await _confirmRestore('Die ausgewählte Datei wird eingespielt.')) return;
    await _runRestore(() => ref.read(backupServiceProvider).restoreFromPicker());
  }

  Future<void> _requestAllFilesAccess() async {
    final opened = await ref.read(backupServiceProvider).requestAllFilesAccess();
    if (!opened) {
      _snack('Dieses Gerät bietet die Einstellung „Zugriff auf alle Dateien“ nicht an.');
    }
  }

  String _formatDate(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year}, ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleLarge;
    const hintStyle = TextStyle(color: Colors.white54, fontSize: 13);

    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Wiederherstellung')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Backups enthalten Favoriten, DAB+ Senderliste und alle Einstellungen (inkl. Zugangsdaten). '
              'Sie werden im Ordner „Download/HomeRadio“ gespeichert und bleiben auch erhalten, '
              'wenn die App deinstalliert wird.',
              style: hintStyle,
            ),
            const SizedBox(height: 12),
            _ActionTile(
              icon: Icons.save_outlined,
              label: 'Jetzt Backup erstellen',
              autofocus: true,
              onTap: _createBackup,
            ),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            const Divider(height: 32),
            Text('Wiederherstellen', style: titleStyle),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            else if (_loadError != null)
              Text(_loadError!, style: hintStyle)
            else if (_backups.isEmpty)
              const Text('Keine Backups gefunden.', style: hintStyle)
            else
              for (final b in _backups)
                _ActionTile(
                  icon: Icons.restore,
                  label: _formatDate(b.modified),
                  subtitle: b.name,
                  onTap: () => _restore(b),
                ),
            if (_canRequestAllFilesAccess) ...[
              const SizedBox(height: 16),
              const Text(
                'Backups von einer früheren Installation der App sind erst sichtbar, wenn der '
                '„Zugriff auf alle Dateien“ erlaubt wurde. Alternativ die Datei direkt auswählen.',
                style: hintStyle,
              ),
              const SizedBox(height: 8),
              _ActionTile(
                icon: Icons.folder_open,
                label: 'Zugriff auf alle Dateien erlauben',
                onTap: _requestAllFilesAccess,
              ),
            ],
            const SizedBox(height: 8),
            _ActionTile(
              icon: Icons.file_open_outlined,
              label: 'Backup-Datei auswählen … (z. B. vom USB-Stick)',
              onTap: _restoreFromPicker,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool autofocus;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.autofocus = false,
  });

  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.subtitle;
    return TvFocusHighlight(
      focused: _focused,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        focusColor: Colors.transparent,
        hoverColor: Colors.white.withValues(alpha: 0.04),
        autofocus: widget.autofocus,
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(widget.icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.label, style: const TextStyle(fontSize: 16, color: Colors.white)),
                    if (subtitle != null)
                      Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
