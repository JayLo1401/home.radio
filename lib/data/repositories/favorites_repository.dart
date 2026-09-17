import 'package:drift/drift.dart';

import '../db/database.dart';
import '../models/favorite_channel.dart';
import '../models/internet_radio_station.dart';

class FavoritesRepository {
  final AppDatabase _db;

  FavoritesRepository(this._db);

  Stream<List<FavoriteChannel>> watchFavorites() {
    return _db.watchFavorites().map(
          (rows) => rows.map(_toChannel).toList(),
        );
  }

  Future<int?> nextFreeProgramNumber() => _db.nextFreeProgramNumber();

  FavoriteChannel _toChannel(Favorite row) {
    return FavoriteChannel(
      programNumber: row.programNumber,
      sourceType: FavoriteChannel.parseSourceType(row.sourceType),
      displayName: row.displayName,
      logoUrl: row.logoUrl,
      logoLocalPath: row.logoLocalPath,
      sourceRef: FavoriteChannel.decodeSourceRef(row.sourceRef),
    );
  }

  Future<void> addInternetStation({
    required int programNumber,
    required InternetRadioStation station,
  }) {
    return _db.upsertFavorite(
      FavoritesCompanion.insert(
        programNumber: Value(programNumber),
        sourceType: 'internet',
        displayName: station.name,
        logoUrl: Value(station.favicon),
        sourceRef: FavoriteChannel.encodeSourceRef({
          'streamUrl': station.streamUrl,
          'stationUuid': station.stationUuid,
        }),
      ),
    );
  }

  /// [freqKhz]/[serviceId] identify the station's Band III channel and DAB
  /// Service Id (SId) - enough to re-tune it natively via
  /// DabUsbService.dabTuneFrequency, independent of any scan session.
  Future<void> addDabService({
    required int programNumber,
    required String displayName,
    required int freqKhz,
    required int serviceId,
    String? logoUrl,
  }) {
    return _db.upsertFavorite(
      FavoritesCompanion.insert(
        programNumber: Value(programNumber),
        sourceType: 'dab',
        displayName: displayName,
        logoUrl: Value(logoUrl),
        sourceRef: FavoriteChannel.encodeSourceRef({
          'freqKhz': freqKhz,
          'serviceId': serviceId,
        }),
      ),
    );
  }

  Future<void> remove(int programNumber) => _db.removeFavorite(programNumber);

  /// Swaps two favorites' program numbers - the building block for moving a
  /// favorite up/down in the settings editor (see SettingsScreen). Routes
  /// through a temporary negative number first: program number is the
  /// primary key, so writing B's number directly onto A while B still holds
  /// it would violate uniqueness mid-transaction.
  Future<void> swapProgramNumbers(int a, int b) async {
    if (a == b) return;
    await _db.transaction(() async {
      const temp = -1;
      await _db.setFavoriteProgramNumber(a, temp);
      await _db.setFavoriteProgramNumber(b, a);
      await _db.setFavoriteProgramNumber(temp, b);
    });
  }

  /// Overrides a favorite's display name - lets the user clean up a DAB+
  /// station's raw decoded FIG label (see DabStationsRepository.setCustomLabel)
  /// without affecting which favorite it stays being.
  Future<void> rename(int programNumber, String displayName) =>
      _db.updateFavoriteDisplayName(programNumber, displayName);

  Future<void> updateLogoUrl(int programNumber, String logoUrl) =>
      _db.updateFavoriteLogoUrl(programNumber, logoUrl);

  /// Removes the DAB favorite (if any) pointing at this exact station, by
  /// frequency + service id (there's no other stable key across scans).
  Future<void> removeDabFavoriteFor(int freqKhz, int serviceId) async {
    final rows = await watchFavorites().first;
    final match = rows.where(
      (c) => c.sourceType == FavoriteSourceType.dab && c.dabFreqKhz == freqKhz && c.dabServiceId == serviceId,
    );
    for (final c in match) {
      await remove(c.programNumber);
    }
  }
}
