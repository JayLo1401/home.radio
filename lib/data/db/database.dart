import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// A single entry in the merged favorites list (DAB+ or internet radio),
/// identified by a unique station-preset "program number".
class Favorites extends Table {
  IntColumn get programNumber => integer()();
  TextColumn get sourceType => text()(); // 'dab' | 'internet'
  TextColumn get displayName => text()();
  TextColumn get logoUrl => text().nullable()();
  TextColumn get logoLocalPath => text().nullable()();
  // JSON-encoded source-specific reference:
  // internet: {"streamUrl": "...", "stationUuid": "..."}
  // dab: {"ensembleId": "...", "serviceId": "...", "frequencyKhz": ...}
  TextColumn get sourceRef => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {programNumber};
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Every DAB+ station a scan has ever found, keyed by which Band III
/// frequency + DAB Service Id (SId) it lives on - persisted independently of
/// [Favorites] so the "Alle DAB+ Sender" list survives across scans/app
/// restarts and stations can be favorited without re-scanning.
class DabStations extends Table {
  IntColumn get freqKhz => integer()();
  IntColumn get serviceId => integer()();
  TextColumn get channelLabel => text()(); // e.g. "8D"
  TextColumn get stationLabel => text()();
  TextColumn get ensembleLabel => text().nullable()();
  DateTimeColumn get lastSeenAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {freqKhz, serviceId};
}

@DriftDatabase(tables: [Favorites, Settings, DabStations])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(dabStations);
        },
      );

  Future<int?> nextFreeProgramNumber() async {
    final rows = await select(favorites).get();
    final used = rows.map((r) => r.programNumber).toSet();
    for (var i = 1; i <= 999; i++) {
      if (!used.contains(i)) return i;
    }
    return null;
  }

  Stream<List<Favorite>> watchFavorites() {
    return (select(favorites)..orderBy([(f) => OrderingTerm.asc(f.programNumber)]))
        .watch();
  }

  Future<void> upsertFavorite(FavoritesCompanion entry) {
    return into(favorites).insertOnConflictUpdate(entry);
  }

  Future<void> removeFavorite(int programNumber) {
    return (delete(favorites)..where((f) => f.programNumber.equals(programNumber))).go();
  }

  Future<String?> getSetting(String key) async {
    final row = await (select(settings)..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) {
    return into(settings).insertOnConflictUpdate(
      SettingsCompanion.insert(key: key, value: value),
    );
  }

  Stream<List<DabStation>> watchDabStations() {
    return (select(dabStations)
          ..orderBy([
            (s) => OrderingTerm.asc(s.ensembleLabel),
            (s) => OrderingTerm.asc(s.stationLabel),
          ]))
        .watch();
  }

  Future<void> upsertDabStation(DabStationsCompanion entry) {
    return into(dabStations).insertOnConflictUpdate(entry);
  }

  Future<void> clearDabStations() => delete(dabStations).go();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'home_radio.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
