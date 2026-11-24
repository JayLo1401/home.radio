import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable, kIsWeb;

/// File types the Musik part lists and plays. ExoPlayer (Android) plays
/// MP3, AAC/M4A (also ALAC on newer devices), FLAC, WAV, Ogg Vorbis/Opus,
/// Matroska audio and AIFF; libmpv (Windows/Linux) plays all of these plus
/// WMA, APE, WavPack and Musepack.
const musicExtensions = {
  '.mp3', '.mp2', '.m4a', '.m4b', '.aac', '.mp4', '.flac', '.wav', '.ogg', '.oga', '.opus', //
  '.mka', '.aif', '.aiff', '.wma', '.ape', '.wv', '.mpc', '.ac3', '.alac',
};

/// What ExoPlayer can't play - not listed on Android.
const _desktopOnlyExtensions = {'.wma', '.ape', '.wv', '.mpc', '.ac3'};

/// The extension of [name] in lower case with the dot ("" if none).
String musicExtensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot).toLowerCase();
}

/// A music file by its name (hidden files like "._01.mp3" from a Mac are
/// left out). [android]: only what ExoPlayer plays.
bool isMusicName(String name, {bool? android}) {
  if (name.startsWith('.')) return false;
  final ext = musicExtensionOf(name);
  if (!musicExtensions.contains(ext)) return false;
  final onAndroid = android ?? (!kIsWeb && Platform.isAndroid);
  return !(onAndroid && _desktopOnlyExtensions.contains(ext));
}

/// Folders nobody wants to see: hidden ones, the NAS's own (Synology
/// "@eaDir", "#recycle", "#snapshot") and Windows' "$RECYCLE.BIN".
bool isHiddenMusicFolder(String name) {
  if (name.startsWith('.') || name.startsWith('@') || name.startsWith(r'$')) return true;
  final lower = name.toLowerCase();
  return lower == '#recycle' || lower == '#snapshot' || lower == 'system volume information';
}

/// Picture files that serve as a folder's cover, best first.
const musicFolderCoverNames = [
  'cover.jpg', 'cover.jpeg', 'cover.png', 'folder.jpg', 'folder.jpeg', 'folder.png', //
  'front.jpg', 'front.jpeg', 'front.png', 'album.jpg', 'album.png', 'albumart.jpg',
];

/// The folder cover among a folder's file names (case-insensitive), or null.
/// Also "AlbumArt_{...}_Large.jpg" (Windows Media Player).
String? pickFolderCover(Iterable<String> names) {
  final lower = {for (final n in names) n.toLowerCase(): n};
  for (final c in musicFolderCoverNames) {
    final hit = lower[c];
    if (hit != null) return hit;
  }
  for (final entry in lower.entries) {
    if (entry.key.startsWith('albumart') && entry.key.endsWith('large.jpg')) return entry.value;
  }
  return null;
}

/// Compares names like people read them: case-insensitive, and numbers by
/// their value - "Track 2" before "Track 10".
int compareMusicNames(String a, String b) {
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

/// One music file on the NAS.
@immutable
class MusicTrack {
  /// Absolute remote path (see NasConfig).
  final String path;

  /// File size in bytes, if the listing told it.
  final int? size;

  const MusicTrack(this.path, {this.size});

  /// The file name with extension.
  String get name {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /// The folder the file is in.
  String get folder {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }

  /// The folder's own name ("" for "/").
  String get folderName {
    final f = folder;
    final slash = f.lastIndexOf('/');
    return f.substring(slash + 1);
  }

  String get extension => musicExtensionOf(name);

  /// The file name without extension.
  String get baseName {
    final n = name;
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  /// Artist and title as far as the file name tells (see [guessFromFileName]).
  ({String? artist, String title}) get nameGuess => guessFromFileName(baseName);

  @override
  bool operator ==(Object other) => other is MusicTrack && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'MusicTrack($path)';
}

final _leadingNumber = RegExp(r'^\s*(?:CD\s*\d+\s*[-.]?\s*)?\d{1,3}(?:[-.]\d{1,3})?\s*(?:[-._)]\s*|\s+)');

/// Artist and title from a file name without extension: "Artist - Title",
/// "01 - Title", "01. Artist - Title", "01 Title". Underscores count as
/// spaces. No artist when the name doesn't say.
({String? artist, String title}) guessFromFileName(String baseName) {
  var s = baseName.replaceAll('_', ' ').trim();
  final withoutNumber = s.replaceFirst(_leadingNumber, '');
  // Only when something is left ("1999" stays a title).
  if (withoutNumber.trim().isNotEmpty) s = withoutNumber.trim();
  final dash = s.indexOf(' - ');
  if (dash > 0) {
    final artist = s.substring(0, dash).trim();
    final title = s.substring(dash + 3).trim();
    if (artist.isNotEmpty && title.isNotEmpty) return (artist: artist, title: title);
  }
  return (artist: null, title: s.isEmpty ? baseName : s);
}

/// What a file's own tags say (ID3, MP4, Vorbis comments, RIFF INFO).
@immutable
class MusicTags {
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final int? year;

  /// The embedded cover picture (JPEG/PNG bytes).
  final Uint8List? cover;

  const MusicTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.year,
    this.cover,
  });

  static const empty = MusicTags();

  bool get isEmpty => title == null && artist == null && album == null && cover == null;

  /// [other]'s values where this has none.
  MusicTags mergedWith(MusicTags other) => MusicTags(
        title: title ?? other.title,
        artist: artist ?? other.artist,
        album: album ?? other.album,
        albumArtist: albumArtist ?? other.albumArtist,
        trackNumber: trackNumber ?? other.trackNumber,
        year: year ?? other.year,
        cover: cover ?? other.cover,
      );

  MusicTags withCover(Uint8List? cover) => MusicTags(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        trackNumber: trackNumber,
        year: year,
        cover: cover,
      );

  @override
  String toString() => 'MusicTags($artist - $title [$album] #$trackNumber $year cover:${cover?.length})';
}

/// What the screens show for a track: from the tags if wanted and there,
/// else from the file name.
@immutable
class MusicDisplay {
  final String title;
  final String? artist;
  final String? album;

  const MusicDisplay({required this.title, this.artist, this.album});

  factory MusicDisplay.of(MusicTrack track, MusicTags? tags, {bool preferTags = true}) {
    final guess = track.nameGuess;
    if (preferTags && tags != null && (tags.title?.trim().isNotEmpty ?? false)) {
      return MusicDisplay(
        title: tags.title!.trim(),
        artist: _blankToNull(tags.artist) ?? _blankToNull(tags.albumArtist) ?? guess.artist,
        album: _blankToNull(tags.album) ?? (track.folderName.isEmpty ? null : track.folderName),
      );
    }
    return MusicDisplay(
      title: preferTags ? guess.title : track.baseName,
      artist: preferTags ? (guess.artist ?? _blankToNull(tags?.artist)) : null,
      album: (preferTags ? _blankToNull(tags?.album) : null) ?? (track.folderName.isEmpty ? null : track.folderName),
    );
  }

  /// "Artist - Title", or just the title.
  String get line => artist == null ? title : '$artist - $title';
}

String? _blankToNull(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
