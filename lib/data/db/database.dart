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
  // User-provided override for [stationLabel] - DAB+ FIG labels sometimes
  // carry decorative/garbled-looking special characters that are genuinely
  // how the station spelled its name over the air (confirmed real-world AT
  // ensembles, not a decode bug), so this lets the user replace it with
  // something readable. Null means "use stationLabel as-is".
  TextColumn get customLabel => text().nullable()();

  @override
  Set<Column> get primaryKey => {freqKhz, serviceId};
}

@DriftDatabase(tables: [Favorites, Settings, DabStations])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(dabStations);
          if (from < 3) await m.addColumn(dabStations, dabStations.customLabel);
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

  Future<void> updateFavoriteLogoUrl(int programNumber, String logoUrl) {
    return (update(favorites)..where((f) => f.programNumber.equals(programNumber)))
        .write(FavoritesCompanion(logoUrl: Value(logoUrl)));
  }

  /// Renumbers a favorite in place (its program number is its primary key).
  /// Callers must route through a temporary, out-of-range number when
  /// swapping two favorites directly - see [FavoritesRepository.swapProgramNumbers] -
  /// since going straight from A's number to B's (while B still holds it)
  /// would hit the primary key's uniqueness constraint mid-transaction.
  Future<void> setFavoriteProgramNumber(int oldNumber, int newNumber) {
    return (update(favorites)..where((f) => f.programNumber.equals(oldNumber)))
        .write(FavoritesCompanion(programNumber: Value(newNumber)));
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

  Future<void> setDabStationCustomLabel(int freqKhz, int serviceId, String? customLabel) {
    return (update(dabStations)
          ..where((s) => s.freqKhz.equals(freqKhz) & s.serviceId.equals(serviceId)))
        .write(DabStationsCompanion(customLabel: Value(customLabel)));
  }

  Future<void> clearDabStations() => delete(dabStations).go();

  Future<void> updateFavoriteDisplayName(int programNumber, String displayName) {
    return (update(favorites)..where((f) => f.programNumber.equals(programNumber)))
        .write(FavoritesCompanion(displayName: Value(displayName)));
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'home_radio.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
