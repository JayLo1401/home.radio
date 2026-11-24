import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/iptv_channel.dart';

/// Internet-TV's catalogue: free, legal live TV streams from iptv-org
/// (https://github.com/iptv-org/iptv), through its JSON API
/// (https://iptv-org.github.io/api/).
///
/// The API files are big (channels, feeds and logos about 8 MB each), so
/// they're read as they come in, one object at a time, in a background
/// isolate - only what Internet-TV needs is kept (channels that have a
/// stream) and saved as one compact file in the app's storage. That file
/// is read again (also in an isolate) when the catalogue is browsed; it's
/// fetched anew at most once a day. Playing favorites never needs it -
/// they carry their streams themselves.
class IptvService {
  static const apiBase = 'https://iptv-org.github.io/api/';

  Future<File> _file() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'iptv', 'catalogue.json'));

  /// The catalogue saved last time, null if there's none (or it's broken).
  Future<IptvCatalogue?> loadCached() async {
    final file = await _file();
    if (!file.existsSync()) return null;
    final path = file.path;
    try {
      return await Isolate.run(() => IptvCatalogue.fromJson(
            jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
          ));
    } catch (e) {
      debugPrint('IPTV: cached catalogue unreadable: $e');
      return null;
    }
  }

  /// Fetches the catalogue from iptv-org, saves and returns it.
  Future<IptvCatalogue> download() async {
    final path = (await _file()).path;
    return Isolate.run(() => _downloadAndSave(path));
  }
}

Future<IptvCatalogue> _downloadAndSave(String path) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'HomeSystem/1.0';
  final builder = IptvCatalogueBuilder();
  Future<void> each(String name, void Function(Map<String, dynamic>) add) async {
    final request = await client.getUrl(Uri.parse('${IptvService.apiBase}$name.json'));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('iptv-org $name.json: HTTP ${response.statusCode}');
    }
    await for (final o in jsonArrayObjects(response.timeout(const Duration(seconds: 30)))) {
      add(o);
    }
  }

  try {
    // Streams first: only channels with a stream are kept of the rest.
    await each('streams', builder.addStream);
    await each('blocklist', builder.addBlocked);
    await each('channels', builder.addChannel);
    await each('feeds', builder.addFeed);
    await each('logos', builder.addLogo);
    await each('countries', builder.addCountry);
    await each('categories', builder.addCategory);
    await each('languages', builder.addLanguage);
  } finally {
    client.close(force: true);
  }
  final catalogue = builder.build(DateTime.now());
  final file = File(path);
  file.parent.createSync(recursive: true);
  final tmp = File('$path.tmp');
  tmp.writeAsStringSync(jsonEncode(catalogue.toJson()));
  tmp.renameSync(path);
  return catalogue;
}

final _objectDecoder = const Utf8Decoder(allowMalformed: true).fuse(const JsonDecoder());

/// The objects of a JSON array (`[{...}, {...}, ...]`) as they come in -
/// one object decoded at a time instead of the whole (big) file at once.
Stream<Map<String, dynamic>> jsonArrayObjects(Stream<List<int>> bytes) async* {
  var depth = 0;
  var inString = false;
  var escape = false;
  final pending = BytesBuilder(copy: true);
  await for (final chunk in bytes) {
    final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    // Where the object being read started in this chunk (-1: none).
    var start = depth >= 2 && pending.isNotEmpty ? 0 : -1;
    for (var i = 0; i < data.length; i++) {
      final b = data[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (b == 0x5C) {
          escape = true;
        } else if (b == 0x22) {
          inString = false;
        }
        continue;
      }
      switch (b) {
        case 0x22: // "
          inString = true;
        case 0x7B: // {
          depth++;
          if (depth == 2) start = i;
        case 0x5B: // [
          depth++;
        case 0x7D: // }
          depth--;
          if (depth == 1 && start >= 0) {
            pending.add(Uint8List.sublistView(data, start, i + 1));
            start = -1;
            final o = _objectDecoder.convert(pending.takeBytes());
            if (o is Map<String, dynamic>) yield o;
          }
        case 0x5D: // ]
          depth--;
      }
    }
    if (start >= 0) pending.add(Uint8List.sublistView(data, start));
  }
}

/// What iptv-org says about a stream, while the catalogue is built.
class _RawStream {
  _RawStream(this.feed, this.stream, this.order);

  final String? feed;
  final IptvStream stream;
  final int order;
}

class _RawChannel {
  _RawChannel(this.name, this.country, this.categories, this.altNames);

  final String name;
  final String country;
  final List<String> categories;
  final List<String> altNames;
}

class _RawFeed {
  _RawFeed(this.name, this.isMain, this.languages);

  final String name;
  final bool isMain;
  final List<String> languages;
}

/// Builds the [IptvCatalogue] from iptv-org's API files, fed object by
/// object in this order: streams, blocklist, channels, feeds, logos,
/// countries, categories, languages.
///
/// Left out: streams without a channel, other than http(s) (rtmp, srt,
/// ...), and channels that are closed, marked NSFW, of the category "xxx"
/// or on iptv-org's blocklist (NSFW, DMCA).
class IptvCatalogueBuilder {
  final _streams = <String, List<_RawStream>>{};
  final _blocked = <String>{};
  final _channels = <String, _RawChannel>{};

  /// "channel@feed" -> feed.
  final _feeds = <String, _RawFeed>{};

  /// channel -> its main feed's id.
  final _mainFeed = <String, String>{};

  /// "channel@feed" or "channel@" (any feed) -> best logo so far.
  final _logos = <String, ({String url, int score})>{};
  final _countries = <String, ({String name, String flag})>{};
  final _categories = <String, String>{};
  final _languages = <String, String>{};
  var _order = 0;

  static String? _string(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

  static List<String> _strings(Object? v) => v is List ? [for (final e in v) if (e is String && e.isNotEmpty) e] : const [];

  void addStream(Map<String, dynamic> o) {
    final channel = _string(o['channel']);
    final url = _string(o['url']);
    if (channel == null || url == null) return;
    final scheme = url.split(':').first.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return;
    final labels = _strings(o['labels']).map((l) => l.toLowerCase()).toList();
    final quality = int.tryParse(RegExp(r'\d+').firstMatch(_string(o['quality']) ?? '')?.group(0) ?? '');
    (_streams[channel] ??= []).add(_RawStream(
      _string(o['feed']),
      IptvStream(
        url: url,
        referrer: _string(o['referrer']),
        userAgent: _string(o['user_agent']),
        quality: quality,
        geoBlocked: labels.contains('geo-blocked'),
        notAlways: labels.contains('not 24/7'),
      ),
      _order++,
    ));
  }

  void addBlocked(Map<String, dynamic> o) {
    final channel = _string(o['channel']);
    if (channel != null) _blocked.add(channel);
  }

  void addChannel(Map<String, dynamic> o) {
    final id = _string(o['id']);
    if (id == null || !_streams.containsKey(id)) return;
    final categories = _strings(o['categories']);
    if (o['is_nsfw'] == true || o['closed'] != null || categories.contains('xxx') || _blocked.contains(id)) return;
    _channels[id] = _RawChannel(
      _string(o['name']) ?? id,
      (_string(o['country']) ?? '').toUpperCase(),
      categories,
      _strings(o['alt_names']),
    );
  }

  void addFeed(Map<String, dynamic> o) {
    final channel = _string(o['channel']);
    final id = _string(o['id']);
    if (channel == null || id == null || !_channels.containsKey(channel)) return;
    final isMain = o['is_main'] == true;
    _feeds['$channel@$id'] = _RawFeed(_string(o['name']) ?? id, isMain, _strings(o['languages']));
    if (isMain) _mainFeed[channel] = id;
  }

  void addLogo(Map<String, dynamic> o) {
    final channel = _string(o['channel']);
    final url = _string(o['url']);
    if (channel == null || url == null || !_channels.containsKey(channel)) return;
    final score = logoScore(o);
    if (score < 0) return;
    final key = '$channel@${_string(o['feed']) ?? ''}';
    final best = _logos[key];
    if (best == null || score > best.score) _logos[key] = (url: url, score: score);
  }

  /// How well a logo suits the TV's dark lists; < 0: unusable (SVG and
  /// AVIF Flutter can't show).
  static int logoScore(Map<String, dynamic> o) {
    final format = (_string(o['format']) ?? '').toUpperCase();
    final url = (_string(o['url']) ?? '').toLowerCase();
    if (format == 'SVG' || format == 'AVIF' || url.endsWith('.svg')) return -1;
    var score = 0;
    if (o['in_use'] != false) score += 100;
    final tags = _strings(o['tags']);
    if (tags.contains('black') || tags.contains('dark')) score -= 40;
    if (tags.contains('color') || tags.contains('white') || tags.contains('transparent')) score += 10;
    if (format == 'PNG' || format == 'WEBP') score += 10;
    final w = (o['width'] as num?)?.toInt() ?? 0;
    final h = (o['height'] as num?)?.toInt() ?? 0;
    // Big enough for the banner, not huge (memory on the Fire TV Stick).
    if (w >= 100 && w <= 1200) score += 20;
    if (h > 0 && w >= h) score += 5;
    return score;
  }

  void addCountry(Map<String, dynamic> o) {
    final code = _string(o['code'])?.toUpperCase();
    if (code == null) return;
    _countries[code] = (name: _string(o['name']) ?? code, flag: _string(o['flag']) ?? '');
  }

  void addCategory(Map<String, dynamic> o) {
    final id = _string(o['id']);
    if (id != null) _categories[id] = _string(o['name']) ?? id;
  }

  void addLanguage(Map<String, dynamic> o) {
    final code = _string(o['code']);
    if (code != null) _languages[code] = _string(o['name']) ?? code;
  }

  static const _plainFeedNames = {'SD', 'HD', 'FHD', 'UHD', '4K', '8K'};

  /// Streams best first: not geo-blocked, round the clock, the higher
  /// quality, https - as iptv-org lists them otherwise.
  static int _compare(_RawStream a, _RawStream b) {
    int flag(bool v) => v ? 1 : 0;
    var c = flag(a.stream.geoBlocked).compareTo(flag(b.stream.geoBlocked));
    if (c != 0) return c;
    c = flag(a.stream.notAlways).compareTo(flag(b.stream.notAlways));
    if (c != 0) return c;
    c = (b.stream.quality ?? 0).compareTo(a.stream.quality ?? 0);
    if (c != 0) return c;
    c = flag(!a.stream.url.startsWith('https')).compareTo(flag(!b.stream.url.startsWith('https')));
    if (c != 0) return c;
    return a.order.compareTo(b.order);
  }

  IptvCatalogue build(DateTime updated) {
    final result = <IptvChannel>[];
    final usedCountries = <String>{};
    final usedCategories = <String>{};
    final usedLanguages = <String>{};
    for (final entry in _streams.entries) {
      final channelId = entry.key;
      final channel = _channels[channelId];
      if (channel == null) continue;
      final main = _mainFeed[channelId];
      List<String> languagesOf(String? feed) =>
          _feeds['$channelId@$feed']?.languages ?? _feeds['$channelId@$main']?.languages ?? const [];
      // One entry per language (the feeds in HD and SD are one channel).
      final groups = <String, List<_RawStream>>{};
      for (final s in entry.value) {
        final langs = [...languagesOf(s.feed)]..sort();
        (groups[langs.join('+')] ??= []).add(s);
      }
      for (final g in groups.entries) {
        final streams = [...g.value]..sort(_compare);
        final seen = <String>{};
        final unique = [
          for (final s in streams)
            if (seen.add(s.stream.url)) s.stream,
        ];
        final feeds = {for (final s in g.value) s.feed ?? main};
        final languages = g.key.isEmpty ? const <String>[] : g.key.split('+');
        var name = channel.name;
        if (groups.length > 1) {
          final label = _groupLabel(channelId, feeds, languages);
          if (label.isNotEmpty) name = '$name ($label)';
        }
        final logo = [for (final f in feeds) _logos['$channelId@${f ?? ''}']]
                .nonNulls
                .fold<({String url, int score})?>(null, (best, l) => best == null || l.score > best.score ? l : best) ??
            _logos['$channelId@'] ??
            _logos.entries.where((e) => e.key.startsWith('$channelId@')).map((e) => e.value).firstOrNull;
        result.add(IptvChannel(
          id: g.key.isEmpty ? channelId : '$channelId@${g.key}',
          name: name,
          country: channel.country,
          categories: channel.categories,
          languages: languages,
          altNames: channel.altNames,
          logo: logo?.url,
          streams: unique,
        ));
        usedCountries.add(channel.country);
        usedCategories.addAll(channel.categories);
        usedLanguages.addAll(languages);
      }
    }
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return IptvCatalogue(
      updated: updated,
      channels: result,
      countries: {
        for (final c in usedCountries)
          if (c.isNotEmpty) c: _countries[c] ?? (name: c, flag: ''),
      },
      categories: {for (final c in usedCategories) c: _categories[c] ?? c},
      languages: {for (final l in usedLanguages) l: _languages[l] ?? l},
    );
  }

  /// "English" for France 24's English feeds - the shortest feed name, or
  /// the languages where the feeds are just "SD"/"HD".
  String _groupLabel(String channelId, Set<String?> feeds, List<String> languages) {
    final names = [
      for (final f in feeds)
        if (_feeds['$channelId@$f']?.name case final n? when !_plainFeedNames.contains(n.toUpperCase())) n,
    ]..sort((a, b) => a.length.compareTo(b.length));
    if (names.isNotEmpty) return names.first;
    return languages.map((l) => _languages[l] ?? l).join(', ');
  }
}
