import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

/// One chunked numeric array found in an HDF5 file.
class Hdf5Array {
  Hdf5Array({required this.shape, required this.isFloat, required this.elementSize, required this.data});

  final List<int> shape;
  final bool isFloat;
  final int elementSize;
  final ByteData data; // little endian, already decompressed

  int get length => shape.fold(1, (a, b) => a * b);

  double valueAt(int index) {
    final o = index * elementSize;
    if (isFloat) return elementSize == 4 ? data.getFloat32(o, Endian.little) : data.getFloat64(o, Endian.little);
    switch (elementSize) {
      case 1:
        return data.getInt8(o).toDouble();
      case 2:
        return data.getInt16(o, Endian.little).toDouble();
      case 4:
        return data.getInt32(o, Endian.little).toDouble();
      default:
        return data.getInt64(o, Endian.little).toDouble();
    }
  }
}

/// Minimal reader for the netCDF-4 files GeoSphere's Dataset API returns:
/// superblock v2, version-2 object headers, every variable stored as a single
/// chunk behind a version-1 B-tree, filtered with shuffle + deflate.
///
/// Group/link structures (fractal heaps) are deliberately not parsed - the
/// datasets are found by scanning for their object headers and told apart by
/// rank and type, which is why callers request one parameter per file.
class Hdf5Lite {
  Hdf5Lite(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;

  int _u(int offset, int size) {
    switch (size) {
      case 1:
        return _view.getUint8(offset);
      case 2:
        return _view.getUint16(offset, Endian.little);
      case 4:
        return _view.getUint32(offset, Endian.little);
      default:
        return _view.getUint64(offset, Endian.little);
    }
  }

  bool _sig(int offset, String s) {
    if (offset < 0 || offset + 4 > _bytes.length) return false;
    for (var i = 0; i < 4; i++) {
      if (_bytes[offset + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// All chunked datasets in the file, in file order.
  List<Hdf5Array> readArrays() {
    if (_bytes.length < 48 || _bytes[8] < 2) {
      throw const FormatException('unsupported HDF5 superblock');
    }
    final result = <Hdf5Array>[];
    for (var i = 0; i + 4 <= _bytes.length; i++) {
      if (_bytes[i] != 0x4F || !_sig(i, 'OHDR')) continue;
      final array = _tryDataset(i);
      if (array != null) result.add(array);
    }
    return result;
  }

  /// Messages (type, data offset, size) of a version-2 object header,
  /// following continuation blocks.
  List<(int, int, int)> _messages(int addr) {
    final out = <(int, int, int)>[];
    if (_bytes[addr + 4] != 2) return out;
    final flags = _bytes[addr + 5];
    var p = addr + 6;
    if (flags & 0x20 != 0) p += 16;
    if (flags & 0x10 != 0) p += 4;
    final sizeField = const [1, 2, 4, 8][flags & 3];
    final chunkSize = _u(p, sizeField);
    p += sizeField;
    final pending = <(int, int)>[(p, p + chunkSize)];
    final creationOrder = flags & 0x04 != 0;
    var guard = 0;
    while (pending.isNotEmpty && guard++ < 64) {
      final (start, end) = pending.removeAt(0);
      var q = start;
      while (q + 4 <= end) {
        final type = _bytes[q];
        final size = _u(q + 1, 2);
        q += 4;
        if (creationOrder) q += 2;
        if (q + size > end) break;
        if (type == 0x10) {
          // continuation: address + length of an "OCHK" block
          final ca = _u(q, 8);
          final cl = _u(q + 8, 8);
          if (_sig(ca, 'OCHK') && ca + cl <= _bytes.length) pending.add((ca + 4, ca + cl - 4));
        } else {
          out.add((type, q, size));
        }
        q += size;
      }
    }
    return out;
  }

  Hdf5Array? _tryDataset(int addr) {
    try {
      List<int>? chunkDims;
      int? btree;
      bool? isFloat;
      var filters = <int>[];
      for (final (type, p, size) in _messages(addr)) {
        switch (type) {
          case 0x03: // datatype
            final cls = _bytes[p] & 0x0F;
            if (cls == 0) isFloat = false;
            if (cls == 1) isFloat = true;
          case 0x08: // data layout, version 3, chunked
            if (_bytes[p] == 3 && _bytes[p + 1] == 2) {
              final dims = _bytes[p + 2];
              btree = _u(p + 3, 8);
              chunkDims = [for (var d = 0; d < dims; d++) _u(p + 11 + 4 * d, 4)];
            }
          case 0x0B: // filter pipeline, version 2
            if (_bytes[p] == 2) {
              final n = _bytes[p + 1];
              var q = p + 2;
              for (var f = 0; f < n; f++) {
                final id = _u(q, 2);
                if (id >= 256) return null; // third-party filter (has a name field) - not used here
                final values = _u(q + 4, 2);
                q += 6 + values * 4;
                filters.add(id);
              }
            }
        }
        if (size < 0) return null;
      }
      if (chunkDims == null || btree == null || isFloat == null) return null;
      if (!_sig(btree, 'TREE') || _bytes[btree + 4] != 1 || _bytes[btree + 5] != 0) return null;
      if (_u(btree + 6, 2) != 1) return null; // single chunk expected
      final keyStart = btree + 8 + 16;
      final chunkBytes = _u(keyStart, 4);
      final childAddr = _u(keyStart + 8 + 8 * chunkDims.length, 8);
      final elementSize = chunkDims.last;
      final shape = chunkDims.sublist(0, chunkDims.length - 1);

      Uint8List raw = Uint8List.sublistView(_bytes, childAddr, childAddr + chunkBytes);
      // Filters were applied in order on write; undo them in reverse.
      for (final id in filters.reversed) {
        if (id == 1) {
          raw = Uint8List.fromList(ZLibDecoder().convert(raw));
        } else if (id == 2) {
          raw = _unshuffle(raw, elementSize);
        } else {
          return null; // unknown filter
        }
      }
      final count = shape.fold(1, (a, b) => a * b);
      if (raw.length < count * elementSize) return null;
      return Hdf5Array(shape: shape, isFloat: isFloat, elementSize: elementSize, data: ByteData.sublistView(raw));
    } catch (_) {
      return null;
    }
  }

  static Uint8List _unshuffle(Uint8List src, int size) {
    if (size <= 1) return src;
    final n = src.length ~/ size;
    final out = Uint8List(src.length);
    for (var b = 0; b < size; b++) {
      final base = b * n;
      for (var i = 0; i < n; i++) {
        out[i * size + b] = src[base + i];
      }
    }
    return out;
  }
}
