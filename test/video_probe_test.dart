import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/video_probe.dart';

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

List<int> _u32le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

List<int> _box(String type, List<int> body) => [..._u32(8 + body.length), ...type.codeUnits, ...body];

/// "mvhd" version 0: [timescale] units per second, [duration] of them.
List<int> _mvhd(int timescale, int duration) =>
    _box('mvhd', [0, 0, 0, 0, ..._u32(0), ..._u32(0), ..._u32(timescale), ..._u32(duration), ...List.filled(80, 0)]);

List<int> get _ftyp => _box('ftyp', [...'isom'.codeUnits, 0, 0, 2, 0, ...'isommp41'.codeUnits]);

void main() {
  group('MP4 / MOV', () {
    test('index at the start', () async {
      final file = Uint8List.fromList([
        ..._ftyp,
        ..._box('moov', [..._mvhd(1000, 65000), ..._box('trak', List.filled(20, 0))]),
        ..._box('mdat', List.filled(100, 0)),
      ]);
      expect(await videoDuration('clip.mp4', file, size: file.length), const Duration(seconds: 65));
    });

    test('index after a big "mdat": reached with small reads', () async {
      const mdatSize = 50 * 1000 * 1000;
      final head = [..._ftyp, ..._u32(mdatSize), ...'mdat'.codeUnits];
      final moovAt = _ftyp.length + mdatSize;
      final moov = _box('moov', _mvhd(600, 600 * 90));
      final reads = <int>[];
      Future<Uint8List> read(int offset, int length) async {
        reads.add(offset);
        if (offset < moovAt) return Uint8List(0);
        final from = offset - moovAt;
        final end = from + length > moov.length ? moov.length : from + length;
        return Uint8List.fromList(moov.sublist(from, end));
      }

      final d = await videoDuration('VID.MOV', Uint8List.fromList(head), size: moovAt + moov.length, read: read);
      expect(d, const Duration(seconds: 90));
      expect(reads, everyElement(greaterThanOrEqualTo(moovAt)));
    });

    test('64-bit "mvhd" (version 1)', () async {
      final mvhd = _box('mvhd', [
        1, 0, 0, 0, //
        ..._u32(0), ..._u32(0), ..._u32(0), ..._u32(0),
        ..._u32(90000),
        ..._u32(0), ..._u32(90000 * 3),
        ...List.filled(80, 0),
      ]);
      final file = Uint8List.fromList([..._ftyp, ..._box('moov', mvhd)]);
      expect(await videoDuration('a.m4v', file, size: file.length), const Duration(seconds: 3));
    });

    test('not ISO media, cut off, no reader: unknown', () async {
      expect(await videoDuration('x.mp4', Uint8List.fromList(List.filled(64, 7))), isNull);
      final head = [..._ftyp, ..._u32(1 << 30), ...'mdat'.codeUnits];
      expect(await videoDuration('x.mp4', Uint8List.fromList(head), size: 2 << 30), isNull);
      expect(await videoDuration('x.mp4', Uint8List(0)), isNull);
    });
  });

  test('AVI: frames x time per frame', () async {
    final avih = [
      ..._u32le(40000), // 25 frames per second
      ..._u32le(0), ..._u32le(0), ..._u32le(0),
      ..._u32le(250), // frames
      ...List.filled(36, 0),
    ];
    final hdrl = [...'hdrl'.codeUnits, ...'avih'.codeUnits, ..._u32le(avih.length), ...avih];
    final file = Uint8List.fromList([
      ...'RIFF'.codeUnits, ..._u32le(10000), ...'AVI '.codeUnits,
      ...'LIST'.codeUnits, ..._u32le(hdrl.length), ...hdrl,
      ...List.filled(64, 0),
    ]);
    expect(await videoDuration('alt.avi', file), const Duration(seconds: 10));
  });

  test('Matroska / WebM: the segment info', () async {
    final duration = ByteData(8)..setFloat64(0, 12345.0);
    final info = [
      0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40, // TimestampScale 1 000 000
      0x44, 0x89, 0x88, ...duration.buffer.asUint8List(), // Duration
    ];
    final file = Uint8List.fromList([
      0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x42, 0x86, 0x81, 0x01, // EBML header
      0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // Segment, size unknown
      0x11, 0x4D, 0x9B, 0x74, 0x82, 0xEC, 0x80, // SeekHead (a Void inside)
      0xEC, 0x83, 0, 0, 0, // Void
      0x15, 0x49, 0xA9, 0x66, 0x80 | info.length, ...info, // Info
      0x1F, 0x43, 0xB6, 0x75, 0x80, // Cluster
    ]);
    expect(await videoDuration('a.mkv', file), const Duration(milliseconds: 12345));
    expect(await videoDuration('a.webm', Uint8List.fromList([0x1A, 0x45, 0xDF])), isNull);
  });

  test('other formats: unknown', () async {
    expect(await videoDuration('a.wmv', Uint8List(100)), isNull);
  });
}
