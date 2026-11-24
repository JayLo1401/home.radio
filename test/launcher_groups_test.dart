import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/models/launcher_group.dart';
import 'package:home_system/data/models/launcher_tile.dart';
import 'package:home_system/features/launcher/launcher_move_mode.dart';

void main() {
  const netflix = LauncherTile.app(package: 'com.netflix.ninja', label: 'Netflix');
  const disney = LauncherTile.app(package: 'com.disney.disneyplus', label: 'Disney+', image: 'http://nas/d.png');
  const files = LauncherTile.app(package: 'com.files', label: 'Dateien');
  const adb = LauncherTile.app(package: 'com.adb', label: 'ADB');

  group('insert order of new favourites', () {
    test('a part goes right after the last part, before the apps', () {
      final tiles = insertLauncherTile(const [
        LauncherTile.radio(),
        LauncherTile.tv(),
        netflix,
        disney,
      ], const LauncherTile.movies());
      expect(tiles.map((t) => t.id), ['radio', 'tv', 'movies', 'app:com.netflix.ninja', 'app:com.disney.disneyplus']);
    });

    test('a new part goes before the first own tile of a later media type', () {
      final tiles = insertLauncherTile(const [
        netflix,
        LauncherTile.radio(),
        disney,
        LauncherTile.tv(),
        files,
      ], const LauncherTile.music());
      expect(tiles.map((t) => t.id), [
        'app:com.netflix.ninja',
        'radio',
        'app:com.disney.disneyplus',
        'music',
        'tv',
        'app:com.files',
      ]);
    });

    test('without parts at the front; apps and the settings tile at the end', () {
      expect(insertLauncherTile(const [netflix], const LauncherTile.pictures()).map((t) => t.id), [
        'pictures',
        'app:com.netflix.ninja',
      ]);
      expect(insertLauncherTile(const [LauncherTile.radio(), netflix], disney).last, disney);
      expect(
        insertLauncherTile(const [
          LauncherTile.radio(),
          netflix,
        ], const LauncherTile.systemSettings()).last.isSystemSettings,
        isTrue,
      );
    });

    test('nothing twice', () {
      const tiles = [LauncherTile.radio(), LauncherTile.tv()];
      expect(insertLauncherTile(tiles, const LauncherTile.tv()), same(tiles));
    });
  });

  group('groups', () {
    test('JSON round trip keeps order, names, tiles and pictures', () {
      const groups = [
        LauncherGroup(id: 'g1', name: 'System-Tools', tiles: [files, adb]),
        LauncherGroup(id: 'g2', name: 'Kino', tiles: [disney]),
        LauncherGroup(id: 'g3', name: 'Leer'),
      ];
      final decoded = decodeLauncherGroups(encodeLauncherGroups(groups));
      expect(decoded, groups);
      expect(decoded[1].tiles.single.imageUrl, 'http://nas/d.png');
    });

    test('junk, duplicates and built-in parts are dropped', () {
      final decoded = decodeLauncherGroups(
        '[{"id":"a","name":"A","tiles":['
        '{"type":"app","package":"x"},{"type":"app","package":"x"},{"type":"radio"},{"type":"settings"},{"type":"?"}]},'
        '{"id":"a","name":"dup"},{"name":"no id"},42,{"id":"b","tiles":"nope"}]',
      );
      expect(decoded.map((g) => g.id), ['a', 'b']);
      expect(decoded.first.tiles.map((t) => t.id), ['app:x', 'settings']);
      expect(decoded[1].name, '');
      expect(decoded[1].tiles, isEmpty);
      expect(decodeLauncherGroups(null), isEmpty);
      expect(decodeLauncherGroups('kaputt'), isEmpty);
    });

    test('add, move, move to another group, remove', () {
      var groups = const [LauncherGroup(id: 'g1', name: 'A'), LauncherGroup(id: 'g2', name: 'B')];
      groups = groups
          .addTile('g1', files)
          .addTile('g1', adb)
          .addTile('g1', files)
          .addTile('g1', const LauncherTile.tv());
      expect(groups.byId('g1')!.tiles, [files, adb]);
      groups = groups.moveTile('g1', adb.id, -1);
      expect(groups.byId('g1')!.tiles, [adb, files]);
      expect(groups.moveTile('g1', adb.id, -1), groups, reason: 'already first');
      groups = groups.moveTileTo('g1', 'g2', adb);
      expect(groups.byId('g1')!.tiles, [files]);
      expect(groups.byId('g2')!.tiles, [adb]);
      // Already in the target: just leaves the source.
      groups = groups.addTile('g2', files).moveTileTo('g1', 'g2', files);
      expect(groups.byId('g1')!.tiles, isEmpty);
      expect(groups.byId('g2')!.tiles, [adb, files]);
      groups = groups.removeTile('g2', adb.id);
      expect(groups.byId('g2')!.tiles, [files]);
    });

    test('groups move, rename, go; pictures change everywhere', () {
      var groups = const [
        LauncherGroup(id: 'g1', name: 'A', tiles: [files]),
        LauncherGroup(id: 'g2', name: 'B', tiles: [files, adb]),
        LauncherGroup(id: 'g3', name: 'C'),
      ];
      expect(groups.moveGroup('g3', -1).map((g) => g.id), ['g1', 'g3', 'g2']);
      expect(groups.moveGroup('g1', -1).map((g) => g.id), ['g1', 'g2', 'g3']);
      expect(groups.moveGroup('g3', 1).map((g) => g.id), ['g1', 'g2', 'g3']);
      expect(groups.rename('g2', 'Tools').byId('g2')!.name, 'Tools');
      expect(groups.without('g2').map((g) => g.id), ['g1', 'g3']);
      groups = groups.setImage(files.id, 'http://nas/f.png');
      expect(groups.byId('g1')!.tiles.single.imageUrl, 'http://nas/f.png');
      expect(groups.byId('g2')!.tiles.first.imageUrl, 'http://nas/f.png');
      expect(groups.byId('g2')!.tiles.last.image, isNull);
    });

    test('new ids are unique', () {
      final now = DateTime(2026, 11, 24);
      final first = newLauncherGroupId(const [], now: now);
      final second = newLauncherGroupId([LauncherGroup(id: first, name: 'A')], now: now);
      expect(second, isNot(first));
      expect(first, startsWith('g'));
    });
  });

  group('up/down between rows', () {
    // Favourites: 256 wide, 22 apart; groups: 192 wide, 18 apart.
    int down({required int from, double fromOffset = 0, double toOffset = 0, int count = 20}) => nearestTileIndex(
      fromIndex: from,
      fromOffset: fromOffset,
      fromWidth: 256,
      fromPitch: 278,
      toOffset: toOffset,
      toWidth: 192,
      toPitch: 210,
      toCount: count,
      leading: 6,
    );

    test('the tile underneath, by position on screen', () {
      expect(down(from: 0), 0);
      // Centre of favourite 2: 6 + 556 + 128 = 690 -> group tile (690 - 6 - 96) / 210 = 2.8.
      expect(down(from: 2), 3);
      expect(down(from: 4), 5);
    });

    test('each row scrolled on its own', () {
      // The favourites scrolled by 3 tiles: favourite 3 is the first on screen.
      expect(down(from: 3, fromOffset: 3 * 278), 0);
      // The group scrolled: its 4th tile is the first on screen.
      expect(down(from: 0, toOffset: 4 * 210), 4);
    });

    test('clamped to the target row', () {
      expect(down(from: 6, count: 2), 1);
      expect(down(from: 0, fromOffset: 0, toOffset: 5000, count: 3), 2);
      expect(down(from: 3, count: 0), -1);
    });

    test('same sizes: straight across', () {
      for (var i = 0; i < 5; i++) {
        expect(
          nearestTileIndex(
            fromIndex: i,
            fromOffset: 0,
            fromWidth: 192,
            fromPitch: 210,
            toOffset: 0,
            toWidth: 192,
            toPitch: 210,
            toCount: 9,
          ),
          i,
        );
      }
    });
  });

  test('own tiles in front, by media type', () {
    const netflix = LauncherTile.app(package: 'n', label: 'Netflix');
    const spotify = LauncherTile.app(package: 's', label: 'Spotify');
    final row = [const LauncherTile.tv(), const LauncherTile.radio(), spotify, const LauncherTile.pictures(), netflix,
      const LauncherTile.music()];
    expect(ownTilesToFront(row).map((t) => t.id), ['radio', 'music', 'tv', 'pictures', 'app:s', 'app:n']);
    final ordered = [const LauncherTile.radio(), spotify];
    expect(ownTilesToFront(ordered), same(ordered));
  });

  test('a new part goes to its media type', () {
    const app = LauncherTile.app(package: 'x', label: 'X');
    final row = [const LauncherTile.radio(), const LauncherTile.tv(), const LauncherTile.browser(), app];
    expect(insertLauncherTile(row, const LauncherTile.music()).map((t) => t.id), ['radio', 'music', 'tv', 'browser', 'app:x']);
    expect(insertLauncherTile(row, const LauncherTile.pictures()).map((t) => t.id), ['radio', 'tv', 'pictures', 'browser', 'app:x']);
  });
  group('move mode: placing a dropped tile', () {
    List<String> ids(List<LauncherTile> tiles) => [for (final t in tiles) t.id];
    final row = [const LauncherTile.radio(), const LauncherTile.tv(), netflix, disney, files];

    test('anywhere in the row - also an app before the own tiles', () {
      expect(ids(placeLauncherTile(row, files.id, 0)), [files.id, 'radio', 'tv', netflix.id, disney.id]);
      expect(ids(placeLauncherTile(row, 'radio', 4)), ['tv', netflix.id, disney.id, files.id, 'radio']);
      expect(ids(placeLauncherTile(row, netflix.id, 1)), ['radio', netflix.id, 'tv', disney.id, files.id]);
      // Out of range: clamped to the ends.
      expect(ids(placeLauncherTile(row, 'tv', 99)), ['radio', netflix.id, disney.id, files.id, 'tv']);
      expect(ids(placeLauncherTile(row, disney.id, -3)), [disney.id, 'radio', 'tv', netflix.id, files.id]);
    });

    test('unchanged: same place, or no such tile', () {
      expect(placeLauncherTile(row, netflix.id, 2), same(row));
      expect(placeLauncherTile(row, adb.id, 0), same(row));
    });

    test('places count the shown tiles - hidden parts keep their place', () {
      // TV switched off: shown are Radio, Netflix, Disney+, Dateien.
      bool shown(LauncherTile t) => !t.isTv;
      // Dateien to the 2nd place shown: right before Netflix, behind the hidden TV.
      expect(ids(placeLauncherTile(row, files.id, 1, shown: shown)), ['radio', 'tv', files.id, netflix.id, disney.id]);
      // Netflix to the front: before Radio.
      expect(ids(placeLauncherTile(row, netflix.id, 0, shown: shown)), [netflix.id, 'radio', 'tv', disney.id, files.id]);
      // Radio to the end: behind the last shown tile.
      expect(ids(placeLauncherTile(row, 'radio', 3, shown: shown)), ['tv', netflix.id, disney.id, files.id, 'radio']);
      // Netflix stays the 2nd shown: nothing changes (TV stays before it).
      expect(placeLauncherTile(row, netflix.id, 1, shown: shown), same(row));
    });

    test('in a group', () {
      final groups = [
        LauncherGroup(id: 'g1', name: 'A', tiles: [netflix, disney, files]),
        const LauncherGroup(id: 'g2', name: 'B', tiles: [adb]),
      ];
      final moved = groups.placeTile('g1', files.id, 0);
      expect(ids(moved.byId('g1')!.tiles), [files.id, netflix.id, disney.id]);
      expect(moved.byId('g2'), same(groups.byId('g2')));
      expect(groups.placeTile('g1', disney.id, 1).byId('g1'), same(groups.byId('g1')));
    });
  });

  group('move mode keys', () {
    const tiles = ['radio', 'tv', 'netflix', 'disney'];
    List<String> shown(LauncherMoveMode m, [String row = '']) => m.arrange(row, tiles, (t) => t);

    test('off: OK, arrows and Back are not its business', () {
      final m = LauncherMoveMode();
      expect(m.active, isFalse);
      expect(m.ok('', 'tv', 1), isNull);
      expect(m.lifted, isNull);
      expect(m.step(1, 4), isNull);
      expect(m.back(), LauncherMoveBack.ignored);
      expect(shown(m), tiles);
    });

    test('OK lifts, ◀ ▶ move (stopping at the ends), OK drops', () {
      final m = LauncherMoveMode()..start();
      expect(m.step(-1, 4), isNull, reason: 'nothing lifted: the arrows move the focus');
      expect(m.ok('', 'disney', 3), isNull);
      expect(m.isLifted('', 'disney'), isTrue);
      expect(m.step(-1, 4), 2);
      expect(m.step(-1, 4), 1);
      expect(m.step(-1, 4), 0);
      expect(m.step(-1, 4), 0, reason: 'already first');
      expect(shown(m), ['disney', 'radio', 'tv', 'netflix']);
      expect(shown(m, 'g1'), tiles, reason: 'other rows stay as they are');
      final drop = m.ok('', 'disney', 0);
      expect(drop, (row: '', tileId: 'disney', from: 3, index: 0));
      expect(m.lifted, isNull);
      expect(m.active, isTrue, reason: 'on to the next tile');
      // The next one: lifted and put down where it was - nothing to save.
      m.ok('', 'tv', 1);
      expect(m.step(1, 4), 2);
      expect(m.step(1, 4), 3);
      expect(m.step(1, 4), 3, reason: 'already last');
      expect(m.step(-1, 4), 2);
      expect(m.step(-1, 4), 1);
      expect(m.ok('', 'tv', 1), isNull);
    });

    test('OK on something that is no tile lifts nothing', () {
      final m = LauncherMoveMode()..start();
      expect(m.ok('', null, 4), isNull);
      expect(m.lifted, isNull);
    });

    test('Back puts the lifted tile back, then ends move mode', () {
      final m = LauncherMoveMode()..start(row: 'g1', tileId: 'netflix', index: 2);
      expect(m.isLifted('g1', 'netflix'), isTrue);
      m.step(-1, 4);
      expect(shown(m, 'g1'), ['radio', 'netflix', 'tv', 'disney']);
      expect(m.back(), LauncherMoveBack.putBack);
      expect(shown(m, 'g1'), tiles);
      expect(m.active, isTrue);
      expect(m.back(), LauncherMoveBack.ended);
      expect(m.active, isFalse);
      expect(m.back(), LauncherMoveBack.ignored);
    });

    test('holding OK ends move mode - a lifted tile stays where it is', () {
      final m = LauncherMoveMode()..start(row: '', tileId: 'radio', index: 0);
      m.step(1, 4);
      expect(m.finish(), (row: '', tileId: 'radio', from: 0, index: 1));
      expect(m.active, isFalse);
      expect(m.lifted, isNull);
      expect((LauncherMoveMode()..start()).finish(), isNull);
    });

    test('a lifted tile that left its row is shown and kept as it is', () {
      final m = LauncherMoveMode()..start(row: '', tileId: 'gone', index: 1);
      m.step(1, 4);
      expect(shown(m), tiles);
      m.cancelLift();
      expect(m.lifted, isNull);
      expect(m.active, isTrue);
    });
  });
}
