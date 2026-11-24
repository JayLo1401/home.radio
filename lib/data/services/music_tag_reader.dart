import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/music_track.dart';

/// Reads [length] bytes of the file from [offset] on - fewer at its end.
typedef MusicByteReader = Future<Uint8List> Function(int offset, int length);

/// How much of a file's head is fetched first - enough for the tags of most
/// files (a cover often lies beyond, then more is read).
const _headBytes = 128 * 1024;

/// Tags (cover included) are never read beyond this.
const _maxTagBytes = 12 * 1024 * 1024;

/// Reads the tags of a music file through [read] - only the parts needed:
/// the head (ID3v2, FLAC/Vorbis comments, Ogg), the atoms of an MP4 up to
/// "moov", RIFF/AIFF chunks, and the last 128 bytes (ID3v1) when the head
/// had nothing. [fileSize] lets it look at the end; without it ID3v1 is
/// skipped. Never throws for broken files - returns what it found.
Future<MusicTags> readMusicTags(MusicByteReader read, {int? fileSize}) async {
  final reader = _HeadCachedReader(read);
  try {
    final head = await reader.read(0, _headBytes);
    if (head.length < 12) return MusicTags.empty;
    var tags = MusicTags.empty;
    var offset = 0;
    if (_ascii(head, 0, 3) == 'ID3') {
      final total = id3v2TotalSize(head);
      if (total != null) {
        final bytes = total <= head.length ? head.sublist(0, total) : await reader.read(0, total.clamp(0, _maxTagBytes));
        tags = await _parseId3(bytes) ?? MusicTags.empty;
        offset = total;
      }
    }
    final magic = await reader.read(offset, 12);
    if (magic.length >= 4 && _ascii(magic, 0, 4) == 'fLaC') {
      tags = tags.mergedWith(await _readFlac(reader, offset));
    } else if (magic.length >= 4 && _ascii(magic, 0, 4) == 'OggS') {
      tags = tags.mergedWith(await _readOgg(reader, offset));
    } else if (magic.length >= 12 && _ascii(magic, 0, 4) == 'RIFF' && _ascii(magic, 8, 4) == 'WAVE') {
      tags = tags.mergedWith(await _readChunks(reader, offset, fileSize, bigEndian: false));
    } else if (magic.length >= 12 && _ascii(magic, 0, 4) == 'FORM' && _ascii(magic, 8, 3) == 'AIF') {
      tags = tags.mergedWith(await _readChunks(reader, offset, fileSize, bigEndian: true));
    } else if (magic.length >= 8 && _ascii(magic, 4, 4) == 'ftyp') {
      tags = tags.mergedWith(await _readMp4(reader, offset, fileSize));
    }
    if (tags.title == null && fileSize != null && fileSize > 128 + offset) {
      final tail = await reader.read(fileSize - 128, 128);
      final v1 = parseId3v1(tail);
      if (v1 != null) tags = tags.mergedWith(v1);
    }
    return tags;
  } catch (_) {
    return MusicTags.empty;
  }
}

/// Serves reads within the first [_headBytes] from one fetch.
class _HeadCachedReader {
  _HeadCachedReader(this._read);

  final MusicByteReader _read;
  Uint8List? _head;

  Future<Uint8List> read(int offset, int length) async {
    if (length <= 0) return Uint8List(0);
    final head = _head ??= await _read(0, _headBytes);
    if (offset + length <= head.length) return Uint8List.sublistView(head, offset, offset + length);
    // The head is all there is (the file ends within it).
    if (head.length < _headBytes && offset >= head.length) return Uint8List(0);
    if (head.length < _headBytes) return Uint8List.sublistView(head, offset);
    return _read(offset, length);
  }
}

String _ascii(Uint8List b, int start, int length) {
  if (start + length > b.length) return '';
  return String.fromCharCodes(b, start, start + length);
}

int _u32be(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _u32le(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
int _u24be(Uint8List b, int o) => (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];
int _syncsafe(Uint8List b, int o) => (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

int? _parseNumber(String? s) {
  if (s == null) return null;
  final m = RegExp(r'\d+').firstMatch(s);
  return m == null ? null : int.tryParse(m.group(0)!);
}

int? _parseYear(String? s) {
  if (s == null) return null;
  final m = RegExp(r'(1[89]|20)\d\d').firstMatch(s);
  return m == null ? null : int.parse(m.group(0)!);
}

String? _clean(String? s) {
  if (s == null) return null;
  final t = s.replaceAll('\u0000', '').trim();
  return t.isEmpty ? null : t;
}

// --- ID3v2 ---

/// Tags this big (covers of several MB, maybe "unsynchronised" byte by
/// byte) are parsed on a worker isolate - not on the UI's, where it would
/// stall the picture (the visualisation) at every track change.
const _isolateFrom = 256 * 1024;

/// [parseId3v2], off the UI isolate for big tags. Only [bytes] goes to
/// the worker (a top-level function: its closure holds nothing else).
Future<MusicTags?> _parseId3(Uint8List bytes) async {
  if (bytes.length < _isolateFrom) return parseId3v2(bytes);
  try {
    return await Isolate.run(() => parseId3v2(bytes));
  } catch (_) {
    return parseId3v2(bytes);
  }
}

/// The whole size of an ID3v2 tag (header, frames, footer) from its first
/// 10 bytes - null if they aren't one.
int? id3v2TotalSize(Uint8List header) {
  if (header.length < 10 || _ascii(header, 0, 3) != 'ID3') return null;
  if (header[3] < 2 || header[3] > 4) return null;
  if (header[6] | header[7] | header[8] | header[9] >= 0x80) return null;
  final footer = header[3] == 4 && header[5] & 0x10 != 0 ? 10 : 0;
  return 10 + _syncsafe(header, 6) + footer;
}

/// Reverses ID3's "unsynchronisation" (a 0x00 after every 0xFF).
Uint8List _unsync(Uint8List b) {
  final buffer = Uint8List(b.length);
  var n = 0;
  for (var i = 0; i < b.length; i++) {
    buffer[n++] = b[i];
    if (b[i] == 0xFF && i + 1 < b.length && b[i + 1] == 0x00) i++;
  }
  return Uint8List.sublistView(buffer, 0, n);
}

/// Text in ID3's [encoding]: 0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16BE,
/// 3 UTF-8. The first of several values (ID3v2.4 separates by a zero).
String _decodeId3Text(int encoding, Uint8List b) {
  switch (encoding) {
    case 1:
    case 2:
      var bigEndian = encoding == 2;
      var start = 0;
      if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        bigEndian = false;
        start = 2;
      } else if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
        bigEndian = true;
        start = 2;
      }
      final units = <int>[];
      for (var i = start; i + 1 < b.length; i += 2) {
        final u = bigEndian ? (b[i] << 8) | b[i + 1] : b[i] | (b[i + 1] << 8);
        if (u == 0) break;
        // A BOM again after a separator.
        if (u == 0xFEFF && units.isEmpty) continue;
        units.add(u);
      }
      return String.fromCharCodes(units);
    case 3:
      final end = b.indexOf(0);
      return utf8.decode(end < 0 ? b : Uint8List.sublistView(b, 0, end), allowMalformed: true);
    default:
      final end = b.indexOf(0);
      return latin1.decode(end < 0 ? b : Uint8List.sublistView(b, 0, end));
  }
}

/// The end of a zero-terminated string in [encoding] from [start]: the
/// index after the terminator.
int _skipTerminated(Uint8List b, int start, int encoding) {
  if (encoding == 1 || encoding == 2) {
    var i = start;
    while (i + 1 < b.length) {
      if (b[i] == 0 && b[i + 1] == 0) return i + 2;
      i += 2;
    }
    return b.length;
  }
  final end = b.indexOf(0, start);
  return end < 0 ? b.length : end + 1;
}

/// The tags of an ID3v2 (2.2, 2.3, 2.4) tag; [bytes] start with "ID3".
MusicTags? parseId3v2(Uint8List bytes) {
  final total = id3v2TotalSize(bytes);
  if (total == null) return null;
  final version = bytes[3];
  final flags = bytes[5];
  var body = Uint8List.sublistView(bytes, 10, total.clamp(10, bytes.length));
  if (version < 4 && flags & 0x80 != 0) body = _unsync(body);
  var pos = 0;
  if (flags & 0x40 != 0 && version >= 3 && body.length >= 4) {
    // Extended header: 2.3 size without itself, 2.4 syncsafe with itself.
    pos = version == 3 ? _u32be(body, 0) + 4 : _syncsafe(body, 0);
  }
  final idLength = version == 2 ? 3 : 4;
  final headerLength = version == 2 ? 6 : 10;
  final text = <String, String>{};
  Uint8List? cover;
  var coverIsFront = false;

  while (pos + headerLength <= body.length) {
    if (body[pos] == 0) break; // padding
    final id = _ascii(body, pos, idLength);
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(id)) break;
    int size;
    var formatFlags = 0;
    if (version == 2) {
      size = _u24be(body, pos + 3);
    } else if (version == 3) {
      size = _u32be(body, pos + 4);
      final f = body[pos + 9];
      // compression, encryption, grouping -> 2.4 style bits.
      formatFlags = (f & 0x80 != 0 ? 0x08 : 0) | (f & 0x40 != 0 ? 0x04 : 0) | (f & 0x20 != 0 ? 0x40 : 0);
    } else {
      final raw = Uint8List.sublistView(body, pos + 4, pos + 8);
      // Some writers put plain sizes into 2.4 frames.
      size = raw.any((b) => b >= 0x80) ? _u32be(body, pos + 4) : _syncsafe(body, pos + 4);
      formatFlags = body[pos + 9];
    }
    final start = pos + headerLength;
    final end = start + size;
    if (size <= 0 || end > body.length) break;
    pos = end;
    var data = Uint8List.sublistView(body, start, end);
    if (formatFlags & 0x0C != 0) continue; // compressed or encrypted
    var skip = 0;
    if (formatFlags & 0x40 != 0) skip += 1; // grouping
    if (version == 4 && formatFlags & 0x01 != 0) skip += 4; // data length
    if (skip >= data.length) continue;
    data = Uint8List.sublistView(data, skip);
    if (version == 4 && formatFlags & 0x02 != 0) data = _unsync(data);
    if (data.isEmpty) continue;

    if (id == 'APIC' || id == 'PIC') {
      final encoding = data[0];
      var p = 1;
      if (id == 'PIC') {
        p += 3; // "JPG" / "PNG"
      } else {
        p = _skipTerminated(data, p, 0); // MIME type
      }
      if (p >= data.length) continue;
      final pictureType = data[p];
      p = _skipTerminated(data, p + 1, encoding);
      if (p >= data.length) continue;
      final front = pictureType == 3;
      if (cover == null || (front && !coverIsFront)) {
        cover = Uint8List.fromList(Uint8List.sublistView(data, p));
        coverIsFront = front;
      }
      continue;
    }
    if (id.startsWith('T') && id != 'TXXX' && id != 'TXX') {
      text[id] = _decodeId3Text(data[0], Uint8List.sublistView(data, 1));
    }
  }

  String? pick(String v23, String v22) => _clean(text[v23] ?? text[v22]);
  return MusicTags(
    title: pick('TIT2', 'TT2'),
    artist: pick('TPE1', 'TP1'),
    album: pick('TALB', 'TAL'),
    albumArtist: pick('TPE2', 'TP2'),
    trackNumber: _parseNumber(pick('TRCK', 'TRK')),
    year: _parseYear(pick('TDRC', 'TYE') ?? pick('TYER', 'TYE') ?? pick('TDOR', 'TOR')),
    cover: cover,
  );
}

/// The tags of an ID3v1 tag (the last 128 bytes of the file).
MusicTags? parseId3v1(Uint8List tail) {
  if (tail.length < 128 || _ascii(tail, 0, 3) != 'TAG') return null;
  String? field(int start, int length) => _clean(_decodeId3Text(0, Uint8List.sublistView(tail, start, start + length)));
  final title = field(3, 30);
  if (title == null) return null;
  return MusicTags(
    title: title,
    artist: field(33, 30),
    album: field(63, 30),
    year: _parseYear(field(93, 4)),
    trackNumber: tail[125] == 0 && tail[126] != 0 ? tail[126] : null,
  );
}

// --- Vorbis comments (FLAC, Ogg Vorbis, Opus) ---

/// A Vorbis comment block (vendor, then "KEY=value" entries), little endian.
MusicTags? parseVorbisComment(Uint8List b) {
  if (b.length < 8) return null;
  var p = 0;
  final vendor = _u32le(b, p);
  p += 4 + vendor;
  if (p + 4 > b.length) return null;
  final count = _u32le(b, p);
  p += 4;
  final values = <String, String>{};
  Uint8List? cover;
  for (var i = 0; i < count && p + 4 <= b.length; i++) {
    final length = _u32le(b, p);
    p += 4;
    if (length < 0 || p + length > b.length) break;
    final entry = Uint8List.sublistView(b, p, p + length);
    p += length;
    final eq = entry.indexOf(0x3D); // '='
    if (eq <= 0) continue;
    final key = ascii.decode(Uint8List.sublistView(entry, 0, eq), allowInvalid: true).toUpperCase();
    if (key == 'METADATA_BLOCK_PICTURE' || key == 'COVERART') {
      if (cover != null) continue;
      try {
        final raw = base64.decode(utf8.decode(Uint8List.sublistView(entry, eq + 1), allowMalformed: true).trim());
        cover = key == 'COVERART' ? raw : parseFlacPicture(raw);
      } catch (_) {}
      continue;
    }
    values.putIfAbsent(key, () => utf8.decode(Uint8List.sublistView(entry, eq + 1), allowMalformed: true));
  }
  return MusicTags(
    title: _clean(values['TITLE']),
    artist: _clean(values['ARTIST']),
    album: _clean(values['ALBUM']),
    albumArtist: _clean(values['ALBUMARTIST'] ?? values['ALBUM ARTIST']),
    trackNumber: _parseNumber(values['TRACKNUMBER']),
    year: _parseYear(values['DATE'] ?? values['YEAR']),
    cover: cover,
  );
}

/// The picture bytes of a FLAC PICTURE block's content.
Uint8List? parseFlacPicture(Uint8List b) {
  if (b.length < 32) return null;
  var p = 4; // picture type
  final mime = _u32be(b, p);
  p += 4 + mime;
  if (p + 4 > b.length) return null;
  final description = _u32be(b, p);
  p += 4 + description + 16; // width, height, depth, colours
  if (p + 4 > b.length) return null;
  final length = _u32be(b, p);
  p += 4;
  if (length <= 0 || p + length > b.length) return null;
  return Uint8List.fromList(Uint8List.sublistView(b, p, p + length));
}

Future<MusicTags> _readFlac(_HeadCachedReader reader, int start) async {
  var offset = start + 4;
  var tags = MusicTags.empty;
  Uint8List? cover;
  for (var i = 0; i < 64; i++) {
    final header = await reader.read(offset, 4);
    if (header.length < 4) break;
    final last = header[0] & 0x80 != 0;
    final type = header[0] & 0x7F;
    final length = _u24be(header, 1);
    if (type == 4 || (type == 6 && cover == null)) {
      if (length > _maxTagBytes) break;
      final body = await reader.read(offset + 4, length);
      if (type == 4) {
        tags = tags.mergedWith(parseVorbisComment(body) ?? MusicTags.empty);
      } else {
        cover = parseFlacPicture(body);
      }
    }
    offset += 4 + length;
    if (last) break;
  }
  return cover == null || tags.cover != null ? tags : tags.withCover(cover);
}

/// The second packet of an Ogg stream (the comment header), read page by
/// page from [start].
Future<MusicTags> _readOgg(_HeadCachedReader reader, int start) async {
  var offset = start;
  var packetIndex = 0;
  final packet = BytesBuilder(copy: false);
  for (var page = 0; page < 512; page++) {
    final header = await reader.read(offset, 27);
    if (header.length < 27 || _ascii(header, 0, 4) != 'OggS') break;
    final segments = header[26];
    final table = await reader.read(offset + 27, segments);
    if (table.length < segments) break;
    final bodyLength = table.fold<int>(0, (a, b) => a + b);
    final body = await reader.read(offset + 27 + segments, bodyLength);
    offset += 27 + segments + bodyLength;
    var p = 0;
    for (final lace in table) {
      if (packetIndex == 1) packet.add(Uint8List.sublistView(body, p, (p + lace).clamp(0, body.length)));
      p += lace;
      if (lace < 255) {
        if (packetIndex == 1) return parseOggCommentPacket(packet.takeBytes()) ?? MusicTags.empty;
        packetIndex++;
      }
    }
    if (packet.length > _maxTagBytes) break;
  }
  return MusicTags.empty;
}

/// The comment header of Ogg Vorbis ("\x03vorbis") or Opus ("OpusTags").
MusicTags? parseOggCommentPacket(Uint8List packet) {
  if (packet.length > 7 && packet[0] == 3 && _ascii(packet, 1, 6) == 'vorbis') {
    return parseVorbisComment(Uint8List.sublistView(packet, 7));
  }
  if (packet.length > 8 && _ascii(packet, 0, 8) == 'OpusTags') {
    return parseVorbisComment(Uint8List.sublistView(packet, 8));
  }
  return null;
}

// --- RIFF (WAV) and AIFF ---

Future<MusicTags> _readChunks(_HeadCachedReader reader, int start, int? fileSize, {required bool bigEndian}) async {
  var offset = start + 12;
  var tags = MusicTags.empty;
  for (var i = 0; i < 64; i++) {
    if (fileSize != null && offset + 8 > fileSize) break;
    final header = await reader.read(offset, 8);
    if (header.length < 8) break;
    final id = _ascii(header, 0, 4);
    final size = bigEndian ? _u32be(header, 4) : _u32le(header, 4);
    if (size < 0) break;
    final body = offset + 8;
    if (id == 'LIST' || id == 'id3 ' || id == 'ID3 ' || id == 'NAME' || id == 'AUTH') {
      if (size <= _maxTagBytes) {
        final bytes = await reader.read(body, size);
        if (id == 'LIST') {
          tags = tags.mergedWith(parseRiffInfo(bytes) ?? MusicTags.empty);
        } else if (id == 'NAME') {
          tags = tags.mergedWith(MusicTags(title: _clean(latin1.decode(bytes))));
        } else if (id == 'AUTH') {
          tags = tags.mergedWith(MusicTags(artist: _clean(latin1.decode(bytes))));
        } else {
          // ID3 tags win over RIFF INFO.
          tags = (await _parseId3(bytes) ?? MusicTags.empty).mergedWith(tags);
        }
      }
    }
    // Chunks are padded to an even length.
    offset = body + size + (size.isOdd ? 1 : 0);
    if (fileSize == null && id == 'data') break;
  }
  return tags;
}

/// A RIFF "LIST" chunk's content of type "INFO".
MusicTags? parseRiffInfo(Uint8List b) {
  if (b.length < 4 || _ascii(b, 0, 4) != 'INFO') return null;
  final values = <String, String>{};
  var p = 4;
  while (p + 8 <= b.length) {
    final id = _ascii(b, p, 4);
    final size = _u32le(b, p + 4);
    final start = p + 8;
    if (size < 0 || start + size > b.length) break;
    final raw = Uint8List.sublistView(b, start, start + size);
    final end = raw.indexOf(0);
    final bytes = end < 0 ? raw : Uint8List.sublistView(raw, 0, end);
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = latin1.decode(bytes);
    }
    values[id] = text;
    p = start + size + (size.isOdd ? 1 : 0);
  }
  return MusicTags(
    title: _clean(values['INAM']),
    artist: _clean(values['IART']),
    album: _clean(values['IPRD']),
    trackNumber: _parseNumber(values['ITRK'] ?? values['IPRT']),
    year: _parseYear(values['ICRD']),
  );
}

// --- MP4 / M4A ---

Future<MusicTags> _readMp4(_HeadCachedReader reader, int start, int? fileSize) async {
  var offset = start;
  for (var i = 0; i < 64; i++) {
    if (fileSize != null && offset + 8 > fileSize) break;
    final header = await reader.read(offset, 16);
    if (header.length < 8) break;
    var size = _u32be(header, 0);
    final type = _ascii(header, 4, 4);
    var headerLength = 8;
    if (size == 1) {
      if (header.length < 16) break;
      size = (_u32be(header, 8) << 32) | _u32be(header, 12);
      headerLength = 16;
    } else if (size == 0) {
      if (fileSize == null) break;
      size = fileSize - offset;
    }
    if (size < headerLength) break;
    if (type == 'moov') {
      if (size > _maxTagBytes * 2) break;
      final body = await reader.read(offset + headerLength, size - headerLength);
      return parseMp4Moov(body);
    }
    offset += size;
  }
  return MusicTags.empty;
}

/// The children of an MP4 atom's content: (type, content) pairs.
Iterable<(String, Uint8List)> _atoms(Uint8List b) sync* {
  var p = 0;
  while (p + 8 <= b.length) {
    var size = _u32be(b, p);
    final type = latin1.decode(Uint8List.sublistView(b, p + 4, p + 8));
    var headerLength = 8;
    if (size == 1) {
      if (p + 16 > b.length) return;
      size = (_u32be(b, p + 8) << 32) | _u32be(b, p + 12);
      headerLength = 16;
    } else if (size == 0) {
      size = b.length - p;
    }
    if (size < headerLength || p + size > b.length) return;
    yield (type, Uint8List.sublistView(b, p + headerLength, p + size));
    p += size;
  }
}

Uint8List? _child(Uint8List b, String type) {
  for (final (t, content) in _atoms(b)) {
    if (t == type) return content;
  }
  return null;
}

/// The iTunes-style tags in an MP4 "moov" atom's content
/// (moov/udta/meta/ilst).
MusicTags parseMp4Moov(Uint8List moov) {
  final udta = _child(moov, 'udta');
  var meta = udta == null ? null : _child(udta, 'meta');
  // "meta" is a full atom (version and flags first) - except in some
  // QuickTime files.
  meta ??= _child(moov, 'meta');
  if (meta == null) return MusicTags.empty;
  if (meta.length >= 8 && _ascii(meta, 4, 4) != 'hdlr' && _ascii(meta, 4, 4) != 'ilst') {
    meta = Uint8List.sublistView(meta, 4);
  }
  final ilst = _child(meta, 'ilst');
  if (ilst == null) return MusicTags.empty;
  final values = <String, String>{};
  int? track;
  Uint8List? cover;
  for (final (type, item) in _atoms(ilst)) {
    final data = _child(item, 'data');
    if (data == null || data.length < 8) continue;
    final kind = _u32be(data, 0) & 0xFFFFFF;
    final payload = Uint8List.sublistView(data, 8);
    if (type == 'covr') {
      if (cover == null && payload.isNotEmpty) cover = Uint8List.fromList(payload);
    } else if (type == 'trkn') {
      if (payload.length >= 4) track = (payload[2] << 8) | payload[3];
    } else if (kind == 1) {
      values[type] = utf8.decode(payload, allowMalformed: true);
    }
  }
  return MusicTags(
    title: _clean(values['©nam']),
    artist: _clean(values['©ART']),
    album: _clean(values['©alb']),
    albumArtist: _clean(values['aART']),
    trackNumber: track == 0 ? null : track,
    year: _parseYear(values['©day']),
    cover: cover,
  );
}
