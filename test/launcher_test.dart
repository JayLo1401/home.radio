import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/ok_long_press.dart';
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
  // The launcher's wiring in move mode: the tile's own OkLongPress gets no
  // onLongPress, so OK (short and held) goes through to the rows' one.
  testWidgets('move mode: OK goes past the tile to the rows', (tester) async {
    var moving = false;
    var opened = 0, options = 0, picked = 0, finished = 0;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: Material(child: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return OkLongPress(
          onTap: moving ? () => picked++ : null,
          onLongPress: moving ? () => finished++ : null,
          child: OkLongPress(
            onTap: () => opened++,
            onLongPress: moving ? null : () => options++,
            child: InkWell(autofocus: true, onTap: () => opened++, child: const SizedBox(width: 50, height: 50)),
          ),
        );
      })),
    ));
    await tester.pump();

    Future<void> press({bool hold = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      if (hold) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
    }

    await press();
    expect((opened, options, picked, finished), (1, 0, 0, 0));
    await press(hold: true);
    expect((opened, options, picked, finished), (1, 1, 0, 0));

    update(() => moving = true);
    await tester.pump();
    await press();
    expect((opened, options, picked, finished), (1, 1, 1, 0), reason: 'OK picks up / drops, opens nothing');
    await press(hold: true);
    expect((opened, options, picked, finished), (1, 1, 1, 1), reason: 'held OK ends move mode');
  });
}
