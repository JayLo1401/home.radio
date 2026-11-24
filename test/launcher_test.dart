import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/models/launcher_tile.dart';
import 'package:home_system/data/services/launcher_background_service.dart';

void main() {
  test('Bing archive: landscapes kept, people and events left out', () {
    const body = '{"images": ['
        '{"urlbase": "/th?id=OHR.Abraham", "copyright": "Abraham Lake in Alberta, Kanada (© Guang Cao/Getty Images)"},'
        '{"urlbase": "/th?id=OHR.Mauer", "copyright": "Schüler spähen durch einen Spalt in der Berliner Mauer (© Sean Gallup)"},'
        '{"urlbase": "/th?id=OHR.Eulen", "copyright": "Ein Schleiereulenpaar (© Zahoor Salmi/Getty Images)"},'
        '{"urlbase": "", "copyright": "leer"}'
        ']}';
    final images = parseBingArchive(body);
    expect(images.map((i) => i.url), [
      'https://www.bing.com/th?id=OHR.Abraham_1920x1080.jpg',
      'https://www.bing.com/th?id=OHR.Eulen_1920x1080.jpg',
    ]);
    expect(images.first.caption, startsWith('Abraham Lake'));
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

    test('Radio is always there, duplicates and junk dropped', () {
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
