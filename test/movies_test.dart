import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/movie_disc_image.dart';
import 'package:home_system/data/services/movie_dvd.dart';
import 'package:home_system/data/services/movie_library.dart';
import 'package:home_system/data/services/movie_resume_store.dart';
import 'package:home_system/data/services/movie_stream_server.dart';
import 'package:home_system/data/services/nas_service.dart';
import 'package:home_system/features/movies/movie_player.dart';
import 'package:home_system/features/movies/movie_player_screen.dart';

void main() {
  group('disc image', () {
    test('ISO 9660: the VIDEO_TS files and where they lie', () async {
      final image = _iso9660Image();
      final files = await readDiscFolder(_reader(image), 'VIDEO_TS');
      expect(files, isNotNull);
      final byName = {for (final f in files!) f.name: f};
      expect(byName.keys, containsAll(['VIDEO_TS.IFO', 'VTS_01_0.IFO', 'VTS_01_0.VOB', 'VTS_01_1.VOB', 'VTS_01_2.VOB', 'VTS_02_1.VOB']));
      expect(byName['VTS_01_1.VOB']!.size, 4096);
      expect(byName['VTS_01_1.VOB']!.extents, [(offset: 25 * 2048, length: 4096)]);
      expect(image[25 * 2048], 0xA1); // the fixture's content marker
      expect(byName['VTS_01_2.VOB']!.extents.single.offset, 27 * 2048);
    });

    test('UDF only: file entries, extended file entries, split extents', () async {
      final image = _udfImage();
      final files = await readDiscFolder(_reader(image), 'video_ts');
      expect(files, isNotNull);
      final byName = {for (final f in files!) f.name: f};
      expect(byName.keys.toSet(), {'VTS_01_0.IFO', 'VTS_01_1.VOB', 'VTS_02_1.VOB'});
      expect(byName['VTS_01_1.VOB']!.size, 3 * 2048);
      // Two pieces: partition start 300 + blocks 20..21 and 30.
      expect(byName['VTS_01_1.VOB']!.extents, [
        (offset: 320 * 2048, length: 2 * 2048),
        (offset: 330 * 2048, length: 2048),
      ]);
      expect(byName['VTS_02_1.VOB']!.extents, [(offset: 340 * 2048, length: 2048)]);
    });

    test('no disc image', () async {
      expect(await readDiscFolder(_reader(Uint8List(300 * 2048)), 'VIDEO_TS'), isNull);
      expect(await readDiscFolder(_reader(Uint8List(100)), 'VIDEO_TS'), isNull);
    });
  });

  group('DVD', () {
    test('main title: the biggest title set, parts in order, no menu', () {
      final vobs = [
        for (final (name, size) in [
          ('VTS_01_0.VOB', 900),
          ('VTS_01_1.VOB', 100),
          ('VTS_02_0.VOB', 10),
          ('VTS_02_2.VOB', 1000),
          ('VTS_02_1.VOB', 1000),
          ('VIDEO_TS.VOB', 5000),
        ])
          if (parseVobName(name) case final v?) DvdVob(titleSet: v.titleSet, part: v.part, size: size, file: name),
      ];
      expect(pickMainTitle(vobs).map((v) => v.file), ['VTS_02_1.VOB', 'VTS_02_2.VOB']);
      expect(pickMainTitle(<DvdVob<String>>[]), isEmpty);
      expect(parseVobName('vts_03_4.vob'), (titleSet: 3, part: 4));
      expect(parseVobName('VTS_03_4.IFO'), isNull);
      expect(ifoNameOf(3), 'VTS_03_0.IFO');
    });

    test('IFO: sound tracks, length and chapters of the longest chain', () {
      final info = parseVtsIfo(_ifo())!;
      expect(info.duration, const Duration(hours: 1, minutes: 30));
      expect(info.audio.map((a) => (a.id, a.language, a.channels, a.extension)), [
        ('bd80', 'de', 6, 1),
        ('c0', 'en', 2, 0),
        ('bd81', 'en', 6, 3),
      ]);
      expect(info.chapters, [Duration.zero, const Duration(minutes: 10), const Duration(minutes: 60)]);
      expect(parseVtsIfo(Uint8List(4096)), isNull);
    });

    test('pack filter: one sound track, AC3 header stripped for ExoPlayer', () {
      final pack = _dvdPack();
      final original = Uint8List.fromList(pack);
      DvdPackFilter(keep: const DvdAudioStream(coding: DvdAudioCoding.ac3, number: 0), stripHeader: true).apply(pack);
      expect(pack.length, discPack);
      final ids = <int, int>{};
      forEachPes(pack, (p, pos, id, end) => ids[pos] = id);
      final originalIds = <int, int>{};
      forEachPes(original, (p, pos, id, end) => originalIds[pos] = id);
      expect(ids.keys, originalIds.keys); // every packet where it was
      final positions = ids.keys.toList();
      expect(ids[positions[0]], 0xE0); // video
      expect(ids[positions[1]], 0xBD); // the AC3 kept ...
      final ac3 = positions[1];
      expect(pack[ac3 + 8], 5 + 4); // ... its DVD header now stuffing
      expect(pack.sublist(ac3 + 9 + 5, ac3 + 9 + 9), [0xFF, 0xFF, 0xFF, 0xFF]);
      expect(pack.sublist(ac3 + 18, ac3 + 20), [0x0B, 0x77]);
      expect(ids[positions[2]], 0xBE); // the other AC3
      expect(ids[positions[3]], 0xBE); // subtitles
      expect(ids[positions[4]], 0xBE); // MPEG audio
      expect(ids[positions[5]], 0xBE); // padding stays padding

      // libmpv: the header stays, MPEG audio kept.
      final mpv = Uint8List.fromList(original);
      DvdPackFilter(keep: const DvdAudioStream(coding: DvdAudioCoding.mpeg, number: 0)).apply(mpv);
      final mpvIds = <int>[];
      forEachPes(mpv, (p, pos, id, end) => mpvIds.add(id));
      expect(mpvIds, [0xE0, 0xBE, 0xBE, 0xBE, 0xC0, 0xBE]);
      final kept = Uint8List.fromList(original);
      DvdPackFilter(keep: const DvdAudioStream(coding: DvdAudioCoding.ac3, number: 1)).apply(kept);
      expect(kept[ac3 + 8], 5);
      expect(kept[ac3 + 3], 0xBE);
    });

    test('sound tracks found in the stream; DVD stream recognised', () {
      final bytes = Uint8List.fromList([..._dvdPack(), ..._dvdPack()]);
      expect(scanDvdAudio(bytes).map((a) => a.id), ['bd80', 'bd81', 'c0']);
      expect(looksLikeDvdStream(bytes), isTrue);
      expect(looksLikeDvdStream(Uint8List(5000)), isFalse);
    });
  });

  group('stream server', () {
    final data = Uint8List.fromList(List.generate(10000, (i) => i * 13 & 0xFF));

    test('range header', () {
      expect(parseRangeHeader(null, 100), isNull);
      expect(parseRangeHeader('bytes=0-', 100), (start: 0, end: 100));
      expect(parseRangeHeader('bytes=10-19', 100), (start: 10, end: 20));
      expect(parseRangeHeader('bytes=90-200', 100), (start: 90, end: 100));
      expect(parseRangeHeader('bytes=-30', 100), (start: 70, end: 100));
      expect(parseRangeHeader('bytes=-300', 100), (start: 0, end: 100));
      expect(parseRangeHeader('bytes=100-', 100)!.start, 100); // 416
      expect(parseRangeHeader('bytes=5-1', 100)!.start, 100);
      expect(parseRangeHeader('bytes=1-2, 5-6', 100), (start: 1, end: 3));
      expect(parseRangeHeader('items=1-2', 100), isNull);
    });

    test('serves ranges (206), the whole file (200), HEAD and 416', () async {
      final source = _MemorySource(data);
      final server = await MovieStreamServer.start(source, name: 'movie.mpg', mime: 'video/mp2p');
      final client = HttpClient();
      try {
        Future<(int, Map<String, String>, List<int>)> get(String? range, {String method = 'GET'}) async {
          final request = await client.openUrl(method, server.uri);
          if (range != null) request.headers.set('range', range);
          final response = await request.close();
          final body = [for (final c in await response.toList()) ...c];
          final headers = <String, String>{};
          response.headers.forEach((k, v) => headers[k] = v.join(','));
          return (response.statusCode, headers, body);
        }

        var (status, headers, body) = await get('bytes=100-199');
        expect(status, 206);
        expect(headers['content-range'], 'bytes 100-199/10000');
        expect(headers['content-length'], '100');
        expect(headers['accept-ranges'], 'bytes');
        expect(headers['content-type'], 'video/mp2p');
        expect(body, data.sublist(100, 200));
        (status, headers, body) = await get(null);
        expect((status, body.length), (200, 10000));
        (status, headers, body) = await get('bytes=-10');
        expect(body, data.sublist(9990));
        (status, headers, body) = await get('bytes=20000-');
        expect((status, headers['content-range']), (416, 'bytes */10000'));
        (status, headers, body) = await get('bytes=0-', method: 'HEAD');
        expect((status, headers['content-length'], body.length), (206, '10000', 0));
        // Two at once.
        final both = await Future.wait([get('bytes=0-4999'), get('bytes=5000-')]);
        expect([...both[0].$3, ...both[1].$3], data);
      } finally {
        client.close(force: true);
        await server.close();
      }
    });

    test('a player that goes away stops the NAS transfer', () async {
      final source = _MemorySource(Uint8List(8 << 20), slow: true);
      final server = await MovieStreamServer.start(source, name: 'movie.mkv', mime: 'video/x-matroska');
      final client = HttpClient();
      try {
        final request = await client.getUrl(server.uri);
        final response = await request.close();
        await response.first;
        client.close(force: true);
        for (var i = 0; i < 50 && source.cancelled == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(source.cancelled, 1);
      } finally {
        await server.close();
      }
    });

    test('segments joined', () async {
      final client = _MemoryNas({'/a.iso': data});
      final source = NasSegmentsSource(client, const [
        NasSegment('/a.iso', 1000, 500),
        NasSegment('/a.iso', 4000, 1000),
        NasSegment('/a.iso', 0, 10),
      ]);
      expect(source.length, 1510);
      expect(await _all(source.read(0, 1510)), [...data.sublist(1000, 1500), ...data.sublist(4000, 5000), ...data.sublist(0, 10)]);
      expect(await _all(source.read(450, 520)), [...data.sublist(1450, 1500), ...data.sublist(4000, 4020)]);
      expect(await _all(source.read(1505, 1510)), data.sublist(5, 10));
    });

    test('packets mapped: M2TS to TS, DVD packs rewritten in place', () async {
      // M2TS: 4 bytes time code + 188.
      final m2ts = BytesBuilder();
      final ts = BytesBuilder();
      for (var i = 0; i < 20; i++) {
        final packet = [0x47, ...List.generate(187, (j) => (i + j) & 0xFF)];
        m2ts.add([1, 2, 3, i, ...packet]);
        ts.add(packet);
      }
      final m2tsBytes = m2ts.takeBytes();
      final tsBytes = ts.takeBytes();
      expect(looksLikeM2ts(m2tsBytes), isTrue);
      expect(looksLikeM2ts(tsBytes), isFalse);
      final mapped = PacketMappedSource(_MemorySource(m2tsBytes), inSize: 192, outSize: 188, map: m2tsToTs);
      expect(mapped.length, tsBytes.length);
      expect(await _all(mapped.read(0, mapped.length)), tsBytes);
      expect(await _all(mapped.read(300, 1000)), tsBytes.sublist(300, 1000));
      expect(await _all(mapped.read(187, 189)), tsBytes.sublist(187, 189));

      // DVD: same size; a range from the middle of a pack.
      final packs = Uint8List.fromList([..._dvdPack(), ..._dvdPack(), 1, 2, 3]);
      final filter = DvdPackFilter(keep: const DvdAudioStream(coding: DvdAudioCoding.ac3, number: 0), stripHeader: true);
      final expected = Uint8List.fromList(packs);
      filter.apply(Uint8List.sublistView(expected, 0, discPack));
      filter.apply(Uint8List.sublistView(expected, discPack, 2 * discPack));
      final dvd = PacketMappedSource(_MemorySource(packs, chunk: 700), inSize: discPack, outSize: discPack, map: (p) {
        filter.apply(p);
        return p;
      });
      expect(dvd.length, packs.length);
      expect(await _all(dvd.read(0, dvd.length)), expected);
      expect(await _all(dvd.read(1000, 3000)), expected.sublist(1000, 3000));
      expect(await _all(dvd.read(4095, 4099)), expected.sublist(4095, 4099));
    });
  });

  group('player engine', () {
    test('the PC always plays with libmpv', () {
      for (final ext in ['mkv', 'mp4', 'wmv', 'iso', '']) {
        expect(firstMovieEngine(android: false, extension: ext), MovieEngine.mpv);
      }
    });

    test('Android: ExoPlayer first, ExoPlayer-unfriendly formats straight to libmpv', () {
      // 3GP: ExoPlayer first - libmpv if the box has no H.263 / AMR decoder.
      for (final ext in ['mp4', 'mkv', 'avi', 'xvid', 'ts', 'm2ts', 'mpg', 'vob', 'iso', 'mov', 'webm', '3gp', '3g2', '']) {
        expect(firstMovieEngine(android: true, extension: ext), MovieEngine.exoPlayer, reason: ext);
      }
      for (final ext in ['rm', 'RMVB', 'ra', 'wmv', 'WMV', 'asf', 'flv', 'f4v', 'divx', 'ogm', 'ogv', 'm1v', 'm2v', 'dv', 'wtv']) {
        expect(firstMovieEngine(android: true, extension: ext), MovieEngine.mpv, reason: ext);
      }
    });

    test('Android: a DVD with only DTS / LPCM sound goes to libmpv', () {
      expect(firstMovieEngine(android: true, extension: 'iso', exoPlayableAudio: false), MovieEngine.mpv);
      expect(firstMovieEngine(android: true, extension: 'iso'), MovieEngine.exoPlayer);
    });

    test('what ExoPlayer cannot play goes on with libmpv - libmpv has nothing after it', () {
      expect(movieFallsBackToMpv(MovieEngine.exoPlayer), isTrue);
      expect(movieFallsBackToMpv(MovieEngine.mpv), isFalse);
    });
  });

  group('library', () {
    test('titles', () {
      expect(movieTitle('Der_Pate.1972.mkv'), 'Der Pate 1972');
      expect(movieTitle('Heat (1995).mp4'), 'Heat (1995)');
      expect(movieTitle('Dr. No.avi'), 'Dr. No');
      expect(movieTitle('Urlaub  2025', isFile: false), 'Urlaub 2025');
      expect(movieTitle('_'), '_');
      expect(isMovieFileName('clip.MTS'), isTrue);
      expect(isMovieFileName('clip.3gp'), isTrue);
      expect(isMovieFileName('notes.txt'), isFalse);
      // The old formats VLC plays (libmpv on Android).
      for (final name in ['a.divx', 'a.XVID', 'a.asf', 'a.flv', 'a.f4v', 'a.ogm', 'a.ogv', 'a.m2v', 'a.qt', 'a.3g2']) {
        expect(isMovieFileName(name), isTrue, reason: name);
      }
      // RealPlayer downloads.
      for (final name in ['a.rm', 'a.RMVB', 'a.ra']) {
        expect(isMovieFileName(name), isTrue, reason: name);
      }
      // A .ram is only a link to a stream.
      expect(isMovieFileName('a.ram'), isFalse);
      expect(movieMimeType('flv'), 'video/x-flv');
      expect(movieMimeType('divx'), 'video/x-msvideo');
    });

    NasEntry file(String folder, String name, [int size = 1]) =>
        NasEntry(name: name, path: joinNasPath(folder, name), isDirectory: false, size: size);
    NasEntry dir(String folder, String name) => NasEntry(name: name, path: joinNasPath(folder, name), isDirectory: true);

    test('a page: folders, films with pictures and subtitles, DVD folder', () {
      const f = '/Filme';
      final page = buildMoviePage(f, [
        dir(f, 'Serien'),
        dir(f, '@eaDir'),
        file(f, 'Heat (1995).mkv', 5000),
        file(f, 'Heat (1995).jpg'),
        file(f, 'Heat (1995).en.srt'),
        file(f, 'Heat (1995).de.srt'),
        file(f, 'Alien.iso'),
        file(f, 'folder.jpg'),
        file(f, 'readme.txt'),
      ]);
      expect(page.map((e) => (e.title, e.movie?.kind)), [
        ('Serien', null),
        ('Heat (1995)', MovieKind.file),
        ('Alien', MovieKind.iso),
      ]);
      expect(page[1].poster, '/Filme/Heat (1995).jpg');
      expect(page[1].movie!.subtitles, ['/Filme/Heat (1995).de.srt', '/Filme/Heat (1995).en.srt']);
      expect(page[1].movie!.size, 5000);
      expect(page[2].poster, isNull); // not the only film: no folder picture

      final dvdPage = buildMoviePage('/Filme/Matrix', [
        dir('/Filme/Matrix', 'VIDEO_TS'),
        dir('/Filme/Matrix', 'AUDIO_TS'),
        file('/Filme/Matrix', 'cover.png'),
      ]);
      expect(dvdPage.single.movie!.kind, MovieKind.dvdFolder);
      expect(dvdPage.single.movie!.path, '/Filme/Matrix');
      expect(dvdPage.single.title, 'Matrix');
      expect(dvdPage.single.poster, '/Filme/Matrix/cover.png');

      final videoTs = buildMoviePage('/Filme/Matrix/VIDEO_TS', [
        file('/Filme/Matrix/VIDEO_TS', 'VTS_01_1.VOB'),
        file('/Filme/Matrix/VIDEO_TS', 'VTS_01_0.IFO'),
      ]);
      expect(videoTs.map((e) => (e.title, e.movie?.kind)), [('Matrix', MovieKind.dvdFolder)]);
    });

    test('folder peek: film folders play, others open', () {
      final heat = dir('/Filme', 'Heat (1995)');
      final peek = peekMovieFolder(heat, [
        file(heat.path, 'heat.1995.mkv'),
        file(heat.path, 'poster.jpg'),
        file(heat.path, 'heat.1995.srt'),
      ]);
      expect(peek.movie!.title, 'Heat (1995)');
      expect(peek.movie!.path, '/Filme/Heat (1995)/heat.1995.mkv');
      expect(peek.movie!.subtitles, ['/Filme/Heat (1995)/heat.1995.srt']);
      expect(peek.poster, '/Filme/Heat (1995)/poster.jpg');
      final series = dir('/Filme', 'Serie');
      final seriesPeek = peekMovieFolder(series, [file(series.path, 'a.mkv'), file(series.path, 'b.mkv'), file(series.path, 'Folder.JPG')]);
      expect(seriesPeek.movie, isNull);
      expect(seriesPeek.poster, '/Filme/Serie/Folder.JPG');
      final dvd = dir('/Filme', 'Matrix');
      expect(peekMovieFolder(dvd, [dir(dvd.path, 'VIDEO_TS')]).movie!.kind, MovieKind.dvdFolder);
    });
  });

  test('player: times, seek steps, chapter jumps', () {
    expect(formatMovieTime(const Duration(hours: 1, minutes: 12, seconds: 30)), '1:12:30');
    expect(formatMovieTime(const Duration(minutes: 3, seconds: 5)), '3:05');
    expect(formatMovieTime(const Duration(seconds: -30)), '-0:30');
    expect([for (var i = 0; i < 12; i++) movieSeekStep(i).inSeconds], [10, 10, 10, 30, 30, 30, 60, 60, 60, 60, 180, 180]);
    const m = Duration(minutes: 1);
    expect(movieJumpTarget(m * 10, 1, const []), m * 15);
    expect(movieJumpTarget(m * 10, -1, const []), m * 5);
    final chapters = [Duration.zero, m * 10, m * 25];
    expect(movieJumpTarget(m * 12, 1, chapters), m * 25);
    expect(movieJumpTarget(m * 12, -1, chapters), m * 10); // start of this one
    expect(movieJumpTarget(m * 10 + const Duration(seconds: 2), -1, chapters), Duration.zero);
    expect(movieJumpTarget(m * 30, 1, chapters), m * 30); // no chapter after the last
  });

  test('resume positions', () async {
    final temp = await Directory.systemTemp.createTemp('movie_resume');
    try {
      final path = File('${temp.path}/resume.json');
      var store = MovieResumeStore(file: () async => path);
      const hour = Duration(hours: 1);
      expect(await store.position('/a.mkv'), isNull);
      await store.save('/a.mkv', const Duration(minutes: 30), hour * 2);
      await store.save('/b.mkv', const Duration(seconds: 20), hour * 2); // too early
      await store.save('/c.mkv', const Duration(minutes: 118), hour * 2); // watched
      store = MovieResumeStore(file: () async => path);
      expect(await store.position('/a.mkv'), const Duration(minutes: 30));
      expect(await store.position('/b.mkv'), isNull);
      expect(await store.position('/c.mkv'), isNull);
      await store.forget('/a.mkv');
      expect(await MovieResumeStore(file: () async => path).position('/a.mkv'), isNull);
    } finally {
      await temp.delete(recursive: true);
    }
  });
}

Future<List<int>> _all(Stream<List<int>> s) async => [for (final c in await s.toList()) ...c];

DiscRead _reader(Uint8List image) => (offset, length) async {
      if (offset >= image.length) return Uint8List(0);
      return Uint8List.sublistView(image, offset, min(image.length, offset + length));
    };

class _MemorySource implements MovieByteSource {
  _MemorySource(this.data, {this.slow = false, this.chunk = 1000});

  final Uint8List data;
  final bool slow;
  final int chunk;
  int cancelled = 0;

  @override
  int get length => data.length;

  @override
  Stream<List<int>> read(int start, int end) {
    late StreamController<List<int>> controller;
    var position = start;
    var stop = false;
    Future<void> pump() async {
      while (!stop && position < end) {
        if (controller.isPaused) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          continue;
        }
        final next = min(end, position + chunk);
        controller.add(Uint8List.fromList(data.sublist(position, next)));
        position = next;
        await Future<void>.delayed(slow ? const Duration(milliseconds: 5) : Duration.zero);
      }
      if (!stop) await controller.close();
    }

    controller = StreamController<List<int>>(
      onListen: pump,
      onCancel: () {
        stop = true;
        cancelled++;
      },
    );
    return controller.stream;
  }
}

class _MemoryNas implements NasClient {
  _MemoryNas(this.files);

  final Map<String, Uint8List> files;

  @override
  Stream<List<int>> openRead(String path, {int offset = 0, int? length}) async* {
    final f = files[path]!;
    final end = length == null ? f.length : min(f.length, offset + length);
    for (var at = offset; at < end; at += 300) {
      yield f.sublist(at, min(end, at + 300));
    }
  }

  @override
  Future<int?> size(String path) async => files[path]?.length;

  @override
  Future<Uint8List> read(String path, {int? maxBytes}) async => files[path]!;

  @override
  Future<List<NasEntry>> list(String folder) async => const [];

  @override
  Future<void> test() async {}

  @override
  Future<void> write(String path, List<int> bytes) async {}

  @override
  Future<void> delete(String path) async {}

  @override
  void close() {}
}

// --- fixtures ---

void _le16(Uint8List b, int o, int v) => b
  ..[o] = v & 0xFF
  ..[o + 1] = v >> 8 & 0xFF;
void _le32(Uint8List b, int o, int v) {
  for (var i = 0; i < 4; i++) {
    b[o + i] = v >> (8 * i) & 0xFF;
  }
}

void _be16(Uint8List b, int o, int v) => b
  ..[o] = v >> 8 & 0xFF
  ..[o + 1] = v & 0xFF;
void _be32(Uint8List b, int o, int v) {
  for (var i = 0; i < 4; i++) {
    b[o + i] = v >> (8 * (3 - i)) & 0xFF;
  }
}

/// An ISO 9660 image: PVD at 16, root at 20, VIDEO_TS at 21, VOB data
/// from 25 on.
Uint8List _iso9660Image() {
  final image = Uint8List(40 * 2048);
  Uint8List record(String name, int extent, int size, {bool dir = false}) {
    final n = name == '.' ? [0] : (name == '..' ? [1] : latin1.encode(name));
    var length = 33 + n.length;
    if (length.isOdd) length++;
    final r = Uint8List(length);
    r[0] = length;
    _le32(r, 2, extent);
    _be32(r, 6, extent);
    _le32(r, 10, size);
    _be32(r, 14, size);
    r[25] = dir ? 2 : 0;
    r[32] = n.length;
    r.setAll(33, n);
    return r;
  }

  void directory(int sector, List<Uint8List> records) {
    var at = sector * 2048;
    for (final r in records) {
      image.setAll(at, r);
      at += r.length;
    }
  }

  // Primary volume descriptor, terminator.
  final pvd = 16 * 2048;
  image[pvd] = 1;
  image.setAll(pvd + 1, ascii.encode('CD001'));
  image[pvd + 6] = 1;
  _le16(image, pvd + 128, 2048);
  image.setAll(pvd + 156, record('.', 20, 2048, dir: true));
  image[17 * 2048] = 255;
  image.setAll(17 * 2048 + 1, ascii.encode('CD001'));
  directory(20, [
    record('.', 20, 2048, dir: true),
    record('..', 20, 2048, dir: true),
    record('AUDIO_TS', 22, 2048, dir: true),
    record('VIDEO_TS', 21, 2048, dir: true),
  ]);
  directory(21, [
    record('.', 21, 2048, dir: true),
    record('..', 20, 2048, dir: true),
    record('VIDEO_TS.IFO;1', 23, 2048),
    record('VTS_01_0.IFO;1', 24, 2048),
    record('VTS_01_0.VOB;1', 24, 0),
    record('VTS_01_1.VOB;1', 25, 4096),
    record('VTS_01_2.VOB;1', 27, 2048),
    record('VTS_02_1.VOB;1', 28, 2048),
  ]);
  image[25 * 2048] = 0xA1;
  return image;
}

/// A UDF-only image: anchor at 256, volume descriptors at 257-259,
/// partition from 300 on.
Uint8List _udfImage() {
  final image = Uint8List(350 * 2048);
  const partition = 300;
  int sector(int lbn) => (partition + lbn) * 2048;

  // Anchor: the main volume descriptor sequence at 257, 3 sectors.
  _le16(image, 256 * 2048, 2);
  _le32(image, 256 * 2048 + 16, 3 * 2048);
  _le32(image, 256 * 2048 + 20, 257);
  // Partition descriptor, logical volume descriptor (file set at block 0),
  // terminator.
  _le16(image, 257 * 2048, 5);
  _le32(image, 257 * 2048 + 188, partition);
  _le16(image, 258 * 2048, 6);
  _le32(image, 258 * 2048 + 248, 2048);
  _le32(image, 258 * 2048 + 252, 0);
  _le16(image, 259 * 2048, 8);
  // File set descriptor: root ICB at block 1.
  _le16(image, sector(0), 256);
  _le32(image, sector(0) + 404, 1);

  void fileEntry(int lbn, int size, List<(int, int)> extents, {bool extended = false}) {
    final at = sector(lbn);
    _le16(image, at, extended ? 266 : 261);
    _le16(image, at + 34, 0); // short_ad
    _le32(image, at + 56, size);
    final (eaAt, adAt, base) = extended ? (208, 212, 216) : (168, 172, 176);
    _le32(image, at + eaAt, 0);
    _le32(image, at + adAt, extents.length * 8);
    for (final (i, (length, block)) in extents.indexed) {
      _le32(image, at + base + i * 8, length);
      _le32(image, at + base + i * 8 + 4, block);
    }
  }

  Uint8List fid(String name, int icb, {bool dir = false, bool parent = false}) {
    final n = parent ? <int>[] : [8, ...latin1.encode(name)];
    final length = (38 + n.length + 3) & ~3;
    final f = Uint8List(length);
    _le16(f, 0, 257);
    f[18] = (dir ? 2 : 0) | (parent ? 8 : 0);
    f[19] = n.length;
    _le32(f, 20, 2048);
    _le32(f, 24, icb);
    f.setAll(38, n);
    return f;
  }

  int directory(int lbn, List<Uint8List> fids) {
    var at = sector(lbn);
    for (final f in fids) {
      image.setAll(at, f);
      at += f.length;
    }
    return at - sector(lbn);
  }

  final rootSize = directory(2, [fid('', 1, dir: true, parent: true), fid('VIDEO_TS', 3, dir: true)]);
  fileEntry(1, rootSize, [(rootSize, 2)]);
  final videoTsSize = directory(4, [
    fid('', 1, dir: true, parent: true),
    fid('VTS_01_0.IFO', 5),
    fid('VTS_01_1.VOB', 6),
    fid('VTS_02_1.VOB', 7),
  ]);
  fileEntry(3, videoTsSize, [(videoTsSize, 4)], extended: true);
  fileEntry(5, 2048, [(2048, 10)]);
  fileEntry(6, 3 * 2048, [(2 * 2048, 20), (2048, 30)]);
  fileEntry(7, 2048, [(2048, 40)], extended: true);
  return image;
}

/// A title set IFO: 3 sound tracks; two program chains, the second (1:30)
/// with 3 chapters over 4 cells.
Uint8List _ifo() {
  final b = Uint8List(2 * 2048);
  b.setAll(0, ascii.encode('DVDVIDEO-VTS'));
  _be32(b, 0xCC, 1); // PGCIT in sector 1
  _be16(b, 0x202, 3);
  void audio(int i, int coding, int channels, String language, int extension) {
    final o = 0x204 + i * 8;
    b[o] = coding << 5 | 1 << 2;
    b[o + 1] = channels - 1;
    b.setAll(o + 2, ascii.encode(language));
    b[o + 5] = extension;
  }

  audio(0, 0, 6, 'de', 1);
  audio(1, 2, 2, 'en', 0);
  audio(2, 0, 6, 'en', 3);
  const pgcit = 2048;
  _be16(b, pgcit, 2);
  _be32(b, pgcit + 8 + 4, 0x100);
  _be32(b, pgcit + 16 + 4, 0x300);
  void time(int o, int h, int m, int s) {
    int bcd(int v) => (v ~/ 10) << 4 | v % 10;
    b
      ..[o] = bcd(h)
      ..[o + 1] = bcd(m)
      ..[o + 2] = bcd(s)
      ..[o + 3] = 0x40;
  }

  time(pgcit + 0x100 + 4, 0, 0, 10);
  const pgc = pgcit + 0x300;
  b[pgc + 2] = 3;
  b[pgc + 3] = 4;
  time(pgc + 4, 1, 30, 0);
  _be16(b, pgc + 0x0C, 0x8000);
  _be16(b, pgc + 0x0E, 0x8000);
  _be16(b, pgc + 0x10, 0x8100);
  _be16(b, pgc + 0xE6, 0xF0);
  _be16(b, pgc + 0xE8, 0x100);
  b.setAll(pgc + 0xF0, [1, 2, 4]);
  for (final (i, minutes) in [10, 20, 30, 30].indexed) {
    time(pgc + 0x100 + i * 24 + 4, 0, minutes, 0);
  }
  return b;
}

/// One DVD pack: video, AC3 (0x80), AC3 (0x81), subtitles (0x20), MPEG
/// audio, padding.
Uint8List _dvdPack() {
  final pack = BytesBuilder();
  pack.add([0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xC3, 0xF8]);
  List<int> pes(int id, List<int> payload, {bool header = true}) {
    final body = [if (header) ...[0x81, 0x80, 5, 0x21, 0, 1, 0, 1], ...payload];
    return [0, 0, 1, id, body.length >> 8, body.length & 0xFF, ...body];
  }

  pack.add(pes(0xE0, List.filled(500, 0x11)));
  pack.add(pes(0xBD, [0x80, 1, 0, 1, 0x0B, 0x77, ...List.filled(300, 0x22)]));
  pack.add(pes(0xBD, [0x81, 1, 0, 1, 0x0B, 0x77, ...List.filled(300, 0x33)]));
  pack.add(pes(0xBD, [0x20, ...List.filled(100, 0x44)]));
  pack.add(pes(0xC0, [0xFF, 0xFD, ...List.filled(200, 0x55)]));
  final padding = 2048 - pack.length - 6;
  pack.add([0, 0, 1, 0xBE, padding >> 8, padding & 0xFF, ...List.filled(padding, 0xFF)]);
  final bytes = pack.takeBytes();
  assert(bytes.length == 2048);
  return bytes;
}
