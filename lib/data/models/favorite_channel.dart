import 'dart:convert';

enum FavoriteSourceType { dab, internet, fm }

/// UI-facing representation of a merged favorite (DAB+, FM or internet
/// radio), decoded from the drift [Favorite] row's JSON `sourceRef`.
class FavoriteChannel {
  final int programNumber;
  final FavoriteSourceType sourceType;
  final String displayName;
  final String? logoUrl;
  final String? logoLocalPath;
  final Map<String, dynamic> sourceRef;

  const FavoriteChannel({
    required this.programNumber,
    required this.sourceType,
    required this.displayName,
    required this.logoUrl,
    required this.logoLocalPath,
    required this.sourceRef,
  });

  String? get internetStreamUrl =>
      sourceType == FavoriteSourceType.internet ? sourceRef['streamUrl'] as String? : null;

  /// DAB Band III channel frequency in kHz (see DabChannels.BAND3 on the
  /// Kotlin side) this favorite's ensemble was found on.
  int? get dabFreqKhz =>
      sourceType == FavoriteSourceType.dab ? sourceRef['freqKhz'] as int? : null;

  /// DAB Service Id (SId) of this specific station within its ensemble.
  /// Not yet usable to select audio (MSC/service-component decoding isn't
  /// implemented yet - see the project plan's DAB+ phase) but saved now so
  /// favorites don't need to be re-created once that lands.
  int? get dabServiceId =>
      sourceType == FavoriteSourceType.dab ? sourceRef['serviceId'] as int? : null;

  /// FM (UKW) frequency in kHz.
  int? get fmFreqKhz => sourceType == FavoriteSourceType.fm ? sourceRef['freqKhz'] as int? : null;

  /// Whether this needs the RTL-SDR receiver (DAB+ or FM), not just internet.
  bool get needsReceiver => sourceType != FavoriteSourceType.internet;

  String get sourceTypeKey => sourceType.name;

  static FavoriteSourceType parseSourceType(String value) => switch (value) {
        'dab' => FavoriteSourceType.dab,
        'fm' => FavoriteSourceType.fm,
        _ => FavoriteSourceType.internet,
      };

  static Map<String, dynamic> decodeSourceRef(String json) =>
      jsonDecode(json) as Map<String, dynamic>;

  static String encodeSourceRef(Map<String, dynamic> map) => jsonEncode(map);
}
