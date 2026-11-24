import 'dart:convert';
import 'dart:typed_data';

/// Reads [length] bytes at [offset] of a disc image (fewer at its end).
typedef DiscRead = Future<Uint8List> Function(int offset, int length);

/// A file inside a disc image: where its bytes lie in the image.
class DiscFile {
  const DiscFile(this.name, this.size, this.extents);

  /// As on the disc, upper case for ISO 9660 (without ";1").
  final String name;
  final int size;

  /// (offset in the image, length) - one for a file in one piece, as DVD
  /// files always are.
  final List<({int offset, int length})> extents;

  @override
  String toString() => 'DiscFile($name, $size, $extents)';
}

const discSector = 2048;

/// The files in [folder] (e.g. "VIDEO_TS") of a DVD image (.iso), found by
/// reading only the image's directories: ISO 9660 first (DVD images carry
/// both file systems - the "UDF bridge"), UDF (1.02) for images without.
/// Null if neither has the folder (or it's no disc image).
Future<List<DiscFile>?> readDiscFolder(DiscRead read, String folder) async {
  final wanted = folder.toUpperCase();
  try {
    final files = await _Iso9660(read).folder(wanted);
    if (files != null) return files;
  } on FormatException {
    // No (usable) ISO 9660 - UDF.
  }
  try {
    return await _Udf(read).folder(wanted);
  } on FormatException {
    return null;
  }
}

int _u16le(Uint8List b, int o) => b[o] | b[o + 1] << 8;
int _u32le(Uint8List b, int o) => b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;

Future<Uint8List> _readExactly(DiscRead read, int offset, int length) async {
  final bytes = await read(offset, length);
  if (bytes.length < length) throw const FormatException('disc image too short');
  return bytes;
}

// --- ISO 9660 ---

class _Iso9660 {
  _Iso9660(this._read);

  final DiscRead _read;

  Future<List<DiscFile>?> folder(String wanted) async {
    // Volume descriptors from sector 16 on; the primary one is type 1.
    Uint8List? pvd;
    for (var sector = 16; sector < 32; sector++) {
      final d = await _readExactly(_read, sector * discSector, discSector);
      if (ascii.decode(d.sublist(1, 6), allowInvalid: true) != 'CD001') throw const FormatException('no ISO 9660');
      if (d[0] == 1) {
        pvd = d;
        break;
      }
      if (d[0] == 255) break;
    }
    if (pvd == null) throw const FormatException('no primary volume descriptor');
    final blockSize = _u16le(pvd, 128);
    if (blockSize == 0) throw const FormatException('block size 0');
    final root = _record(pvd, 156, blockSize);
    if (root == null) throw const FormatException('no root');
    final top = await _list(root.$2, root.$3, blockSize);
    final dir = top.where((e) => e.dir && e.name == wanted).firstOrNull;
    if (dir == null) return null;
    return [
      for (final e in await _list(dir.offset, dir.size, blockSize))
        if (!e.dir) DiscFile(e.name, e.size, [(offset: e.offset, length: e.size)]),
    ];
  }

  /// The directory record at [at]: (name, extent offset in bytes, size).
  static (String, int, int, bool)? _record(Uint8List b, int at, int blockSize) {
    final length = b[at];
    if (length < 34 || at + length > b.length) return null;
    final extent = _u32le(b, at + 2) * blockSize;
    final size = _u32le(b, at + 10);
    final flags = b[at + 25];
    final nameLength = b[at + 32];
    if (at + 33 + nameLength > b.length) return null;
    var name = latin1.decode(b.sublist(at + 33, at + 33 + nameLength));
    final version = name.indexOf(';');
    if (version >= 0) name = name.substring(0, version);
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);
    return (name.toUpperCase(), extent, size, flags & 2 != 0);
  }

  Future<List<({String name, int offset, int size, bool dir})>> _list(int offset, int size, int blockSize) async {
    if (size <= 0 || size > 1 << 20) throw const FormatException('odd directory size');
    final b = await _readExactly(_read, offset, size);
    final entries = <({String name, int offset, int size, bool dir})>[];
    var at = 0;
    while (at < b.length) {
      final length = b[at];
      if (length == 0) {
        // Records don't cross sectors - on to the next one.
        at = (at ~/ blockSize + 1) * blockSize;
        continue;
      }
      final record = _record(b, at, blockSize);
      if (record == null) break;
      final nameLength = b[at + 32];
      // "\0" and "\1": the folder itself and its parent.
      final self = nameLength == 1 && b[at + 33] <= 1;
      if (!self) entries.add((name: record.$1, offset: record.$2, size: record.$3, dir: record.$4));
      at += length;
    }
    return entries;
  }
}

// --- UDF ---

class _Udf {
  _Udf(this._read);

  final DiscRead _read;
  int _partitionStart = 0;

  Future<Uint8List> _sector(int sector, [int count = 1]) =>
      _readExactly(_read, sector * discSector, count * discSector);

  static int _tag(Uint8List b, int at) => _u16le(b, at);

  Future<List<DiscFile>?> folder(String wanted) async {
    // Anchor volume descriptor pointer: sector 256.
    final anchor = await _sector(256);
    if (_tag(anchor, 0) != 2) throw const FormatException('no UDF anchor');
    final vdsLength = _u32le(anchor, 16);
    final vdsStart = _u32le(anchor, 20);
    final count = (vdsLength ~/ discSector).clamp(1, 32);
    final vds = await _sector(vdsStart, count);
    int? partitionStart;
    int? fsdBlock;
    for (var i = 0; i < count; i++) {
      final at = i * discSector;
      switch (_tag(vds, at)) {
        case 5: // Partition descriptor.
          partitionStart ??= _u32le(vds, at + 188);
        case 6: // Logical volume descriptor: where the file set is.
          fsdBlock ??= _u32le(vds, at + 252);
        case 8: // Terminator.
          break;
      }
    }
    if (partitionStart == null || fsdBlock == null) throw const FormatException('no UDF partition');
    _partitionStart = partitionStart;
    final fsd = await _sector(_partitionStart + fsdBlock);
    if (_tag(fsd, 0) != 256) throw const FormatException('no UDF file set');
    final rootIcb = _u32le(fsd, 404);
    final root = await _entry(rootIcb);
    final top = await _directory(root);
    final dir = top.where((e) => e.dir && e.name.toUpperCase() == wanted).firstOrNull;
    if (dir == null) return null;
    final files = <DiscFile>[];
    for (final e in await _directory(await _entry(dir.icb))) {
      if (e.dir) continue;
      final entry = await _entry(e.icb);
      files.add(DiscFile(e.name.toUpperCase(), entry.size, entry.extents));
    }
    return files;
  }

  /// A file entry (tag 261) or extended file entry (266) in logical block
  /// [block]: size and where its data lies.
  Future<({int size, List<({int offset, int length})> extents, Uint8List? embedded})> _entry(int block) async {
    final b = await _sector(_partitionStart + block);
    final tag = _tag(b, 0);
    if (tag != 261 && tag != 266) throw FormatException('no UDF file entry ($tag)');
    final allocation = _u16le(b, 34) & 7;
    final size = _u32le(b, 56) + _u32le(b, 60) * 0x100000000;
    final (eaLength, adLength, base) = tag == 261 ? (_u32le(b, 168), _u32le(b, 172), 176) : (_u32le(b, 208), _u32le(b, 212), 216);
    final start = base + eaLength;
    if (start + adLength > b.length) throw const FormatException('UDF descriptors too long');
    if (allocation == 3) {
      return (size: size, extents: const <({int offset, int length})>[], embedded: b.sublist(start, start + adLength));
    }
    final step = allocation == 0 ? 8 : 16; // short_ad / long_ad
    if (allocation > 1) throw const FormatException('UDF allocation type');
    final extents = <({int offset, int length})>[];
    var left = size;
    for (var at = start; at + step <= start + adLength && left > 0; at += step) {
      final length = _u32le(b, at) & 0x3FFFFFFF;
      final type = _u32le(b, at) >>> 30;
      final position = _u32le(b, at + 4);
      if (length == 0) break;
      // Type 3: the next descriptors elsewhere - not on DVDs.
      if (type == 3) break;
      final part = length < left ? length : left;
      extents.add((offset: (_partitionStart + position) * discSector, length: part));
      left -= part;
    }
    return (size: size, extents: extents, embedded: null);
  }

  Future<List<({String name, int icb, bool dir})>> _directory(
    ({int size, List<({int offset, int length})> extents, Uint8List? embedded}) entry,
  ) async {
    if (entry.size > 1 << 20) throw const FormatException('odd UDF directory size');
    final Uint8List b;
    if (entry.embedded != null) {
      b = entry.embedded!;
    } else {
      final builder = BytesBuilder(copy: false);
      for (final e in entry.extents) {
        builder.add(await _readExactly(_read, e.offset, e.length));
      }
      b = builder.takeBytes();
    }
    final entries = <({String name, int icb, bool dir})>[];
    var at = 0;
    while (at + 38 <= b.length) {
      if (_tag(b, at) != 257) break;
      final characteristics = b[at + 18];
      final nameLength = b[at + 19];
      final icb = _u32le(b, at + 24);
      final implementationLength = _u16le(b, at + 36);
      final nameAt = at + 38 + implementationLength;
      if (nameAt + nameLength > b.length) break;
      final isParent = characteristics & 8 != 0;
      final isDeleted = characteristics & 4 != 0;
      if (!isParent && !isDeleted && nameLength > 0) {
        entries.add((
          name: _decodeName(b.sublist(nameAt, nameAt + nameLength)),
          icb: icb,
          dir: characteristics & 2 != 0,
        ));
      }
      at += (38 + implementationLength + nameLength + 3) & ~3;
    }
    return entries;
  }

  /// OSTA compressed unicode: 8 = one byte per character, 16 = UTF-16BE.
  static String _decodeName(Uint8List b) {
    if (b.isEmpty) return '';
    if (b[0] == 16) {
      final codes = <int>[for (var i = 1; i + 1 < b.length; i += 2) b[i] << 8 | b[i + 1]];
      return String.fromCharCodes(codes);
    }
    return latin1.decode(b.sublist(1));
  }
}
