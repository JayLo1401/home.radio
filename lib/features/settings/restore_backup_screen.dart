import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/nas_providers.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/services/admin_server.dart';
import '../../data/services/backup_service.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';

/// Saves a backup into Download/HomeSystem (Documents/HomeSystem on the PC)
/// and says where it went - Settings → System → "Backup erstellen".
Future<void> createBackupWithFeedback(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final l = context.l10n;
  try {
    final location = await ref.read(backupServiceProvider).createBackup();
    final urls = await AdminServer.urls();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${l.settingsBackupSaved(location)}'
          '${urls.isEmpty ? '' : '\n${l.settingsBackupDownloadAlso(urls.join(' ${l.settingsOr} '))}'}',
        ),
      ),
    );
  } on PlatformException catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          e.code == 'PERMISSION_DENIED' ? l.settingsBackupNoPermission : l.settingsBackupFailed('${e.message}'),
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

  /// The NAS backup folder (Settings → NAS), null if none is set.
  String? _nasFolder;
  List<NasEntry> _nasBackups = const [];
  bool _nasLoading = false;
  String? _nasError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _server.restoreHandler = _restoreFromWeb;
    _reload();
    _reloadNas();
  }

  /// The backups in the NAS backup folder - once when the screen opens
  /// (not on every return to the foreground like the device's).
  Future<void> _reloadNas() async {
    final settings = await ref.read(nasSettingsRepositoryProvider).load();
    final folder = settings.folder(NasFolder.backups);
    if (!mounted) return;
    setState(() {
      _nasFolder = folder;
      _nasLoading = folder != null;
      _nasError = null;
    });
    if (folder == null) return;
    try {
      final backups = await ref.read(nasBackupServiceProvider).listBackups();
      if (!mounted) return;
      setState(() {
        _nasBackups = backups;
        _nasLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nasBackups = const [];
        _nasError = e is NasException ? e.message : '$e';
        _nasLoading = false;
      });
    }
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
            ? context.l10n.settingsRestoreNoPermission
            : context.l10n.settingsRestoreReadFailed('${e.message}');
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
    if (_busy) throw BackupFormatException(l10n.settingsRestoreBusy);
    setState(() => _busy = true);
    try {
      await ref.read(backupServiceProvider).restoreJson(content);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
    _snack(l10n.settingsRestoreFromWebDone);
    // Lets the page's answer go out first.
    Future<void>.delayed(const Duration(milliseconds: 1500), () => ref.read(backupServiceProvider).restartApp());
  }

  Future<bool> _confirmRestore(String what) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.settingsRestoreConfirmTitle),
        content: Text(context.l10n.settingsRestoreConfirmText(what)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.settingsRestoreButton),
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
      _snack(l10n.settingsRestoreDone);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await ref.read(backupServiceProvider).restartApp();
    } on BackupFormatException catch (e) {
      _snack(e.message);
    } on PlatformException catch (e) {
      _snack(
        e.code == 'NO_PICKER' ? l10n.settingsRestoreNoPicker : l10n.settingsRestoreFailed('${e.message}'),
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

  Future<void> _restoreFromNas(NasEntry file) async {
    final l = context.l10n;
    if (!await _confirmRestore(file.name)) return;
    await _runRestore(() async {
      final String content;
      try {
        content = await ref.read(nasBackupServiceProvider).download(file);
      } on NasException catch (e) {
        _snack(l.nasRestoreDownloadFailed(e.message));
        return false;
      }
      await ref.read(backupServiceProvider).restoreJson(content);
      return true;
    });
  }

  Future<void> _restoreFromPicker() async {
    if (!await _confirmRestore(context.l10n.settingsRestorePickedFile)) return;
    await _runRestore(() => ref.read(backupServiceProvider).restoreFromPicker());
  }

  Future<void> _requestAllFilesAccess() async {
    final opened = await ref.read(backupServiceProvider).requestAllFilesAccess();
    if (!opened) {
      _snack(l10n.settingsRestoreNoAllFilesSetting);
    }
  }

  String _formatDate(DateTime t) {
    final locale = context.l10n.localeName;
    if (locale != 'de') return DateFormat.yMd(locale).add_Hm().format(t);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year}, ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleLarge;
    const hintStyle = TextStyle(color: Colors.white54, fontSize: 13);
    final primary = Theme.of(context).colorScheme.primary;
    final l = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsBackupRestore)),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l.settingsRestoreViaAdmin, style: titleStyle),
            const SizedBox(height: 8),
            if (_loading)
              const SizedBox.shrink()
            else if (_urls.isEmpty)
              Text(l.settingsRestoreNoNetwork, style: hintStyle)
            else ...[
              Text(
                l.settingsRestoreOpenInBrowser,
                style: const TextStyle(fontSize: 16),
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
                  child: Text(l.settingsRestoreHostname(_hostname!), style: const TextStyle(fontSize: 16)),
                ),
              const SizedBox(height: 6),
              Text(l.settingsRestoreAdminHint, style: hintStyle),
            ],
            if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            const Divider(height: 32),
            Text(l.settingsRestoreOnDevice, style: titleStyle),
            const SizedBox(height: 4),
            Text(
              l.settingsRestoreOnDeviceHint(Platform.isAndroid ? 'Download' : l.settingsRestoreFolderDocuments),
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
              Text(l.settingsRestoreNone, style: hintStyle)
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
              Text(l.settingsRestoreAllFilesHint, style: hintStyle),
              const SizedBox(height: 8),
              ActionTile(
                icon: Icons.folder_open,
                label: l.settingsRestoreAllowAllFiles,
                autofocus: _backups.isEmpty,
                onTap: _requestAllFilesAccess,
              ),
            ],
            const SizedBox(height: 8),
            ActionTile(
              icon: Icons.file_open_outlined,
              label: l.settingsRestorePickFile,
              autofocus: _backups.isEmpty && !_canRequestAllFilesAccess,
              onTap: _restoreFromPicker,
            ),
            if (_nasFolder != null) ...[
              const Divider(height: 32),
              Text(context.l10n.nasRestoreSection, style: titleStyle),
              const SizedBox(height: 4),
              Text(context.l10n.nasRestoreHint(_nasFolder!), style: hintStyle),
              const SizedBox(height: 8),
              if (_nasLoading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_nasError != null)
                Text(context.l10n.nasRestoreLoadFailed(_nasError!), style: hintStyle)
              else if (_nasBackups.isEmpty)
                Text(context.l10n.nasRestoreNone, style: hintStyle)
              else
                for (final b in _nasBackups)
                  ActionTile(
                    icon: Icons.cloud_download_outlined,
                    label: b.modified == null ? b.name : _formatDate(b.modified!.toLocal()),
                    subtitle: b.modified == null ? null : b.name,
                    onTap: () => _restoreFromNas(b),
                  ),
            ],
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
