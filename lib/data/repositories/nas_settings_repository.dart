import 'dart:convert';

import '../../l10n/l10n.dart';
import '../db/database.dart';
import '../services/nas_service.dart';
import '../services/secret_store.dart';

/// Settings → NAS: server, login and the chosen folders.
class NasSettings {
  final NasConfig config;

  /// Chosen folder per kind (absolute remote paths); missing = not chosen.
  /// Never [NasFolder.movies] or [NasFolder.videos] - those are
  /// [movieFolders] now.
  final Map<NasFolder, String> folders;

  /// The films part's folders, in the user's order (any number).
  final List<MovieFolder> movieFolders;

  const NasSettings({this.config = const NasConfig(), this.folders = const {}, this.movieFolders = const []});

  /// The folder of [kind], or null if the NAS isn't set up or none is chosen.
  String? folder(NasFolder kind) => config.isConfigured ? folders[kind] : null;

  /// [movieFolders] - empty if the NAS isn't set up.
  List<MovieFolder> get movieSources => config.isConfigured ? movieFolders : const [];

  NasSettings copyWith({NasConfig? config, Map<NasFolder, String>? folders, List<MovieFolder>? movieFolders}) =>
      NasSettings(
        config: config ?? this.config,
        folders: folders ?? this.folders,
        movieFolders: movieFolders ?? this.movieFolders,
      );
}

/// The folders chosen one at a time (Settings → NAS) - without the old
/// fixed "Filme" and "Videos" folders, which are [MovieFolder]s now.
List<NasFolder> get singleNasFolders => [
      for (final kind in NasFolder.values)
        if (kind != NasFolder.movies && kind != NasFolder.videos) kind,
    ];

/// One folder of the films part: where it is on the NAS and what it's
/// called in Filme (its own place there, like "Filme" and "Videos" were).
class MovieFolder {
  const MovieFolder({required this.path, this.name = ''});

  /// Absolute remote path (see [NasConfig]).
  final String path;

  /// As the user named it; empty: [defaultName] of the path.
  final String name;

  /// The name shown.
  String get label => name.trim().isEmpty ? defaultName(path) : name.trim();

  MovieFolder copyWith({String? path, String? name}) => MovieFolder(path: path ?? this.path, name: name ?? this.name);

  /// The folder's own name ("Spielfilme" of "/Daten/Spielfilme"), the
  /// share's or "/" at the top.
  static String defaultName(String path) {
    final normalized = normalizeNasPath(path);
    return normalized == '/' ? '/' : normalized.split('/').last;
  }

  Map<String, Object?> toJson() => {'path': path, 'name': name};

  /// null if [json] isn't a folder (no path).
  static MovieFolder? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final name = json['name'];
    if (path is! String || path.trim().isEmpty) return null;
    return MovieFolder(path: normalizeNasPath(path), name: name is String ? name : '');
  }

  @override
  bool operator ==(Object other) => other is MovieFolder && other.path == path && other.name == name;

  @override
  int get hashCode => Object.hash(path, name);

  @override
  String toString() => 'MovieFolder($name: $path)';
}

/// The stored list (JSON) - unreadable entries are left out, unreadable
/// text gives an empty list.
List<MovieFolder> decodeMovieFolders(String raw) {
  try {
    final json = jsonDecode(raw);
    if (json is! List) return const [];
    return [for (final entry in json) ?MovieFolder.fromJson(entry)];
  } catch (_) {
    return const [];
  }
}

String encodeMovieFolders(List<MovieFolder> folders) => jsonEncode([for (final f in folders) f.toJson()]);

/// Before the list, Filme had the two fixed folders "Filme" and "Videos"
/// (settings nas_folder_movies / nas_folder_videos): they become its first
/// entries, with those names.
List<MovieFolder> migrateMovieFolders({
  String? movies,
  String? videos,
  required String moviesName,
  required String videosName,
}) => [
      if (movies != null && movies.trim().isNotEmpty) MovieFolder(path: normalizeNasPath(movies), name: moviesName),
      if (videos != null && videos.trim().isNotEmpty) MovieFolder(path: normalizeNasPath(videos), name: videosName),
    ];

/// Stores [NasSettings] in the settings table (so backups carry them) - the
/// password in the [SecretStore].
class NasSettingsRepository {
  NasSettingsRepository(this._db) : _secrets = SecretStore(_db);

  final AppDatabase _db;
  final SecretStore _secrets;

  /// SecretStore key of the NAS password.
  static const passwordKey = 'nas_password';

  static const _protocol = 'nas_protocol';
  static const _host = 'nas_host';
  static const _port = 'nas_port';
  static const _https = 'nas_https';
  static const _basePath = 'nas_base_path';
  static const _user = 'nas_user';
  static const _domain = 'nas_domain';
  static String _folderKey(NasFolder kind) => 'nas_folder_${kind.name}';

  /// The films part's folders (JSON list of {path, name}); missing: not
  /// yet migrated from nas_folder_movies / nas_folder_videos.
  static const movieFoldersKey = 'nas_movie_folders';

  Future<NasSettings> load() async {
    final protocol = await _db.getSetting(_protocol);
    final config = NasConfig(
      protocol: NasProtocol.values.firstWhere((p) => p.name == protocol, orElse: () => NasProtocol.webdav),
      host: await _db.getSetting(_host) ?? '',
      port: int.tryParse(await _db.getSetting(_port) ?? ''),
      https: await _db.getSetting(_https) == 'true',
      basePath: await _db.getSetting(_basePath) ?? '',
      user: await _db.getSetting(_user) ?? '',
      password: await _secrets.read(passwordKey) ?? '',
      domain: await _db.getSetting(_domain) ?? '',
    );
    final folders = <NasFolder, String>{};
    for (final kind in NasFolder.values) {
      final path = await _db.getSetting(_folderKey(kind));
      if (path != null && path.isNotEmpty) folders[kind] = path;
    }
    // Before the own background folder, Home's pictures came from the
    // pictures folder - it carries on as the background folder.
    final pictures = folders[NasFolder.pictures];
    if (!folders.containsKey(NasFolder.backgrounds) &&
        pictures != null &&
        await _db.getSetting(_folderKey(NasFolder.backgrounds)) == null) {
      folders[NasFolder.backgrounds] = pictures;
      await setFolder(NasFolder.backgrounds, pictures);
    }
    final movieFolders = await _loadMovieFolders(folders);
    folders
      ..remove(NasFolder.movies)
      ..remove(NasFolder.videos);
    return NasSettings(config: config, folders: folders, movieFolders: movieFolders);
  }

  /// The stored list - or, the first time (also after restoring an older
  /// backup), the old "Filme" and "Videos" folders from [folders] as its
  /// first entries. The old settings stay as they were.
  Future<List<MovieFolder>> _loadMovieFolders(Map<NasFolder, String> folders) async {
    final raw = await _db.getSetting(movieFoldersKey);
    if (raw != null) return decodeMovieFolders(raw);
    final texts = lookupAppLocalizations(AppLanguage.parse(await _db.getSetting('language')).locale);
    final migrated = migrateMovieFolders(
      movies: folders[NasFolder.movies],
      videos: folders[NasFolder.videos],
      moviesName: texts.nasFolderMovies,
      videosName: texts.nasFolderVideos,
    );
    if (migrated.isNotEmpty) await saveMovieFolders(migrated);
    return migrated;
  }

  Future<void> saveMovieFolders(List<MovieFolder> folders) =>
      _db.setSetting(movieFoldersKey, encodeMovieFolders(folders));

  Future<void> saveConfig(NasConfig config) async {
    await _db.setSetting(_protocol, config.protocol.name);
    await _db.setSetting(_host, config.host.trim());
    await _db.setSetting(_port, config.port?.toString() ?? '');
    await _db.setSetting(_https, '${config.https}');
    await _db.setSetting(_basePath, config.basePath.trim());
    await _db.setSetting(_user, config.user);
    await _db.setSetting(_domain, config.domain.trim());
    await _secrets.write(passwordKey, config.password);
  }

  /// [path] null or empty clears the folder.
  Future<void> setFolder(NasFolder kind, String? path) => _db.setSetting(_folderKey(kind), path ?? '');
}
