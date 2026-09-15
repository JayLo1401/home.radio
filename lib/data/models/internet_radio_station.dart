class InternetRadioStation {
  final String stationUuid;
  final String name;
  final String streamUrl;
  final String? favicon;
  final String countryCode;
  final List<String> tags;
  final String codec;
  final int bitrateKbps;
  final int clickCount;

  const InternetRadioStation({
    required this.stationUuid,
    required this.name,
    required this.streamUrl,
    required this.favicon,
    required this.countryCode,
    required this.tags,
    required this.codec,
    required this.bitrateKbps,
    required this.clickCount,
  });

  factory InternetRadioStation.fromJson(Map<String, dynamic> json) {
    return InternetRadioStation(
      stationUuid: json['stationuuid'] as String? ?? '',
      name: (json['name'] as String? ?? '').trim(),
      streamUrl: json['url_resolved'] as String? ?? json['url'] as String? ?? '',
      favicon: (json['favicon'] as String?)?.isNotEmpty == true
          ? json['favicon'] as String
          : null,
      countryCode: json['countrycode'] as String? ?? '',
      tags: (json['tags'] as String? ?? '')
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(),
      codec: json['codec'] as String? ?? '',
      bitrateKbps: (json['bitrate'] as num?)?.toInt() ?? 0,
      clickCount: (json['clickcount'] as num?)?.toInt() ?? 0,
    );
  }
}
