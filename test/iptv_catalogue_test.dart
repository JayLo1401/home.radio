import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/models/iptv_channel.dart';
import 'package:home_system/data/services/iptv_service.dart';

/// [text] as a byte stream cut into pieces of [size] bytes.
Stream<List<int>> chunked(String text, int size) async* {
  final bytes = utf8.encode(text);
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

IptvCatalogue buildCatalogue({
  List<Map<String, dynamic>> streams = const [],
  List<Map<String, dynamic>> blocklist = const [],
  List<Map<String, dynamic>> channels = const [],
  List<Map<String, dynamic>> feeds = const [],
  List<Map<String, dynamic>> logos = const [],
  List<Map<String, dynamic>> countries = const [],
  List<Map<String, dynamic>> categories = const [],
  List<Map<String, dynamic>> languages = const [],
}) {
  final b = IptvCatalogueBuilder();
  streams.forEach(b.addStream);
  blocklist.forEach(b.addBlocked);
  channels.forEach(b.addChannel);
  feeds.forEach(b.addFeed);
  logos.forEach(b.addLogo);
  countries.forEach(b.addCountry);
  categories.forEach(b.addCategory);
  languages.forEach(b.addLanguage);
  return b.build(DateTime(2026, 11, 24, 12));
}

Map<String, dynamic> channel(String id, String name, {String country = 'AT', List<String> categories = const ['general']}) =>
    {
      'id': id,
      'name': name,
      'alt_names': <String>[],
      'country': country,
      'categories': categories,
      'is_nsfw': false,
      'closed': null,
    };

Map<String, dynamic> stream(String channel, String url,
        {String? feed, String? quality, List<String> labels = const [], String? referrer, String? userAgent}) =>
    {
      'channel': channel,
      'feed': feed,
      'title': channel,
      'url': url,
      'quality': quality,
      'labels': labels,
      'referrer': referrer,
      'user_agent': userAgent,
    };

void main() {
  group('jsonArrayObjects', () {
    const text = '[{"a":"x{y}z","b":[1,{"c":2}],"d":{"e":"\\"}"}},\n'
        ' {"name":"Österreich ü","list":[]} , {"q":"\\\\"}]';

    for (final size in [1, 2, 3, 7, 64, 1000]) {
      test('splits the objects in chunks of $size bytes', () async {
        final objects = await jsonArrayObjects(chunked(text, size)).toList();
        expect(objects, hasLength(3));
        expect(objects[0]['a'], 'x{y}z');
        expect(objects[0]['b'], [
          1,
          {'c': 2},
        ]);
        expect(objects[0]['d'], {'e': '"}'});
        expect(objects[1]['name'], 'Österreich ü');
        expect(objects[2]['q'], r'\');
      });
    }

    test('an empty array: nothing', () async {
      expect(await jsonArrayObjects(chunked('[ ]', 1)).toList(), isEmpty);
    });
  });

  group('IptvCatalogueBuilder', () {
    test('leaves out closed, NSFW, blocked and xxx channels, unknown channels and non-http streams', () {
      final c = buildCatalogue(
        streams: [
          stream('ORF2.at', 'https://a/orf2.m3u8'),
          stream('Closed.at', 'https://a/closed.m3u8'),
          stream('Nsfw.at', 'https://a/nsfw.m3u8'),
          stream('Blocked.at', 'https://a/blocked.m3u8'),
          stream('Xxx.at', 'https://a/xxx.m3u8'),
          stream('Unknown.at', 'https://a/unknown.m3u8'),
          stream('Rtmp.at', 'rtmp://a/live'),
          {'channel': null, 'url': 'https://a/nochannel.m3u8', 'labels': <String>[]},
        ],
        blocklist: [
          {'channel': 'Blocked.at', 'reason': 'dmca'},
        ],
        channels: [
          channel('ORF2.at', 'ORF 2'),
          channel('Closed.at', 'Closed')..['closed'] = '2020-01-01',
          channel('Nsfw.at', 'Nsfw')..['is_nsfw'] = true,
          channel('Blocked.at', 'Blocked'),
          channel('Xxx.at', 'Xxx', categories: ['xxx']),
          channel('Rtmp.at', 'Rtmp'),
          channel('NoStream.at', 'No stream'),
        ],
      );
      expect(c.channels.map((x) => x.id), ['ORF2.at']);
    });

    test('one entry per language: HD and SD feeds together, other languages apart', () {
      final c = buildCatalogue(
        streams: [
          stream('ORF2.at', 'https://a/orf2-sd.m3u8', feed: 'SD', quality: '576p'),
          stream('ORF2.at', 'https://a/orf2-hd.m3u8', feed: 'HD', quality: '720p'),
          stream('France24.fr', 'https://f/en.m3u8', feed: 'English', quality: '720p'),
          stream('France24.fr', 'https://f/en-hd.m3u8', feed: 'EnglishHD', quality: '1080p'),
          stream('France24.fr', 'https://f/fr.m3u8', feed: 'French', quality: '1080p'),
        ],
        channels: [
          channel('ORF2.at', 'ORF 2'),
          channel('France24.fr', 'France 24', country: 'FR', categories: ['news']),
        ],
        feeds: [
          {'channel': 'ORF2.at', 'id': 'SD', 'name': 'SD', 'is_main': true, 'languages': ['deu']},
          {'channel': 'ORF2.at', 'id': 'HD', 'name': 'HD', 'is_main': false, 'languages': ['deu']},
          {'channel': 'France24.fr', 'id': 'English', 'name': 'English', 'is_main': false, 'languages': ['eng']},
          {'channel': 'France24.fr', 'id': 'EnglishHD', 'name': 'English HD', 'is_main': false, 'languages': ['eng']},
          {'channel': 'France24.fr', 'id': 'French', 'name': 'French', 'is_main': true, 'languages': ['fra']},
        ],
        countries: [
          {'name': 'Austria', 'code': 'AT', 'languages': ['deu'], 'flag': '🇦🇹'},
          {'name': 'France', 'code': 'FR', 'languages': ['fra'], 'flag': '🇫🇷'},
          {'name': 'Germany', 'code': 'DE', 'languages': ['deu'], 'flag': '🇩🇪'},
        ],
        categories: [
          {'id': 'general', 'name': 'General'},
          {'id': 'news', 'name': 'News'},
          {'id': 'sports', 'name': 'Sports'},
        ],
        languages: [
          {'code': 'deu', 'name': 'German'},
          {'code': 'eng', 'name': 'English'},
          {'code': 'fra', 'name': 'French'},
          {'code': 'spa', 'name': 'Spanish'},
        ],
      );
      expect(c.channels.map((x) => '${x.id}|${x.name}'), [
        'France24.fr@eng|France 24 (English)',
        'France24.fr@fra|France 24 (French)',
        'ORF2.at@deu|ORF 2',
      ]);
      final orf = c.channels.last;
      expect(orf.languages, ['deu']);
      // The better picture first.
      expect(orf.streams.map((s) => s.url), ['https://a/orf2-hd.m3u8', 'https://a/orf2-sd.m3u8']);
      expect(orf.streams.first.quality, 720);
      // Only what the channels use.
      expect(c.countries.keys.toSet(), {'AT', 'FR'});
      expect(c.countries['AT']!.name, 'Austria');
      expect(c.categories.keys.toSet(), {'general', 'news'});
      expect(c.languages, {'deu': 'German', 'eng': 'English', 'fra': 'French'});
    });

    test('streams: not geo-blocked and round the clock first, duplicates once, headers kept', () {
      final c = buildCatalogue(
        streams: [
          stream('ZDF.de', 'https://z/geo.m3u8', quality: '1080p', labels: ['Geo-blocked']),
          stream('ZDF.de', 'https://z/part.m3u8', quality: '1080p', labels: ['Not 24/7']),
          stream('ZDF.de', 'http://z/plain.m3u8', quality: '720p'),
          stream('ZDF.de', 'https://z/plain-https.m3u8', quality: '720p', referrer: 'https://zdf.de/', userAgent: 'UA/1'),
          stream('ZDF.de', 'http://z/plain.m3u8', quality: '720p'),
        ],
        channels: [channel('ZDF.de', 'ZDF', country: 'DE')],
      );
      final zdf = c.channels.single;
      expect(zdf.id, 'ZDF.de');
      expect(zdf.streams.map((s) => s.url), [
        'https://z/plain-https.m3u8',
        'http://z/plain.m3u8',
        'https://z/part.m3u8',
        'https://z/geo.m3u8',
      ]);
      expect(zdf.streams.first.headers, {'Referer': 'https://zdf.de/', 'User-Agent': 'UA/1'});
      expect(zdf.streams[2].notAlways, isTrue);
      expect(zdf.streams[3].geoBlocked, isTrue);
      expect(zdf.streams[1].headers, isEmpty);
    });

    test('logo: no SVG, the one in use and of a fitting size', () {
      final c = buildCatalogue(
        streams: [stream('ORF1.at', 'https://a/orf1.m3u8')],
        channels: [channel('ORF1.at', 'ORF 1')],
        logos: [
          {'channel': 'ORF1.at', 'feed': null, 'in_use': true, 'tags': <String>[], 'width': 512, 'height': 512, 'format': 'SVG', 'url': 'https://l/orf1.svg'},
          {'channel': 'ORF1.at', 'feed': null, 'in_use': false, 'tags': <String>[], 'width': 400, 'height': 200, 'format': 'PNG', 'url': 'https://l/old.png'},
          {'channel': 'ORF1.at', 'feed': null, 'in_use': true, 'tags': <String>[], 'width': 400, 'height': 200, 'format': 'PNG', 'url': 'https://l/orf1.png'},
          {'channel': 'Other.at', 'feed': null, 'in_use': true, 'tags': <String>[], 'width': 400, 'height': 200, 'format': 'PNG', 'url': 'https://l/other.png'},
        ],
      );
      expect(c.channels.single.logo, 'https://l/orf1.png');
    });

    test('stream format for the player', () {
      expect(const IptvStream(url: 'https://a/b/index.m3u8?token=1').format, IptvStreamFormat.hls);
      expect(const IptvStream(url: 'https://a/api/play?format=m3u8').format, IptvStreamFormat.hls);
      expect(const IptvStream(url: 'https://a/b/manifest.mpd').format, IptvStreamFormat.dash);
      expect(const IptvStream(url: 'http://a/b/stream.ts').format, isNull);
    });
  });

  group('IptvCatalogue', () {
    test('saved and read again: the same', () {
      final c = buildCatalogue(
        streams: [stream('ORF2.at', 'https://a/orf2.m3u8', quality: '720p', labels: ['Geo-blocked'], userAgent: 'UA')],
        channels: [channel('ORF2.at', 'ORF 2')..['alt_names'] = ['ORF zwei']],
        countries: [
          {'name': 'Austria', 'code': 'AT', 'flag': '🇦🇹'},
        ],
      );
      final again = IptvCatalogue.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect(again.updated, c.updated);
      expect(again.channels.single.sameAs(c.channels.single), isTrue);
      expect(again.channels.single.altNames, ['ORF zwei']);
      expect(again.countries['AT']!.flag, '🇦🇹');
      expect(again.channels.single.matches('zwei'), isTrue);
      expect(again.channels.single.matches('orf 2'), isTrue);
      expect(again.channels.single.matches('ZDF'), isFalse);
    });

    test('stale after a day', () {
      final c = IptvCatalogue(updated: DateTime(2026, 11, 24, 12), channels: const []);
      expect(c.isStale(DateTime(2026, 11, 25, 11)), isFalse);
      expect(c.isStale(DateTime(2026, 11, 25, 13)), isTrue);
    });

    test('find: by id, else the same iptv-org channel if it is the only one', () {
      final c = IptvCatalogue(updated: DateTime(2026), channels: const [
        IptvChannel(id: 'ORF2.at@deu', name: 'ORF 2', streams: [IptvStream(url: 'https://a')]),
        IptvChannel(id: 'France24.fr@eng', name: 'France 24 (English)', streams: [IptvStream(url: 'https://e')]),
        IptvChannel(id: 'France24.fr@fra', name: 'France 24 (French)', streams: [IptvStream(url: 'https://f')]),
      ]);
      expect(c.find('ORF2.at@deu')?.name, 'ORF 2');
      expect(c.find('ORF2.at')?.name, 'ORF 2');
      expect(c.find('France24.fr'), isNull);
      expect(c.find('ZDF.de'), isNull);
    });
  });
}
