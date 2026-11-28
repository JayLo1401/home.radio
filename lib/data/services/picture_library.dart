import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'nas_service.dart';

/// The Bilder part's NAS side: which files are pictures, which folders are
/// looked into, the recursive walk for a slideshow and its play list.

/// File types a slideshow shows (GIFs with their first frame).
const pictureExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};

/// A picture file by its name (hidden files like "._IMG_1.jpg" from a Mac
/// are left out).
bool isPictureName(String name) {
  if (name.startsWith('.')) return false;
  final dot = name.lastIndexOf('.');
  return dot > 0 && pictureExtensions.contains(name.substring(dot).toLowerCase());
}

/// Video files a pictures folder may hold too (phones, cameras, camcorders):
/// shown with "Videos anzeigen", played by the films' player. No DVD
/// images or VOBs - those belong to Filme.
const pictureVideoExtensions = {
  '.mp4', '.m4v', '.mkv', '.mov', '.qt', '.avi', '.3gp', '.3g2', '.mts', '.m2ts', '.webm', '.wmv', '.asf', //
  '.mpg', '.mpeg', '.flv', '.divx', '.ogv', //
};

/// A video file by its name (hidden ones left out, as for pictures).
bool isPictureVideoName(String name) {
  if (name.startsWith('.')) return false;
  final dot = name.lastIndexOf('.');
  return dot > 0 && pictureVideoExtensions.contains(name.substring(dot).toLowerCase());
}

/// What a slideshow shows (asked when it starts, if there are videos).
enum SlideshowMedia {
  pictures,
  both,
  videos;

  bool get withPictures => this != videos;
  bool get withVideos => this != pictures;
}

/// Small picture files next to a video that show it: a camera's ".THM"
/// (a JPEG), or a picture of the same name ("MVI_0001.JPG").
const _videoSidecarExtensions = ['.thm', '.jpg', '.jpeg', '.png'];

/// Folders nobody wants to see: hidden ones (".thumbnails"), the NAS's own
/// (Synology "@eaDir", "#recycle", "#snapshot") and Windows' "$RECYCLE.BIN".
bool isHiddenPictureFolder(String name) {
  if (name.startsWith('.') || name.startsWith('@') || name.startsWith(r'$')) return true;
  final lower = name.toLowerCase();
  return lower == '#recycle' || lower == '#snapshot';
}

/// Compares names like people read them: case-insensitive, and numbers by
/// their value - "Tag 2" before "Tag 10".
int compareNatural(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  var i = 0, j = 0;
  bool digit(int c) => c >= 0x30 && c <= 0x39;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i), cy = y.codeUnitAt(j);
    if (digit(cx) && digit(cy)) {
      final si = i, sj = j;
      while (i < x.length && digit(x.codeUnitAt(i))) {
        i++;
      }
      while (j < y.length && digit(y.codeUnitAt(j))) {
        j++;
      }
      // Without leading zeros: longer is bigger, else digit by digit.
      final nx = x.substring(si, i).replaceFirst(RegExp('^0+(?=.)'), '');
      final ny = y.substring(sj, j).replaceFirst(RegExp('^0+(?=.)'), '');
      if (nx.length != ny.length) return nx.length - ny.length;
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      continue;
    }
    if (cx != cy) return cx - cy;
    i++;
    j++;
  }
  final rest = (x.length - i) - (y.length - j);
  return rest != 0 ? rest : a.compareTo(b);
}

/// One folder's content as the browser shows it.
class PictureFolder {
  /// Subfolders (without hidden ones), in natural order.
  final List<NasEntry> folders;

  /// Pictures directly in the folder, in natural order.
  final List<NasEntry> pictures;

  /// Videos directly in the folder, in natural order.
  final List<NasEntry> videos;

  /// Where a video's preview may be, by its path: a small picture next to
  /// it (see [_videoSidecarExtensions]) and/or the folder a Synology NAS
  /// keeps its previews in ("@eaDir/" plus its name) - found in the listing alone.
  final Map<String, VideoPreviewHint> videoHints;

  const PictureFolder({
    required this.folders,
    required this.pictures,
    this.videos = const [],
    this.videoHints = const {},
  });

  factory PictureFolder.of(List<NasEntry> entries) {
    int byName(NasEntry a, NasEntry b) => compareNatural(a.name, b.name);
    final videos = [for (final e in entries) if (!e.isDirectory && isPictureVideoName(e.name)) e]..sort(byName);
    final hints = <String, VideoPreviewHint>{};
    if (videos.isNotEmpty) {
      final synology = entries.any((e) => e.isDirectory && e.name == '@eaDir');
      // Base name (lower case) → the best sidecar ([_videoSidecarExtensions]
      // in that order).
      final sidecars = <String, ({String path, int rank})>{};
      for (final e in entries) {
        if (e.isDirectory || e.name.startsWith('.')) continue;
        final dot = e.name.lastIndexOf('.');
        if (dot <= 0) continue;
        final rank = _videoSidecarExtensions.indexOf(e.name.substring(dot).toLowerCase());
        if (rank < 0) continue;
        final base = e.name.substring(0, dot).toLowerCase();
        final known = sidecars[base];
        if (known == null || rank < known.rank) sidecars[base] = (path: e.path, rank: rank);
      }
      for (final v in videos) {
        final dot = v.name.lastIndexOf('.');
        final sidecar = sidecars[v.name.substring(0, dot).toLowerCase()]?.path;
        final eaDir = synology ? joinNasPath(joinNasPath(parentNasPath(v.path), '@eaDir'), v.name) : null;
        if (sidecar != null || eaDir != null) hints[v.path] = VideoPreviewHint(sidecar: sidecar, synologyFolder: eaDir);
      }
    }
    return PictureFolder(
      folders: [for (final e in entries) if (e.isDirectory && !isHiddenPictureFolder(e.name)) e]..sort(byName),
      pictures: [for (final e in entries) if (!e.isDirectory && isPictureName(e.name)) e]..sort(byName),
      videos: videos,
      videoHints: hints,
    );
  }

  /// The pictures and/or videos, by name - as a phone's gallery mixes them
  /// ("20260704_101500.jpg", "20260704_101622.mp4").
  List<NasEntry> media(SlideshowMedia media) {
    if (!media.withVideos) return pictures;
    if (!media.withPictures) return videos;
    if (videos.isEmpty) return pictures;
    return [...pictures, ...videos]..sort((a, b) => compareNatural(a.name, b.name));
  }
}

/// Where a video's preview picture may be (see [PictureFolder.videoHints]).
class VideoPreviewHint {
  const VideoPreviewHint({this.sidecar, this.synologyFolder});

  /// A picture file next to the video.
  final String? sidecar;

  /// "…/@eaDir/(video name)" - Synology's previews of the video.
  final String? synologyFolder;
}

/// All pictures in [root] and its subfolders, folder by folder (a folder's
/// own pictures, then its subfolders one after the other, each in natural
/// order) - as a stream of one list per folder, so a slideshow can start
/// with the first ones while the rest is still being looked for.
///
/// Stops at [maxPictures] and doesn't go deeper than [maxDepth] folders
/// below [root]. A subfolder that can't be read is left out (reported to
/// [onError]); if [root] can't be read, the stream ends with its error.
/// Every folder gives a list (also an empty one) - so cancelling the
/// subscription stops the walk after the folder being read.
///
/// [media]: pictures, videos or both (mixed by name, see
/// [PictureFolder.media]).
Stream<List<NasEntry>> collectPictures(
  NasClient client,
  String root, {
  int maxPictures = 10000,
  int maxDepth = 8,
  SlideshowMedia media = SlideshowMedia.pictures,
  void Function(String folder, Object error)? onError,
}) async* {
  var count = 0;
  // Depth first, in order: a stack of folders still to read.
  final stack = <({String path, int depth})>[(path: root, depth: 0)];
  while (stack.isNotEmpty && count < maxPictures) {
    final folder = stack.removeLast();
    final PictureFolder content;
    try {
      content = PictureFolder.of(await client.list(folder.path));
    } catch (e) {
      if (folder.depth == 0) rethrow;
      onError?.call(folder.path, e);
      yield const [];
      continue;
    }
    final take = content.media(media).take(maxPictures - count).toList();
    count += take.length;
    yield take;
    if (folder.depth < maxDepth) {
      for (final sub in content.folders.reversed) {
        stack.add((path: sub.path, depth: folder.depth + 1));
      }
    }
  }
}

/// The order of a slideshow (Einstellungen → Bilder).
enum SlideshowOrder {
  /// Folder by folder, by name - like the browser shows them.
  folders,

  /// Mixed up.
  shuffled,
}

/// The pictures of a running slideshow and which one is shown. Pictures
/// can still be added while it runs ([addAll], from [collectPictures]);
/// [complete] says the list is whole - only then it starts over after the
/// last one (shuffled anew).
///
/// [startWhere]: the slideshow starts at the picture it matches ("ab hier",
/// or resumed) - in folder order at its place, so the ones before it come
/// after the last one; shuffled it comes first, the rest mixed after it.
/// Until it has been added there is no [current] one; if it never comes,
/// [finish] starts at the first.
class SlideshowPlaylist<T> {
  SlideshowPlaylist({this.order = SlideshowOrder.folders, Random? random, bool Function(T item)? startWhere})
      : _random = random ?? Random(),
        _startMatch = startWhere;

  final SlideshowOrder order;
  final Random _random;
  bool Function(T item)? _startMatch;
  final _items = <T>[];
  var _index = 0;
  var _complete = false;

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  int get index => _index;
  bool get complete => _complete;
  List<T> get items => List.unmodifiable(_items);

  /// Still waiting for the picture to start at.
  bool get startPending => _startMatch != null;

  T? get current => !startPending && _index < _items.length ? _items[_index] : null;

  /// No more pictures will be added.
  void finish() {
    _complete = true;
    _startMatch = null;
  }

  /// Folder order: at the end. Shuffled: each at a random place among the
  /// ones still to come - but not right after the current one, which may
  /// already be loading.
  void addAll(Iterable<T> items) {
    final batch = items.toList();
    final startWhere = _startMatch;
    if (order == SlideshowOrder.folders) {
      final from = _items.length;
      _items.addAll(batch);
      if (startWhere != null) {
        final i = batch.indexWhere(startWhere);
        if (i >= 0) {
          _index = from + i;
          _startMatch = null;
        }
      }
      return;
    }
    if (startWhere != null) {
      final i = batch.indexWhere(startWhere);
      if (i >= 0) {
        _items.insert(0, batch.removeAt(i));
        _index = 0;
        _startMatch = null;
      }
    }
    for (final item in batch..shuffle(_random)) {
      final from = min(_index + 2, _items.length);
      _items.insert(from + _random.nextInt(_items.length - from + 1), item);
    }
  }

  /// The item [delta] places from the current one (wrapping around when
  /// [complete]), or null if there is none (yet).
  T? peek(int delta) {
    if (_items.isEmpty || startPending) return null;
    final i = _index + delta;
    if (i >= 0 && i < _items.length) return _items[i];
    if (!_complete) return null;
    return _items[i % _items.length];
  }

  /// Moves [delta] places on. Past the end it starts over (shuffled anew)
  /// when [complete], before the first one it goes to the last; false when
  /// there's nothing there (yet) - the current one stays.
  bool move(int delta) {
    if (_items.isEmpty || startPending) return false;
    final i = _index + delta;
    if (i >= 0 && i < _items.length) {
      _index = i;
      return true;
    }
    if (!_complete) return false;
    if (i >= _items.length) {
      if (order == SlideshowOrder.shuffled && _items.length > 2) _reshuffle();
      _index = 0;
    } else {
      _index = _items.length - 1;
    }
    return true;
  }

  /// A new round in a new order - not starting with the one just shown.
  void _reshuffle() {
    final last = _items[_index];
    _items.shuffle(_random);
    if (identical(_items.first, last) || _items.first == last) {
      _items
        ..removeAt(0)
        ..insert(1 + _random.nextInt(_items.length - 1), last);
    }
  }

  /// Drops the current item (a picture that can't be shown). The current
  /// one is then the one after it ([forward]) or before it. False when
  /// there's none in that direction (yet) - with [forward] the one before
  /// stays current, so [move] (1) reaches the next one added.
  bool removeCurrent({bool forward = true}) {
    if (startPending || _index >= _items.length) return false;
    _items.removeAt(_index);
    if (_items.isEmpty) {
      _index = 0;
      return false;
    }
    if (forward) {
      if (_index < _items.length) return true;
      if (_complete) {
        _index = 0;
        return true;
      }
      _index = _items.length - 1;
      return false;
    }
    if (_index > 0) {
      _index--;
      return true;
    }
    if (_complete) {
      _index = _items.length - 1;
      return true;
    }
    // Index 0 is the one that came after it - better than nothing.
    return true;
  }
}

/// Size [width] x [height] reduced (never enlarged) to fit into
/// [boxWidth] x [boxHeight], keeping its aspect ratio.
({int width, int height}) fitWithin(int width, int height, int boxWidth, int boxHeight) {
  if (width <= 0 || height <= 0) return (width: width, height: height);
  final scale = min(1.0, min(boxWidth / width, boxHeight / height));
  if (scale >= 1) return (width: width, height: height);
  return (width: max(1, (width * scale).round()), height: max(1, (height * scale).round()));
}

/// The folder of [picture] relative to [root] ("Urlaub 2026/Tag 2"), or
/// [root]'s own name when it lies directly in it.
String pictureFolderLabel(String root, String picture) {
  final base = normalizeNasPath(root);
  final folder = parentNasPath(picture);
  if (folder == base || !folder.startsWith(base == '/' ? '/' : '$base/')) {
    return base == '/' ? '/' : base.split('/').last;
  }
  return folder.substring(base == '/' ? 1 : base.length + 1);
}

/// Loads things one key at a time for a long, scrolling grid (thumbnails):
/// at most [maxConcurrent] at once, the newest request first (what just
/// scrolled into view), cancelled requests never start, and the last
/// [cacheSize] results kept (least recently used ones go, [onEvict] frees
/// them). [copy] hands every user its own copy (e.g. a ui.Image clone).
class LoadQueue<V extends Object> {
  LoadQueue({
    required this.fetch,
    this.maxConcurrent = 2,
    this.cacheSize = 60,
    this.copy,
    this.onEvict,
  });

  /// Null: nothing to show for this key (not tried again).
  final Future<V?> Function(String key) fetch;
  final int maxConcurrent;
  final int cacheSize;
  final V Function(V value)? copy;
  final void Function(V value)? onEvict;

  // Insertion order = use order: the first is the least recently used.
  final _cache = <String, V>{};
  final _failed = <String>{};
  final _pending = <LoadRequest<V>>[];
  final _running = <String, List<LoadRequest<V>>>{};
  var _suspended = false;
  var _closed = false;

  int get running => _running.length;
  int get waiting => _pending.length;
  Iterable<String> get cachedKeys => _cache.keys;

  /// Gave nothing before - no need to ask again.
  bool failed(String key) => _failed.contains(key);

  /// The cached value (a copy) - and it's now the most recently used.
  V? peek(String key) {
    final value = _cache.remove(key);
    if (value == null) return null;
    _cache[key] = value;
    return copy == null ? value : copy!(value);
  }

  /// Asks for [key]; [done] gets the value (a copy) or null - never after
  /// [LoadRequest.cancel].
  LoadRequest<V> request(String key, void Function(V? value) done) {
    final request = LoadRequest<V>._(this, key, done);
    if (_closed) return request;
    final running = _running[key];
    if (running != null) {
      running.add(request);
    } else {
      _pending.add(request);
      _pump();
    }
    return request;
  }

  /// No new loads meanwhile (e.g. while a slideshow runs); [resume] goes on.
  void suspend() => _suspended = true;

  void resume() {
    _suspended = false;
    _pump();
  }

  void _pump() {
    while (!_closed && !_suspended && _running.length < maxConcurrent && _pending.isNotEmpty) {
      final request = _pending.removeLast();
      final key = request.key;
      if (_cache.containsKey(key)) {
        // Never in the middle of building the grid.
        scheduleMicrotask(() {
          if (!request._cancelled && !_closed) request._deliver(peek(key));
        });
        continue;
      }
      final running = _running[key];
      if (running != null) {
        running.add(request);
        continue;
      }
      _running[key] = [request];
      _start(key);
    }
  }

  Future<void> _start(String key) async {
    V? value;
    var gaveNothing = false;
    try {
      value = await fetch(key);
      gaveNothing = value == null;
    } catch (_) {
      // A network error - may work another time.
    }
    final requests = _running.remove(key) ?? const [];
    if (_closed) {
      if (value != null) onEvict?.call(value);
      return;
    }
    if (gaveNothing) _failed.add(key);
    if (value != null) {
      for (final request in requests) {
        if (!request._cancelled) request._deliver(copy == null ? value : copy!(value));
      }
      _cache[key] = value;
      while (_cache.length > cacheSize) {
        final oldest = _cache.keys.first;
        onEvict?.call(_cache.remove(oldest) as V);
      }
    } else {
      for (final request in requests) {
        request._deliver(null);
      }
    }
    _pump();
  }

  /// Frees everything; later requests get nothing.
  void close() {
    _closed = true;
    _pending.clear();
    for (final value in _cache.values) {
      onEvict?.call(value);
    }
    _cache.clear();
  }
}

/// One wish of [LoadQueue.request].
class LoadRequest<V extends Object> {
  LoadRequest._(this._queue, this.key, this._done);

  final LoadQueue<V> _queue;
  final String key;
  final void Function(V? value) _done;
  var _cancelled = false;

  /// Not wanted any more (scrolled away): it won't start, or its result
  /// only goes into the cache.
  void cancel() {
    _cancelled = true;
    _queue._pending.remove(this);
  }

  void _deliver(V? value) {
    if (_cancelled) {
      // A copy made for it isn't anybody's.
      if (value != null && _queue.copy != null) _queue.onEvict?.call(value);
      return;
    }
    _done(value);
  }
}

/// The small preview picture a camera stores in a JPEG's EXIF block (often
/// 160x120, some 512x384), found in the first bytes of the file [head] - a
/// thumbnail without reading a 10 MB photo. [quarterTurns]: clockwise turns
/// for the EXIF orientation (the preview itself isn't turned). Null if
/// there is none (or it lies beyond [head]).
({Uint8List jpeg, int quarterTurns})? exifThumbnail(Uint8List head) {
  if (head.length < 4 || head[0] != 0xFF || head[1] != 0xD8) return null;
  var pos = 2;
  while (pos + 4 <= head.length) {
    if (head[pos] != 0xFF) return null;
    final marker = head[pos + 1];
    // Fill bytes.
    if (marker == 0xFF) {
      pos++;
      continue;
    }
    // Start of the picture data or its end: no EXIF block before.
    if (marker == 0xDA || marker == 0xD9) return null;
    final length = (head[pos + 2] << 8) | head[pos + 3];
    if (length < 2) return null;
    final start = pos + 4;
    if (marker == 0xE1 &&
        start + 6 <= head.length &&
        String.fromCharCodes(head.sublist(start, start + 4)) == 'Exif' &&
        head[start + 4] == 0 &&
        head[start + 5] == 0) {
      return _thumbnailInTiff(head, start + 6);
    }
    pos += 2 + length;
  }
  return null;
}

({Uint8List jpeg, int quarterTurns})? _thumbnailInTiff(Uint8List data, int tiff) {
  if (tiff + 8 > data.length) return null;
  final little = data[tiff] == 0x49 && data[tiff + 1] == 0x49;
  if (!little && !(data[tiff] == 0x4D && data[tiff + 1] == 0x4D)) return null;
  final view = ByteData.sublistView(data);
  final endian = little ? Endian.little : Endian.big;
  int? u16(int at) => tiff + at + 2 <= data.length ? view.getUint16(tiff + at, endian) : null;
  int? u32(int at) => tiff + at + 4 <= data.length ? view.getUint32(tiff + at, endian) : null;
  if (u16(2) != 42) return null;

  // The IFD at [at]: its entries (tag: value as stored inline) and the
  // offset of the next IFD.
  ({Map<int, int> tags, int next})? ifd(int at) {
    final count = u16(at);
    if (count == null || count > 500) return null;
    final tags = <int, int>{};
    for (var i = 0; i < count; i++) {
      final entry = at + 2 + i * 12;
      final tag = u16(entry), type = u16(entry + 2);
      if (tag == null || type == null) return null;
      // SHORT values sit in the first two bytes of the value field.
      final value = type == 3 ? u16(entry + 8) : u32(entry + 8);
      if (value != null) tags[tag] = value;
    }
    return (tags: tags, next: u32(at + 2 + count * 12) ?? 0);
  }

  final first = u32(4);
  if (first == null) return null;
  final ifd0 = ifd(first);
  if (ifd0 == null || ifd0.next == 0) return null;
  final ifd1 = ifd(ifd0.next);
  if (ifd1 == null) return null;
  final offset = ifd1.tags[0x0201], length = ifd1.tags[0x0202];
  if (offset == null || length == null || length < 4) return null;
  final from = tiff + offset;
  if (from + length > data.length) return null;
  if (data[from] != 0xFF || data[from + 1] != 0xD8) return null;
  final turns = switch (ifd0.tags[0x0112]) {
    3 || 4 => 2,
    5 || 6 => 1,
    7 || 8 => 3,
    _ => 0,
  };
  return (jpeg: Uint8List.sublistView(data, from, from + length), quarterTurns: turns);
}

/// Where a folder's slideshow was last: the picture shown and its number
/// then - to go on from there next time.
class SlideshowResumePoint {
  const SlideshowResumePoint({required this.path, required this.name, required this.position});

  final String path;
  final String name;

  /// 1-based, in the order it was shown then.
  final int position;

  Map<String, Object> toJson() => {'path': path, 'name': name, 'position': position};

  static SlideshowResumePoint? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'], name = json['name'], position = json['position'];
    if (path is! String || name is! String || position is! int) return null;
    return SlideshowResumePoint(path: path, name: name, position: position);
  }
}

/// The resume points as stored: folder key to point, the most recent last.
Map<String, SlideshowResumePoint> decodeResumePoints(String? raw) {
  try {
    final json = jsonDecode(raw ?? '{}');
    if (json is! Map) return {};
    final points = <String, SlideshowResumePoint>{};
    for (final e in json.entries) {
      final point = SlideshowResumePoint.fromJson(e.value);
      if (e.key is String && point != null) points[e.key as String] = point;
    }
    return points;
  } catch (_) {
    return {};
  }
}

/// [points] with [key] set to [point] (now the most recent) - only the
/// [keep] most recent folders are remembered.
String encodeResumePoints(
  Map<String, SlideshowResumePoint> points,
  String key,
  SlideshowResumePoint point, {
  int keep = 30,
}) {
  final updated = {...points}
    ..remove(key)
    ..[key] = point;
  final entries = updated.entries.toList();
  return jsonEncode({
    for (final e in entries.skip(max(0, entries.length - keep))) e.key: e.value.toJson(),
  });
}
