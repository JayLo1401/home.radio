import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/nas_providers.dart';
import 'package:home_system/data/db/database.dart';
import 'package:home_system/data/repositories/nas_settings_repository.dart';
import 'package:home_system/data/services/backup_service.dart';
import 'package:home_system/data/services/movie_resume_store.dart';
import 'package:home_system/data/services/nas_service.dart';
import 'package:home_system/features/movies/movies_screen.dart';
import 'package:home_system/l10n/l10n.dart';

class _NasSettings extends NasSettingsNotifier {
  _NasSettings(this.settings);

  final NasSettings settings;

  @override
  Future<NasSettings> build() async => settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MovieFolder', () {
    test('default name is the folder\'s own name', () {
      expect(MovieFolder.defaultName('/Daten/Spielfilme'), 'Spielfilme');
      expect(MovieFolder.defaultName('Daten/Kinder/'), 'Kinder');
      expect(MovieFolder.defaultName('/'), '/');
      expect(const MovieFolder(path: '/Daten/Doku').label, 'Doku');
      expect(const MovieFolder(path: '/Daten/Doku', name: '  ').label, 'Doku');
      expect(const MovieFolder(path: '/Daten/Doku', name: ' Dokus ').label, 'Dokus');
    });

    test('encode and decode keep order, names and paths', () {
      const folders = [
        MovieFolder(path: '/Filme', name: 'Filme'),
        MovieFolder(path: '/Videos/Urlaub', name: ''),
        MovieFolder(path: '/Kinder', name: 'Für die Kinder'),
      ];
      expect(decodeMovieFolders(encodeMovieFolders(folders)), folders);
    });

    test('decode skips broken entries and survives broken text', () {
      expect(decodeMovieFolders('not json'), isEmpty);
      expect(decodeMovieFolders('{"path": "/a"}'), isEmpty);
      expect(
        decodeMovieFolders('[{"path": "a\\\\b"}, {"name": "x"}, 3, {"path": ""}, {"path": "/c", "name": 5}]'),
        const [MovieFolder(path: '/a/b'), MovieFolder(path: '/c')],
      );
    });
  });

  group('migrateMovieFolders', () {
    test('Filme and Videos become the first entries, in this order', () {
      expect(
        migrateMovieFolders(movies: '/Daten/Filme', videos: '/Daten/Videos/', moviesName: 'Filme', videosName: 'Videos'),
        const [MovieFolder(path: '/Daten/Filme', name: 'Filme'), MovieFolder(path: '/Daten/Videos', name: 'Videos')],
      );
    });

    test('only the chosen ones', () {
      expect(
        migrateMovieFolders(movies: '', videos: '/V', moviesName: 'Filme', videosName: 'Videos'),
        const [MovieFolder(path: '/V', name: 'Videos')],
      );
      expect(migrateMovieFolders(moviesName: 'Filme', videosName: 'Videos'), isEmpty);
    });
  });

  group('NasSettingsRepository', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('old Filme/Videos settings (also from an old backup) move into the list once', () async {
      await db.setSetting('nas_host', 'nas');
      await db.setSetting('language', 'de');
      await db.setSetting('nas_folder_movies', '/Daten/Filme');
      await db.setSetting('nas_folder_videos', '/Daten/Videos');
      await db.setSetting('nas_folder_music', '/Daten/Musik');
      final repo = NasSettingsRepository(db);

      final settings = await repo.load();
      expect(settings.movieFolders, const [
        MovieFolder(path: '/Daten/Filme', name: 'Filme'),
        MovieFolder(path: '/Daten/Videos', name: 'Videos'),
      ]);
      expect(settings.movieSources, settings.movieFolders);
      expect(settings.folders.containsKey(NasFolder.movies), isFalse);
      expect(settings.folders.containsKey(NasFolder.videos), isFalse);
      expect(settings.folder(NasFolder.music), '/Daten/Musik');
      expect(await db.getSetting(NasSettingsRepository.movieFoldersKey), isNotNull);

      // Changed (here: all removed) - the old settings don't come back.
      await repo.saveMovieFolders(const []);
      expect((await repo.load()).movieFolders, isEmpty);
    });

    test('restoring an old backup over a new list brings its Filme/Videos back as the list', () async {
      final repo = NasSettingsRepository(db);
      await repo.saveMovieFolders(const [MovieFolder(path: '/Neu', name: 'Neu')]);
      await BackupService(db).restoreJson(jsonEncode({
        'app': 'home_radio',
        'format': 1,
        'settings': [
          {'key': 'nas_host', 'value': 'nas'},
          {'key': 'nas_folder_movies', 'value': '/Alt/Filme'},
        ],
      }));
      expect((await repo.load()).movieFolders, [MovieFolder(path: '/Alt/Filme', name: lookupAppLocalizations(AppLanguage.system.locale).nasFolderMovies)]);
      // A new backup carries the list itself.
      final restored = await BackupService(db).export();
      await repo.saveMovieFolders(const []);
      await BackupService(db).restoreJson(restored.content);
      expect((await repo.load()).movieFolders, hasLength(1));
    });

    test('English names on an English device', () async {
      await db.setSetting('language', 'en');
      await db.setSetting('nas_folder_videos', '/V');
      expect((await NasSettingsRepository(db).load()).movieFolders, const [MovieFolder(path: '/V', name: 'Videos')]);
    });

    test('nothing to migrate, nothing stored', () async {
      final settings = await NasSettingsRepository(db).load();
      expect(settings.movieFolders, isEmpty);
      expect(await db.getSetting(NasSettingsRepository.movieFoldersKey), isNull);
    });

    test('without a server, Filme has no sources', () async {
      await NasSettingsRepository(db).saveMovieFolders(const [MovieFolder(path: '/F')]);
      final settings = await NasSettingsRepository(db).load();
      expect(settings.movieFolders, hasLength(1));
      expect(settings.movieSources, isEmpty);
    });
  });

  testWidgets('Filme lists every folder by its name, in order', (tester) async {
    const settings = NasSettings(
      config: NasConfig(host: 'nas'),
      movieFolders: [
        MovieFolder(path: '/Daten/Filme', name: 'Filme'),
        MovieFolder(path: '/Daten/Videos', name: 'Videos'),
        MovieFolder(path: '/Daten/Kinderfilme'),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        nasSettingsProvider.overrideWith(() => _NasSettings(settings)),
        movieResumeStoreProvider.overrideWithValue(MovieResumeStore(file: () async => throw UnsupportedError('test'))),
      ],
      child: MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MoviesScreen(),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final names = [for (final w in tester.widgetList<Text>(find.byType(Text))) w.data];
    expect(names.where((n) => const ['Filme', 'Videos', 'Kinderfilme'].contains(n)).toList(),
        // The heading "Filme", then the three places.
        ['Filme', 'Filme', 'Videos', 'Kinderfilme']);
  });
}
