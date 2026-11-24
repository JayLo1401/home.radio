import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../data/services/nas_service.dart';

/// Film pictures from the NAS, kept in memory for the library pages (the
/// file bytes - the picture is decoded downscaled when shown). Bounded by
/// size: the Fire TV Stick has 1 GB.
class MoviePosterCache {
  MoviePosterCache({this.maxBytes = 12 << 20});

  final int maxBytes;
  final _bytes = <String, Uint8List>{}; // in use order
  final _failed = <String>{};
  final _loading = <String, Future<Uint8List?>>{};
  int _total = 0;
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  /// Bigger pictures aren't loaded.
  static const maxFile = 3 << 20;

  Uint8List? cached(String path) {
    final bytes = _bytes.remove(path);
    if (bytes != null) _bytes[path] = bytes; // most recent
    return bytes;
  }

  Future<Uint8List?> load(NasClient client, String path) {
    final hit = cached(path);
    if (hit != null) return Future.value(hit);
    if (_failed.contains(path)) return Future.value();
    return _loading[path] ??= _load(client, path).whenComplete(() => _loading.remove(path));
  }

  Future<Uint8List?> _load(NasClient client, String path) async {
    // Two at a time - the listings go on meanwhile.
    if (_running >= 2) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final bytes = await client.read(path, maxBytes: maxFile);
      _bytes[path] = bytes;
      _total += bytes.length;
      while (_total > maxBytes && _bytes.length > 1) {
        final oldest = _bytes.keys.first;
        _total -= _bytes.remove(oldest)!.length;
      }
      return bytes;
    } catch (_) {
      _failed.add(path);
      return null;
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}
