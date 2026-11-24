import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nas_providers.dart';
import '../../core/popup_text_field.dart';
import '../../data/repositories/nas_settings_repository.dart';
import '../../data/services/nas_backup_service.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';

String nasFolderLabel(BuildContext context, NasFolder kind) => switch (kind) {
      NasFolder.backgrounds => context.l10n.nasFolderBackgrounds,
      NasFolder.pictures => context.l10n.nasFolderPictures,
      NasFolder.music => context.l10n.nasFolderMusic,
      NasFolder.videos => context.l10n.nasFolderVideos,
      NasFolder.movies => context.l10n.nasFolderMovies,
      NasFolder.backups => context.l10n.nasFolderBackups,
    };

IconData _folderIcon(NasFolder kind) => switch (kind) {
      NasFolder.backgrounds => Icons.wallpaper,
      NasFolder.pictures => Icons.photo_library_outlined,
      NasFolder.music => Icons.library_music_outlined,
      NasFolder.videos => Icons.video_library_outlined,
      NasFolder.movies => Icons.movie_outlined,
      NasFolder.backups => Icons.settings_backup_restore,
    };

/// Settings → System → NAS: the home NAS (WebDAV or FTP) - address, login,
/// and the folders for pictures, music, videos, movies and backups. Every
/// change is saved right away.
class NasSettingsScreen extends ConsumerStatefulWidget {
  const NasSettingsScreen({super.key});

  @override
  ConsumerState<NasSettingsScreen> createState() => _NasSettingsScreenState();
}

class _NasSettingsScreenState extends ConsumerState<NasSettingsScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _basePath = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  NasProtocol _protocol = NasProtocol.webdav;
  bool _https = false;
  bool _loaded = false;

  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    () async {
      final settings = await ref.read(nasSettingsProvider.future);
      if (!mounted) return;
      final c = settings.config;
      setState(() {
        _protocol = c.protocol;
        _https = c.https;
        _host.text = c.host;
        _port.text = c.port?.toString() ?? '';
        _basePath.text = c.basePath;
        _user.text = c.user;
        _password.text = c.password;
        _loaded = true;
      });
    }();
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _basePath, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  NasConfig get _config => NasConfig(
        protocol: _protocol,
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()),
        https: _https,
        basePath: _basePath.text.trim(),
        user: _user.text.trim(),
        password: _password.text,
      );

  int get _defaultPort => _protocol == NasProtocol.ftp ? 21 : (_https ? 443 : 80);

  Future<void> _save() async {
    setState(() => _testResult = null);
    await ref.read(nasSettingsProvider.notifier).setConfig(_config);
  }

  Future<void> _test() async {
    final l = context.l10n;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final client = _config.createClient();
    String result;
    try {
      final entries = await client.list('/');
      result = l.nasTestOk(entries.length);
    } on NasException catch (e) {
      result = l.nasTestFailed(e.message);
    } finally {
      client.close();
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  Future<void> _browse(NasFolder kind, String? current) async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => NasFolderBrowserScreen(
          config: _config,
          title: context.l10n.nasBrowseTitle(nasFolderLabel(context, kind)),
          initialPath: current ?? '/',
        ),
      ),
    );
    if (path != null) await ref.read(nasSettingsProvider.notifier).setFolder(kind, path);
  }

  Widget _choice({required String title, required String subtitle, required bool selected, required VoidCallback onTap, bool autofocus = false}) {
    return ListTile(
      autofocus: autofocus,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? Theme.of(context).colorScheme.primary : Colors.white54,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      focusColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    final settings = ref.watch(nasSettingsProvider).value ?? const NasSettings();
    final hasServer = _host.text.trim().isNotEmpty;
    final focusColor = Theme.of(context).colorScheme.primary.withValues(alpha: 0.35);
    return Scaffold(
      appBar: AppBar(title: Text(l.nasTitle)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : FocusTraversalGroup(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(l.nasIntro, style: help),
                  const SizedBox(height: 12),
                  Text(l.nasServerSection, style: Theme.of(context).textTheme.titleMedium),
                  _choice(
                    title: l.nasProtocolWebdav,
                    subtitle: l.nasProtocolWebdavHint,
                    selected: _protocol == NasProtocol.webdav,
                    autofocus: true,
                    onTap: () {
                      setState(() => _protocol = NasProtocol.webdav);
                      _save();
                    },
                  ),
                  _choice(
                    title: l.nasProtocolFtp,
                    subtitle: l.nasProtocolFtpHint,
                    selected: _protocol == NasProtocol.ftp,
                    onTap: () {
                      setState(() => _protocol = NasProtocol.ftp);
                      _save();
                    },
                  ),
                  const SizedBox(height: 12),
                  PopupTextField(
                    controller: _host,
                    label: l.nasHost,
                    hint: l.nasHostHint,
                    icon: Icons.dns_outlined,
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 12),
                  PopupTextField(
                    controller: _port,
                    label: l.nasPort(_defaultPort),
                    icon: Icons.numbers,
                    keyboardType: TextInputType.number,
                    onSubmitted: (v) {
                      if (int.tryParse(v.trim()) == null) _port.text = '';
                      _save();
                    },
                  ),
                  if (_protocol == NasProtocol.webdav) ...[
                    SwitchListTile(
                      title: Text(l.nasHttps),
                      subtitle: Text(l.nasHttpsHint, style: help),
                      value: _https,
                      onChanged: (v) {
                        setState(() => _https = v);
                        _save();
                      },
                    ),
                    PopupTextField(
                      controller: _basePath,
                      label: l.nasBasePath,
                      hint: l.nasBasePathHint,
                      icon: Icons.route_outlined,
                      onSubmitted: (_) => _save(),
                    ),
                  ],
                  const SizedBox(height: 12),
                  PopupTextField(
                    controller: _user,
                    label: l.nasUser,
                    icon: Icons.person_outline,
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 12),
                  PopupTextField(
                    controller: _password,
                    label: l.nasPassword,
                    icon: Icons.key_outlined,
                    obscureText: true,
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _testing || !hasServer ? null : _test,
                        icon: const Icon(Icons.network_check),
                        label: Text(l.nasTest),
                      ),
                      const SizedBox(width: 12),
                      if (_testing) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      if (_testResult != null) Expanded(child: Text(_testResult!, style: help)),
                    ],
                  ),
                  const Divider(height: 32),
                  Text(l.nasFoldersSection, style: Theme.of(context).textTheme.titleMedium),
                  Text(hasServer ? l.nasFoldersHint : l.nasNeedServer, style: help),
                  const SizedBox(height: 8),
                  for (final kind in NasFolder.values)
                    Row(
                      children: [
                        Expanded(
                          child: ListTile(
                            enabled: hasServer,
                            leading: Icon(_folderIcon(kind)),
                            title: Text(nasFolderLabel(context, kind)),
                            subtitle: Text(settings.folders[kind] ?? l.nasFolderNotChosen),
                            trailing: const Icon(Icons.chevron_right),
                            focusColor: focusColor,
                            onTap: () => _browse(kind, settings.folders[kind]),
                          ),
                        ),
                        if (settings.folders[kind] != null)
                          IconButton(
                            tooltip: l.nasFolderClear,
                            icon: const Icon(Icons.clear),
                            onPressed: () => ref.read(nasSettingsProvider.notifier).setFolder(kind, null),
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Text(l.nasBackupsHint(NasBackupService.keep), style: help),
                  const SizedBox(height: 4),
                  Text(l.nasPicturesHint, style: help),
                ],
              ),
            ),
    );
  }
}

/// Picks a folder on the NAS with the remote: the subfolders of the current
/// folder as a list - OK opens one, Back goes one level up (and closes at
/// the top), "Choose this folder" returns the current folder's path.
class NasFolderBrowserScreen extends StatefulWidget {
  const NasFolderBrowserScreen({super.key, required this.config, required this.title, this.initialPath = '/'});

  final NasConfig config;
  final String title;
  final String initialPath;

  @override
  State<NasFolderBrowserScreen> createState() => _NasFolderBrowserScreenState();
}

class _NasFolderBrowserScreenState extends State<NasFolderBrowserScreen> {
  late final NasClient _client = widget.config.createClient();
  late String _path = normalizeNasPath(widget.initialPath);
  List<NasEntry> _folders = const [];
  int _files = 0;
  bool _loading = true;
  String? _error;
  final _firstFocus = FocusNode();
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _open(_path, fallBackToRoot: true);
  }

  @override
  void dispose() {
    _client.close();
    _firstFocus.dispose();
    super.dispose();
  }

  Future<void> _open(String path, {bool fallBackToRoot = false}) async {
    final request = ++_request;
    setState(() {
      _path = normalizeNasPath(path);
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _client.list(_path);
      if (!mounted || request != _request) return;
      setState(() {
        _folders = entries.where((e) => e.isDirectory).toList();
        _files = entries.length - _folders.length;
        _loading = false;
      });
    } on NasException catch (e) {
      if (!mounted || request != _request) return;
      // The saved folder is gone - start at the top instead.
      if (fallBackToRoot && _path != '/') return _open('/');
      setState(() {
        _folders = const [];
        _files = 0;
        _loading = false;
        _error = e.message;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    final focusColor = Theme.of(context).colorScheme.primary.withValues(alpha: 0.35);
    final atRoot = _path == '/';
    return PopScope(
      canPop: atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _open(parentNasPath(_path));
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: FocusTraversalGroup(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(_path, style: Theme.of(context).textTheme.titleMedium),
              if (!_loading && _error == null) Text(l.nasFilesInFolder(_files), style: help),
              if (!atRoot) Text(l.nasBrowseBackHint, style: help),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  focusNode: _folders.isEmpty && _error == null ? _firstFocus : null,
                  autofocus: true,
                  onPressed: _loading || _error != null ? null : () => Navigator.of(context).pop(_path),
                  icon: const Icon(Icons.check),
                  label: Text(l.nasChooseThisFolder),
                ),
              ),
              const SizedBox(height: 8),
              if (_loading)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (_error != null) ...[
                Text(_error!, style: help),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    focusNode: _firstFocus,
                    onPressed: () => _open(_path),
                    icon: const Icon(Icons.refresh),
                    label: Text(l.commonRetry),
                  ),
                ),
              ] else ...[
                if (!atRoot)
                  ListTile(
                    leading: const Icon(Icons.arrow_upward),
                    title: Text(l.nasUp),
                    focusColor: focusColor,
                    onTap: () => _open(parentNasPath(_path)),
                  ),
                if (_folders.isEmpty) Text(l.nasNoSubfolders, style: help),
                for (final (i, folder) in _folders.indexed)
                  ListTile(
                    focusNode: i == 0 ? _firstFocus : null,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(folder.name),
                    trailing: const Icon(Icons.chevron_right),
                    focusColor: focusColor,
                    onTap: () => _open(folder.path),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
