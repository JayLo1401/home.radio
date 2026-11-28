import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'nas_service.dart';
import 'tv_stream_session.dart' show alignToTsPacket;

/// Where timeshift keeps the parts of the stream that left the memory:
/// a folder on this device or on the NAS. One file per part ("segment"),
/// named by its first byte's place in the stream.
abstract class TimeshiftBackend {
  /// Gets ready (folder, leftovers of an earlier run gone). Throws if it
  /// can't be used.
  Future<void> open();

  Future<void> write(int start, Uint8List bytes);

  /// [length] bytes of the segment starting at [start], from [offset] in it.
  Future<Uint8List> read(int start, int offset, int length);

  Future<void> delete(int start);

  /// Removes everything written and lets go.
  Future<void> close();
}

/// Why the buffer went on in memory alone.
enum TimeshiftProblem {
  /// The folder can't be written (full, gone, no rights).
  writeFailed,

  /// It takes the stream slower than it comes (the NAS).
  tooSlow,
}

/// A piece read from the buffer: [offset] is where it starts - later than
/// asked for if that part was gone already.
typedef TimeshiftChunk = ({int offset, Uint8List bytes});

class _Block {
  _Block(this.start, int capacity) : data = Uint8List(capacity);

  final int start;
  final Uint8List data;
  int length = 0;
  bool persisted = false;

  int get end => start + length;
  bool get full => length == data.length;
}

typedef _Segment = ({int start, int end, DateTime last});

/// The stream of the channel on air as it came, for pausing and rewinding
/// live TV: bytes counted from the first one ([head] - all so far,
/// [tail] - the oldest still there), and when each part arrived (to find
/// "two minutes ago").
///
/// Without a [TimeshiftBackend] everything stays in memory, at most
/// [memoryBytes] (older parts drop out). With one, the stream goes into
/// [blockBytes] large segments: each full one is written there, the last
/// [cacheBytes] of them stay in memory too; segments older than [maxAge]
/// are deleted. If the backend can't keep up - more than [maxPendingBytes]
/// waiting - or fails, the buffer goes on in memory alone and says why in
/// [problem].
class TimeshiftBuffer {
  TimeshiftBuffer({
    TimeshiftBackend? backend,
    required this.memoryBytes,
    this.maxAge,
    int? blockBytes,
    this.cacheBytes = 24 << 20,
    int? maxPendingBytes,
    DateTime Function()? clock,
  })  : _backend = backend,
        blockBytes = blockBytes ?? (backend == null ? 1 << 20 : 8 << 20),
        maxPendingBytes = maxPendingBytes ?? math.min(memoryBytes, 64 << 20),
        _clock = clock ?? DateTime.now {
    final b = backend;
    if (b != null) {
      _opened = b.open().then((_) => true, onError: (Object e) {
        debugPrint('Timeshift: $e');
        _fallBack(TimeshiftProblem.writeFailed);
        return false;
      });
    }
  }

  final int memoryBytes;
  final Duration? maxAge;
  final int blockBytes;
  final int cacheBytes;
  final int maxPendingBytes;
  final DateTime Function() _clock;
  TimeshiftBackend? _backend;
  Future<bool> _opened = Future.value(false);

  final _blocks = <_Block>[];
  final _segments = <_Segment>[];
  final _markOffsets = <int>[];
  final _markTimes = <DateTime>[];
  int _head = 0;
  int _tail = 0;
  bool _closed = false;
  bool _writing = false;
  Completer<void>? _grew;

  /// Set once it went on in memory alone.
  final problem = ValueNotifier<TimeshiftProblem?>(null);

  int get head => _head;
  int get tail => _tail;
  bool get closed => _closed;

  /// Whether a backend still takes the stream.
  bool get usesBackend => _backend != null;

  /// When the oldest part still there arrived (null: nothing yet).
  DateTime? get oldestTime => _markTimes.isEmpty ? null : timeAt(_tail);

  /// How far back it goes.
  Duration get span {
    final oldest = oldestTime;
    return oldest == null ? Duration.zero : _clock().difference(oldest);
  }

  /// Takes the next bytes of the stream.
  void append(List<int> chunk) {
    if (_closed || chunk.isEmpty) return;
    final now = _clock();
    if (_markTimes.isEmpty || now.difference(_markTimes.last) >= const Duration(milliseconds: 500)) {
      _markOffsets.add(_head);
      _markTimes.add(now);
    }
    var i = 0;
    var filled = false;
    while (i < chunk.length) {
      var b = _blocks.isEmpty ? null : _blocks.last;
      if (b == null || b.full) {
        if (b != null) filled = true;
        b = _Block(_head, blockBytes);
        _blocks.add(b);
      }
      final n = math.min(b.data.length - b.length, chunk.length - i);
      b.data.setRange(b.length, b.length + n, chunk, i);
      b.length += n;
      i += n;
      _head += n;
    }
    if (filled && _backend != null) unawaited(_writeFull());
    _evict();
    final grew = _grew;
    _grew = null;
    grew?.complete();
  }

  int get _pendingBytes {
    var n = 0;
    for (final b in _blocks) {
      if (b.full && !b.persisted) n += b.length;
    }
    return n;
  }

  Future<void> _writeFull() async {
    if (_writing) return;
    _writing = true;
    try {
      if (!await _opened) return;
      while (!_closed) {
        final backend = _backend;
        if (backend == null) break;
        final b = _blocks.where((b) => b.full && !b.persisted).firstOrNull;
        if (b == null) break;
        try {
          await backend.write(b.start, Uint8List.sublistView(b.data, 0, b.length));
        } catch (e) {
          debugPrint('Timeshift: writing failed: $e');
          _fallBack(TimeshiftProblem.writeFailed);
          break;
        }
        if (_closed || _backend != backend) break;
        b.persisted = true;
        _segments.add((start: b.start, end: b.end, last: _clock()));
        _evict();
      }
    } finally {
      _writing = false;
    }
  }

  void _evict() {
    final now = _clock();
    if (_backend == null) {
      var bytes = _blocks.fold<int>(0, (n, b) => n + b.data.length);
      while (_blocks.length > 1 && bytes > memoryBytes) {
        bytes -= _blocks.removeAt(0).data.length;
      }
    } else {
      if (_pendingBytes > maxPendingBytes) {
        _fallBack(TimeshiftProblem.tooSlow);
        return _evict();
      }
      // In memory: what isn't written yet, and the last [cacheBytes].
      var cached = 0;
      for (var i = _blocks.length - 1; i >= 0; i--) {
        final b = _blocks[i];
        if (!b.persisted) continue;
        cached += b.data.length;
        if (cached > cacheBytes) _blocks.removeAt(i);
      }
      final age = maxAge;
      if (age != null) {
        final backend = _backend!;
        while (_segments.isNotEmpty && now.difference(_segments.first.last) > age) {
          final s = _segments.removeAt(0);
          _blocks.removeWhere((b) => b.persisted && b.end <= s.end);
          unawaited(backend.delete(s.start).catchError((Object e) => debugPrint('Timeshift: delete: $e')));
        }
      }
    }
    final starts = [
      if (_segments.isNotEmpty) _segments.first.start,
      if (_blocks.isNotEmpty) _blocks.first.start,
    ];
    _tail = starts.isEmpty ? _head : starts.reduce(math.min);
    // The arrival times before the tail aren't needed (one stays for it).
    var drop = 0;
    while (drop + 1 < _markOffsets.length && _markOffsets[drop + 1] <= _tail) {
      drop++;
    }
    if (drop > 0) {
      _markOffsets.removeRange(0, drop);
      _markTimes.removeRange(0, drop);
    }
  }

  /// The backend let it down: from here on in memory - what was only
  /// there is gone.
  void _fallBack(TimeshiftProblem why) {
    final backend = _backend;
    if (backend == null) return;
    _backend = null;
    _segments.clear();
    for (final b in _blocks) {
      b.persisted = false;
    }
    unawaited(backend.close().catchError((Object e) => debugPrint('Timeshift: close: $e')));
    if (!_closed) problem.value = why;
    _evict();
  }

  /// Up to [max] bytes from [offset] on - waits for them if they haven't
  /// come yet; from the oldest still there if [offset] is gone. Null once
  /// closed.
  Future<TimeshiftChunk?> read(int offset, int max) async {
    var pos = offset;
    while (true) {
      if (_closed) return null;
      if (pos < _tail) pos = _tail;
      if (pos >= _head) {
        await (_grew ??= Completer<void>()).future;
        continue;
      }
      for (final b in _blocks) {
        if (pos >= b.start && pos < b.end) {
          final from = pos - b.start;
          return (offset: pos, bytes: Uint8List.sublistView(b.data, from, math.min(b.length, from + max)));
        }
      }
      final s = _segments.where((s) => pos >= s.start && pos < s.end).firstOrNull;
      final backend = _backend;
      if (s != null && backend != null) {
        try {
          final bytes = await backend.read(s.start, pos - s.start, math.min(max, s.end - pos));
          if (bytes.isNotEmpty) return (offset: pos, bytes: bytes);
        } catch (e) {
          debugPrint('Timeshift: reading failed: $e');
        }
        // Gone meanwhile (deleted, or the backend failed): on after it.
        pos = math.max(pos, s.end);
        continue;
      }
      // Between parts (shouldn't be): the next one still there.
      final next = [
        for (final b in _blocks)
          if (b.start > pos) b.start,
        for (final s in _segments)
          if (s.start > pos) s.start,
      ];
      pos = next.isEmpty ? _head : next.reduce(math.min);
    }
  }

  /// Where the stream was at [t] (clamped to what's there).
  int offsetAt(DateTime t) {
    if (_markTimes.isEmpty) return _head;
    var lo = 0, hi = _markTimes.length - 1;
    if (t.isBefore(_markTimes.first)) return math.max(_markOffsets.first, _tail);
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_markTimes[mid].isAfter(t)) {
        hi = mid - 1;
      } else {
        lo = mid;
      }
    }
    return math.max(_markOffsets[lo], _tail);
  }

  /// When the byte at [offset] arrived (about).
  DateTime timeAt(int offset) {
    if (_markOffsets.isEmpty) return _clock();
    var lo = 0, hi = _markOffsets.length - 1;
    if (offset <= _markOffsets.first) return _markTimes.first;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_markOffsets[mid] > offset) {
        hi = mid - 1;
      } else {
        lo = mid;
      }
    }
    return _markTimes[lo];
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final grew = _grew;
    _grew = null;
    grew?.complete();
    _blocks.clear();
    _segments.clear();
    final backend = _backend;
    _backend = null;
    if (backend != null) {
      try {
        await backend.close();
      } catch (e) {
        debugPrint('Timeshift: close: $e');
      }
    }
  }
}

/// Segments as files in a folder of this device (the app's cache) -
/// [locate] finds it (on the first use, not holding up the start).
class FileTimeshiftBackend implements TimeshiftBackend {
  FileTimeshiftBackend(this._locate);

  final Future<Directory> Function() _locate;
  Directory? _directory;

  File _file(int start) => File('${_directory!.path}${Platform.pathSeparator}seg_$start.ts');

  @override
  Future<void> open() async {
    final directory = _directory = await _locate();
    // Folders of earlier runs next to it (the app was stopped, or the
    // channel before): away with them.
    try {
      await for (final other in directory.parent.list()) {
        if (other is Directory && other.path != directory.path) {
          try {
            await other.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    await directory.create(recursive: true);
  }

  @override
  Future<void> write(int start, Uint8List bytes) async {
    await _file(start).writeAsBytes(bytes, flush: false);
  }

  @override
  Future<Uint8List> read(int start, int offset, int length) async {
    final f = await _file(start).open();
    try {
      await f.setPosition(offset);
      return await f.read(length);
    } finally {
      await f.close();
    }
  }

  @override
  Future<void> delete(int start) async {
    try {
      await _file(start).delete();
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    final directory = _directory;
    if (directory == null) return;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {}
  }
}

/// Segments as files in the NAS folder "Timeshift": [devicePrefix] (names
/// the device, so several can share the folder) + a number of this run +
/// the segment's start + ".ts".
class NasTimeshiftBackend implements TimeshiftBackend {
  NasTimeshiftBackend(this._client, this.folder, this.devicePrefix)
      : prefix = '$devicePrefix${DateTime.now().millisecondsSinceEpoch}_';

  final NasClient _client;
  final String folder;
  final String devicePrefix;
  final String prefix;
  final _written = <int>{};
  bool _closed = false;

  String _path(int start) => joinNasPath(folder, '$prefix$start.ts');

  @override
  Future<void> open() async {
    // Leftovers of this device's earlier runs.
    final entries = await _client.list(folder);
    for (final e in entries) {
      if (_closed) return;
      if (!e.isDirectory && e.name.startsWith(devicePrefix) && !e.name.startsWith(prefix) && e.name.endsWith('.ts')) {
        try {
          await _client.delete(e.path);
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> write(int start, Uint8List bytes) async {
    if (_closed) return;
    await _client.write(_path(start), bytes);
    _written.add(start);
  }

  @override
  Future<Uint8List> read(int start, int offset, int length) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in _client.openRead(_path(start), offset: offset, length: length)) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  @override
  Future<void> delete(int start) async {
    _written.remove(start);
    await _client.delete(_path(start));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final start in _written.toList()) {
      try {
        await _client.delete(_path(start));
      } catch (_) {}
    }
    _written.clear();
    _client.close();
  }
}

/// Plays the buffer to a player: a little HTTP server on this device
/// (127.0.0.1) - [uriAt] is the stream from a place in it on, live as it
/// grows. A player that pauses stops reading; the buffer goes on filling.
class TimeshiftServer {
  TimeshiftServer._(this._server, this._buffer);

  final HttpServer _server;
  final TimeshiftBuffer _buffer;
  int _count = 0;

  /// Called when a reader had to skip forward (that part was gone).
  void Function(int offset)? onSkip;

  static Future<TimeshiftServer> start(TimeshiftBuffer buffer) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ts = TimeshiftServer._(server, buffer);
    server.listen((r) => unawaited(ts._serve(r)));
    return ts;
  }

  static final _nullPacket = Uint8List(188)
    ..fillRange(4, 188, 0xFF)
    ..setAll(0, const [0x47, 0x1F, 0xFF, 0x10]);

  /// The stream from [offset] on (a new address each time - players cache).
  Uri uriAt(int offset) => Uri.parse('http://127.0.0.1:${_server.port}/timeshift.ts?o=$offset&n=${_count++}');

  Future<void> _serve(HttpRequest request) async {
    final offset = int.tryParse(request.uri.queryParameters['o'] ?? '') ?? _buffer.head;
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..bufferOutput = false
      ..headers.contentType = ContentType('video', 'mp2t');
    try {
      response.add(_nullPacket);
      await response.flush();
      await response.addStream(_read(offset));
      await response.close();
    } catch (_) {
      // The player went away.
    }
  }

  Stream<List<int>> _read(int offset) async* {
    var pos = offset;
    var align = true;
    while (true) {
      final chunk = await _buffer.read(pos, 256 << 10);
      if (chunk == null) return;
      if (chunk.offset != pos) {
        align = true;
        if (pos != offset) onSkip?.call(chunk.offset);
      }
      pos = chunk.offset + chunk.bytes.length;
      // From a packet's start - the place asked for may be anywhere in one.
      yield align ? alignToTsPacket(chunk.bytes) : chunk.bytes;
      align = false;
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// The memory for timeshift on this device: a tenth of its RAM (from
/// /proc/meminfo on Android and Linux; 4 GB assumed elsewhere), between 32
/// MB and 1 GB.
Future<int> timeshiftMemoryBytes() async {
  var total = 4 << 30;
  try {
    if (!kIsWeb && (Platform.isAndroid || Platform.isLinux)) {
      final kb = parseMemTotalKb(await File('/proc/meminfo').readAsString());
      if (kb != null) total = kb * 1024;
    }
  } catch (_) {}
  return timeshiftMemoryFor(total);
}

/// [timeshiftMemoryBytes] for [totalRam] bytes.
int timeshiftMemoryFor(int totalRam) => (totalRam ~/ 10).clamp(32 << 20, 1 << 30);

/// "MemTotal:  1932456 kB" of /proc/meminfo.
int? parseMemTotalKb(String meminfo) {
  final m = RegExp(r'^MemTotal:\s+(\d+)\s*kB', multiLine: true).firstMatch(meminfo);
  return m == null ? null : int.tryParse(m[1]!);
}
