import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/models/launcher_tile.dart';
import 'package:home_radio/data/services/launcher_background_service.dart';

void main() {
  group('extractImageUrls', () {
    final base = Uri.parse('http://nas.local/wallpapers/');

    test('nginx directory listing', () {
      const html = '''
<html><head><title>Index of /wallpapers/</title></head><body>
<h1>Index of /wallpapers/</h1><hr><pre><a href="../">../</a>
<a href="alpen.jpg">alpen.jpg</a>     22-Nov-2026 10:00   2.1M
<a href="meer%20blau.JPEG">meer blau.JPEG</a>
<a href="readme.txt">readme.txt</a>
<a href="sub/">sub/</a>
</pre></body></html>''';
      expect(extractImageUrls(html, 'text/html', base), [
        Uri.parse('http://nas.local/wallpapers/alpen.jpg'),
        Uri.parse('http://nas.local/wallpapers/meer%20blau.JPEG'),
      ]);
    });

    test('JSON list, relative and absolute', () {
      const json = '["a.png", "https://cdn.example.org/b.webp", "a.png"]';
      expect(extractImageUrls(json, 'application/json', base), [
        Uri.parse('http://nas.local/wallpapers/a.png'),
        Uri.parse('https://cdn.example.org/b.webp'),
      ]);
    });

    test('JSON object with url entries', () {
      const json = '{"images": [{"url": "/img/1.jpg"}, {"src": "2.jpg"}, 5]}';
      expect(extractImageUrls(json, 'application/json; charset=utf-8', base), [
        Uri.parse('http://nas.local/img/1.jpg'),
        Uri.parse('http://nas.local/wallpapers/2.jpg'),
      ]);
    });

    test('nothing usable', () {
      expect(extractImageUrls('<p>leer</p>', 'text/html', base), isEmpty);
      expect(extractImageUrls('{"x": 1}', 'application/json', base), isEmpty);
    });

    test('folder address without slash counts as folder', () {
      expect(directoryBase(Uri.parse('http://nas/wallpapers')), Uri.parse('http://nas/wallpapers/'));
      expect(directoryBase(Uri.parse('http://nas/list.json')), Uri.parse('http://nas/list.json'));
      expect(directoryBase(Uri.parse('http://nas/')), Uri.parse('http://nas/'));
    });
  });

  group('launcher tiles', () {
    test('round trip keeps order, pictures and labels', () {
      const tiles = [
        LauncherTile.app(package: 'com.netflix.ninja', label: 'Netflix'),
        LauncherTile.radio(),
        LauncherTile.app(package: 'com.disney.disneyplus', label: 'Disney+', image: 'http://nas/disney.png'),
        LauncherTile.systemSettings(),
      ];
      final decoded = decodeLauncherTiles(encodeLauncherTiles(tiles));
      expect(decoded, tiles);
      expect(decoded[2].imageUrl, 'http://nas/disney.png');
      expect(decoded[0].displayLabel, 'Netflix');
    });

    test('Home Radio is always there, duplicates and junk dropped', () {
      final decoded = decodeLauncherTiles(
        '[{"type":"app","package":"a.b","label":"A"},{"type":"app","package":"a.b"},{"type":"x"},{"type":"app"}]',
      );
      expect(decoded.map((t) => t.id), ['radio', 'app:a.b']);
      expect(decodeLauncherTiles('kaputt').single.isRadio, isTrue);
    });

    test('original picture is not a URL', () {
      const tile = LauncherTile.app(package: 'a.b', label: 'A', image: LauncherTile.originalImage);
      expect(tile.imageUrl, isNull);
      expect(tile.withImage(null).image, isNull);
    });
  });
}
