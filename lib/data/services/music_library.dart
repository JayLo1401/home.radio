import 'dart:async';
import 'dart:collection';
import 'dart:math';

import '../models/music_track.dart';
import 'nas_service.dart';

/// One folder's content as the music browser shows it.
class MusicFolderListing {
  /// Subfolders (without hidden ones), in natural order.
  final List<NasEntry> folders;

  /// Music files directly in the folder, in natural order.
  final List<MusicTrack> tracks;

  /// The folder's cover picture file name (cover.jpg, folder.jpg, ...).
  final String? coverName;

  const MusicFolderListing({required this.folders, required this.tracks, this.coverName});

  factory MusicFolderListing.of(List<NasEntry> entries, {bool? android}) => MusicFolderListing(
        folders: [for (final e in entries) if (e.isDirectory && !isHiddenMusicFolder(e.name)) e]
          ..sort((a, b) => compareMusicNames(a.name, b.name)),
        tracks: [
          for (final e in entries)
            if (!e.isDirectory && isMusicName(e.name, android: android)) MusicTrack(e.path, size: e.size),
        ]..sort((a, b) => compareMusicNames(a.name, b.name)),
        coverName: pickFolderCover([for (final e in entries) if (!e.isDirectory) e.name]),
      );

  bool get isEmpty => folders.isEmpty && tracks.isEmpty;
}

/// Stops a walk from outside.
class MusicWalkToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// All music in [root] and its subfolders, folder by folder: a folder's
/// own tracks, then its subfolders one after the other (depth first, each
/// in natural order - or in random order with [random], so a shuffled
/// queue gets tracks from all over the collection early). One list per
/// folder with tracks, so playback can start with the first while the rest
/// is still being looked for. A subfolder that can't be listed is skipped;
/// [root] itself failing throws. [onListed] sees every listing (e.g. to
/// keep an index up to date).
Stream<List<MusicTrack>> walkMusic(
  NasClient client,
  String root, {
  Random? random,
  MusicWalkToken? token,
  bool? android,
  bool subfolders = true,
  void Function(String folder, MusicFolderListing listing)? onListed,
}) async* {
  final stack = <String>[normalizeNasPath(root)];
  final seen = <String>{};
  var first = true;
  while (stack.isNotEmpty) {
    if (token?.cancelled ?? false) return;
    final folder = stack.removeLast();
    // Links that point back up.
    if (!seen.add(folder)) continue;
    MusicFolderListing listing;
    try {
      listing = MusicFolderListing.of(await client.list(folder), android: android);
    } on NasException {
      if (first) rethrow;
      continue;
    }
    first = false;
    if (token?.cancelled ?? false) return;
    onListed?.call(folder, listing);
    // Without [subfolders]: just [root]'s own tracks.
    final below = subfolders ? [for (final f in listing.folders) f.path] : <String>[];
    if (random != null) below.shuffle(random);
    // Reversed onto the stack: the first one is walked next.
    stack.addAll(below.reversed);
    if (listing.tracks.isNotEmpty) yield listing.tracks;
  }
}

/// How the queue repeats.
enum MusicRepeat { off, all, one }

/// The play queue: the tracks in play order, the current position, and -
/// with shuffle - the original order to go back to. Tracks can keep coming
/// in while it plays ([addDiscovered], from a running [walkMusic]); in
/// shuffle mode each lands at a random place among the tracks not played
/// yet, so every track plays exactly once per round.
class MusicQueue {
  MusicQueue({Random? random}) : _random = random ?? Random();

  final Random _random;
  final List<MusicTrack> _items = [];
  final List<MusicTrack> _ordered = [];
  int _index = -1;
  bool _shuffle = false;

  /// In play order (a view, no copy).
  List<MusicTrack> get items => UnmodifiableListView(_items);
  int get length => _items.length;
  int get index => _index;
  bool get shuffle => _shuffle;
  bool get isEmpty => _items.isEmpty;
  MusicTrack? get current => _index >= 0 && _index < _items.length ? _items[_index] : null;
  MusicTrack trackAt(int i) => _items[i];

  /// A new queue of [tracks]; [start] is played first. With [shuffle] the
  /// order is random - [start] (if given) first.
  void replace(List<MusicTrack> tracks, {int start = 0, bool shuffle = false, bool startRandom = false}) {
    _items
      ..clear()
      ..addAll(tracks);
    _ordered
      ..clear()
      ..addAll(tracks);
    _shuffle = shuffle;
    if (tracks.isEmpty) {
      _index = -1;
      return;
    }
    if (shuffle) {
      final first = startRandom ? null : tracks[start.clamp(0, tracks.length - 1)];
      _items.shuffle(_random);
      if (first != null) {
        _items.remove(first);
        _items.insert(0, first);
      }
      _index = 0;
    } else {
      _index = start.clamp(0, tracks.length - 1);
    }
  }

  void clear() => replace(const []);

  /// Tracks found later (the walk goes on). The current track and the one
  /// after it (already loaded into the player) keep their places.
  void addDiscovered(List<MusicTrack> tracks) {
    if (tracks.isEmpty) return;
    _ordered.addAll(tracks);
    if (!_shuffle) {
      _items.addAll(tracks);
    } else {
      final protect = (_index + 2).clamp(0, 1 << 30);
      for (final t in tracks) {
        final from = protect.clamp(0, _items.length);
        final at = from + _random.nextInt(_items.length - from + 1);
        _items.insert(at, t);
      }
    }
    if (_index < 0) _index = 0;
  }

  /// Shuffle on: the tracks not played yet in random order after the
  /// current one. Off: back to the original order, at the current track.
  void setShuffle(bool on) {
    if (on == _shuffle) return;
    _shuffle = on;
    final current = this.current;
    if (current == null) return;
    if (on) {
      final played = _items.sublist(0, _index + 1);
      final rest = _items.sublist(_index + 1)..shuffle(_random);
      _items
        ..clear()
        ..addAll(played)
        ..addAll(rest);
    } else {
      _items
        ..clear()
        ..addAll(_ordered);
      _index = _items.indexOf(current);
      if (_index < 0) _index = 0;
    }
  }

  /// The index after the current one (null at the end without repeat).
  int? nextIndex({MusicRepeat repeat = MusicRepeat.off}) {
    if (_items.isEmpty) return null;
    if (_index + 1 < _items.length) return _index + 1;
    return repeat == MusicRepeat.all ? 0 : null;
  }

  MusicTrack? peekNext({MusicRepeat repeat = MusicRepeat.off}) {
    final i = nextIndex(repeat: repeat);
    return i == null ? null : _items[i];
  }

  /// Moves on; false at the end. Repeat all starts the same order again
  /// (the next track is already loaded into the player by then).
  bool next({MusicRepeat repeat = MusicRepeat.off}) {
    final i = nextIndex(repeat: repeat);
    if (i == null) return false;
    _index = i;
    return true;
  }

  /// One back; false at the start.
  bool previous({MusicRepeat repeat = MusicRepeat.off}) {
    if (_items.isEmpty) return false;
    if (_index > 0) {
      _index--;
      return true;
    }
    if (repeat == MusicRepeat.all) {
      _index = _items.length - 1;
      return true;
    }
    return false;
  }

  void jumpTo(int i) {
    if (i < 0 || i >= _items.length) return;
    _index = i;
  }

  /// Takes a track out that can't be played (not the original order).
  void removeAt(int i) {
    if (i < 0 || i >= _items.length) return;
    final track = _items.removeAt(i);
    _ordered.remove(track);
    if (i < _index || (_index >= _items.length && _index > 0)) _index--;
    if (_items.isEmpty) _index = -1;
  }
}
