import '../db/database.dart';

/// Persisted FM (UKW) stations - found by a scan or saved while tuning
/// manually - the FM counterpart of DabStationsRepository.
class FmStationsRepository {
  final AppDatabase _db;

  FmStationsRepository(this._db);

  Stream<List<FmStation>> watchAll() => _db.watchFmStations();

  /// [levelDb] only from a scan - null keeps the stored one.
  Future<void> upsert({required int freqKhz, int? pi, String? psName, bool stereo = false, double? levelDb}) =>
      _db.upsertFmStation(freqKhz: freqKhz, pi: pi, psName: _cleanPs(psName), stereo: stereo, levelDb: levelDb);

  /// An empty [customLabel] reverts to the RDS name / frequency.
  Future<void> setCustomLabel(int freqKhz, String? customLabel) {
    final trimmed = customLabel?.trim();
    return _db.setFmStationCustomLabel(freqKhz, trimmed?.isEmpty ?? true ? null : trimmed);
  }

  /// A logo the user chose - the other source is cleared (see
  /// FavoritesRepository.setLogo).
  Future<void> setLogo(int freqKhz, {String? logoUrl, String? logoLocalPath}) =>
      _db.setFmStationLogo(freqKhz, logoUrl: logoUrl, logoLocalPath: logoLocalPath);

  Future<void> delete(int freqKhz) => _db.deleteFmStation(freqKhz);

  Future<void> clearAll() => _db.clearFmStations();

  /// RDS PS names are padded to 8 characters with spaces.
  static String? _cleanPs(String? ps) {
    final trimmed = ps?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// "99,9 MHz" / "88,85 MHz" - German decimal comma, no trailing zero.
String formatFmFrequency(int freqKhz) {
  final mhz = (freqKhz / 1000).toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  return '${mhz.replaceAll('.', ',')} MHz';
}

extension FmStationDisplay on FmStation {
  /// The user's own name, else the RDS name, else just the frequency.
  String get displayLabel => customLabel ?? psName ?? formatFmFrequency(freqKhz);

  String get frequencyLabel => formatFmFrequency(freqKhz);
}

/// Other stations with the same RDS PI - the same programme on another
/// frequency (a repeater, another transmitter site, or an overloaded
/// stick's spurious copy), strongest first. Empty without PI.
List<FmStation> sameProgrammeElsewhere(FmStation station, List<FmStation> all) {
  final pi = station.pi;
  if (pi == null) return const [];
  return [
    for (final s in all)
      if (s.pi == pi && s.freqKhz != station.freqKhz) s,
  ]..sort((a, b) => (b.levelDb ?? -999).compareTo(a.levelDb ?? -999));
}

/// "auch auf 105,0 MHz (schwächer)" - a hint instead of grouping, so lists
/// stay sorted by frequency. Null if the programme is on no other frequency.
String? sameProgrammeHint(FmStation station, List<FmStation> all) {
  final others = sameProgrammeElsewhere(station, all);
  if (others.isEmpty) return null;
  final best = others.first;
  final mine = station.levelDb, theirs = best.levelDb;
  final compare = mine == null || theirs == null ? '' : (theirs > mine ? ' (stärker)' : ' (schwächer)');
  final more = others.length > 1 ? ' +${others.length - 1}' : '';
  return 'auch auf ${best.frequencyLabel}$compare$more';
}

extension FmStationDetails on FmStation {
  /// RDS PI as it's usually written, e.g. "A203".
  String? get piLabel => pi?.toRadixString(16).toUpperCase().padLeft(4, '0');

  /// "-25 dB" - the scan's relative level (higher = stronger).
  String? get levelLabel => levelDb == null ? null : '${levelDb!.round()} dB';
}
