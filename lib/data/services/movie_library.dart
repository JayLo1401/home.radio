import 'nas_service.dart';

/// What the films part shows of the NAS: films (single files, DVD images,
/// DVD folders) and the folders around them - worked out from listings
/// only (no file is opened for it).

/// Film files by extension (lower case). Home videos from phones and
/// cameras too: .mts (AVCHD), .3gp, .3g2, .mov. And the old formats VLC
/// plays (libmpv takes them on Android - see firstMovieEngine): RealMedia
/// (rm, rmvb, ra), DivX/Xvid, Windows Media (asf), Flash video (flv, f4v),
/// Ogg video (ogm, ogv), raw MPEG video (m1v, m2v, mpe), QuickTime (qt),
/// DV, Windows Media Center (wtv). Not .ram: only a link to a stream.
const movieExtensions = {
  'mp4', 'm4v', 'mkv', 'avi', 'mpg', 'mpeg', 'ts', 'm2ts', 'mts', 'vob', 'wmv', 'mov', 'webm', '3gp', 'iso', //
  'divx', 'xvid', 'asf', 'flv', 'f4v', 'ogm', 'ogv', 'm1v', 'm2v', 'mpe', 'qt', '3g2', //
  'rm', 'rmvb', 'ra', 'dv', 'wtv', //
};

const _pictureExtensions = {'jpg', 'jpeg', 'png', 'webp'};

/// "mkv" of "Film.MKV"; '' without.
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1 ? '' : name.substring(dot + 1).toLowerCase();
}

/// The name without its extension.
String fileBaseName(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

bool isMovieFileName(String name) => movieExtensions.contains(fileExtension(name));

/// A film's name as people write it: without the extension, dots and
/// underscores as spaces ("Der_Pate.1972.mkv" → "Der Pate 1972"), a year
/// in brackets stays ("Heat (1995)").
String movieTitle(String name, {bool isFile = true}) {
  var title = isFile ? fileBaseName(name) : name;
  // Dots between letters/digits only - "Dr. No" keeps its dot and space.
  title = title.replaceAll('_', ' ').replaceAllMapped(RegExp(r'\.(?=\S)'), (_) => ' ');
  title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  return title.isEmpty ? name : title;
}

/// How a film is stored.
enum MovieKind {
  /// A video file (mp4, mkv, mpg ...).
  file,

  /// A DVD image: the film's VOB files inside the .iso.
  iso,

  /// A folder with the DVD's VIDEO_TS (or the VIDEO_TS folder itself).
  dvdFolder,
}

/// One film of the library.
class MovieItem {
  const MovieItem({
    required this.path,
    required this.title,
    required this.kind,
    this.size,
    this.poster,
    this.subtitles = const [],
  });

  /// The file - or for [MovieKind.dvdFolder] the folder.
  final String path;
  final String title;
  final MovieKind kind;
  final int? size;

  /// A picture next to it (NAS path).
  final String? poster;

  /// Subtitle files (.srt) next to it, the best first.
  final List<String> subtitles;

  MovieItem copyWith({String? title, String? poster}) => MovieItem(
        path: path,
        title: title ?? this.title,
        kind: kind,
        size: size,
        poster: poster ?? this.poster,
        subtitles: subtitles,
      );

  @override
  String toString() => 'MovieItem($kind $path)';
}

/// An entry of a library page: a film, or a folder to open.
class MovieLibraryEntry {
  const MovieLibraryEntry.movie(MovieItem this.movie)
      : folder = null,
        folderPoster = null;
  const MovieLibraryEntry.folder(NasEntry this.folder, {this.folderPoster}) : movie = null;

  final MovieItem? movie;
  final NasEntry? folder;
  final String? folderPoster;

  String get path => movie?.path ?? folder!.path;
  String get title => movie?.title ?? movieTitle(folder!.name, isFile: false);
  String? get poster => movie?.poster ?? folderPoster;
}

bool _isPicture(NasEntry e) => !e.isDirectory && _pictureExtensions.contains(fileExtension(e.name));

bool _isDvdFolderName(String name) => name.toUpperCase() == 'VIDEO_TS';

bool _isVob(NasEntry e) => !e.isDirectory && fileExtension(e.name) == 'vob';

/// The folder picture of a folder's listing: folder.jpg, poster.jpg,
/// cover.jpg (any of the picture formats, any case).
String? folderPosterIn(List<NasEntry> entries) {
  for (final base in const ['folder', 'poster', 'cover']) {
    for (final e in entries) {
      if (_isPicture(e) && fileBaseName(e.name).toLowerCase() == base) return e.path;
    }
  }
  return null;
}

/// The picture of the film [movieName] in its folder: `Name.jpg`,
/// `Name-poster.jpg` - or the folder's picture if it's the only film.
String? moviePosterIn(List<NasEntry> entries, String movieName, {required bool onlyMovie}) {
  final base = fileBaseName(movieName).toLowerCase();
  for (final suffix in const ['', '-poster', '.poster', '-cover']) {
    for (final e in entries) {
      if (_isPicture(e) && fileBaseName(e.name).toLowerCase() == '$base$suffix') return e.path;
    }
  }
  return onlyMovie ? folderPosterIn(entries) : null;
}

/// Subtitle files of [movieName]: `Name.srt`, `Name.de.srt`,
/// `Name.ger.srt` ... - those in [language] first.
List<String> subtitlesIn(List<NasEntry> entries, String movieName, {String language = 'de'}) {
  final base = fileBaseName(movieName).toLowerCase();
  final found = <({String path, String tag})>[];
  for (final e in entries) {
    if (e.isDirectory || fileExtension(e.name) != 'srt') continue;
    final name = fileBaseName(e.name).toLowerCase();
    if (name == base) {
      found.add((path: e.path, tag: ''));
    } else if (name.startsWith('$base.')) {
      found.add((path: e.path, tag: name.substring(base.length + 1)));
    }
  }
  final codes = switch (language) {
    'de' => const {'de', 'ger', 'deu', 'german', 'deutsch'},
    'en' => const {'en', 'eng', 'english'},
    _ => {language},
  };
  int rank(String tag) => tag.split('.').any(codes.contains) ? 0 : (tag.isEmpty ? 1 : 2);
  found.sort((a, b) => rank(a.tag).compareTo(rank(b.tag)));
  return [for (final f in found) f.path];
}

/// The films and folders of [folder]'s listing, for one library page:
/// folders first (without VIDEO_TS/AUDIO_TS - a DVD folder shows as the
/// film), then the films by name. A folder with a VIDEO_TS in it, or a
/// VIDEO_TS folder itself, is a DVD film.
List<MovieLibraryEntry> buildMoviePage(String folder, List<NasEntry> entries, {String language = 'de'}) {
  final result = <MovieLibraryEntry>[];
  final folderName = normalizeNasPath(folder).split('/').last;
  final dvd = dvdFolderIn(folder, entries);
  if (dvd != null) {
    final title = _isDvdFolderName(folderName)
        ? movieTitle(normalizeNasPath(parentNasPath(folder)).split('/').last, isFile: false)
        : movieTitle(folderName, isFile: false);
    result.add(MovieLibraryEntry.movie(MovieItem(
      path: dvd,
      title: title.isEmpty || title == '/' ? 'DVD' : title,
      kind: MovieKind.dvdFolder,
      poster: folderPosterIn(entries),
    )));
  }
  for (final e in entries) {
    if (!e.isDirectory) continue;
    final upper = e.name.toUpperCase();
    if (upper == 'VIDEO_TS' || upper == 'AUDIO_TS' || e.name.startsWith('.') || e.name.startsWith('@')) continue;
    result.add(MovieLibraryEntry.folder(e));
  }
  final movies = [
    for (final e in entries)
      if (!e.isDirectory && isMovieFileName(e.name) && !(dvd != null && _isVob(e))) e,
  ];
  for (final e in movies) {
    result.add(MovieLibraryEntry.movie(movieItemOf(e, entries, onlyMovie: movies.length == 1, language: language)));
  }
  return result;
}

/// [file] (a film file) as a [MovieItem], with its picture and subtitles
/// from the folder's [entries].
MovieItem movieItemOf(NasEntry file, List<NasEntry> entries, {required bool onlyMovie, String language = 'de'}) =>
    MovieItem(
      path: file.path,
      title: movieTitle(file.name),
      kind: fileExtension(file.name) == 'iso' ? MovieKind.iso : MovieKind.file,
      size: file.size,
      poster: moviePosterIn(entries, file.name, onlyMovie: onlyMovie),
      subtitles: subtitlesIn(entries, file.name, language: language),
    );

/// The DVD of a folder's listing: the folder path to play if [entries]
/// has a VIDEO_TS folder ([folder] itself is the film), or [folder] is a
/// VIDEO_TS with VOB files; else null.
String? dvdFolderIn(String folder, List<NasEntry> entries) {
  final name = normalizeNasPath(folder).split('/').last;
  if (_isDvdFolderName(name) && entries.any(_isVob)) return normalizeNasPath(folder);
  if (entries.any((e) => e.isDirectory && _isDvdFolderName(e.name))) return normalizeNasPath(folder);
  return null;
}

/// What a folder holds, seen from the page above: a film folder (exactly
/// one film, or a DVD) plays at once; otherwise it opens - with its
/// picture.
class MovieFolderPeek {
  const MovieFolderPeek({this.movie, this.poster});

  /// The film if the folder is one.
  final MovieItem? movie;
  final String? poster;
}

/// [folder] (an entry of the page above) by its listing [entries].
MovieFolderPeek peekMovieFolder(NasEntry folder, List<NasEntry> entries, {String language = 'de'}) {
  final poster = folderPosterIn(entries);
  final title = movieTitle(folder.name, isFile: false);
  if (dvdFolderIn(folder.path, entries) != null) {
    return MovieFolderPeek(
      movie: MovieItem(path: folder.path, title: title, kind: MovieKind.dvdFolder, poster: poster),
      poster: poster,
    );
  }
  final subfolders = entries.where((e) => e.isDirectory && !e.name.startsWith('.') && !e.name.startsWith('@'));
  final movies = entries.where((e) => !e.isDirectory && isMovieFileName(e.name)).toList();
  if (movies.length == 1 && subfolders.isEmpty) {
    final item = movieItemOf(movies.single, entries, onlyMovie: true, language: language);
    return MovieFolderPeek(movie: item.copyWith(title: title), poster: item.poster ?? poster);
  }
  return MovieFolderPeek(poster: poster);
}
