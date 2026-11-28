import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nas_providers.dart';
import '../../core/ok_long_press.dart';
import '../../core/remote_keys.dart';
import '../../core/theme.dart';
import '../../data/services/enigma2_recording_meta.dart';
import '../../data/services/enigma2_recordings.dart';
import '../../data/services/enigma2_service.dart' show Enigma2Exception;
import '../../data/services/movie_library.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';
import '../movies/movie_player_screen.dart';
import '../movies/movies_screen.dart' show movieResumeStoreProvider;
import 'tv_programme_actions.dart';
import 'tv_providers.dart';
import 'tv_recording_providers.dart';
import 'tv_timers_screen.dart';
import 'tv_widgets.dart';

/// Where the list of recordings comes from.
enum TvRecordingSource {
  /// The NAS folder "Aufnahmen" (the receiver records onto the NAS share) -
  /// played straight from the NAS, the receiver isn't needed.
  nas,

  /// The receiver's own list (OpenWebif), played through it.
  receiver,
}

/// One entry of the list: a recording - or a folder of the NAS to open.
class TvRecordingItem {
  TvRecordingItem({
    required this.path,
    required this.title,
    this.channel = '',
    this.recorded,
    this.length,
    this.size,
    this.description = '',
    this.folder = false,
    this.receiver,
    this.siblings = const {},
  });

  /// NAS path, or the file on the receiver.
  final String path;
  String title;
  String channel;
  DateTime? recorded;
  Duration? length;
  int? size;
  String description;
  final bool folder;

  /// From the receiver's list.
  final E2Recording? receiver;

  /// NAS: the names of the files next to it of its set (.meta, .eit, .cuts
  /// ...).
  final Set<String> siblings;
  bool detailsLoaded = false;

  String get fileName => path.split('/').last;
}

/// "Aufnahmen": the receiver's finished recordings - from the NAS folder
/// "Aufnahmen" if one is chosen (the receiver records onto the NAS),
/// else from the receiver's list. Title, date, channel, length; OK plays
/// it (the films' player), holding OK or the options key deletes it (the
/// whole set of files). A recording still running carries the red dot and
/// plays as far as it got.
class TvRecordingsScreen extends ConsumerStatefulWidget {
  const TvRecordingsScreen({super.key});

  @override
  ConsumerState<TvRecordingsScreen> createState() => _TvRecordingsScreenState();
}

class _TvRecordingsScreenState extends ConsumerState<TvRecordingsScreen> {
  TvRecordingSource? _source;
  final _folders = <String>[];
  List<TvRecordingItem>? _items;
  String? _error;
  int _load = 0;
  TvRecordingItem? _focused;
  NasClient? _client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _load++;
    _client?.close();
    super.dispose();
  }

  String? get _nasRoot => ref.read(nasSettingsProvider).value?.folder(NasFolder.recordings);
  bool get _hasReceiver => ref.read(enigma2RecordingsProvider) != null;

  Future<void> _start() async {
    try {
      await ref.read(nasSettingsProvider.future);
    } catch (_) {}
    if (!mounted) return;
    final root = _nasRoot;
    if (root != null) {
      _folders
        ..clear()
        ..add(root);
      _source = TvRecordingSource.nas;
    } else if (_hasReceiver) {
      _source = TvRecordingSource.receiver;
    }
    await _reload();
  }

  NasClient _nas() => _client ??= ref.read(nasSettingsProvider).value!.config.createClient();

  Future<void> _reload() async {
    final load = ++_load;
    final noSource = context.l10n.tvRecNoSource;
    setState(() {
      _items = null;
      _error = null;
      _focused = null;
    });
    try {
      final items = switch (_source) {
        TvRecordingSource.nas => await _listNas(_folders.last),
        TvRecordingSource.receiver => await _listReceiver(),
        null => throw Enigma2Exception(noSource),
      };
      if (!mounted || load != _load) return;
      setState(() => _items = items);
      if (_source == TvRecordingSource.nas) unawaited(_loadDetails(items, load));
    } catch (e) {
      if (mounted && load == _load) setState(() => _error = '$e');
    }
  }

  Future<List<TvRecordingItem>> _listNas(String folder) async {
    final entries = await _nas().list(folder);
    final names = {for (final e in entries) e.name};
    final folders = <TvRecordingItem>[];
    final files = <TvRecordingItem>[];
    for (final e in entries) {
      if (e.isDirectory) {
        if (!e.name.startsWith('.')) folders.add(TvRecordingItem(path: e.path, title: e.name, folder: true));
        continue;
      }
      if (fileExtension(e.name) != 'ts') continue;
      final parsed = parseRecordingFileName(e.name);
      files.add(TvRecordingItem(
        path: e.path,
        title: parsed.title,
        channel: parsed.channel,
        recorded: parsed.recorded ?? e.modified,
        size: e.size,
        siblings: {for (final s in recordingSidecarNames(e.name)) if (names.contains(s)) s},
      ));
    }
    files.sort((a, b) => (b.recorded ?? DateTime(0)).compareTo(a.recorded ?? DateTime(0)));
    return [...folders, ...files];
  }

  /// Title, description and length from the .meta and .eit files, one
  /// after the other (the list shows meanwhile).
  Future<void> _loadDetails(List<TvRecordingItem> items, int load) async {
    final client = _nas();
    var changed = 0;
    for (final item in items) {
      if (!mounted || load != _load) return;
      if (item.folder || item.detailsLoaded) continue;
      item.detailsLoaded = true;
      final dir = parentNasPath(item.path);
      final meta = item.siblings.where((s) => s.endsWith('.meta')).firstOrNull;
      final eit = item.siblings.where((s) => s.endsWith('.eit')).firstOrNull;
      try {
        if (meta != null) {
          final bytes = await client.read(joinNasPath(dir, meta), maxBytes: 64 << 10);
          final m = parseRecordingMeta(utf8.decode(bytes, allowMalformed: true));
          if (m.title.isNotEmpty) item.title = m.title;
          if (m.description.isNotEmpty) item.description = m.description;
          item.recorded = m.recorded ?? item.recorded;
          item.length = m.length ?? item.length;
        }
        if (eit != null) {
          final bytes = await client.read(joinNasPath(dir, eit), maxBytes: 64 << 10);
          final e = parseRecordingEit(bytes);
          if (e != null) {
            if (item.title.isEmpty && e.title.isNotEmpty) item.title = e.title;
            if (e.description.length > item.description.length) item.description = e.description;
            item.length ??= e.duration;
          }
        }
      } catch (e) {
        debugPrint('Aufnahmen: $e');
      }
      if (++changed % 4 == 0 && mounted && load == _load) setState(() {});
    }
    if (mounted && load == _load) setState(() {});
  }

  Future<List<TvRecordingItem>> _listReceiver() async {
    final api = ref.read(enigma2RecordingsProvider);
    if (api == null) throw Enigma2Exception(context.l10n.tvErrorNoReceiver);
    String? folder;
    try {
      folder = (await api.locations()).current;
    } catch (_) {}
    final list = await api.recordings(folder: folder);
    return [
      for (final r in list)
        TvRecordingItem(
          path: r.fileName,
          title: r.title,
          channel: r.serviceName,
          recorded: r.recorded,
          length: r.length,
          size: r.size,
          description: r.description,
          receiver: r,
        )..detailsLoaded = true,
    ];
  }

  void _switchSource(TvRecordingSource source) {
    if (source == _source) return;
    _source = source;
    final root = _nasRoot;
    _folders.clear();
    if (root != null) _folders.add(root);
    unawaited(_reload());
  }

  bool _running(TvRecordingItem item, List<E2Timer> timers) {
    if (item.folder) return false;
    final title = item.title.trim().toLowerCase();
    return timers.any((t) => t.isRecording && t.running && t.name.trim().toLowerCase() == title);
  }

  Future<void> _open(TvRecordingItem item) async {
    if (item.folder) {
      _folders.add(item.path);
      return _reload();
    }
    final l = context.l10n;
    final resume = ref.read(movieResumeStoreProvider);
    if (_source == TvRecordingSource.nas) {
      final nas = ref.read(nasSettingsProvider).value;
      if (nas == null) return;
      // Where the receiver stopped (its .cuts) - unless the app knows better.
      final cuts = item.siblings.where((s) => s.endsWith('.cuts')).firstOrNull;
      if (cuts != null && await resume.position(item.path) == null) {
        try {
          final at = parseCutsLastPosition(await _nas().read(joinNasPath(parentNasPath(item.path), cuts), maxBytes: 1 << 20));
          if (at != null) await resume.save(item.path, at, item.length ?? Duration.zero);
        } catch (_) {}
      }
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => MoviePlayerScreen(
          movie: MovieItem(path: item.path, title: item.title, kind: MovieKind.file, size: item.size),
          config: nas.config,
        ),
      ));
      return;
    }
    final api = ref.read(enigma2RecordingsProvider);
    final config = ref.read(enigma2ConfigProvider);
    if (api == null || config == null) return;
    final key = 'e2:${item.path}';
    if (await resume.position(key) == null) {
      try {
        final cuts = await api.readFile('${item.path}.cuts');
        final at = cuts == null ? null : parseCutsLastPosition(cuts);
        if (at != null) await resume.save(key, at, item.length ?? Duration.zero);
      } catch (_) {}
    }
    HttpForwardProxy? proxy;
    try {
      var uri = api.fileUri(item.path);
      if (config.authHeaders.isNotEmpty) {
        proxy = await HttpForwardProxy.start(uri, config.authHeaders);
        uri = proxy.uri;
      }
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => MoviePlayerScreen(
          movie: MovieItem(path: key, title: item.title, kind: MovieKind.file, size: item.size),
          config: const NasConfig(),
          directUri: uri,
        ),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.tvRecFailed('$e'))));
      }
    } finally {
      await proxy?.close();
    }
  }

  Future<void> _actions(TvRecordingItem item) async {
    if (item.folder) return;
    final l = context.l10n;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: const Color(0xFF111A16),
        title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        children: [
          TvRow(
            autofocus: true,
            onTap: () => Navigator.of(context).pop('play'),
            child: ListTile(leading: const Icon(Icons.play_arrow, color: brandGreen), title: Text(l.tvRecPlay)),
          ),
          TvRow(
            onTap: () => Navigator.of(context).pop('delete'),
            child: ListTile(leading: const Icon(Icons.delete_outline, color: tvRecordRed), title: Text(l.tvRecDeleteRecording)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'play') await _open(item);
    if (choice == 'delete') await _delete(item);
  }

  Future<void> _delete(TvRecordingItem item) async {
    final l = context.l10n;
    final ok = await confirmTvRecordingAction(
      context,
      title: l.tvRecDeleteRecordingQuestion,
      text: [item.title, _facts(item)].where((s) => s.isNotEmpty).join('\n'),
      confirm: l.commonDelete,
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_source == TvRecordingSource.nas) {
        final client = _nas();
        final dir = parentNasPath(item.path);
        await client.delete(item.path);
        for (final s in item.siblings) {
          try {
            await client.delete(joinNasPath(dir, s));
          } catch (_) {}
        }
      } else {
        final api = ref.read(enigma2RecordingsProvider);
        final receiver = item.receiver;
        if (api == null || receiver == null) return;
        final result = await api.deleteRecording(receiver);
        if (!result.ok) throw Enigma2Exception(result.message);
      }
      messenger.showSnackBar(SnackBar(content: Text(l.tvRecRecordingDeleted(item.title))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l.tvRecFailed('$e'))));
    }
    if (mounted) await _reload();
  }

  String _facts(TvRecordingItem item) {
    final l = context.l10n;
    final recorded = item.recorded;
    return [
      if (recorded != null) tvProgrammeWhen(context, recorded, item.length == null ? recorded : recorded.add(item.length!)),
      if (item.channel.isNotEmpty) item.channel,
      if (item.length != null) l.tvMinutes(item.length!.inMinutes),
      if (item.size != null) _size(item.size!),
    ].join('  ·  ');
  }

  static String _size(int bytes) =>
      bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).round()} MB';

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final focused = _focused;
    if (focused != null && !focused.folder && ref.read(remoteKeysProvider).matches(RemoteAction.options, event.logicalKey)) {
      unawaited(_actions(focused));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _back() {
    if (_source == TvRecordingSource.nas && _folders.length > 1) {
      _folders.removeLast();
      unawaited(_reload());
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final timers = ref.watch(tvTimersProvider).value ?? const <E2Timer>[];
    final nasRoot = ref.watch(nasSettingsProvider).value?.folder(NasFolder.recordings);
    final receiver = ref.watch(enigma2RecordingsProvider) != null;
    final items = _items;
    final focused = _focused;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF05070A),
        body: Focus(
          onKeyEvent: _onKey,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TvRecordingTopBar(
                  title: l.tvRecRecordingsTitle,
                  icon: Icons.video_library_outlined,
                  trailing: receiver
                      ? TextButton.icon(
                          onPressed: () => Navigator.of(context)
                              .push(MaterialPageRoute<void>(builder: (_) => const TvTimersScreen())),
                          icon: const Icon(Icons.schedule),
                          label: Text(l.tvRecTimersTitle),
                        )
                      : null,
                ),
                if (nasRoot != null && receiver)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(40, 12, 40, 0),
                    child: Wrap(
                      spacing: 10,
                      children: [
                        ChoiceChip(
                          label: Text(l.tvRecSourceNas),
                          selected: _source == TvRecordingSource.nas,
                          onSelected: (_) => _switchSource(TvRecordingSource.nas),
                        ),
                        ChoiceChip(
                          label: Text(l.tvRecSourceReceiver),
                          selected: _source == TvRecordingSource.receiver,
                          onSelected: (_) => _switchSource(TvRecordingSource.receiver),
                        ),
                      ],
                    ),
                  ),
                if (_source == TvRecordingSource.nas && _folders.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(44, 10, 40, 0),
                    child: Text(_folders.last, style: const TextStyle(color: Colors.white54, fontSize: 14)),
                  ),
                Expanded(
                  child: _error != null
                      ? TvRecordingMessage(icon: Icons.error_outline, text: _error!, action: l.commonRetry, onAction: _reload)
                      : items == null
                          ? (_source == null && !receiver && nasRoot == null
                              ? TvRecordingMessage(icon: Icons.info_outline, text: l.tvRecNoSource)
                              : const Center(child: CircularProgressIndicator()))
                          : items.isEmpty
                              ? TvRecordingMessage(icon: Icons.video_library_outlined, text: l.tvRecRecordingsEmpty)
                              : Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    SizedBox(
                                      width: 700,
                                      child: ListView(
                                        padding: const EdgeInsets.fromLTRB(40, 16, 20, 24),
                                        children: [
                                          for (final (i, item) in items.indexed)
                                            Padding(
                                              padding: const EdgeInsets.only(bottom: 6),
                                              child: OkLongPress(
                                                onTap: () => unawaited(_open(item)),
                                                onLongPress: item.folder ? null : () => unawaited(_actions(item)),
                                                child: TvRow(
                                                  autofocus: i == 0,
                                                  onFocused: () => setState(() => _focused = item),
                                                  onTap: () => unawaited(_open(item)),
                                                  child: _RecordingRow(
                                                    item: item,
                                                    facts: _facts(item),
                                                    running: _running(item, timers),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          const SizedBox(height: 12),
                                          Text(l.tvRecRecordingsHint(remoteKeyHint(ref.watch(remoteKeysProvider), RemoteAction.options)),
                                              style: const TextStyle(color: Colors.white54, fontSize: 15)),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: focused == null || focused.folder
                                          ? const SizedBox.shrink()
                                          : Container(
                                              margin: const EdgeInsets.fromLTRB(0, 16, 24, 24),
                                              padding: const EdgeInsets.all(24),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF0E151A),
                                                borderRadius: BorderRadius.circular(16),
                                              ),
                                              child: SingleChildScrollView(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(focused.title,
                                                        style: const TextStyle(
                                                            color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                                                    const SizedBox(height: 8),
                                                    Text(_facts(focused), style: const TextStyle(color: brandGreen, fontSize: 16)),
                                                    if (_running(focused, timers)) ...[
                                                      const SizedBox(height: 8),
                                                      Row(children: [
                                                        const TvRecordDot(),
                                                        const SizedBox(width: 8),
                                                        Text(l.tvRecStillRecording,
                                                            style: const TextStyle(color: Colors.white70, fontSize: 15)),
                                                      ]),
                                                    ],
                                                    const SizedBox(height: 18),
                                                    Text(
                                                      focused.description.isEmpty ? l.tvNoDescription : focused.description,
                                                      style: const TextStyle(color: Colors.white70, fontSize: 18, height: 1.4),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({required this.item, required this.facts, required this.running});

  final TvRecordingItem item;
  final String facts;
  final bool running;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: item.folder
                  ? const Icon(Icons.folder_outlined, color: Colors.white70)
                  : running
                      ? const TvRecordDot(size: 14)
                      : const Icon(Icons.movie_outlined, color: Colors.white38, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                  if (!item.folder && facts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(facts,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white60, fontSize: 14)),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}
