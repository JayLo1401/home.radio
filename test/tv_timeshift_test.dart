import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/tv_timeshift_buffer.dart';
import 'package:home_system/features/tv/tv_timeshift.dart';

/// A backend in memory that can be made slow or broken.
class _FakeBackend implements TimeshiftBackend {
  final files = <int, Uint8List>{};
  final deleted = <int>[];
  bool fail = false;
  Completer<void>? hold;
  bool closed = false;

  @override
  Future<void> open() async {}

  @override
  Future<void> write(int start, Uint8List bytes) async {
    if (hold != null) await hold!.future;
    if (fail) throw const FileSystemException('full');
    files[start] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> read(int start, int offset, int length) async =>
      Uint8List.sublistView(files[start]!, offset, offset + length);

  @override
  Future<void> delete(int start) async {
    deleted.add(start);
    files.remove(start);
  }

  @override
  Future<void> close() async => closed = true;
}

Uint8List _bytes(int n, int from) => Uint8List.fromList([for (var i = 0; i < n; i++) (from + i) & 0xFF]);

void main() {
  var now = DateTime(2026, 11, 28, 20);
  DateTime clock() => now;

  setUp(() => now = DateTime(2026, 11, 28, 20));

  group('TimeshiftBuffer in memory', () {
    test('keeps the newest bytes up to its size', () async {
      final b = TimeshiftBuffer(memoryBytes: 4096, blockBytes: 1024, clock: clock);
      for (var i = 0; i < 10; i++) {
        b.append(_bytes(1000, i * 1000));
        now = now.add(const Duration(seconds: 1));
      }
      expect(b.head, 10000);
      expect(b.tail, greaterThan(5000));
      final chunk = (await b.read(9000, 500))!;
      expect(chunk.offset, 9000);
      expect(chunk.bytes.first, 9000 & 0xFF);
      // Gone: from the oldest part still there.
      final old = (await b.read(0, 10))!;
      expect(old.offset, b.tail);
      await b.close();
    });

    test('a read at the head waits for the next bytes', () async {
      final b = TimeshiftBuffer(memoryBytes: 1 << 20, blockBytes: 1024, clock: clock);
      b.append(_bytes(100, 0));
      final pending = b.read(100, 50);
      var done = false;
      unawaited(pending.then((_) => done = true));
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      b.append(_bytes(100, 100));
      final chunk = (await pending)!;
      expect(chunk.offset, 100);
      expect(chunk.bytes.length, 50);
      await b.close();
      expect(await b.read(0, 10), isNull);
    });

    test('finds a time and the time of a place', () async {
      final b = TimeshiftBuffer(memoryBytes: 1 << 20, blockBytes: 4096, clock: clock);
      final start = now;
      for (var i = 0; i < 60; i++) {
        b.append(_bytes(100, i * 100));
        now = now.add(const Duration(seconds: 1));
      }
      expect(b.offsetAt(start.add(const Duration(seconds: 30))), 3000);
      expect(b.offsetAt(start.add(const Duration(milliseconds: 30500))), 3000);
      expect(b.timeAt(3050), start.add(const Duration(seconds: 30)));
      expect(b.offsetAt(start.subtract(const Duration(minutes: 5))), 0);
      expect(b.oldestTime, start);
      expect(b.span, const Duration(seconds: 60));
      await b.close();
    });
  });

  group('TimeshiftBuffer with a backend', () {
    test('writes full segments, reads them back, deletes the old ones', () async {
      final backend = _FakeBackend();
      final b = TimeshiftBuffer(
        backend: backend,
        memoryBytes: 1 << 20,
        blockBytes: 1000,
        cacheBytes: 1000,
        maxAge: const Duration(seconds: 30),
        clock: clock,
      );
      for (var i = 0; i < 6; i++) {
        b.append(_bytes(1000, i * 1000));
        await Future<void>.delayed(Duration.zero);
        now = now.add(const Duration(seconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.files.keys, containsAll([0, 1000, 2000, 3000, 4000]));
      // Out of memory, back from the backend.
      final chunk = (await b.read(1500, 200))!;
      expect(chunk.offset, 1500);
      expect(chunk.bytes.first, 1500 & 0xFF);
      // Older than 30 s: deleted on the next bytes.
      now = now.add(const Duration(seconds: 40));
      b.append(_bytes(10, 6000));
      expect(backend.deleted, isNotEmpty);
      expect(b.tail, greaterThan(0));
      await b.close();
      expect(backend.closed, isTrue);
    });

    test('a failing backend: on in memory, with the reason', () async {
      final backend = _FakeBackend()..fail = true;
      final b = TimeshiftBuffer(backend: backend, memoryBytes: 1 << 20, blockBytes: 1000, clock: clock);
      b.append(_bytes(2500, 0));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(b.problem.value, TimeshiftProblem.writeFailed);
      expect(b.usesBackend, isFalse);
      expect((await b.read(0, 100))!.offset, 0);
      await b.close();
    });

    test('a slow backend: on in memory once too much waits', () async {
      final backend = _FakeBackend()..hold = Completer<void>();
      final b = TimeshiftBuffer(
        backend: backend,
        memoryBytes: 1 << 20,
        blockBytes: 1000,
        maxPendingBytes: 3000,
        clock: clock,
      );
      for (var i = 0; i < 6; i++) {
        b.append(_bytes(1000, i * 1000));
      }
      expect(b.problem.value, TimeshiftProblem.tooSlow);
      expect(b.usesBackend, isFalse);
      backend.hold!.complete();
      await b.close();
    });
  });

  test('the server plays the buffer from a place, packet-aligned', () async {
    final b = TimeshiftBuffer(memoryBytes: 1 << 20, blockBytes: 4096, clock: clock);
    // MPEG-TS packets: sync byte, then padding.
    final packets = <int>[];
    for (var p = 0; p < 20; p++) {
      packets.addAll([0x47, 0x00, p, 0x10, ...List.filled(184, 0xAA)]);
    }
    b.append(packets);
    final server = await TimeshiftServer.start(b);
    final client = HttpClient();
    try {
      final request = await client.getUrl(server.uriAt(188 * 5 + 7));
      final response = await request.close();
      expect(response.statusCode, 200);
      final got = <int>[];
      await for (final chunk in response) {
        got.addAll(chunk);
        if (got.length >= 188 * 3) break;
      }
      // The null packet first, then the next whole packet after the place.
      expect(got[0], 0x47);
      expect(got[1], 0x1F);
      expect(got[188], 0x47);
      expect(got[188 + 2], 6);
    } finally {
      client.close(force: true);
      await server.close();
      await b.close();
    }
  });

  test('memory for timeshift from the device\'s RAM', () {
    expect(parseMemTotalKb('MemTotal:        1932456 kB\nMemFree: 1 kB'), 1932456);
    expect(parseMemTotalKb('nothing'), isNull);
    expect(timeshiftMemoryFor(2 << 30), (2 << 30) ~/ 10);
    expect(timeshiftMemoryFor(64 << 20), 32 << 20);
    expect(timeshiftMemoryFor(64 << 30), 1 << 30);
  });

  test('the delay as shown', () {
    expect(formatTimeshiftDelay(const Duration(seconds: 75)), '−1:15');
    expect(formatTimeshiftDelay(const Duration(hours: 1, minutes: 2, seconds: 3)), '−1:02:03');
    expect(const TvTimeshiftState().shifted, isFalse);
    expect(const TvTimeshiftState(paused: true).shifted, isTrue);
    expect(const TvTimeshiftState(delay: Duration(seconds: 10)).shifted, isTrue);
  });
}
