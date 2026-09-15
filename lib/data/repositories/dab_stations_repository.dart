import 'package:drift/drift.dart';

import '../db/database.dart';

/// Persisted "all DAB+ stations ever found by a scan" list - independent of
/// [FavoritesRepository]/Favorites, so stations can be browsed and favorited
/// without re-scanning every time, and cleared out separately if the user
/// wants a fresh scan result set.
class DabStationsRepository {
  final AppDatabase _db;

  DabStationsRepository(this._db);

  Stream<List<DabStation>> watchAll() => _db.watchDabStations();

  Future<void> upsert({
    required int freqKhz,
    required int serviceId,
    required String channelLabel,
    required String stationLabel,
    String? ensembleLabel,
  }) {
    return _db.upsertDabStation(
      DabStationsCompanion.insert(
        freqKhz: freqKhz,
        serviceId: serviceId,
        channelLabel: channelLabel,
        stationLabel: stationLabel,
        ensembleLabel: Value(ensembleLabel),
        lastSeenAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> clearAll() => _db.clearDabStations();
}
