import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/models/iptv_channel.dart';
import 'package:home_system/data/repositories/iptv_repository.dart';

IptvChannel ch(String id, {String url = 'https://x/a.m3u8', String? logo}) =>
    IptvChannel(id: id, name: id, logo: logo, streams: [IptvStream(url: url)]);

void main() {
  group('IptvFavorites', () {
    final a = ch('A.at'), b = ch('B.at'), c = ch('C.de'), d = ch('D.de');

    test('numbers are the positions, 1-based', () {
      final list = [a, b, c];
      expect(IptvFavorites.numberOf(list, 'A.at'), 1);
      expect(IptvFavorites.numberOf(list, 'C.de'), 3);
      expect(IptvFavorites.numberOf(list, 'X'), isNull);
      expect(IptvFavorites.byNumber(list, 2), b);
      expect(IptvFavorites.byNumber(list, 0), isNull);
      expect(IptvFavorites.byNumber(list, 4), isNull);
    });

    test('add: at the end, once', () {
      var list = IptvFavorites.add(const [], a);
      list = IptvFavorites.add(list, b);
      list = IptvFavorites.add(list, a);
      expect(list.map((x) => x.id), ['A.at', 'B.at']);
      expect(IptvFavorites.numberOf(list, 'B.at'), 2);
    });

    test('remove: the ones after move up a number', () {
      final list = IptvFavorites.remove([a, b, c, d], 'B.at');
      expect(list.map((x) => x.id), ['A.at', 'C.de', 'D.de']);
      expect(IptvFavorites.numberOf(list, 'C.de'), 2);
      expect(IptvFavorites.remove(list, 'X').map((x) => x.id), ['A.at', 'C.de', 'D.de']);
    });

    test('move: up, down, clamped, out of range unchanged', () {
      final list = [a, b, c, d];
      expect(IptvFavorites.move(list, 3, 0).map((x) => x.id), ['D.de', 'A.at', 'B.at', 'C.de']);
      expect(IptvFavorites.move(list, 0, 2).map((x) => x.id), ['B.at', 'C.de', 'A.at', 'D.de']);
      expect(IptvFavorites.move(list, 1, 99).map((x) => x.id), ['A.at', 'C.de', 'D.de', 'B.at']);
      expect(IptvFavorites.move(list, 2, -5).map((x) => x.id), ['C.de', 'A.at', 'B.at', 'D.de']);
      expect(identical(IptvFavorites.move(list, 9, 0), list), isTrue);
      expect(identical(IptvFavorites.move(list, 1, 1), list), isTrue);
      // The original stays as it was.
      expect(list.map((x) => x.id), ['A.at', 'B.at', 'C.de', 'D.de']);
    });

    test('refresh: new streams and logos from the catalogue, order and ids kept', () {
      final catalogue = IptvCatalogue(updated: DateTime(2026), channels: [
        ch('B.at', url: 'https://new/b.m3u8', logo: 'https://l/b.png'),
        // Split into languages since: still found (the only one).
        ch('A.at@deu', url: 'https://new/a.m3u8'),
      ]);
      final list = [a, b, c];
      final fresh = IptvFavorites.refresh(list, catalogue);
      expect(fresh.map((x) => x.id), ['A.at', 'B.at', 'C.de']);
      expect(fresh[0].streams.single.url, 'https://new/a.m3u8');
      expect(fresh[1].streams.single.url, 'https://new/b.m3u8');
      expect(fresh[1].logo, 'https://l/b.png');
      // Gone from the catalogue: stays as it was.
      expect(identical(fresh[2], c), isTrue);
      // Nothing new a second time: the very same list.
      expect(identical(IptvFavorites.refresh(fresh, catalogue), fresh), isTrue);
    });
  });

  group('IptvRepository', () {
    test('favorites survive their JSON, broken entries are left out', () {
      final list = [ch('A.at'), ch('B.at')];
      final json = jsonEncode([
        for (final c in list) c.toJson(),
        {'name': 'no id'},
        'garbage',
      ]);
      final back = IptvRepository.decodeChannels(json);
      expect(back.map((x) => x.id), ['A.at', 'B.at']);
      expect(back.first.sameAs(list.first), isTrue);
      expect(IptvRepository.decodeChannels('not json'), isEmpty);
      expect(IptvRepository.decodeChannels(null), isEmpty);
    });

    test('default countries: Austria, Germany and the device country', () {
      expect(IptvRepository.defaultCountries('AT'), ['AT', 'DE']);
      expect(IptvRepository.defaultCountries('de'), ['AT', 'DE']);
      expect(IptvRepository.defaultCountries('CH'), ['AT', 'DE', 'CH']);
      expect(IptvRepository.defaultCountries(''), ['AT', 'DE']);
    });
  });
}
