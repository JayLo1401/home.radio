import 'package:flutter/foundation.dart';

/// The satellite signal of one of the receiver's tuners, as OpenWebif's
/// /api/signal tells it: quality (SNR) in % and dB, level (AGC) in %, bit
/// error rate.
@immutable
class E2Signal {
  const E2Signal({required this.tuner, this.snrPercent, this.snrDb, this.agcPercent, this.ber});

  /// The tuner measured (0 = Tuner A).
  final int tuner;
  final int? snrPercent;
  final double? snrDb;
  final int? agcPercent;
  final int? ber;

  /// "SNR 13.6 dB · 85 %" - the quality, as far as the box tells it.
  String get quality => [
        if (snrDb != null) '${snrDb!.toStringAsFixed(1)} dB',
        if (snrPercent != null) '$snrPercent %',
      ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is E2Signal &&
      other.tuner == tuner &&
      other.snrPercent == snrPercent &&
      other.snrDb == snrDb &&
      other.agcPercent == agcPercent &&
      other.ber == ber;

  @override
  int get hashCode => Object.hash(tuner, snrPercent, snrDb, agcPercent, ber);
}

/// /api/signal (= /api/tunersignal): the signal of the tuner of the
/// channel the receiver shows itself - null when there is none to tell
/// (in standby every field is empty, even while it streams: the stream's
/// tuner isn't the "current service" then).
E2Signal? parseE2Signal(Map<String, dynamic> j) {
  final tuner = _int(j['tunernumber']);
  final snr = _int(j['snr']);
  // snr_db: "13.62" - or the percentage again when the tuner gives no dB.
  final rawDb = j['snr_db'];
  final db = rawDb is String && rawDb.contains('%') ? null : _double(rawDb);
  if (tuner == null || (snr == null && db == null)) return null;
  return E2Signal(
    tuner: tuner,
    snrPercent: snr?.clamp(0, 100),
    // Equal to the percentage: no dB value of its own.
    snrDb: db == null || (snr != null && db == snr.toDouble() && rawDb is! String) ? null : db,
    agcPercent: _int(j['agc'])?.clamp(0, 100),
    ber: _int(j['ber']),
  );
}

/// /api/about's "streams": the tuner the receiver streams [serviceKey] from
/// (compared without trailing ':' and case) - null if it doesn't say.
int? streamTunerOf(Map<String, dynamic> about, String serviceKey) {
  final info = about['info'] is Map ? about['info'] as Map : about;
  final streams = info['streams'];
  if (streams is! List) return null;
  for (final s in streams.whereType<Map>()) {
    final ref = s['ref'];
    if (ref is! String) continue;
    if (ref.replaceAll(RegExp(r':+$'), '').toUpperCase() != serviceKey) continue;
    final tuner = _int(s['tuner_number']);
    if (tuner != null && tuner >= 0) return tuner;
  }
  return null;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) {
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v);
    return m == null ? null : double.parse(m[0]!).round();
  }
  return null;
}

double? _double(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v.replaceAll(',', '.'));
    return m == null ? null : double.parse(m[0]!);
  }
  return null;
}
