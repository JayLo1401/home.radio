import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../repositories/nas_settings_repository.dart';
import 'nas_service.dart';

/// What the background settings show about the NAS pictures.
class NasPictureStatus {
  final int count;
  final bool syncing;
  final DateTime? lastSync;

  /// The last sync's error (user-facing), if it failed.
  final String? error;

  const NasPictureStatus({this.count = 0, this.syncing = false, this.lastSync, this.error});
}

/// The launcher's background pictures from the NAS pictures folder
/// (Settings → NAS), kept in a small local cache: at most [maxPictures],
/// stored at about screen size, so showing one is a cheap file read and a
/// small decode - the NAS isn't asked each time.
///
/// The NAS is read only by a sync: the first time a picture is wanted in
/// each app run (i.e. once after the start), and when the user presses
/// "Sync now" in the background settings - no timers. A sync keeps cached
/// pictures that are still on the NAS, swaps up to [replacePerSync] of them
/// for others (so a big folder shows variety over time), and fills up to
/// [maxPictures].
class NasPictureCache {
  NasPictureCache(this._settings, {Random? random, Future<Directory> Function()? directory})
      : _random = random ?? Random(),
        _directory = directory ?? _defaultDirectory;

  static const maxPictures = 30;
  static const replacePerSync = 10;

  /// Bigger files are skipped (raw camera files, panoramas).
  static const maxFileBytes = 40 * 1024 * 1024;

  /// Pictures with more pixels are skipped - decoding one would need too
  /// much memory on a small box (Fire TV Stick: 1 GB).
  static const maxPixels = 40 * 1000 * 1000;

  /// The whole cache stays below this.
  static const maxCacheBytes = 150 * 1024 * 1024;

  /// Subfolders of the pictures folder that are looked into (one level).
  static const maxSubfolders = 30;

  static const _imageExtensions = {'.jpg', '.jpeg', '.png', '.webp'};

  final NasSettingsRepository _settings;
  final Random _random;
  final Future<Directory> Function() _directory;

  final status = ValueNotifier(const NasPictureStatus());

  bool _loaded = false;
  String? _source;
  DateTime? _lastSync;
  List<({String remote, String file, int bytes})> _pictures = [];
  Future<void>? _sync;

  /// The source a sync ran for in this app run (once per source).
  String? _syncedSource;
  String? _lastShown;
  final _added = StreamController<void>.broadcast();

  static Future<Directory> _defaultDirectory() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'nas_backgrounds'));
    await dir.create(recursive: true);
    return dir;
  }

  static bool isImageName(String name) => _imageExtensions.contains(p.extension(name).toLowerCase());

  /// Where the pictures come from (server, login and folder) - a change
  /// makes the cache outdated.
  static String? sourceOf(NasSettings settings) {
    final folder = settings.folder(NasFolder.pictures);
    return folder == null ? null : '${settings.config.identity}|$folder';
  }

  /// A random cached picture (not the one shown last), or null if there is
  /// none (no pictures folder, nothing synced yet and the sync found none).
  Future<Uint8List?> next() async {
    await _load();
    final source = sourceOf(await _settings.load());
    if (source == null) return null;
    if (_syncedSource != source) unawaited(sync());
    // Nothing cached yet (first start, other folder): the first picture of
    // the running sync.
    final running = _sync;
    if ((_pictures.isEmpty || source != _source) && running != null) {
      await Future.any([running, _added.stream.first]).timeout(const Duration(minutes: 3), onTimeout: () {});
    }
    if (source != _source) return null;
    while (_pictures.isNotEmpty) {
      final choices = _pictures.length > 1 ? _pictures.where((x) => x.file != _lastShown).toList() : _pictures;
      final pick = choices[_random.nextInt(choices.length)];
      final file = File(p.join((await _directory()).path, pick.file));
      try {
        final bytes = await file.readAsBytes();
        _lastShown = pick.file;
        return bytes;
      } catch (_) {
        // Gone (cleared by the system) - forget it.
        _pictures = [..._pictures]..remove(pick);
        _publish();
      }
    }
    return null;
  }

  /// Reads the pictures folder and updates the cache. A sync that is
  /// already running is joined.
  Future<void> sync() {
    return _sync ??= _runSync().catchError((Object e) => debugPrint('NAS background sync: $e')).whenComplete(() {
      _sync = null;
      _publish();
    });
  }

  Future<void> _runSync() async {
    await _load();
    final settings = await _settings.load();
    final source = sourceOf(settings);
    final folder = settings.folder(NasFolder.pictures);
    if (source == null || folder == null) return;
    _syncedSource = source;
    status.value = NasPictureStatus(count: _countFor(source), syncing: true, lastSync: _lastSync);
    final dir = await _directory();
    final client = settings.config.createClient();
    String? error;
    try {
      final remote = await _listPictures(client, folder);
      final available = {for (final e in remote) e.path};
      if (source != _source) {
        _pictures = [];
        _source = source;
      }
      final kept = _pictures.where((x) => available.contains(x.remote)).toList();
      final cachedRemotes = {for (final x in kept) x.remote};
      final candidates = remote.where((e) => !cachedRemotes.contains(e.path)).toList()..shuffle(_random);
      // Swap some for variety when the folder has more than fits.
      final replace = (kept.toList()..shuffle(_random))
          .take(kept.length >= maxPictures ? min(replacePerSync, candidates.length) : 0)
          .toList();
      final wanted = maxPictures - kept.length + replace.length;
      _pictures = kept;
      _publish();
      var added = 0;
      for (final entry in candidates) {
        if (added >= wanted) break;
        final total = _pictures.fold<int>(0, (sum, x) => sum + x.bytes);
        if (total >= maxCacheBytes && replace.isEmpty) break;
        try {
          final shrunk = await shrinkToScreen(await client.read(entry.path, maxBytes: maxFileBytes));
          if (shrunk == null) continue;
          final name = '${DateTime.now().microsecondsSinceEpoch}${_random.nextInt(1000)}.img';
          await File(p.join(dir.path, name)).writeAsBytes(shrunk, flush: true);
          // Room for it: one of those to swap out goes.
          if (_pictures.length >= maxPictures || total + shrunk.length > maxCacheBytes) {
            if (replace.isEmpty) break;
            _pictures.remove(replace.removeLast());
          }
          _pictures.add((remote: entry.path, file: name, bytes: shrunk.length));
          added++;
          await _save();
          _publish();
          _added.add(null);
        } on NasException catch (e) {
          debugPrint('NAS background ${entry.path}: $e');
        }
      }
      _lastSync = DateTime.now();
      await _save();
    } catch (e) {
      error = e is NasException ? e.message : '$e';
      debugPrint('NAS background sync: $e');
    } finally {
      client.close();
    }
    await _removeStrayFiles(dir);
    status.value = NasPictureStatus(count: _countFor(source), lastSync: _lastSync, error: error);
  }

  /// The pictures in [folder] and its direct subfolders.
  Future<List<NasEntry>> _listPictures(NasClient client, String folder) async {
    final entries = await client.list(folder);
    final pictures = [for (final e in entries) if (!e.isDirectory && _usable(e)) e];
    for (final sub in entries.where((e) => e.isDirectory && !e.name.startsWith('.') && !e.name.startsWith('@')).take(maxSubfolders)) {
      try {
        pictures.addAll((await client.list(sub.path)).where((e) => !e.isDirectory && _usable(e)));
      } on NasException catch (e) {
        debugPrint('NAS background ${sub.path}: $e');
      }
    }
    return pictures;
  }

  static bool _usable(NasEntry e) =>
      isImageName(e.name) && !e.name.startsWith('.') && (e.size == null || e.size! <= maxFileBytes);

  int _countFor(String source) => source == _source ? _pictures.length : 0;

  void _publish() {
    status.value = NasPictureStatus(
      count: _pictures.length,
      syncing: _sync != null,
      lastSync: _lastSync,
      error: status.value.error,
    );
  }

  /// Reads what's cached (for [status]) - without asking the NAS.
  Future<void> init() => _load();

  /// Loads the cache's list (once).
  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(p.join((await _directory()).path, 'pictures.json'));
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _source = json['source'] as String?;
      _lastSync = DateTime.tryParse(json['lastSync'] as String? ?? '');
      _pictures = [
        for (final x in (json['pictures'] as List? ?? const []).cast<Map<String, dynamic>>())
          (remote: x['remote'] as String, file: x['file'] as String, bytes: (x['bytes'] as num?)?.toInt() ?? 0),
      ];
      _publish();
    } catch (e) {
      debugPrint('NAS background cache: $e');
    }
  }

  Future<void> _save() async {
    final file = File(p.join((await _directory()).path, 'pictures.json'));
    await file.writeAsString(jsonEncode({
      'source': _source,
      'lastSync': _lastSync?.toIso8601String(),
      'pictures': [for (final x in _pictures) {'remote': x.remote, 'file': x.file, 'bytes': x.bytes}],
    }));
  }

  Future<void> _removeStrayFiles(Directory dir) async {
    final keep = {for (final x in _pictures) x.file, 'pictures.json'};
    try {
      await for (final f in dir.list()) {
        if (f is File && !keep.contains(p.basename(f.path))) await f.delete();
      }
    } catch (e) {
      debugPrint('NAS background cleanup: $e');
    }
  }

  /// The screen in pixels, landscape, 1280x720 to 1920x1080 (the launcher
  /// shows pictures at no more than 1920 wide).
  static ({int width, int height}) _screen() {
    final size = ui.PlatformDispatcher.instance.views.firstOrNull?.physicalSize ?? ui.Size.zero;
    var w = max(size.width, size.height).round(), h = min(size.width, size.height).round();
    if (w <= 0 || h <= 0) (w, h) = (1920, 1080);
    final scale = min(1920 / w, 1080 / h);
    if (scale < 1) (w, h) = ((w * scale).round(), (h * scale).round());
    return (width: max(w, 1280), height: max(h, 720));
  }

  /// [bytes] (an encoded picture) reduced to cover the screen, as PNG - or
  /// unchanged if it's about screen size already. Null if it isn't a
  /// picture or too big to decode. Decoding and encoding run in the engine,
  /// not on the UI thread.
  static Future<Uint8List?> shrinkToScreen(Uint8List bytes) async {
    final screen = _screen();
    var keepOriginal = false;
    var tooBig = false;
    ui.Codec? codec;
    ui.Image? image;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // Disposes the buffer.
      codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
        if (w * h > maxPixels) {
          tooBig = true;
          return ui.TargetImageSize(width: 1, height: 1);
        }
        // Cover: both sides at least the screen's.
        final scale = max(screen.width / w, screen.height / h);
        if (scale >= 0.75) {
          keepOriginal = true;
          return ui.TargetImageSize(width: 1, height: 1);
        }
        return ui.TargetImageSize(width: (w * scale).round(), height: (h * scale).round());
      });
      if (tooBig) return null;
      if (keepOriginal) return bytes;
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (e) {
      debugPrint('NAS background: not a usable picture ($e)');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}
