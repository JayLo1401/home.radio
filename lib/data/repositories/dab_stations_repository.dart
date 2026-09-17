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

  /// Overrides the decoded FIG label for one station - DAB+ labels sometimes
  /// carry genuinely-real but garbled-looking special characters, so this
  /// lets the user replace it (see [DabStationDisplay.displayLabel]). An
  /// empty [customLabel] reverts back to the decoded [DabStation.stationLabel].
  Future<void> setCustomLabel({
    required int freqKhz,
    required int serviceId,
    required String? customLabel,
  }) {
    final trimmed = customLabel?.trim();
    return _db.setDabStationCustomLabel(freqKhz, serviceId, trimmed?.isEmpty ?? true ? null : trimmed);
  }
}

/// [DabStation.stationLabel] with any user-provided [DabStation.customLabel]
/// override applied - use this everywhere a station's name is displayed.
extension DabStationDisplay on DabStation {
  String get displayLabel {
    final custom = customLabel;
    return custom == null || custom.isEmpty ? stationLabel : custom;
  }
}
