import 'dart:typed_data';

import '../../l10n/l10n.dart';
import 'movie_disc_image.dart';
import 'movie_dvd.dart';
import 'movie_library.dart';
import 'movie_stream_server.dart';
import 'nas_service.dart';

/// A film made ready for the [MovieStreamServer]: its bytes, the name and
/// type the player gets, and for DVDs the sound tracks (the stream server
/// hands the player one of them - see [DvdPackFilter]).
class PreparedMovie {
  PreparedMovie._({
    required this.base,
    required this.name,
    required this.mime,
    this.dvd,
    this.dvdAudio = const [],
    this.m2ts = false,
  });

  /// The film's bytes as they are on the NAS.
  final MovieByteSource base;

  /// The file name for the player's address (its extension tells the
  /// format).
  final String name;
  final String mime;

  /// What the DVD's IFO says (length, chapters) - null for other films.
  final DvdTitleInfo? dvd;

  /// An MPEG program stream in DVD packs (ISO, DVD folder, .vob): its
  /// sound tracks - the player gets one at a time.
  final List<DvdAudioStream> dvdAudio;

  /// Camcorder M2TS (192-byte packets).
  final bool m2ts;

  bool get isDvdStream => dvdAudio.isNotEmpty || dvd != null;

  /// The bytes for the player: [audio] the DVD sound track to keep;
  /// [exoPlayer]: Android's player (it needs DVD's AC3 without the DVD
  /// header, and plain 188-byte MPEG-TS).
  MovieByteSource sourceFor({DvdAudioStream? audio, required bool exoPlayer}) {
    if (isDvdStream) {
      final filter = DvdPackFilter(keep: audio, stripHeader: exoPlayer);
      return PacketMappedSource(base, inSize: discPack, outSize: discPack, map: (pack) {
        filter.apply(pack);
        return pack;
      });
    }
    if (m2ts && exoPlayer) return PacketMappedSource(base, inSize: 192, outSize: 188, map: m2tsToTs);
    return base;
  }

  /// The tracks the player can play: ExoPlayer has no DTS or LPCM in
  /// program streams.
  List<DvdAudioStream> playableAudio({required bool exoPlayer}) => [
        for (final a in dvdAudio)
          if (!exoPlayer || a.coding == DvdAudioCoding.ac3 || a.coding == DvdAudioCoding.mpeg) a,
      ];

  /// The sound to start with: in [language] if there is one (not the
  /// comments track), else the first.
  DvdAudioStream? defaultAudio({required bool exoPlayer, required String language}) {
    final playable = playableAudio(exoPlayer: exoPlayer);
    if (playable.isEmpty) return dvdAudio.firstOrNull;
    return playable.where((a) => a.language == language && a.extension <= 1).firstOrNull ?? playable.first;
  }
}

/// A user-facing error of the films part.
class MovieException implements Exception {
  const MovieException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// [length] bytes at [offset] of [path].
Future<Uint8List> readNasRange(NasClient client, String path, int offset, int length) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in client.openRead(path, offset: offset, length: length)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Looks [movie] up on the NAS (sizes, a DVD's files and IFO; only a few
/// small reads) - throws [MovieException] / [NasException].
Future<PreparedMovie> prepareMovie(NasClient client, MovieItem movie) async {
  switch (movie.kind) {
    case MovieKind.iso:
      return _prepareIso(client, movie.path);
    case MovieKind.dvdFolder:
      return _prepareDvdFolder(client, movie.path);
    case MovieKind.file:
      return _prepareFile(client, movie);
  }
}

Future<PreparedMovie> _prepareFile(NasClient client, MovieItem movie) async {
  final size = movie.size ?? await client.size(movie.path);
  if (size == null || size <= 0) throw NasException(l10n.nasErrorNotFound);
  final extension = fileExtension(movie.path);
  final base = NasSegmentsSource(client, [NasSegment(movie.path, 0, size)]);
  if (const {'vob', 'mpg', 'mpeg', 'mpe'}.contains(extension)) {
    // A DVD's stream (a VOB, or an MPEG cut from a DVD): its sound tracks.
    final head = await readNasRange(client, movie.path, 0, size < 1 << 20 ? size : 1 << 20);
    if (looksLikeDvdStream(head)) {
      final audio = scanDvdAudio(head);
      if (audio.isNotEmpty) {
        return PreparedMovie._(base: base, name: 'movie.mpg', mime: movieMimeType('mpg'), dvdAudio: audio);
      }
    }
  }
  if (const {'mts', 'm2ts'}.contains(extension)) {
    final head = await readNasRange(client, movie.path, 0, size < 1024 ? size : 1024);
    if (looksLikeM2ts(head)) return PreparedMovie._(base: base, name: 'movie.ts', mime: movieMimeType('ts'), m2ts: true);
  }
  final name = 'movie.${extension.isEmpty ? 'bin' : extension}';
  return PreparedMovie._(base: base, name: name, mime: movieMimeType(extension));
}

Future<PreparedMovie> _prepareIso(NasClient client, String path) async {
  final files = await readDiscFolder((offset, length) => readNasRange(client, path, offset, length), 'VIDEO_TS');
  if (files == null) throw MovieException(l10n.moviesErrorNoDvd);
  final vobs = <DvdVob<DiscFile>>[
    for (final f in files)
      if (parseVobName(f.name) case final v?) DvdVob(titleSet: v.titleSet, part: v.part, size: f.size, file: f),
  ];
  final title = pickMainTitle(vobs);
  if (title.isEmpty) throw MovieException(l10n.moviesErrorNoDvd);
  final segments = [
    for (final v in title)
      for (final e in v.file.extents) NasSegment(path, e.offset, e.length),
  ];
  DvdTitleInfo? info;
  final ifo = files.where((f) => f.name == ifoNameOf(title.first.titleSet)).firstOrNull;
  if (ifo != null && ifo.size < 4 << 20 && ifo.extents.length == 1) {
    try {
      info = parseVtsIfo(await readNasRange(client, path, ifo.extents.single.offset, ifo.size));
    } catch (_) {}
  }
  return _dvd(client, NasSegmentsSource(client, segments), info);
}

Future<PreparedMovie> _prepareDvdFolder(NasClient client, String folder) async {
  var entries = await client.list(folder);
  var dir = folder;
  final videoTs = entries.where((e) => e.isDirectory && e.name.toUpperCase() == 'VIDEO_TS').firstOrNull;
  if (videoTs != null) {
    dir = videoTs.path;
    entries = await client.list(dir);
  }
  final vobs = <DvdVob<NasEntry>>[
    for (final e in entries)
      if (!e.isDirectory)
        if (parseVobName(e.name) case final v?) DvdVob(titleSet: v.titleSet, part: v.part, size: e.size ?? 0, file: e),
  ];
  final title = pickMainTitle(vobs);
  if (title.isEmpty) throw MovieException(l10n.moviesErrorNoDvd);
  final segments = <NasSegment>[];
  for (final v in title) {
    final size = v.file.size ?? await client.size(v.file.path) ?? 0;
    if (size > 0) segments.add(NasSegment(v.file.path, 0, size));
  }
  DvdTitleInfo? info;
  final ifoName = ifoNameOf(title.first.titleSet);
  final ifo = entries.where((e) => !e.isDirectory && e.name.toUpperCase() == ifoName).firstOrNull;
  if (ifo != null) {
    try {
      info = parseVtsIfo(await client.read(ifo.path, maxBytes: 4 << 20));
    } catch (_) {}
  }
  return _dvd(client, NasSegmentsSource(client, segments), info);
}

Future<PreparedMovie> _dvd(NasClient client, NasSegmentsSource source, DvdTitleInfo? info) async {
  var audio = info?.audio ?? const <DvdAudioStream>[];
  if (audio.isEmpty && source.length > 0) {
    // No IFO (or it names no sound): what the first packs carry.
    final head = BytesBuilder(copy: false);
    await for (final chunk in source.read(0, source.length < 1 << 20 ? source.length : 1 << 20)) {
      head.add(chunk);
    }
    audio = scanDvdAudio(head.takeBytes());
  }
  return PreparedMovie._(base: source, name: 'movie.mpg', mime: movieMimeType('mpg'), dvd: info, dvdAudio: audio);
}
