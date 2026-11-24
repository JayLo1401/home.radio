import 'package:flutter/foundation.dart';

/// How a stream is packaged - tells ExoPlayer which source to use when the
/// address doesn't say so (no ".m3u8" at the end).
enum IptvStreamFormat { hls, dash }

/// One address of an Internet-TV channel (a channel often has several -
/// another quality, another server).
@immutable
class IptvStream {
  const IptvStream({
    required this.url,
    this.referrer,
    this.userAgent,
    this.quality,
    this.geoBlocked = false,
    this.notAlways = false,
  });

  final String url;

  /// Some servers only answer with these (iptv-org's `referrer` and
  /// `user_agent`).
  final String? referrer;
  final String? userAgent;

  /// Picture lines ("720p" -> 720), null if unknown.
  final int? quality;

  /// iptv-org's labels: "Geo-blocked" (only in its country), "Not 24/7".
  final bool geoBlocked;
  final bool notAlways;

  /// The HTTP headers the player has to send.
  Map<String, String> get headers => {
        if (referrer case final r? when r.isNotEmpty) 'Referer': r,
        if (userAgent case final a? when a.isNotEmpty) 'User-Agent': a,
      };

  IptvStreamFormat? get format {
    final u = url.toLowerCase();
    if (u.contains('m3u8')) return IptvStreamFormat.hls;
    if (u.contains('.mpd')) return IptvStreamFormat.dash;
    return null;
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        if (referrer != null) 'referrer': referrer,
        if (userAgent != null) 'userAgent': userAgent,
        if (quality != null) 'quality': quality,
        if (geoBlocked) 'geoBlocked': true,
        if (notAlways) 'notAlways': true,
      };

  factory IptvStream.fromJson(Map<String, dynamic> json) => IptvStream(
        url: json['url'] as String,
        referrer: json['referrer'] as String?,
        userAgent: json['userAgent'] as String?,
        quality: (json['quality'] as num?)?.toInt(),
        geoBlocked: json['geoBlocked'] == true,
        notAlways: json['notAlways'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is IptvStream &&
      other.url == url &&
      other.referrer == referrer &&
      other.userAgent == userAgent &&
      other.quality == quality &&
      other.geoBlocked == geoBlocked &&
      other.notAlways == notAlways;

  @override
  int get hashCode => Object.hash(url, referrer, userAgent, quality, geoBlocked, notAlways);
}

/// An Internet-TV channel from the iptv-org catalogue: one channel in one
/// language (France 24 English and France 24 French are two), with its
/// streams best first.
@immutable
class IptvChannel {
  const IptvChannel({
    required this.id,
    required this.name,
    required this.streams,
    this.country = '',
    this.categories = const [],
    this.languages = const [],
    this.altNames = const [],
    this.logo,
  });

  /// iptv-org's channel id ("ORF2.at"), with the languages if the channel
  /// comes in several ("France24.fr@eng") - stays the same across catalogue
  /// updates, so favorites find their channel again.
  final String id;
  final String name;

  /// ISO 3166-1 alpha-2, upper case ("AT").
  final String country;

  /// iptv-org's category ids ("news", "sports", ...).
  final List<String> categories;

  /// ISO 639-3 ("deu", "eng", ...).
  final List<String> languages;

  /// Other names it's known by (for the search).
  final List<String> altNames;
  final String? logo;
  final List<IptvStream> streams;

  /// iptv-org's own channel id, without the language part.
  String get channelId {
    final at = id.indexOf('@');
    return at < 0 ? id : id.substring(0, at);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (country.isNotEmpty) 'country': country,
        if (categories.isNotEmpty) 'categories': categories,
        if (languages.isNotEmpty) 'languages': languages,
        if (altNames.isNotEmpty) 'altNames': altNames,
        if (logo != null) 'logo': logo,
        'streams': [for (final s in streams) s.toJson()],
      };

  factory IptvChannel.fromJson(Map<String, dynamic> json) => IptvChannel(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        country: json['country'] as String? ?? '',
        categories: _strings(json['categories']),
        languages: _strings(json['languages']),
        altNames: _strings(json['altNames']),
        logo: json['logo'] as String?,
        streams: [
          for (final s in (json['streams'] as List? ?? const []))
            if (s is Map<String, dynamic> && s['url'] is String) IptvStream.fromJson(s),
        ],
      );

  IptvChannel copyWith({String? name, String? logo, List<IptvStream>? streams}) => IptvChannel(
        id: id,
        name: name ?? this.name,
        country: country,
        categories: categories,
        languages: languages,
        altNames: altNames,
        logo: logo ?? this.logo,
        streams: streams ?? this.streams,
      );

  /// Same channel with the same data (a catalogue update changed nothing).
  bool sameAs(IptvChannel other) =>
      other.id == id &&
      other.name == name &&
      other.logo == logo &&
      other.country == country &&
      listEquals(other.categories, categories) &&
      listEquals(other.languages, languages) &&
      listEquals(other.streams, streams);

  /// Matches a search text in its name or other names (case and accents
  /// as typed: case-insensitive only).
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (name.toLowerCase().contains(q)) return true;
    return altNames.any((n) => n.toLowerCase().contains(q));
  }

  static List<String> _strings(Object? v) =>
      v is List ? [for (final e in v) if (e is String) e] : const [];
}

/// The catalogue as kept on disk: the channels (with at least one stream)
/// and the names of countries, categories and languages they use.
class IptvCatalogue {
  IptvCatalogue({
    required this.updated,
    required this.channels,
    this.countries = const {},
    this.categories = const {},
    this.languages = const {},
  });

  /// When it was downloaded.
  final DateTime updated;
  final List<IptvChannel> channels;

  /// Code -> (English name, flag emoji).
  final Map<String, ({String name, String flag})> countries;

  /// Category id -> English name.
  final Map<String, String> categories;

  /// Language code -> English name.
  final Map<String, String> languages;

  static const format = 1;

  /// Older than a day: fetched again (in the background).
  bool isStale(DateTime now) => now.difference(updated) > const Duration(hours: 24) || now.isBefore(updated);

  Map<String, dynamic> toJson() => {
        'format': format,
        'updated': updated.toIso8601String(),
        'countries': {
          for (final e in countries.entries) e.key: {'name': e.value.name, 'flag': e.value.flag},
        },
        'categories': categories,
        'languages': languages,
        'channels': [for (final c in channels) c.toJson()],
      };

  factory IptvCatalogue.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) throw const FormatException('unknown catalogue format');
    return IptvCatalogue(
      updated: DateTime.parse(json['updated'] as String),
      countries: {
        for (final e in (json['countries'] as Map<String, dynamic>? ?? const {}).entries)
          e.key: (
            name: (e.value as Map)['name'] as String? ?? e.key,
            flag: (e.value as Map)['flag'] as String? ?? '',
          ),
      },
      categories: (json['categories'] as Map<String, dynamic>? ?? const {}).cast<String, String>(),
      languages: (json['languages'] as Map<String, dynamic>? ?? const {}).cast<String, String>(),
      channels: [
        for (final c in (json['channels'] as List? ?? const []))
          if (c is Map<String, dynamic>) IptvChannel.fromJson(c),
      ],
    );
  }

  /// The channel with [id] - or, if a channel's language split changed,
  /// the one of the same iptv-org channel.
  IptvChannel? find(String id) {
    final exact = channels.where((c) => c.id == id).firstOrNull;
    if (exact != null) return exact;
    final at = id.indexOf('@');
    final base = at < 0 ? id : id.substring(0, at);
    final same = channels.where((c) => c.channelId == base).toList();
    return same.length == 1 ? same.first : null;
  }
}

/// The Internet-TV favorites: their own list with their own numbers -
/// 1, 2, 3, ... in the user's order (the position in the list).
abstract final class IptvFavorites {
  /// [channel] at the end - unless it's already in.
  static List<IptvChannel> add(List<IptvChannel> list, IptvChannel channel) =>
      list.any((c) => c.id == channel.id) ? list : [...list, channel];

  static List<IptvChannel> remove(List<IptvChannel> list, String id) => [
        for (final c in list)
          if (c.id != id) c,
      ];

  /// The channel at [from] moved to [to] (both clamped into the list).
  static List<IptvChannel> move(List<IptvChannel> list, int from, int to) {
    if (from < 0 || from >= list.length) return list;
    final target = to.clamp(0, list.length - 1);
    if (target == from) return list;
    final result = [...list];
    final c = result.removeAt(from);
    result.insert(target, c);
    return result;
  }

  /// Its number in the list (1-based), null if it isn't in.
  static int? numberOf(List<IptvChannel> list, String id) {
    final i = list.indexWhere((c) => c.id == id);
    return i < 0 ? null : i + 1;
  }

  /// The channel with number [number], null if there's none.
  static IptvChannel? byNumber(List<IptvChannel> list, int number) =>
      number >= 1 && number <= list.length ? list[number - 1] : null;

  /// The favorites with what the [catalogue] now says about them (new
  /// stream addresses, logo, name) - same order; channels no longer in
  /// it stay as they were. Returns [list] itself if nothing changed.
  static List<IptvChannel> refresh(List<IptvChannel> list, IptvCatalogue catalogue) {
    var changed = false;
    final result = <IptvChannel>[];
    for (final c in list) {
      final fresh = catalogue.find(c.id);
      if (fresh == null || fresh.streams.isEmpty) {
        result.add(c);
        continue;
      }
      // Keeps the id the user has (even if the catalogue's changed).
      final updated = IptvChannel(
        id: c.id,
        name: fresh.name,
        country: fresh.country,
        categories: fresh.categories,
        languages: fresh.languages,
        altNames: fresh.altNames,
        logo: fresh.logo,
        streams: fresh.streams,
      );
      if (updated.sameAs(c)) {
        result.add(c);
      } else {
        changed = true;
        result.add(updated);
      }
    }
    return changed ? result : list;
  }
}
