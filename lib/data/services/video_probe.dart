import 'dart:typed_data';

/// A video's length from its first bytes (and, for an MP4 with its index at
/// the end, one or two small reads more) - for the duration on the
/// pictures browser's video tiles, without a player. Never throws: null
/// when it can't be told (unknown format, broken file).

/// How much of a video's start is read for [videoDuration].
const videoProbeHeadBytes = 64 * 1024;

/// Reads [length] bytes of the file from [offset] (fewer at its end).
typedef VideoRangeReader = Future<Uint8List> Function(int offset, int length);

/// The length of the video [name] (its extension tells the format) whose
/// first bytes are [head] - MP4/MOV/3GP (ISO media: the "mvhd" box, also
/// when the index comes after the picture data: [read] fetches its header
/// then, [size] is the file's size), AVI (its main header) and Matroska /
/// WebM (the segment info). Null if unknown.
Future<Duration?> videoDuration(String name, Uint8List head, {int? size, VideoRangeReader? read}) async {
  try {
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final Duration? d = switch (extension) {
      'mp4' || 'm4v' || 'mov' || 'qt' || '3gp' || '3g2' => await isoMediaDuration(head, size: size, read: read),
      'avi' || 'divx' => aviDuration(head),
      'mkv' || 'webm' => matroskaDuration(head),
      _ => null,
    };
    return _plausible(d);
  } catch (_) {
    return null;
  }
}

Duration? _plausible(Duration? d) =>
    d == null || d <= Duration.zero || d > const Duration(hours: 48) ? null : d;

int _u32(Uint8List b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

int _u64(Uint8List b, int at) => _u32(b, at) * 0x100000000 + _u32(b, at + 4);

int _u32le(Uint8List b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

String _fourCc(Uint8List b, int at) => String.fromCharCodes(b.sublist(at, at + 4));

/// ISO media (MP4, MOV, 3GP): the top-level boxes one after the other up
/// to "moov", then its "mvhd" (time scale and duration). The boxes in
/// [head] cost nothing; a "moov" after a big "mdat" is reached with [read]
/// (two small reads).
Future<Duration?> isoMediaDuration(Uint8List head, {int? size, VideoRangeReader? read}) async {
  Future<Uint8List?> bytesAt(int offset, int length) async {
    if (offset + length <= head.length) return Uint8List.sublistView(head, offset, offset + length);
    if (read == null) return null;
    final bytes = await read(offset, length);
    return bytes.length < length ? null : bytes;
  }

  var offset = 0;
  for (var boxes = 0; boxes < 32; boxes++) {
    if (size != null && offset + 8 > size) return null;
    final header = await bytesAt(offset, 8);
    if (header == null) return null;
    var boxSize = _u32(header, 0);
    final type = _fourCc(header, 4);
    var headerSize = 8;
    if (boxSize == 1) {
      // A 64-bit size after the type.
      final large = await bytesAt(offset + 8, 8);
      if (large == null) return null;
      boxSize = _u64(large, 0);
      headerSize = 16;
    } else if (boxSize == 0) {
      // Up to the end of the file.
      if (type != 'moov') return null;
      boxSize = (size ?? offset + 4096) - offset;
    }
    if (boxSize < headerSize) return null;
    if (boxes == 0 && type != 'ftyp' && type != 'moov' && type != 'wide' && type != 'mdat' && type != 'free') {
      // Not ISO media.
      return null;
    }
    if (type == 'moov') {
      // "mvhd" comes first in practice; a little more for odd orders.
      final length = boxSize - headerSize < 4096 ? boxSize - headerSize : 4096;
      final moov = await bytesAt(offset + headerSize, length);
      return moov == null ? null : _mvhdIn(moov);
    }
    offset += boxSize;
  }
  return null;
}

Duration? _mvhdIn(Uint8List moov) {
  var pos = 0;
  while (pos + 8 <= moov.length) {
    final boxSize = _u32(moov, pos);
    final type = _fourCc(moov, pos + 4);
    if (type == 'mvhd') {
      final body = pos + 8;
      if (body + 1 > moov.length) return null;
      final version = moov[body];
      int timescale, duration;
      if (version == 1) {
        if (body + 32 > moov.length) return null;
        timescale = _u32(moov, body + 20);
        duration = _u64(moov, body + 24);
      } else {
        if (body + 20 > moov.length) return null;
        timescale = _u32(moov, body + 12);
        duration = _u32(moov, body + 16);
      }
      if (timescale <= 0 || duration <= 0 || duration == 0xFFFFFFFF) return null;
      return Duration(microseconds: (duration * 1000000 / timescale).round());
    }
    if (boxSize < 8) return null;
    pos += boxSize;
  }
  return null;
}

/// AVI: frames × time per frame from the main header ("avih") - or the
/// OpenDML header's frame count ("dmlh") of files over 1 GB.
Duration? aviDuration(Uint8List head) {
  if (head.length < 64 || _fourCc(head, 0) != 'RIFF' || _fourCc(head, 8) != 'AVI ') return null;
  final limit = head.length < 16384 ? head.length : 16384;
  int? find(String fourCc, int from) {
    for (var i = from; i + 8 <= limit; i++) {
      if (head[i] == fourCc.codeUnitAt(0) && _fourCc(head, i) == fourCc) return i;
    }
    return null;
  }

  final avih = find('avih', 12);
  if (avih == null || avih + 8 + 20 > head.length) return null;
  final microsPerFrame = _u32le(head, avih + 8);
  var frames = _u32le(head, avih + 8 + 16);
  final dmlh = find('dmlh', avih);
  if (dmlh != null && dmlh + 12 <= head.length) {
    final total = _u32le(head, dmlh + 8);
    if (total > frames) frames = total;
  }
  if (microsPerFrame <= 0 || frames <= 0) return null;
  return Duration(microseconds: microsPerFrame * frames);
}

/// Matroska / WebM: "Duration" (in "TimestampScale" units, 1 ms unless said
/// otherwise) of the segment's "Info" - which comes near the start.
Duration? matroskaDuration(Uint8List head) {
  // An EBML number: its length from the first byte's leading zeros.
  ({int value, int length, bool unknown})? vint(int at, {required bool keepMarker}) {
    if (at >= head.length) return null;
    final first = head[at];
    var length = 1;
    var mask = 0x80;
    while (length <= 8 && first & mask == 0) {
      length++;
      mask >>= 1;
    }
    if (length > 8 || at + length > head.length) return null;
    var value = keepMarker ? first : first & (mask - 1);
    var allOnes = (first & (mask - 1)) == mask - 1;
    for (var i = 1; i < length; i++) {
      value = value * 256 + head[at + i];
      if (head[at + i] != 0xFF) allOnes = false;
    }
    return (value: value, length: length, unknown: !keepMarker && allOnes);
  }

  const ebmlHeader = 0x1A45DFA3, segment = 0x18538067, info = 0x1549A966, cluster = 0x1F43B675;
  const timestampScale = 0x2AD7B1, durationId = 0x4489;
  var pos = 0;
  final end = head.length;
  var sawHeader = false;
  for (var steps = 0; steps < 200 && pos < end; steps++) {
    final id = vint(pos, keepMarker: true);
    if (id == null) return null;
    final size = vint(pos + id.length, keepMarker: false);
    if (size == null) return null;
    final body = pos + id.length + size.length;
    if (!sawHeader) {
      if (id.value != ebmlHeader) return null;
      sawHeader = true;
      pos = body + size.value;
      continue;
    }
    if (id.value == segment) {
      // Into the segment (its size may be "unknown" - live recordings).
      pos = body;
      continue;
    }
    if (id.value == cluster) return null;
    if (id.value == info) {
      final infoEnd = size.unknown ? head.length : (body + size.value).clamp(0, head.length);
      var scale = 1000000;
      double? duration;
      var p = body;
      while (p < infoEnd) {
        final cid = vint(p, keepMarker: true);
        if (cid == null) break;
        final csize = vint(p + cid.length, keepMarker: false);
        if (csize == null) break;
        final cbody = p + cid.length + csize.length;
        if (cbody + csize.value > head.length) break;
        if (cid.value == timestampScale && csize.value >= 1 && csize.value <= 8) {
          var v = 0;
          for (var i = 0; i < csize.value; i++) {
            v = v * 256 + head[cbody + i];
          }
          if (v > 0) scale = v;
        } else if (cid.value == durationId) {
          final data = ByteData.sublistView(head, cbody, cbody + csize.value);
          if (csize.value == 4) duration = data.getFloat32(0);
          if (csize.value == 8) duration = data.getFloat64(0);
        }
        p = cbody + csize.value;
      }
      if (duration == null || duration.isNaN || duration <= 0) return null;
      return Duration(microseconds: (duration * scale / 1000).round());
    }
    if (size.unknown) return null;
    pos = body + size.value;
  }
  return null;
}
