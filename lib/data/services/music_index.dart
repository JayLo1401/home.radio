import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../models/music_track.dart';
import 'music_library.dart';
import 'nas_service.dart';

/// The optional list of every music file in the music folder - names and
/// sizes only, no tags (reading 50,000 files' tags over the network would
/// take hours). For searching everything and "Alles zufällig" at once;
/// browsing and playing folders work without it.
///
/// Stored gzipped as JSON in the app's own folder (a few MB for 50,000
/// files): `{"v":1,"id":identity,"root":"/Musik","updated":ms,
/// "complete":true,"pending":[...],"f":{"/Musik/A":["a.mp3",123,...]}}` -
/// per folder its files as name/size pairs (size -1 = unknown). [pending]
/// are folders not walked yet (a build that was interrupted).
class MusicIndexData {
  MusicIndexData({
    required this.identity,
    required this.root,
    required this.folders,
    required this.updated,
    this.complete = true,
    List<String>? pending,
  }) : pending = pending ?? [];

  /// NasConfig.identity of the server it was built from.
  final String identity;
  final String root;

  /// Folder path -> its music files (name, size).
  final Map<String, List<(String, int?)>> folders;
  final DateTime updated;
  final bool complete;
  final List<String> pending;

  static const version = 1;

  int get trackCount => folders.values.fold(0, (n, files) => n + files.length);

  /// Every track, folder by folder (folders in natural order).
  List<MusicTrack> get tracks {
    final keys = folders.keys.toList()..sort(compareMusicNames);
    return [
      for (final folder in keys)
        for (final (name, size) in folders[folder]!) MusicTrack(joinNasPath(folder, name), size: size),
    ];
  }

  bool fits(String identity, String root) => this.identity == identity && this.root == normalizeNasPath(root);

  Map<String, Object?> toJson() => {
        'v': version,
        'id': identity,
        'root': root,
        'updated': updated.millisecondsSinceEpoch,
        'complete': complete,
        if (pending.isNotEmpty) 'pending': pending,
        'f': {
          for (final e in folders.entries) e.key: [for (final (name, size) in e.value) ...[name, size ?? -1]],
        },
      };

  static MusicIndexData? fromJson(Map<String, Object?> json) {
    if (json['v'] != version) return null;
    final raw = json['f'];
    if (raw is! Map) return null;
    final folders = <String, List<(String, int?)>>{};
    for (final e in raw.entries) {
      final list = e.value;
      if (list is! List) continue;
      final files = <(String, int?)>[];
      for (var i = 0; i + 1 < list.length; i += 2) {
        final name = list[i];
        final size = list[i + 1];
        if (name is! String) continue;
        files.add((name, size is int && size >= 0 ? size : null));
      }
      folders['${e.key}'] = files;
    }
    return MusicIndexData(
      identity: '${json['id'] ?? ''}',
      root: '${json['root'] ?? '/'}',
      folders: folders,
      updated: DateTime.fromMillisecondsSinceEpoch((json['updated'] as num?)?.toInt() ?? 0),
      complete: json['complete'] != false,
      pending: [for (final p in (json['pending'] as List?) ?? const []) '$p'],
    );
  }

  /// Gzipped JSON.
  Uint8List encode() => Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(toJson()))));

  static MusicIndexData? decode(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(gzip.decode(bytes)));
      return json is Map ? fromJson(json.cast<String, Object?>()) : null;
    } catch (_) {
      return null;
    }
  }

  /// Replaces everything at and below [subtree] with [replacement] (folder
  /// -> files of a new walk there).
  MusicIndexData withSubtree(String subtree, Map<String, List<(String, int?)>> replacement) {
    final base = normalizeNasPath(subtree);
    bool inside(String folder) => folder == base || folder.startsWith(base == '/' ? '/' : '$base/');
    return MusicIndexData(
      identity: identity,
      root: root,
      folders: {
        for (final e in folders.entries)
          if (!inside(e.key)) e.key: e.value,
        ...replacement,
      },
      updated: DateTime.now(),
      complete: complete,
      pending: pending,
    );
  }
}

/// A search over the index: every word of the query must appear in the
/// track's path (folders and file name), case and accents ignored.
class MusicIndexSearch {
  MusicIndexSearch(this.data) : _tracks = data.tracks;

  final MusicIndexData data;
  final List<MusicTrack> _tracks;
  List<String>? _haystack;

  List<MusicTrack> get tracks => _tracks;

  /// Prepares the search text of every track in the background (once) -
  /// for 50,000 tracks that takes a weak box a moment.
  Future<void> prepare() async {
    if (_haystack != null) return;
    final skip = data.root.length;
    final paths = [for (final t in _tracks) t.path];
    _haystack = await Isolate.run(() => [for (final p in paths) foldForSearch(p.substring(skip.clamp(0, p.length)))]);
  }

  List<MusicTrack> search(String query, {int limit = 300}) {
    final words = foldForSearch(query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    final haystack = _haystack ??= [
      for (final t in _tracks) foldForSearch(t.path.substring(data.root.length.clamp(0, t.path.length))),
    ];
    final results = <MusicTrack>[];
    for (var i = 0; i < haystack.length && results.length < limit; i++) {
      final h = haystack[i];
      if (words.every(h.contains)) results.add(_tracks[i]);
    }
    return results;
  }
}

const _accents = {
  'ä': 'a', 'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'å': 'a', 'ö': 'o', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', //
  'ø': 'o', 'ü': 'u', 'ù': 'u', 'ú': 'u', 'û': 'u', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'í': 'i', 'ì': 'i',
  'î': 'i', 'ï': 'i', 'ñ': 'n', 'ç': 'c', 'ß': 'ss', 'ý': 'y', 'ÿ': 'y',
};

/// Lower case, without accents, "_" as space - for matching.
String foldForSearch(String s) {
  final lower = s.toLowerCase().replaceAll('_', ' ');
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final c = String.fromCharCode(rune);
    out.write(_accents[c] ?? c);
  }
  return out.toString();
}

/// Progress of building the index.
@immutable
class MusicIndexProgress {
  final bool running;
  final int folders;
  final int tracks;
  final String? folder;
  final String? error;

  /// A build stopped half way (can go on).
  final bool interrupted;

  const MusicIndexProgress({
    this.running = false,
    this.folders = 0,
    this.tracks = 0,
    this.folder,
    this.error,
    this.interrupted = false,
  });
}

/// Keeps the index file and builds it: [build] walks the whole music
/// folder (resumable - the folders still to do are saved every few
/// seconds, an interrupted build goes on from there), [refreshFolder] just
/// one subtree, [noteListing] takes a folder's files from browsing.
class MusicIndexStore {
  MusicIndexStore(this._directory);

  /// Where the files live (app support dir) - a future so tests and the
  /// app can pass their own.
  final Future<Directory> Function() _directory;

  final current = ValueNotifier<MusicIndexData?>(null);
  final progress = ValueNotifier(const MusicIndexProgress());
  MusicIndexSearch? _search;
  bool _loaded = false;
  MusicWalkToken? _token;
  Timer? _saveTimer;

  static const _file = 'music_index.json.gz';
  static const _partialFile = 'music_index.partial.json.gz';

  Future<File> _path(String name) async => File('${(await _directory()).path}${Platform.pathSeparator}$name');

  /// Loads the saved index (once).
  Future<MusicIndexData?> load() async {
    if (_loaded) return current.value;
    _loaded = true;
    try {
      final file = await _path(_file);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        current.value = await Isolate.run(() => MusicIndexData.decode(bytes));
      }
      final partial = await _path(_partialFile);
      if (await partial.exists() && !progress.value.running) {
        progress.value = const MusicIndexProgress(interrupted: true);
      }
    } catch (e) {
      debugPrint('music index: $e');
    }
    return current.value;
  }

  /// The index if it was built from [identity]/[root] (else null).
  Future<MusicIndexData?> indexFor(String identity, String root) async {
    final data = await load();
    return data != null && data.fits(identity, root) ? data : null;
  }

  Future<MusicIndexSearch?> searchFor(String identity, String root) async {
    final data = await indexFor(identity, root);
    if (data == null) return null;
    if (_search?.data != data) _search = MusicIndexSearch(data);
    final search = _search!;
    await search.prepare();
    return search;
  }

  Future<void> _write(String name, MusicIndexData data) async {
    final bytes = await Isolate.run(data.encode);
    final file = await _path(name);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> _deletePartial() async {
    try {
      final f = await _path(_partialFile);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  bool get running => progress.value.running;

  /// Stops a running build (it can go on later).
  void cancel() => _token?.cancel();

  /// Builds the index of [root] in the background through [client] (a
  /// client of its own - closed when done). Goes on with an interrupted
  /// build of the same place if there is one, unless [fresh].
  Future<void> build(NasClient client, String identity, String root, {bool fresh = false}) async {
    if (running) return;
    await load();
    final base = normalizeNasPath(root);
    final token = _token = MusicWalkToken();
    var folders = <String, List<(String, int?)>>{};
    var stack = <String>[base];
    if (!fresh) {
      try {
        final partial = await _path(_partialFile);
        if (await partial.exists()) {
          final bytes = await partial.readAsBytes();
          final data = await Isolate.run(() => MusicIndexData.decode(bytes));
          if (data != null && data.fits(identity, base) && data.pending.isNotEmpty) {
            folders = Map.of(data.folders);
            stack = List.of(data.pending);
          }
        }
      } catch (_) {}
    }
    var tracks = folders.values.fold(0, (n, f) => n + f.length);
    var done = folders.length;
    progress.value = MusicIndexProgress(running: true, folders: done, tracks: tracks);
    var lastSave = DateTime.now();
    final seen = <String>{};
    String? error;
    try {
      while (stack.isNotEmpty) {
        if (token.cancelled) break;
        final folder = stack.removeLast();
        if (!seen.add(folder)) continue;
        List<NasEntry> entries;
        try {
          entries = await client.list(folder);
        } on NasException catch (e) {
          if (folder == base) {
            error = e.message;
            break;
          }
          // Once more, then on without it.
          try {
            entries = await client.list(folder);
          } on NasException {
            continue;
          }
        }
        final listing = MusicFolderListing.of(entries);
        if (listing.tracks.isNotEmpty) {
          folders[folder] = [for (final t in listing.tracks) (t.name, t.size)];
          tracks += listing.tracks.length;
        }
        stack.addAll([for (final f in listing.folders) f.path].reversed);
        done++;
        progress.value = MusicIndexProgress(running: true, folders: done, tracks: tracks, folder: folder);
        if (DateTime.now().difference(lastSave) > const Duration(seconds: 20)) {
          lastSave = DateTime.now();
          await _write(
            _partialFile,
            MusicIndexData(
              identity: identity,
              root: base,
              folders: folders,
              updated: DateTime.now(),
              complete: false,
              pending: List.of(stack),
            ),
          );
        }
      }
      if (error == null && !token.cancelled) {
        final data = MusicIndexData(identity: identity, root: base, folders: folders, updated: DateTime.now());
        await _write(_file, data);
        await _deletePartial();
        current.value = data;
        progress.value = MusicIndexProgress(folders: done, tracks: tracks);
      } else {
        if (stack.isNotEmpty || error == null) {
          await _write(
            _partialFile,
            MusicIndexData(
              identity: identity,
              root: base,
              folders: folders,
              updated: DateTime.now(),
              complete: false,
              pending: stack.isEmpty ? [base] : stack,
            ),
          );
        }
        progress.value = MusicIndexProgress(folders: done, tracks: tracks, error: error, interrupted: true);
      }
    } catch (e) {
      progress.value = MusicIndexProgress(folders: done, tracks: tracks, error: '$e', interrupted: true);
    } finally {
      client.close();
      _token = null;
    }
  }

  /// Walks [folder] anew and puts it into the index (the rest stays).
  Future<int> refreshFolder(NasClient client, String identity, String root, String folder) async {
    final data = await indexFor(identity, root);
    if (data == null) return 0;
    final replacement = <String, List<(String, int?)>>{};
    var count = 0;
    try {
      await for (final batch in walkMusic(client, folder)) {
        replacement[batch.first.folder] = [for (final t in batch) (t.name, t.size)];
        count += batch.length;
      }
    } finally {
      client.close();
    }
    final updated = data.withSubtree(folder, replacement);
    current.value = updated;
    await _write(_file, updated);
    return count;
  }

  /// A folder listed while browsing: its files go into the index (if there
  /// is one for this place) - saved a little later.
  void noteListing(String identity, String root, String folder, MusicFolderListing listing) {
    final data = current.value;
    if (data == null || !data.fits(identity, root) || running) return;
    final base = normalizeNasPath(root);
    if (folder != base && !folder.startsWith('$base/')) return;
    final files = [for (final t in listing.tracks) (t.name, t.size)];
    final old = data.folders[folder];
    if (old != null && listEquals(old, files)) return;
    if (old == null && files.isEmpty) return;
    if (files.isEmpty) {
      data.folders.remove(folder);
    } else {
      data.folders[folder] = files;
    }
    _search = null;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 10), () => _write(_file, data).catchError((Object e) {
          debugPrint('music index: $e');
        }));
  }

  /// Removes the index (Settings).
  Future<void> delete() async {
    cancel();
    current.value = null;
    _search = null;
    progress.value = const MusicIndexProgress();
    for (final name in [_file, _partialFile]) {
      try {
        final f = await _path(name);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
