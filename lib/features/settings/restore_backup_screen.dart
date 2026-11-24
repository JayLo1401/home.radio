import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/services/admin_server.dart';
import '../../data/services/backup_service.dart';

/// Saves a backup into Download/HomeSystem (Documents/HomeSystem on the PC)
/// and says where it went - Settings → System → "Backup erstellen".
Future<void> createBackupWithFeedback(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final location = await ref.read(backupServiceProvider).createBackup();
    final urls = await AdminServer.urls();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Backup gespeichert: $location${urls.isEmpty ? '' : '\nZum Herunterladen auch unter ${urls.join(' oder ')}'}',
        ),
      ),
    );
  } on PlatformException catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          e.code == 'PERMISSION_DENIED'
              ? 'Ohne Speicher-Berechtigung kann kein Backup gespeichert werden.'
              : 'Backup fehlgeschlagen: ${e.message}',
        ),
      ),
    );
  }
}

/// "Backup wiederherstellen": while this screen is open, the admin page
/// (`http://<ip>:1401/`) accepts an uploaded backup; the backups on the
/// device itself are listed below. Reached from Settings → System and from
/// the setup wizard. The backup list is reloaded whenever the app comes back
/// to the foreground, so it picks up "All files access" right after the user
/// granted it in the system settings.
class RestoreBackupScreen extends ConsumerStatefulWidget {
  const RestoreBackupScreen({super.key});

  @override
  ConsumerState<RestoreBackupScreen> createState() => _RestoreBackupScreenState();
}

class _RestoreBackupScreenState extends ConsumerState<RestoreBackupScreen> with WidgetsBindingObserver {
  List<BackupFile> _backups = const [];
  List<String> _urls = const [];
  String? _hostname;
  bool _canRequestAllFilesAccess = false;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  late final AdminServer _server = ref.read(adminServerProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _server.restoreHandler = _restoreFromWeb;
    _reload();
  }

  @override
  void dispose() {
    if (_server.restoreHandler == _restoreFromWeb) _server.restoreHandler = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _reload();
  }

  Future<void> _reload() async {
    final service = ref.read(backupServiceProvider);
    final urls = await AdminServer.urls();
    final hostname = await AdminServer.hostname();
    if (mounted) setState(() => _hostname = hostname);
    try {
      final backups = await service.listBackups();
      final canRequest = await service.canRequestAllFilesAccess();
      if (!mounted) return;
      setState(() {
        _urls = urls;
        _backups = backups;
        _canRequestAllFilesAccess = canRequest;
        _loadError = null;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _urls = urls;
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

  /// An upload from the admin page - the confirmation happened there.
  Future<void> _restoreFromWeb(String content) async {
    if (_busy) throw const BackupFormatException('Das Gerät spielt gerade schon ein Backup ein.');
    setState(() => _busy = true);
    try {
      await ref.read(backupServiceProvider).restoreJson(content);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
    _snack('Backup von der Verwaltungsseite eingespielt - App startet neu …');
    // Lets the page's answer go out first.
    Future<void>.delayed(const Duration(milliseconds: 1500), () => ref.read(backupServiceProvider).restartApp());
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
      _snack(
        e.code == 'NO_PICKER'
            ? 'Dieses Gerät hat keine Dateiauswahl. Bitte stattdessen „Zugriff auf alle Dateien“ erlauben.'
            : 'Wiederherstellen fehlgeschlagen: ${e.message}',
      );
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
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(title: const Text('Backup wiederherstellen')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Über die Verwaltungsseite', style: titleStyle),
            const SizedBox(height: 8),
            if (_loading)
              const SizedBox.shrink()
            else if (_urls.isEmpty)
              const Text('Keine Netzwerkverbindung - die Verwaltungsseite ist nicht erreichbar.', style: hintStyle)
            else ...[
              const Text(
                'Auf einem Computer oder Handy im selben Netz im Browser öffnen:',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 6),
              for (final u in _urls)
                Text(
                  u,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: primary),
                ),
              if (_hostname != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Hostname dieses Geräts: $_hostname', style: const TextStyle(fontSize: 16)),
                ),
              const SizedBox(height: 6),
              const Text(
                'Dort die Backup-Datei auswählen und einspielen. Solange diese Seite hier offen ist, nimmt das Gerät '
                'ein Backup an. Danach startet die App neu.',
                style: hintStyle,
              ),
            ],
            if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            const Divider(height: 32),
            Text('Backups auf diesem Gerät', style: titleStyle),
            const SizedBox(height: 4),
            Text(
              'Aus dem Ordner „${Platform.isAndroid ? 'Download' : 'Dokumente'}/HomeSystem“ (und HomeRadio der früheren App).',
              style: hintStyle,
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadError != null)
              Text(_loadError!, style: hintStyle)
            else if (_backups.isEmpty)
              const Text('Keine Backups gefunden.', style: hintStyle)
            else
              for (final (i, b) in _backups.indexed)
                ActionTile(
                  icon: Icons.restore,
                  label: _formatDate(b.modified),
                  subtitle: b.name,
                  autofocus: i == 0,
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
              ActionTile(
                icon: Icons.folder_open,
                label: 'Zugriff auf alle Dateien erlauben',
                autofocus: _backups.isEmpty,
                onTap: _requestAllFilesAccess,
              ),
            ],
            const SizedBox(height: 8),
            ActionTile(
              icon: Icons.file_open_outlined,
              label: 'Backup-Datei auswählen … (z. B. vom USB-Stick)',
              autofocus: _backups.isEmpty && !_canRequestAllFilesAccess,
              onTap: _restoreFromPicker,
            ),
          ],
        ),
      ),
    );
  }
}

/// A focusable row with an icon (and optional second line) that runs
/// [onTap] - used by the backup screens and the setup wizard.
class ActionTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool autofocus;
  final VoidCallback onTap;

  const ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.autofocus = false,
  });

  @override
  State<ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<ActionTile> {
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
                    if (subtitle != null) Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white54)),
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
