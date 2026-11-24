import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Canvas, Colors, Offset, Paint, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/models/music_track.dart';
import 'package:home_system/data/services/music_cover.dart';
import 'package:home_system/data/services/music_index.dart';
import 'package:home_system/data/services/music_library.dart';
import 'package:home_system/data/services/music_spectrum.dart';
import 'package:home_system/data/services/music_stream_server.dart';
import 'package:home_system/data/services/music_tag_reader.dart';
import 'package:home_system/data/services/nas_service.dart';
import 'package:home_system/features/music/music_visualizer.dart';

// --- Fixture builders ---

List<int> _u32be(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> _u32le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
List<int> _syncsafe(int v) => [(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F];

List<int> _id3Frame(String id, List<int> data, {required int version}) => [
      ...ascii.encode(id),
      ...(version == 4 ? _syncsafe(data.length) : _u32be(data.length)),
      0,
      0,
      ...data,
    ];

List<int> _id3Tag(List<int> frames, {required int version, int padding = 16}) => [
      ...ascii.encode('ID3'),
      version,
      0,
      0,
      ..._syncsafe(frames.length + padding),
      ...frames,
      ...List.filled(padding, 0),
    ];

final _jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9];

/// Some fake MPEG audio after the tags.
final _audio = List.generate(4000, (i) => i & 0x7F);

MusicByteReader _reader(List<int> file) => (offset, length) async {
      if (offset >= file.length) return Uint8List(0);
      return Uint8List.fromList(file.sublist(offset, min(offset + length, file.length)));
    };

Future<MusicTags> _tags(List<int> file) => readMusicTags(_reader(file), fileSize: file.length);

List<int> _vorbisComment(Map<String, String> values) {
  const vendor = 'test';
  final entries = [for (final e in values.entries) utf8.encode('${e.key}=${e.value}')];
  return [
    ..._u32le(vendor.length),
    ...ascii.encode(vendor),
    ..._u32le(entries.length),
    for (final e in entries) ...[..._u32le(e.length), ...e],
  ];
}

List<int> _flacPicture(List<int> image) => [
      ..._u32be(3),
      ..._u32be(10),
      ...ascii.encode('image/jpeg'),
      ..._u32be(0),
      ..._u32be(500),
      ..._u32be(500),
      ..._u32be(24),
      ..._u32be(0),
      ..._u32be(image.length),
      ...image,
    ];

List<int> _atom(String type, List<int> content) => [..._u32be(content.length + 8), ...latin1.encode(type), ...content];

List<int> _mp4Data(int kind, List<int> payload) => _atom('data', [..._u32be(kind), ..._u32be(0), ...payload]);

/// One Ogg page holding [packets] (each under 255 * 255 bytes).
List<int> _oggPage(List<List<int>> packets, int sequence) {
  final lacing = <int>[];
  for (final p in packets) {
    var n = p.length;
    while (n >= 255) {
      lacing.add(255);
      n -= 255;
    }
    lacing.add(n);
  }
  return [
    ...ascii.encode('OggS'),
    0,
    sequence == 0 ? 2 : 0,
    ...List.filled(8, 0),
    ..._u32le(1),
    ..._u32le(sequence),
    ..._u32le(0),
    lacing.length,
    ...lacing,
    for (final p in packets) ...p,
  ];
}

// --- A NAS in memory ---

class _FakeNas implements NasClient {
  _FakeNas(this.files);

  /// Path -> content.
  final Map<String, List<int>> files;

  final listed = <String>[];
  final failing = <String>{};

  @override
  Future<List<NasEntry>> list(String folder) async {
    final base = normalizeNasPath(folder);
    listed.add(base);
    if (failing.contains(base)) throw const NasException('kaputt');
    final prefix = base == '/' ? '/' : '$base/';
    final entries = <String, NasEntry>{};
    for (final path in files.keys) {
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      final slash = rest.indexOf('/');
      final name = slash < 0 ? rest : rest.substring(0, slash);
      final isDir = slash >= 0;
      entries[name] = NasEntry(
        name: name,
        path: joinNasPath(base, name),
        isDirectory: isDir,
        size: isDir ? null : files[path]?.length,
      );
    }
    if (entries.isEmpty && base != '/') throw const NasException('nicht gefunden');
    return entries.values.toList();
  }

  @override
  Future<Uint8List> read(String path, {int? maxBytes}) async => Uint8List.fromList(files[path]!);

  @override
  Future<int?> size(String path) async => files[path]?.length;

  @override
  Stream<List<int>> openRead(String path, {int offset = 0, int? length}) async* {
    final data = files[path];
    if (data == null) throw const NasException('nicht gefunden');
    final end = length == null ? data.length : min(data.length, offset + length);
    for (var i = offset; i < end; i += 1000) {
      yield data.sublist(i, min(i + 1000, end));
    }
  }

  @override
  Future<void> test() async {}

  @override
  Future<void> write(String path, List<int> bytes) async => files[path] = bytes;

  @override
  Future<void> delete(String path) async => files.remove(path);

  @override
  void close() {}
}

void main() {
  group('tags', () {
    test('ID3v2.3: Latin-1 and UTF-16 texts, track, year, front cover', () async {
      final frames = [
        ..._id3Frame('TIT2', [0, ...latin1.encode('Schöne Grüße')], version: 3),
        // UTF-16 with BOM (little endian).
        ..._id3Frame('TPE1', [1, 0xFF, 0xFE, ...'Björk'.codeUnits.expand((c) => [c & 0xFF, c >> 8]), 0, 0],
            version: 3),
        ..._id3Frame('TALB', [0, ...ascii.encode('Album')], version: 3),
        ..._id3Frame('TRCK', [0, ...ascii.encode('7/12')], version: 3),
        ..._id3Frame('TYER', [0, ...ascii.encode('1997')], version: 3),
        // A back cover first, then the front one - the front wins.
        ..._id3Frame('APIC', [0, ...ascii.encode('image/png'), 0, 4, 0, 9, 9, 9], version: 3),
        ..._id3Frame('APIC', [0, ...ascii.encode('image/jpeg'), 0, 3, ...ascii.encode('Cover'), 0, ..._jpeg],
            version: 3),
      ];
      final tags = await _tags([..._id3Tag(frames, version: 3), ..._audio]);
      expect(tags.title, 'Schöne Grüße');
      expect(tags.artist, 'Björk');
      expect(tags.album, 'Album');
      expect(tags.trackNumber, 7);
      expect(tags.year, 1997);
      expect(tags.cover, _jpeg);
    });

    test('ID3v2.4: UTF-8, syncsafe frame sizes, TDRC', () async {
      final longTitle = 'Ä' * 100; // a frame over 127 bytes: syncsafe matters
      final frames = [
        ..._id3Frame('TIT2', [3, ...utf8.encode(longTitle)], version: 4),
        ..._id3Frame('TPE1', [3, ...utf8.encode('Sigur Rós'), 0, ...utf8.encode('Zweiter')], version: 4),
        ..._id3Frame('TDRC', [3, ...utf8.encode('2005-06-01')], version: 4),
      ];
      final tags = await _tags([..._id3Tag(frames, version: 4), ..._audio]);
      expect(tags.title, longTitle);
      expect(tags.artist, 'Sigur Rós');
      expect(tags.year, 2005);
    });

    test('ID3v2.2 (three-letter frames)', () async {
      List<int> frame(String id, String text) {
        final data = [0, ...latin1.encode(text)];
        return [...ascii.encode(id), 0, 0, data.length, ...data];
      }

      final tags = await _tags([
        ..._id3Tag([...frame('TT2', 'Old Song'), ...frame('TP1', 'Old Band')], version: 2),
        ..._audio,
      ]);
      expect(tags.title, 'Old Song');
      expect(tags.artist, 'Old Band');
    });

    test('ID3v1 at the end when there is no ID3v2', () async {
      List<int> field(String s, int n) => [...latin1.encode(s), ...List.filled(n - s.length, 0)];
      final v1 = [
        ...ascii.encode('TAG'),
        ...field('Title One', 30),
        ...field('Artist One', 30),
        ...field('Album One', 30),
        ...ascii.encode('1984'),
        ...field('comment', 28),
        0,
        5,
        12,
      ];
      final tags = await _tags([..._audio, ...v1]);
      expect(tags.title, 'Title One');
      expect(tags.artist, 'Artist One');
      expect(tags.album, 'Album One');
      expect(tags.year, 1984);
      expect(tags.trackNumber, 5);
    });

    test('FLAC: Vorbis comment and picture block', () async {
      final comment = _vorbisComment({'TITLE': 'Flac Titel', 'ARTIST': 'Flac Band', 'TRACKNUMBER': '3', 'DATE': '2011'});
      final picture = _flacPicture(_jpeg);
      final file = [
        ...ascii.encode('fLaC'),
        0x00, 0, 0, 34, ...List.filled(34, 0), // STREAMINFO
        0x04, ...[(comment.length >> 16) & 0xFF, (comment.length >> 8) & 0xFF, comment.length & 0xFF], ...comment,
        0x86, ...[(picture.length >> 16) & 0xFF, (picture.length >> 8) & 0xFF, picture.length & 0xFF], ...picture,
        ..._audio,
      ];
      final tags = await _tags(file);
      expect(tags.title, 'Flac Titel');
      expect(tags.artist, 'Flac Band');
      expect(tags.trackNumber, 3);
      expect(tags.year, 2011);
      expect(tags.cover, _jpeg);
    });

    test('MP4/M4A: moov after mdat, ilst items, cover', () async {
      final ilst = _atom('ilst', [
        ..._atom('©nam', _mp4Data(1, utf8.encode('M4A Titel'))),
        ..._atom('©ART', _mp4Data(1, utf8.encode('M4A Künstler'))),
        ..._atom('©alb', _mp4Data(1, utf8.encode('M4A Album'))),
        ..._atom('trkn', _mp4Data(0, [0, 0, 0, 9, 0, 12, 0, 0])),
        ..._atom('covr', _mp4Data(13, _jpeg)),
      ]);
      final meta = _atom('meta', [0, 0, 0, 0, ..._atom('hdlr', List.filled(25, 0)), ...ilst]);
      final moov = _atom('moov', [..._atom('mvhd', List.filled(100, 0)), ..._atom('udta', meta)]);
      final file = [
        ..._atom('ftyp', ascii.encode('M4A mp42isom')),
        // A big mdat first - the reader skips it by its size.
        ..._atom('mdat', List.filled(200000, 7)),
        ...moov,
      ];
      final tags = await _tags(file);
      expect(tags.title, 'M4A Titel');
      expect(tags.artist, 'M4A Künstler');
      expect(tags.album, 'M4A Album');
      expect(tags.trackNumber, 9);
      expect(tags.cover, _jpeg);
    });

    test('Ogg Vorbis and Opus comment headers', () async {
      final ident = [1, ...ascii.encode('vorbis'), ...List.filled(23, 0)];
      final comment = [3, ...ascii.encode('vorbis'), ..._vorbisComment({'TITLE': 'Ogg Lied', 'ARTIST': 'Ogg Band'}), 1];
      final ogg = await _tags([..._oggPage([ident], 0), ..._oggPage([comment, List.filled(300, 1)], 1), ..._audio]);
      expect(ogg.title, 'Ogg Lied');
      expect(ogg.artist, 'Ogg Band');

      final opus = parseOggCommentPacket(Uint8List.fromList([
        ...ascii.encode('OpusTags'),
        ..._vorbisComment({'title': 'Opus Lied', 'album': 'Opus Album'}),
      ]));
      expect(opus?.title, 'Opus Lied');
      expect(opus?.album, 'Opus Album');
    });

    test('WAV: RIFF INFO after the data chunk', () async {
      List<int> sub(String id, String text) {
        final b = [...utf8.encode(text), 0];
        return [...ascii.encode(id), ..._u32le(b.length), ...b, if (b.length.isOdd) 0];
      }

      final info = [...ascii.encode('INFO'), ...sub('INAM', 'Wave Titel'), ...sub('IART', 'Wave Band')];
      final data = List.filled(5001, 0); // odd: padded
      final body = [
        ...ascii.encode('WAVE'),
        ...ascii.encode('fmt '), ..._u32le(16), ...List.filled(16, 0),
        ...ascii.encode('data'), ..._u32le(data.length), ...data, 0,
        ...ascii.encode('LIST'), ..._u32le(info.length), ...info,
      ];
      final tags = await _tags([...ascii.encode('RIFF'), ..._u32le(body.length), ...body]);
      expect(tags.title, 'Wave Titel');
      expect(tags.artist, 'Wave Band');
    });

    test('broken files give no tags, no error', () async {
      expect((await _tags(List.filled(50, 0xFF))).isEmpty, isTrue);
      expect((await _tags([...ascii.encode('ID3'), 3, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F, 1, 2])).isEmpty, isTrue);
      expect((await _tags([])).isEmpty, isTrue);
    });
  });

  group('names', () {
    test('artist and title from file names', () {
      expect(guessFromFileName('01 - Queen - Bohemian Rhapsody'), (artist: 'Queen', title: 'Bohemian Rhapsody'));
      expect(guessFromFileName('07. Song Name'), (artist: null, title: 'Song Name'));
      expect(guessFromFileName('03_Some_Title'), (artist: null, title: 'Some Title'));
      expect(guessFromFileName('1999'), (artist: null, title: '1999'));
      expect(guessFromFileName('Artist - Title'), (artist: 'Artist', title: 'Title'));
    });

    test('display: tags first, file name otherwise', () {
      const track = MusicTrack('/Musik/Album/02 - Band - Lied.mp3');
      expect(MusicDisplay.of(track, null).line, 'Band - Lied');
      expect(MusicDisplay.of(track, null).album, 'Album');
      expect(MusicDisplay.of(track, const MusicTags(title: 'Echt', artist: 'Echte Band')).line, 'Echte Band - Echt');
      expect(MusicDisplay.of(track, const MusicTags(title: 'Echt'), preferTags: false).title, '02 - Band - Lied');
    });

    test('music files and natural order', () {
      expect(isMusicName('a.MP3', android: true), isTrue);
      expect(isMusicName('a.wma', android: true), isFalse);
      expect(isMusicName('a.wma', android: false), isTrue);
      expect(isMusicName('._a.mp3', android: false), isFalse);
      expect(isMusicName('cover.jpg', android: false), isFalse);
      final names = ['Track 10.mp3', 'track 2.mp3', 'Track 1.mp3']..sort(compareMusicNames);
      expect(names, ['Track 1.mp3', 'track 2.mp3', 'Track 10.mp3']);
      expect(pickFolderCover(['01.mp3', 'Folder.JPG', 'back.jpg']), 'Folder.JPG');
    });

    test('byte ranges', () {
      expect(parseByteRange(null, 100), isNull);
      expect(parseByteRange('bytes=0-', 100), (start: 0, end: 99));
      expect(parseByteRange('bytes=10-19', 100), (start: 10, end: 19));
      expect(parseByteRange('bytes=90-200', 100), (start: 90, end: 99));
      expect(parseByteRange('bytes=-10', 100), (start: 90, end: 99));
      final beyond = parseByteRange('bytes=100-', 100)!;
      expect(beyond.start > beyond.end, isTrue);
    });
  });

  group('walk and queue', () {
    final nas = _FakeNas({
      '/M/B/2.mp3': [1],
      '/M/B/10.mp3': [1],
      '/M/A/x.flac': [1],
      '/M/A/Sub/y.mp3': [1],
      '/M/A/cover.jpg': [1],
      '/M/@eaDir/z.mp3': [1],
      '/M/top.mp3': [1],
      '/M/Broken/q.mp3': [1],
    });

    test('depth first, natural order, hidden folders and broken ones skipped', () async {
      nas.failing.add('/M/Broken');
      final batches = await walkMusic(nas, '/M', android: true).toList();
      expect(
        [for (final b in batches) for (final t in b) t.path],
        ['/M/top.mp3', '/M/A/x.flac', '/M/A/Sub/y.mp3', '/M/B/2.mp3', '/M/B/10.mp3'],
      );
      nas.failing.clear();
    });

    test('without subfolders: only the tracks of the folder itself', () async {
      final batches = await walkMusic(nas, '/M', android: true, subfolders: false).toList();
      expect([for (final b in batches) for (final t in b) t.path], ['/M/top.mp3']);
    });

    test('the root failing throws', () async {
      expect(walkMusic(nas, '/Nope', android: true).toList(), throwsA(isA<NasException>()));
    });

    test('random folder order still finds everything once', () async {
      final batches = await walkMusic(nas, '/M', random: Random(3), android: true).toList();
      final paths = [for (final b in batches) for (final t in b) t.path];
      expect(paths.toSet().length, paths.length);
      expect(paths.length, 6);
    });

    List<MusicTrack> tracks(int n) => [for (var i = 0; i < n; i++) MusicTrack('/M/$i.mp3')];

    test('shuffle plays every track exactly once, also tracks found later', () {
      final q = MusicQueue(random: Random(42));
      q.replace(tracks(30), shuffle: true, startRandom: true);
      final played = <MusicTrack>[q.current!];
      var more = 30;
      while (q.next()) {
        played.add(q.current!);
        // Tracks keep coming in while it plays.
        if (more < 100) {
          q.addDiscovered([for (var i = more; i < more + 10; i++) MusicTrack('/M/$i.mp3')]);
          more += 10;
        }
      }
      expect(played.length, 100);
      expect(played.toSet().length, 100);
      // Not simply in order.
      expect(played.take(10).map((t) => t.path).toList(), isNot([for (var i = 0; i < 10; i++) '/M/$i.mp3']));
    });

    test('found tracks never land before the next loaded one', () {
      final q = MusicQueue(random: Random(1));
      q.replace(tracks(3), shuffle: true, start: 0);
      final next = q.peekNext();
      for (var i = 0; i < 20; i++) {
        q.addDiscovered([MusicTrack('/N/$i.mp3')]);
        expect(q.peekNext(), next);
      }
    });

    test('shuffle off goes back to the order at the current track', () {
      final q = MusicQueue(random: Random(5));
      final list = tracks(10);
      q.replace(list, start: 4);
      expect(q.current, list[4]);
      q.setShuffle(true);
      expect(q.current, list[4]);
      expect(q.items.toSet(), list.toSet());
      q.next();
      final now = q.current!;
      q.setShuffle(false);
      expect(q.current, now);
      expect(q.items, list);
    });

    test('repeat all wraps, off stops, previous', () {
      final q = MusicQueue()..replace(tracks(2));
      expect(q.next(), isTrue);
      expect(q.next(), isFalse);
      expect(q.peekNext(repeat: MusicRepeat.all), q.items.first);
      expect(q.next(repeat: MusicRepeat.all), isTrue);
      expect(q.index, 0);
      expect(q.previous(), isFalse);
      expect(q.previous(repeat: MusicRepeat.all), isTrue);
      expect(q.index, 1);
    });
  });

  group('index', () {
    MusicIndexData sample() => MusicIndexData(
          identity: 'webdav|nas|',
          root: '/Musik',
          updated: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          folders: {
            '/Musik/Queen/A Night at the Opera': [('11 - Bohemian Rhapsody.mp3', 123), ('01 Death on Two Legs.mp3', null)],
            '/Musik/Björk/Homogenic': [('Jóga.flac', 456)],
          },
        );

    test('serialisation round trip (gzipped JSON)', () {
      final data = sample();
      final back = MusicIndexData.decode(data.encode())!;
      expect(back.identity, data.identity);
      expect(back.root, '/Musik');
      expect(back.updated, data.updated);
      expect(back.complete, isTrue);
      expect(back.trackCount, 3);
      expect(back.folders['/Musik/Queen/A Night at the Opera'], [('11 - Bohemian Rhapsody.mp3', 123), ('01 Death on Two Legs.mp3', null)]);
      expect(back.fits('webdav|nas|', '/Musik/'), isTrue);
      expect(MusicIndexData.decode([1, 2, 3]), isNull);
    });

    test('interrupted build keeps its pending folders', () {
      final data = MusicIndexData(
        identity: 'x',
        root: '/M',
        folders: const {},
        updated: DateTime(2026),
        complete: false,
        pending: ['/M/B', '/M/C'],
      );
      final back = MusicIndexData.decode(data.encode())!;
      expect(back.complete, isFalse);
      expect(back.pending, ['/M/B', '/M/C']);
    });

    test('search: all words, accents and case ignored', () async {
      final search = MusicIndexSearch(sample());
      await search.prepare();
      expect(search.search('queen bohemian').map((t) => t.name), ['11 - Bohemian Rhapsody.mp3']);
      expect(search.search('BJORK joga').map((t) => t.name), ['Jóga.flac']);
      expect(search.search('opera'), hasLength(2));
      expect(search.search('nothing here'), isEmpty);
    });

    test('a subtree is replaced, the rest stays', () {
      final updated = sample().withSubtree('/Musik/Queen', {
        '/Musik/Queen/Innuendo': [('Innuendo.mp3', 1)],
      });
      expect(updated.folders.keys, unorderedEquals(['/Musik/Björk/Homogenic', '/Musik/Queen/Innuendo']));
    });

    test('a build through a fake NAS, saved and loaded again', () async {
      final dir = await Directory.systemTemp.createTemp('music_index_test');
      addTearDown(() => dir.delete(recursive: true));
      final nas = _FakeNas({'/M/a.mp3': [1, 2], '/M/X/b.flac': [3], '/M/X/c.txt': [4]});
      final store = MusicIndexStore(() async => dir);
      await store.build(nas, 'id', '/M');
      expect(store.current.value?.trackCount, 2);
      expect(store.progress.value.running, isFalse);
      final again = MusicIndexStore(() async => dir);
      final loaded = await again.indexFor('id', '/M');
      expect(loaded?.tracks.map((t) => t.path), ['/M/a.mp3', '/M/X/b.flac']);
      expect(await again.indexFor('other', '/M'), isNull);
    });
  });

  group('stream server', () {
    test('serves ranges from the NAS', () async {
      final content = List.generate(10000, (i) => i % 251);
      final nas = _FakeNas({'/M/song.mp3': content});
      final server = MusicStreamServer.local(nas);
      addTearDown(server.close);
      final uri = await server.uriFor(MusicTrack('/M/song.mp3', size: content.length));
      expect(uri.path, endsWith('.mp3'));
      final client = HttpClient();
      addTearDown(client.close);

      final full = await (await client.getUrl(uri)).close();
      expect(full.statusCode, 200);
      expect(full.headers.contentType?.mimeType, 'audio/mpeg');
      expect(await full.fold<List<int>>([], (a, b) => a..addAll(b)), content);

      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=5000-5009');
      final part = await request.close();
      expect(part.statusCode, 206);
      expect(part.headers.value(HttpHeaders.contentRangeHeader), 'bytes 5000-5009/10000');
      expect(await part.fold<List<int>>([], (a, b) => a..addAll(b)), content.sublist(5000, 5010));

      final beyond = await client.getUrl(uri);
      beyond.headers.set(HttpHeaders.rangeHeader, 'bytes=20000-');
      final response = await beyond.close();
      expect(response.statusCode, 416);
      await response.drain<void>();
    });

    test('reads tags through ranges', () async {
      final frames = _id3Frame('TIT2', [0, ...ascii.encode('Remote')], version: 3);
      final file = [..._id3Tag(frames, version: 3), ..._audio];
      final nas = _FakeNas({'/M/r.mp3': file});
      final tags = await readMusicTags((o, l) => readNasRange(nas, '/M/r.mp3', o, l), fileSize: file.length);
      expect(tags.title, 'Remote');
    });
  });

  group('track change stays light', () {
    test('the stream address carries path and size (no state in the server isolate)', () {
      const track = MusicTrack('/Musik/Björk/01 - Jóga (Live) #1.flac', size: 123456);
      final uri = musicStreamUri(4711, track);
      expect(uri.port, 4711);
      expect(uri.path, endsWith('.flac'));
      final back = musicStreamTrack(uri)!;
      expect(back.path, track.path);
      expect(back.size, 123456);
      expect(musicStreamTrack(musicStreamUri(1, const MusicTrack('/a/b.mp3')))?.size, isNull);
      expect(musicStreamTrack(Uri.parse('http://127.0.0.1:1/x/y')), isNull);
    });

    Future<Uint8List> png(int w, int h) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(Offset.zero & Size(w.toDouble(), h.toDouble()), Paint()..color = Colors.green);
      final image = await recorder.endRecording().toImage(w, h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }

    Future<(int, int)> sizeOf(Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return (frame.image.width, frame.image.height);
    }

    test('big covers are scaled down once, small ones kept', () async {
      final big = await png(1600, 1000);
      final small = await shrinkMusicCover(big);
      expect(await sizeOf(small!), (512, 320));
      final tiny = await png(300, 300);
      expect(identical(await shrinkMusicCover(tiny), tiny), isTrue);
      expect(await shrinkMusicCover(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('big ID3 tags are parsed off the UI isolate with the same result', () async {
      final cover = List.generate(400 * 1024, (i) => i & 0xFF);
      final frames = [
        ..._id3Frame('TIT2', [0, ...latin1.encode('Groß')], version: 3),
        ..._id3Frame('APIC', [0, ...ascii.encode('image/jpeg'), 0, 3, 0, ...cover], version: 3),
      ];
      final tags = await _tags([..._id3Tag(frames, version: 3), ..._audio]);
      expect(tags.title, 'Groß');
      expect(tags.cover?.length, cover.length);
    });
  });

  group('visualisation', () {
    const size = Size(960, 540);

    test('opens with the chute; scenes change without repeats back to back', () {
      final engine = MusicVisualizerEngine(detail: 0.5, random: Random(4), interval: 20);
      expect(engine.scene, 0);
      final seen = <int>[engine.scene];
      for (var t = 0.0; t < 20.0 * 30; t += 0.5) {
        final lines = engine.frame(size, t, MusicLevels.silent);
        for (final v in [...lines.glow, ...lines.core]) {
          v.dispose();
        }
        if (engine.scene != seen.last) seen.add(engine.scene);
      }
      // About one change per 20 s.
      expect(seen.length, greaterThanOrEqualTo(28));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], isNot(seen[i - 1]));
      }
      // Every scene comes within each round of all of them.
      for (var i = 0; i + MusicVisualizerEngine.sceneCount <= seen.length - 1; i += MusicVisualizerEngine.sceneCount) {
        expect(seen.sublist(i + 1, i + 1 + MusicVisualizerEngine.sceneCount).toSet().length,
            greaterThanOrEqualTo(MusicVisualizerEngine.sceneCount - 1));
      }
    });

    test('manual: only nextScene changes it', () {
      final engine = MusicVisualizerEngine(detail: 0.5, random: Random(1), interval: 0);
      for (var t = 0.0; t < 300; t += 1) {
        for (final v in engine.frame(size, t, MusicLevels.silent).core) {
          v.dispose();
        }
      }
      expect(engine.scene, 0);
      engine.nextScene();
      engine.frame(size, 301, MusicLevels.silent);
      expect(engine.scene, isNot(0));
    });

    test('every scene draws lines, also while fading into the next', () {
      final engine = MusicVisualizerEngine(detail: 1, random: Random(9), interval: 0);
      final pulse = MusicPulse(2);
      final scenes = <int>{};
      var t = 0.0;
      for (var round = 0; round < 12; round++) {
        scenes.add(engine.scene);
        for (var f = 0; f < 10; f++) {
          t += 0.5;
          final lines = engine.frame(size, t, pulse.at(t, playing: true));
          expect(lines.core, isNotEmpty, reason: 'scene ${engine.scene} at $t');
          expect(lines.glow, isNotEmpty);
          for (final v in [...lines.glow, ...lines.core]) {
            v.dispose();
          }
        }
        engine.nextScene();
      }
      expect(scenes, hasLength(MusicVisualizerEngine.sceneCount));
    });
  });
}
