import 'dart:math';
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/services/nas_picture_cache.dart';
import '../../data/services/nas_service.dart';
import '../../data/services/picture_library.dart';

/// A picture's thumbnail: small (the shorter side [ThumbnailLoader.size]
/// pixels), and how far to turn it (EXIF previews aren't turned).
class Thumbnail {
  Thumbnail(this.image, this.quarterTurns);

  final ui.Image image;
  final int quarterTurns;

  Thumbnail clone() => Thumbnail(image.clone(), quarterTurns);

  void dispose() => image.dispose();
}

/// The browser's thumbnails: two NAS reads at a time, newest wish first,
/// the last 60 kept in memory (about 300 KB each), loads of tiles scrolled
/// away cancelled - smooth also on the Fire TV Stick with thousands of
/// photos in a folder. Camera JPEGs need only their first 128 KB (the
/// preview in the EXIF block); others are read whole and decoded small.
class ThumbnailLoader {
  ThumbnailLoader(this._client) {
    _queue = LoadQueue<Thumbnail>(
      fetch: _fetch,
      maxConcurrent: 2,
      cacheSize: 60,
      copy: (t) => t.clone(),
      onEvict: (t) => t.dispose(),
    );
  }

  /// Pixels of a thumbnail's shorter side.
  static const size = 240;

  /// The start of a JPEG read for its EXIF preview.
  static const headBytes = 128 * 1024;

  /// Smaller JPEGs (WhatsApp pictures - they have no preview anyway) are
  /// read whole straight away.
  static const smallJpeg = 300 * 1024;

  /// Bigger files get no thumbnail (unless they have a preview).
  static const maxBytes = 25 * 1024 * 1024;

  /// Its own connection (e.g. FTP): listings don't wait behind photos.
  final NasClient Function() _client;
  late final LoadQueue<Thumbnail> _queue;
  final _entries = <String, NasEntry>{};

  Thumbnail? peek(String path) => _queue.peek(path);

  bool failed(String path) => _queue.failed(path);

  LoadRequest<Thumbnail> request(NasEntry entry, void Function(Thumbnail? thumbnail) done) {
    _entries[entry.path] = entry;
    return _queue.request(entry.path, done);
  }

  void suspend() => _queue.suspend();

  void resume() => _queue.resume();

  void close() => _queue.close();

  Future<Thumbnail?> _fetch(String path) async {
    final entry = _entries.remove(path) ?? NasEntry(name: path.split('/').last, path: path, isDirectory: false);
    try {
      return await fetchThumbnail(_client(), entry);
    } on NasException catch (e) {
      // Once more - e.g. an FTP connection dropped while idle.
      debugPrint('thumbnail ${entry.path}: $e - once more');
      return fetchThumbnail(_client(), entry);
    }
  }
}

/// [entry]'s thumbnail: the EXIF preview of a big JPEG, else the whole file
/// decoded small. Null if it isn't a usable picture.
Future<Thumbnail?> fetchThumbnail(NasClient client, NasEntry entry) async {
  final name = entry.name.toLowerCase();
  final jpeg = name.endsWith('.jpg') || name.endsWith('.jpeg');
  final size = entry.size;
  if (jpeg && (size == null || size > ThumbnailLoader.smallJpeg)) {
    final head = await _readHead(client, entry.path);
    final preview = head == null ? null : exifThumbnail(head);
    if (preview != null) {
      final image = await decodeThumbnail(preview.jpeg);
      if (image != null) return Thumbnail(image, preview.quarterTurns);
    }
  }
  if ((size ?? 0) > ThumbnailLoader.maxBytes) return null;
  final bytes = await client.read(entry.path, maxBytes: ThumbnailLoader.maxBytes);
  final image = await decodeThumbnail(bytes);
  return image == null ? null : Thumbnail(image, 0);
}

Future<Uint8List?> _readHead(NasClient client, String path) async {
  try {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in client.openRead(path, length: ThumbnailLoader.headBytes)) {
      builder.add(chunk);
      if (builder.length >= ThumbnailLoader.headBytes) break;
    }
    return builder.takeBytes();
  } catch (e) {
    debugPrint('thumbnail $path: no head ($e)');
    return null;
  }
}

/// [bytes] decoded with the shorter side [ThumbnailLoader.size] pixels
/// (never enlarged) - by the engine, at that size straight away.
Future<ui.Image?> decodeThumbnail(Uint8List bytes) async {
  var tooBig = false;
  ui.Codec? codec;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      if (w * h > NasPictureCache.maxPixels) {
        tooBig = true;
        return ui.TargetImageSize(width: 1, height: 1);
      }
      final scale = ThumbnailLoader.size / min(w, h);
      if (scale >= 1) return ui.TargetImageSize(width: w, height: h);
      return ui.TargetImageSize(width: max(1, (w * scale).round()), height: max(1, (h * scale).round()));
    });
    if (tooBig) return null;
    return (await codec.getNextFrame()).image;
  } catch (e) {
    debugPrint('thumbnail: not a usable picture ($e)');
    return null;
  } finally {
    codec?.dispose();
  }
}

/// One picture in the browser's grid: its thumbnail (loaded once it's
/// built - the grid builds only what is (nearly) visible), its name small.
/// OK or a tap starts the slideshow from it.
class ThumbnailTile extends StatefulWidget {
  const ThumbnailTile({
    super.key,
    required this.entry,
    required this.loader,
    required this.onTap,
    required this.onKey,
  });

  final NasEntry entry;
  final ThumbnailLoader loader;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event) onKey;

  @override
  State<ThumbnailTile> createState() => _ThumbnailTileState();
}

class _ThumbnailTileState extends State<ThumbnailTile> {
  Thumbnail? _thumbnail;
  LoadRequest<Thumbnail>? _request;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _thumbnail = widget.loader.peek(widget.entry.path);
    if (_thumbnail == null && !widget.loader.failed(widget.entry.path)) {
      _request = widget.loader.request(widget.entry, (thumbnail) {
        _request = null;
        if (!mounted) {
          thumbnail?.dispose();
          return;
        }
        setState(() => _thumbnail = thumbnail);
      });
    }
  }

  @override
  void dispose() {
    // Scrolled away: not loaded for nothing.
    _request?.cancel();
    _thumbnail?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thumbnail = _thumbnail;
    final failed = thumbnail == null && _request == null;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => widget.onKey(event),
      child: TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(10),
        child: Material(
          color: const Color(0xFF15191B),
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            focusColor: Colors.white.withValues(alpha: 0.06),
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: thumbnail != null
                      ? RotatedBox(
                          quarterTurns: thumbnail.quarterTurns,
                          child: RawImage(
                            image: thumbnail.image,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                          ),
                        )
                      : Center(
                          child: Icon(
                            failed ? Icons.broken_image_outlined : Icons.image_outlined,
                            color: Colors.white24,
                            size: 36,
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 5),
                  child: Text(
                    widget.entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
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
