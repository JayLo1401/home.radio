import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/services/nas_service.dart';
import '../../data/services/picture_library.dart';
import '../../data/services/video_probe.dart';
import '../movies/movie_player_screen.dart' show formatMovieTime;
import 'thumbnails.dart';

/// What the browser shows of a video: a preview picture if one is cheap to
/// get (a camera's .THM or a picture of the same name next to it, a
/// Synology NAS's own preview) and its length if its first bytes tell it.
/// No frame is decoded - that would mean loading the video.
class VideoPreview {
  VideoPreview(this.thumbnail, this.duration);

  final Thumbnail? thumbnail;
  final Duration? duration;

  VideoPreview clone() => VideoPreview(thumbnail?.clone(), duration);

  void dispose() => thumbnail?.dispose();
}

/// The video tiles' previews: one NAS request at a time (they come after
/// the photos' thumbnails), the newest wish first, the last 40 kept.
class VideoPreviewLoader {
  VideoPreviewLoader(this._client) {
    _queue = LoadQueue<VideoPreview>(
      fetch: _fetch,
      maxConcurrent: 1,
      cacheSize: 40,
      copy: (p) => p.clone(),
      onEvict: (p) => p.dispose(),
    );
  }

  /// The thumbnails' connection.
  final NasClient Function() _client;
  late final LoadQueue<VideoPreview> _queue;
  final _wanted = <String, ({NasEntry entry, VideoPreviewHint? hint})>{};

  VideoPreview? peek(String path) => _queue.peek(path);

  bool failed(String path) => _queue.failed(path);

  LoadRequest<VideoPreview> request(NasEntry entry, VideoPreviewHint? hint, void Function(VideoPreview? p) done) {
    _wanted[entry.path] = (entry: entry, hint: hint);
    return _queue.request(entry.path, done);
  }

  void suspend() => _queue.suspend();

  void resume() => _queue.resume();

  void close() => _queue.close();

  Future<VideoPreview?> _fetch(String path) async {
    final wanted = _wanted.remove(path);
    final entry = wanted?.entry ?? NasEntry(name: path.split('/').last, path: path, isDirectory: false);
    return fetchVideoPreview(_client(), entry, wanted?.hint);
  }
}

/// Synology's previews of a video, the best fit for a tile first.
const _synologyPreviews = [
  'SYNOPHOTO_THUMB_M.jpg',
  'SYNOVIDEO_VIDEO_SCREENSHOT.jpg',
  'SYNOPHOTO_THUMB_SM.jpg',
  'SYNOPHOTO_THUMB_B.jpg',
  'SYNOPHOTO_THUMB_XL.jpg',
];

/// [entry]'s preview (see [VideoPreview]) - never throws; what can't be
/// had stays null.
Future<VideoPreview> fetchVideoPreview(NasClient client, NasEntry entry, VideoPreviewHint? hint) async {
  Thumbnail? thumbnail;
  final sidecar = hint?.sidecar;
  if (sidecar != null) thumbnail = await _pictureAt(client, sidecar);
  final synology = hint?.synologyFolder;
  if (thumbnail == null && synology != null) {
    try {
      final names = {for (final e in await client.list(synology)) if (!e.isDirectory) e.name.toUpperCase(): e.path};
      for (final name in _synologyPreviews) {
        final path = names[name.toUpperCase()];
        if (path == null) continue;
        thumbnail = await _pictureAt(client, path);
        if (thumbnail != null) break;
      }
    } catch (e) {
      debugPrint('video preview ${entry.path}: no Synology preview ($e)');
    }
  }
  Duration? duration;
  try {
    final head = await _readRange(client, entry.path, 0, videoProbeHeadBytes);
    duration = await videoDuration(
      entry.name,
      head,
      size: entry.size,
      read: (offset, length) => _readRange(client, entry.path, offset, length),
    );
  } catch (e) {
    debugPrint('video preview ${entry.path}: no length ($e)');
  }
  return VideoPreview(thumbnail, duration);
}

/// A small picture file decoded as a thumbnail - null if it isn't one.
Future<Thumbnail?> _pictureAt(NasClient client, String path) async {
  try {
    final bytes = await client.read(path, maxBytes: 4 << 20);
    final image = await decodeThumbnail(bytes);
    return image == null ? null : Thumbnail(image, 0);
  } catch (e) {
    debugPrint('video preview $path: $e');
    return null;
  }
}

Future<Uint8List> _readRange(NasClient client, String path, int offset, int length) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in client.openRead(path, offset: offset, length: length)) {
    builder.add(chunk);
    if (builder.length >= length) break;
  }
  final bytes = builder.takeBytes();
  return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
}

/// A video in the browser's grid: its preview (or a film symbol), a play
/// badge, its length when known, its name small. OK or a tap plays it.
class VideoTile extends StatefulWidget {
  const VideoTile({
    super.key,
    required this.entry,
    required this.hint,
    required this.loader,
    required this.onTap,
    required this.onKey,
    this.focusNode,
  });

  final NasEntry entry;
  final VideoPreviewHint? hint;
  final VideoPreviewLoader loader;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event) onKey;
  final FocusNode? focusNode;

  @override
  State<VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<VideoTile> {
  VideoPreview? _preview;
  LoadRequest<VideoPreview>? _request;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _preview = widget.loader.peek(widget.entry.path);
    if (_preview == null && !widget.loader.failed(widget.entry.path)) {
      _request = widget.loader.request(widget.entry, widget.hint, (preview) {
        _request = null;
        if (!mounted) {
          preview?.dispose();
          return;
        }
        setState(() => _preview = preview);
      });
    }
  }

  @override
  void dispose() {
    _request?.cancel();
    _preview?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thumbnail = _preview?.thumbnail;
    final duration = _preview?.duration;
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
            focusNode: widget.focusNode,
            focusColor: Colors.white.withValues(alpha: 0.06),
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (thumbnail != null)
                        RotatedBox(
                          quarterTurns: thumbnail.quarterTurns,
                          child: RawImage(image: thumbnail.image, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
                        )
                      else
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF1B2A22), Color(0xFF0E1412)],
                            ),
                          ),
                          child: Align(
                            alignment: Alignment(0, -0.55),
                            child: Icon(Icons.movie_outlined, color: Colors.white24, size: 30),
                          ),
                        ),
                      Center(
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _focused ? brandGreen : Colors.black.withValues(alpha: 0.55),
                            border: Border.all(color: Colors.white70, width: 2),
                          ),
                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
                        ),
                      ),
                      if (duration != null)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              formatMovieTime(duration),
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 5),
                  child: Row(
                    children: [
                      const Icon(Icons.videocam_outlined, color: Colors.white38, size: 14),
                      const SizedBox(width: 4),
                      Expanded(
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
