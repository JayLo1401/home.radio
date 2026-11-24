import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/nas_providers.dart';
import 'package:home_system/core/pictures_providers.dart';
import 'package:home_system/core/remote_keys.dart';
import 'package:home_system/data/repositories/nas_settings_repository.dart';
import 'package:home_system/data/services/nas_service.dart';
import 'package:home_system/data/services/picture_library.dart';
import 'package:home_system/features/pictures/pictures_screen.dart';
import 'package:home_system/features/pictures/slide_loader.dart';
import 'package:home_system/features/pictures/thumbnails.dart';
import 'package:home_system/l10n/l10n.dart';

class _NasSettings extends NasSettingsNotifier {
  _NasSettings(this.settings);

  final NasSettings settings;

  @override
  Future<NasSettings> build() async => settings;
}

class _Keys extends RemoteKeysNotifier {
  @override
  RemoteKeys build() => const RemoteKeys();
}

/// Resume points in memory instead of the database.
SlideshowResumeStore _memoryResume([Map<String, String>? store]) {
  final data = store ?? <String, String>{};
  return SlideshowResumeStore((key) async => data[key], (key, value) async => data[key] = value);
}

Future<void> _pumpBrowser(
  WidgetTester tester,
  NasSettings settings,
  NasClient nas, {
  SlideshowResumeStore? resume,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      nasSettingsProvider.overrideWith(() => _NasSettings(settings)),
      remoteKeysProvider.overrideWith(_Keys.new),
      slideshowResumeProvider.overrideWithValue(resume ?? _memoryResume()),
    ],
    child: MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PicturesScreen(createClient: (_) => nas),
    ),
  ));
  await _settle(tester);
}

/// A few frames (the loading wave never settles).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String? get _focused => FocusManager.instance.primaryFocus?.debugLabel;

/// A NAS in memory: folder path → its entries (names; folders end with "/").
class _FakeNas implements NasClient {
  _FakeNas(Map<String, List<String>> tree, {this.broken = const {}})
      : _tree = {
          for (final e in tree.entries)
            normalizeNasPath(e.key): [
              for (final name in e.value)
                NasEntry(
                  name: name.replaceAll('/', ''),
                  path: joinNasPath(e.key, name.replaceAll('/', '')),
                  isDirectory: name.endsWith('/'),
                ),
            ],
        };

  final Map<String, List<NasEntry>> _tree;
  final Set<String> broken;
  final listed = <String>[];

  @override
  Future<List<NasEntry>> list(String folder) async {
    final path = normalizeNasPath(folder);
    listed.add(path);
    if (broken.contains(path)) throw const NasException('broken');
    return _tree[path] ?? const [];
  }

  @override
  void close() {}

  // Thumbnails: no picture data here (they show the "broken" icon).
  @override
  Future<Uint8List> read(String path, {int? maxBytes}) async => Uint8List(0);

  @override
  Stream<List<int>> openRead(String path, {int offset = 0, int? length}) => const Stream.empty();

  // The rest isn't used.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> _paths(Iterable<NasEntry> entries) => [for (final e in entries) e.path];

Future<List<String>> _collect(NasClient nas, String root, {int maxPictures = 10000, int maxDepth = 8}) async {
  final all = <NasEntry>[];
  await for (final batch in collectPictures(nas, root, maxPictures: maxPictures, maxDepth: maxDepth)) {
    all.addAll(batch);
  }
  return _paths(all);
}

/// The preview a camera would store.
final _previewBytes = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 4, 0xFF, 0xD9]);

/// A JPEG start: JFIF block, EXIF block (orientation in IFD0, the preview
/// in IFD1), then the picture data.
Uint8List _jpegWithExif({required bool little, int orientation = 1, bool withPreview = true}) {
  final endian = little ? Endian.little : Endian.big;
  List<int> u16(int v) {
    final b = ByteData(2)..setUint16(0, v, endian);
    return b.buffer.asUint8List();
  }

  List<int> u32(int v) {
    final b = ByteData(4)..setUint32(0, v, endian);
    return b.buffer.asUint8List();
  }

  final tiff = <int>[
    ...(little ? [0x49, 0x49] : [0x4D, 0x4D]),
    ...u16(42),
    ...u32(8),
    // IFD0 at 8: orientation; next IFD at 26.
    ...u16(1),
    ...u16(0x0112), ...u16(3), ...u32(1), ...u16(orientation), 0, 0,
    ...u32(withPreview ? 26 : 0),
    // IFD1 at 26: where the preview is (at 56) and how long.
    ...u16(2),
    ...u16(0x0201), ...u16(4), ...u32(1), ...u32(56),
    ...u16(0x0202), ...u16(4), ...u32(1), ...u32(_previewBytes.length),
    ...u32(0),
    ..._previewBytes,
  ];
  final exif = [0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff];
  final length = exif.length + 2;
  return Uint8List.fromList([
    0xFF, 0xD8,
    0xFF, 0xE0, 0, 16, ...List.filled(14, 0x4A),
    0xFF, 0xE1, length >> 8, length & 0xFF, ...exif,
    0xFF, 0xDA, 0, 4, 9, 9,
  ]);
}

void main() {
  group('names', () {
    test('picture extensions', () {
      for (final name in ['a.jpg', 'B.JPEG', 'c.png', 'd.webp', 'e.gif', 'f.bmp', 'Urlaub 2026.Jpg']) {
        expect(isPictureName(name), isTrue, reason: name);
      }
      for (final name in ['a.txt', 'film.mp4', 'raw.cr2', 'jpg', '.jpg', '._IMG_1.jpg', 'x.jpg.part', 'Thumbs.db']) {
        expect(isPictureName(name), isFalse, reason: name);
      }
    });

    test('hidden folders', () {
      for (final name in ['.thumbnails', '@eaDir', r'$RECYCLE.BIN', '#recycle', '#Snapshot']) {
        expect(isHiddenPictureFolder(name), isTrue, reason: name);
      }
      for (final name in ['Urlaub', '2026', '#1 Hochzeit', 'Fotos.alt']) {
        expect(isHiddenPictureFolder(name), isFalse, reason: name);
      }
    });

    test('natural order', () {
      final names = ['Tag 10', 'tag 2', 'Tag 1', 'IMG_0100.jpg', 'IMG_99.jpg', 'a', 'B', 'Tag 02b'];
      names.sort(compareNatural);
      expect(names, ['a', 'B', 'IMG_99.jpg', 'IMG_0100.jpg', 'Tag 1', 'tag 2', 'Tag 02b', 'Tag 10']);
      expect(compareNatural('x', 'x'), 0);
    });

    test('a folder: subfolders and pictures, without hidden ones and other files', () {
      final folder = PictureFolder.of([
        const NasEntry(name: 'Tag 10', path: '/F/Tag 10', isDirectory: true),
        const NasEntry(name: '@eaDir', path: '/F/@eaDir', isDirectory: true),
        const NasEntry(name: 'Tag 2', path: '/F/Tag 2', isDirectory: true),
        const NasEntry(name: 'b10.jpg', path: '/F/b10.jpg', isDirectory: false),
        const NasEntry(name: 'b9.jpg', path: '/F/b9.jpg', isDirectory: false),
        const NasEntry(name: 'notes.txt', path: '/F/notes.txt', isDirectory: false),
      ]);
      expect(folder.folders.map((e) => e.name), ['Tag 2', 'Tag 10']);
      expect(folder.pictures.map((e) => e.name), ['b9.jpg', 'b10.jpg']);
    });
  });

  group('collectPictures', () {
    final nas = _FakeNas({
      '/Bilder': ['b.jpg', 'a.jpg', 'Urlaub/', 'Familie/', '.hidden/', '@eaDir/', 'liesmich.txt'],
      '/Bilder/Urlaub': ['u2.jpg', 'u10.jpg', 'Tag 2/', 'Tag 10/'],
      '/Bilder/Urlaub/Tag 2': ['t.png'],
      '/Bilder/Urlaub/Tag 10': ['t.webp', 'Tief/'],
      '/Bilder/Urlaub/Tag 10/Tief': ['tief.gif'],
      '/Bilder/Familie': ['f.jpeg'],
      '/Bilder/.hidden': ['geheim.jpg'],
      '/Bilder/@eaDir': ['thumb.jpg'],
    });

    test('folder by folder, each in natural order, depth first', () async {
      expect(await _collect(nas, '/Bilder'), [
        '/Bilder/a.jpg',
        '/Bilder/b.jpg',
        '/Bilder/Familie/f.jpeg',
        '/Bilder/Urlaub/u2.jpg',
        '/Bilder/Urlaub/u10.jpg',
        '/Bilder/Urlaub/Tag 2/t.png',
        '/Bilder/Urlaub/Tag 10/t.webp',
        '/Bilder/Urlaub/Tag 10/Tief/tief.gif',
      ]);
      expect(nas.listed, isNot(contains('/Bilder/.hidden')));
      expect(nas.listed, isNot(contains('/Bilder/@eaDir')));
    });

    test('a subfolder alone', () async {
      expect(await _collect(nas, '/Bilder/Urlaub/Tag 10'),
          ['/Bilder/Urlaub/Tag 10/t.webp', '/Bilder/Urlaub/Tag 10/Tief/tief.gif']);
    });

    test('limits: number of pictures and depth', () async {
      expect(await _collect(nas, '/Bilder', maxPictures: 4),
          ['/Bilder/a.jpg', '/Bilder/b.jpg', '/Bilder/Familie/f.jpeg', '/Bilder/Urlaub/u2.jpg']);
      expect(await _collect(nas, '/Bilder', maxDepth: 1),
          ['/Bilder/a.jpg', '/Bilder/b.jpg', '/Bilder/Familie/f.jpeg', '/Bilder/Urlaub/u2.jpg', '/Bilder/Urlaub/u10.jpg']);
      expect(await _collect(nas, '/Bilder', maxDepth: 0), ['/Bilder/a.jpg', '/Bilder/b.jpg']);
    });

    test('stops listing once enough pictures are found', () async {
      final counting = _FakeNas({
        '/P': ['1.jpg', '2.jpg', 'A/', 'B/'],
        '/P/A': ['3.jpg'],
        '/P/B': ['4.jpg'],
      });
      expect(await _collect(counting, '/P', maxPictures: 2), ['/P/1.jpg', '/P/2.jpg']);
      expect(counting.listed, ['/P']);
    });

    test('a broken subfolder is left out, a broken root is an error', () async {
      final broken = _FakeNas({
        '/P': ['1.jpg', 'A/', 'B/'],
        '/P/A': ['2.jpg'],
        '/P/B': ['3.jpg'],
      }, broken: {'/P/A'});
      final errors = <String>[];
      final all = <NasEntry>[];
      await for (final batch in collectPictures(broken, '/P', onError: (folder, _) => errors.add(folder))) {
        all.addAll(batch);
      }
      expect(_paths(all), ['/P/1.jpg', '/P/B/3.jpg']);
      expect(errors, ['/P/A']);

      final dead = _FakeNas({}, broken: {'/P'});
      expect(collectPictures(dead, '/P').toList(), throwsA(isA<NasException>()));
    });

    test('cancelling stops the walk', () async {
      final big = _FakeNas({
        '/P': ['1.jpg', 'A/', 'B/', 'C/'],
        '/P/A': ['2.jpg'],
        '/P/B': ['3.jpg'],
        '/P/C': ['4.jpg'],
      });
      await collectPictures(big, '/P').first;
      // Let a generator that wasn't stopped run on.
      await Future<void>.delayed(Duration.zero);
      expect(big.listed.length, lessThan(4));
    });
  });

  group('SlideshowPlaylist', () {
    test('folder order: as added; wraps around only once complete', () {
      final list = SlideshowPlaylist<int>()..addAll([1, 2, 3]);
      expect(list.current, 1);
      expect(list.peek(-1), isNull);
      expect(list.move(-1), isFalse);
      expect(list.move(1), isTrue);
      expect(list.move(1), isTrue);
      expect(list.current, 3);
      expect(list.peek(1), isNull);
      expect(list.move(1), isFalse, reason: 'more may still come');
      expect(list.current, 3);
      list.addAll([4]);
      expect(list.move(1), isTrue);
      expect(list.current, 4);
      list.finish();
      expect(list.peek(1), 1);
      expect(list.move(1), isTrue);
      expect(list.current, 1);
      expect(list.move(-1), isTrue);
      expect(list.current, 4);
    });

    test('shuffled: everything once, new ones never right after the current one', () {
      final list = SlideshowPlaylist<int>(order: SlideshowOrder.shuffled, random: Random(1));
      list.addAll(List.generate(50, (i) => i));
      expect(list.items.toSet(), Set.of(List.generate(50, (i) => i)));
      expect(list.items, isNot(List.generate(50, (i) => i)));
      list.move(1);
      list.move(1);
      final current = list.current;
      final next = list.peek(1);
      for (var round = 0; round < 20; round++) {
        list.addAll([100 + round]);
        expect(list.current, current);
        expect(list.peek(1), next, reason: 'the next one may already be loading');
      }
      expect(list.length, 70);
      // Added ones only come after the current one.
      final i = list.items.indexOf(current!);
      for (var round = 0; round < 20; round++) {
        expect(list.items.indexOf(100 + round), greaterThan(i + 1));
      }
    });

    test('shuffled: a new round in a new order, not starting with the last one', () {
      final list = SlideshowPlaylist<int>(order: SlideshowOrder.shuffled, random: Random(7))
        ..addAll(List.generate(10, (i) => i))
        ..finish();
      for (var round = 0; round < 30; round++) {
        while (list.index < list.length - 1) {
          list.move(1);
        }
        final last = list.current;
        expect(list.move(1), isTrue);
        expect(list.index, 0);
        expect(list.current, isNot(last));
        expect(list.items.toSet(), Set.of(List.generate(10, (i) => i)));
      }
    });

    test('removing a picture that cannot be shown', () {
      final list = SlideshowPlaylist<String>()..addAll(['a', 'b', 'c']);
      list.move(1);
      expect(list.removeCurrent(), isTrue);
      expect(list.current, 'c');
      expect(list.items, ['a', 'c']);
      // The last one, more may come: the one before stays current.
      expect(list.removeCurrent(), isFalse);
      expect(list.current, 'a');
      list.addAll(['d']);
      expect(list.move(1), isTrue);
      expect(list.current, 'd');
      // Backwards.
      expect(list.removeCurrent(forward: false), isTrue);
      expect(list.current, 'a');
      // Complete: wraps around.
      list
        ..addAll(['e'])
        ..finish();
      expect(list.removeCurrent(forward: false), isTrue);
      expect(list.items, ['e']);
      expect(list.current, 'e');
      expect(list.removeCurrent(), isFalse);
      expect(list.isEmpty, isTrue);
      expect(list.current, isNull);
    });

    test('the very first one failing: the next one added becomes current', () {
      final list = SlideshowPlaylist<String>()..addAll(['a']);
      expect(list.removeCurrent(), isFalse);
      list.addAll(['b', 'c']);
      expect(list.current, 'b');
    });
  });

  group('sizes and labels', () {
    test('fit within, never enlarged', () {
      expect(fitWithin(6000, 4000, 1920, 1080), (width: 1620, height: 1080));
      expect(fitWithin(4000, 6000, 1920, 1080), (width: 720, height: 1080));
      expect(fitWithin(800, 600, 1920, 1080), (width: 800, height: 600));
      expect(fitWithin(1920, 1080, 1920, 1080), (width: 1920, height: 1080));
    });

    test('decode box: the screen, at most Full HD', () {
      expect(slideBox(const Size(1920, 1080)), (width: 1920, height: 1080));
      expect(slideBox(const Size(3840, 2160)), (width: 1920, height: 1080));
      expect(slideBox(const Size(1280, 720)), (width: 1280, height: 720));
      expect(slideBox(const Size(1200, 1920)), (width: 1080, height: 1728));
      expect(slideBox(Size.zero), (width: 1920, height: 1080));
    });

    test('folder of a picture relative to the slideshow', () {
      expect(pictureFolderLabel('/Bilder', '/Bilder/a.jpg'), 'Bilder');
      expect(pictureFolderLabel('/Bilder', '/Bilder/Urlaub/Tag 2/a.jpg'), 'Urlaub/Tag 2');
      expect(pictureFolderLabel('/Bilder/', '/Bilder/Urlaub/a.jpg'), 'Urlaub');
      expect(pictureFolderLabel('/', '/Fotos/a.jpg'), 'Fotos');
      expect(pictureFolderLabel('/', '/a.jpg'), '/');
    });
  });

  group('browser', () {
    const configured = NasSettings(
      config: NasConfig(host: 'nas'),
      folders: {NasFolder.pictures: '/Bilder'},
    );

    testWidgets('without a pictures folder: the way to the NAS settings', (tester) async {
      await _pumpBrowser(tester, const NasSettings(), _FakeNas({}));
      expect(find.text('NAS-Einstellungen öffnen'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('remote: into a folder and back up, numbers on the tiles', (tester) async {
      final nas = _FakeNas({
        '/Bilder': ['a.jpg', 'Urlaub/', 'Familie/'],
        '/Bilder/Urlaub': ['u1.jpg', 'u2.jpg'],
        '/Bilder/Familie': ['f.jpg', 'Kinder/'],
      });
      await _pumpBrowser(tester, configured, nas);
      expect(find.text('Diashow: Bilder (mit Unterordnern)'), findsOneWidget);
      expect(_focused, 'slideshow:/Bilder');
      // Each subfolder listed once for its numbers.
      expect(find.text('2 Bilder'), findsOneWidget);
      expect(find.text('1 Bild  ·  1 Ordner'), findsOneWidget);

      // Grid: [Diashow] [Familie] / [Urlaub]
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      expect(_focused, '/Bilder/Urlaub');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _settle(tester);
      // Only pictures in there: the slideshow is the one thing to do.
      expect(find.text('Diashow: Urlaub'), findsOneWidget);
      expect(find.text('Bilder  ›  Urlaub'), findsOneWidget);
      expect(_focused, 'slideshow:/Bilder/Urlaub');

      // Back: up again, on the folder just left - no new listing.
      final listings = nas.listed.length;
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.text('Diashow: Bilder (mit Unterordnern)'), findsOneWidget);
      expect(_focused, '/Bilder/Urlaub');
      expect(nas.listed.length, listings);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a folder\'s own pictures as thumbnails, reached with the D-Pad', (tester) async {
      final nas = _FakeNas({
        '/Bilder': ['b.jpg', 'a.jpg', 'Urlaub/'],
        '/Bilder/Urlaub': ['u.jpg'],
      });
      await _pumpBrowser(tester, configured, nas);
      expect(find.text('2 Bilder in diesem Ordner - OK auf einem Bild startet die Diashow ab dort'), findsOneWidget);
      // In the walk's order (natural).
      expect(tester.getTopLeft(find.text('a.jpg')).dx, lessThan(tester.getTopLeft(find.text('b.jpg')).dx));
      // [Diashow] [Urlaub] / thumbnails below.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused?.findAncestorWidgetOfExactType<ThumbnailTile>()?.entry.name, 'a.jpg');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a folder stopped before: "Fortsetzen" offered, focused; Back starts nothing', (tester) async {
      final store = <String, String>{};
      final resume = _memoryResume(store);
      await resume.save(
        SlideshowResumeStore.keyOf(configured.config.identity, '/Bilder'),
        const SlideshowResumePoint(path: '/Bilder/b.jpg', name: 'b.jpg', position: 5),
      );
      await _pumpBrowser(tester, configured, _FakeNas({'/Bilder': ['a.jpg', 'b.jpg']}), resume: resume);
      expect(_focused, 'slideshow:/Bilder');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _settle(tester);
      expect(find.text('Fortsetzen ab Bild 5 (b.jpg)'), findsOneWidget);
      expect(find.text('Von vorne'), findsOneWidget);
      final focused = FocusManager.instance.primaryFocus?.context;
      final title = focused?.findAncestorWidgetOfExactType<ListTile>()?.title;
      expect(title is Text ? title.data : null, 'Fortsetzen ab Bild 5 (b.jpg)');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.text('Fortsetzen ab Bild 5 (b.jpg)'), findsNothing);
      expect(find.text('Diashow: Bilder'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('start at a picture', () {
    test('folder order: there, the ones before it after the last', () {
      final list = SlideshowPlaylist<String>(startWhere: (s) => s == 'c');
      list.addAll(['a', 'b']);
      expect(list.current, isNull, reason: 'not there yet');
      expect(list.move(1), isFalse);
      list.addAll(['c', 'd']);
      expect(list.current, 'c');
      expect(list.peek(1), 'd');
      expect(list.move(-1), isTrue);
      expect(list.current, 'b');
      list
        ..move(1)
        ..move(1)
        ..finish();
      expect(list.move(1), isTrue);
      expect(list.current, 'a');
    });

    test('shuffled: that one first, the rest mixed after it', () {
      final list = SlideshowPlaylist<int>(order: SlideshowOrder.shuffled, random: Random(3), startWhere: (i) => i == 37)
        ..addAll(List.generate(20, (i) => i))
        ..addAll(List.generate(30, (i) => 20 + i));
      expect(list.current, 37);
      expect(list.index, 0);
      expect(list.items.toSet(), Set.of(List.generate(50, (i) => i)));
    });

    test('gone meanwhile: the first one once the walk is done', () {
      final list = SlideshowPlaylist<String>(startWhere: (s) => s == 'x')..addAll(['a', 'b']);
      expect(list.current, isNull);
      list.finish();
      expect(list.current, 'a');
    });
  });

  group('LoadQueue', () {
    test('two at a time, newest wish first, cancelled ones never start', () async {
      final started = <String>[];
      final gates = <String, Completer<String?>>{};
      final queue = LoadQueue<String>(
        maxConcurrent: 2,
        fetch: (key) {
          started.add(key);
          return (gates[key] = Completer<String?>()).future;
        },
      );
      final got = <String, String?>{};
      for (final key in ['1', '2', '3', '4', '5']) {
        queue.request(key, (v) => got[key] = v);
      }
      expect(started, ['1', '2']);
      expect(queue.running, 2);
      queue.request('6', (v) => got['6'] = v);
      final cancelled = queue.request('3', (v) => got['3x'] = v);
      cancelled.cancel();
      gates['1']!.complete('one');
      await pumpEventQueue();
      // The newest wish ('6') before the older ones.
      expect(started, ['1', '2', '6']);
      expect(got['1'], 'one');
      gates['2']!.complete('two');
      gates['6']!.complete('six');
      await pumpEventQueue();
      gates['5']!.complete('five');
      await pumpEventQueue();
      gates['4']!.complete('four');
      await pumpEventQueue();
      expect(started, ['1', '2', '6', '5', '4', '3']);
      gates['3']!.complete('three');
      await pumpEventQueue();
      expect(got['3'], 'three', reason: 'the first wish for 3 was not cancelled');
      expect(got.containsKey('3x'), isFalse);
    });

    test('the least recently used go, failures are not asked again, copies per user', () async {
      final evicted = <String>[];
      var fetches = 0;
      final queue = LoadQueue<String>(
        cacheSize: 2,
        fetch: (key) async {
          fetches++;
          return key == 'bad' ? null : key.toUpperCase();
        },
        copy: (v) => '$v*',
        onEvict: evicted.add,
      );
      final got = <String?>[];
      queue.request('a', got.add);
      queue.request('b', got.add);
      await pumpEventQueue();
      expect(queue.peek('a'), 'A*'); // a is now the most recent
      queue.request('c', got.add);
      await pumpEventQueue();
      expect(evicted, ['B']);
      expect(queue.cachedKeys, ['a', 'c']);
      expect(got, containsAll(['A*', 'B*', 'C*']));

      queue.request('bad', got.add);
      await pumpEventQueue();
      expect(queue.failed('bad'), isTrue);
      final before = fetches;
      // From the cache: no fetch, delivered later (not while building).
      String? cached;
      queue.request('c', (v) => cached = v);
      expect(cached, isNull);
      await pumpEventQueue();
      expect(cached, 'C*');
      expect(fetches, before);

      queue.close();
      expect(evicted, containsAll(['A', 'C']));
    });

    test('suspended: nothing starts until resumed; one fetch for the same key', () async {
      final started = <String>[];
      final queue = LoadQueue<String>(fetch: (key) async {
        started.add(key);
        return key;
      });
      queue.suspend();
      final got = <String?>[];
      queue.request('x', got.add);
      queue.request('x', got.add);
      await pumpEventQueue();
      expect(started, isEmpty);
      queue.resume();
      await pumpEventQueue();
      expect(started, ['x']);
      expect(got, ['x', 'x']);
    });
  });

  group('EXIF preview', () {
    for (final little in [true, false]) {
      test('found, with its orientation (${little ? 'Intel' : 'Motorola'} byte order)', () {
        final jpeg = _jpegWithExif(little: little, orientation: 6);
        final preview = exifThumbnail(jpeg);
        expect(preview, isNotNull);
        expect(preview!.jpeg, _previewBytes);
        expect(preview.quarterTurns, 1);
        expect(exifThumbnail(_jpegWithExif(little: little, orientation: 1))!.quarterTurns, 0);
        expect(exifThumbnail(_jpegWithExif(little: little, orientation: 3))!.quarterTurns, 2);
        expect(exifThumbnail(_jpegWithExif(little: little, orientation: 8))!.quarterTurns, 3);
      });
    }

    test('none: no EXIF, no preview, cut off, not a JPEG', () {
      expect(exifThumbnail(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA, 0, 2, 1, 2])), isNull);
      expect(exifThumbnail(_jpegWithExif(little: true, withPreview: false)), isNull);
      final whole = _jpegWithExif(little: true);
      expect(exifThumbnail(Uint8List.sublistView(whole, 0, whole.length - 20)), isNull);
      expect(exifThumbnail(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isNull);
      expect(exifThumbnail(Uint8List(0)), isNull);
    });
  });

  group('resume points', () {
    test('stored and read back, the 30 most recent folders', () {
      var raw = '';
      var points = <String, SlideshowResumePoint>{};
      for (var i = 0; i < 35; i++) {
        raw = encodeResumePoints(points, 'f$i', SlideshowResumePoint(path: '/f$i/p.jpg', name: 'p.jpg', position: i));
        points = decodeResumePoints(raw);
      }
      expect(points.length, 30);
      expect(points.containsKey('f4'), isFalse);
      expect(points['f34']!.position, 34);
      // Used again: now the most recent, kept.
      raw = encodeResumePoints(points, 'f5', const SlideshowResumePoint(path: '/x.jpg', name: 'x.jpg', position: 2));
      raw = encodeResumePoints(decodeResumePoints(raw), 'new', const SlideshowResumePoint(path: '/n', name: 'n', position: 1));
      points = decodeResumePoints(raw);
      expect(points['f5']!.path, '/x.jpg');
      expect(points.containsKey('f6'), isFalse);
      expect(decodeResumePoints('not json'), isEmpty);
      expect(decodeResumePoints(null), isEmpty);
      expect(decodeResumePoints('{"a": {"path": 1}}'), isEmpty);
    });

    test('store: per NAS and folder', () async {
      final store = _memoryResume();
      final key = SlideshowResumeStore.keyOf('webdav|nas', '/Bilder/');
      expect(key, SlideshowResumeStore.keyOf('webdav|nas', '/Bilder'));
      expect(await store.get(key), isNull);
      await store.save(key, const SlideshowResumePoint(path: '/Bilder/a.jpg', name: 'a.jpg', position: 3));
      expect((await store.get(key))!.position, 3);
      expect(await store.get(SlideshowResumeStore.keyOf('ftp|other', '/Bilder')), isNull);
    });
  });

  testWidgets('decoding: at the size shown, with a tiny background copy', (tester) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = Colors.green);
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 200);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      picture.dispose();
      image.dispose();
      const entry = NasEntry(name: 'a.png', path: '/a.png', isDirectory: false);

      final slide = await decodeSlide(entry, png, box: (width: 100, height: 100), cover: true);
      expect(slide, isNotNull);
      expect((slide!.image.width, slide.image.height), (100, 50));
      expect((slide.cover!.width, slide.cover!.height), (32, 16));
      slide.dispose();

      final small = await decodeSlide(entry, png, box: (width: 1920, height: 1080), cover: false);
      expect((small!.image.width, small.image.height), (400, 200));
      expect(small.cover, isNull);
      small.dispose();

      expect(await decodeSlide(entry, Uint8List.fromList([1, 2, 3]), box: (width: 100, height: 100), cover: true),
          isNull);
    });
  });
}
