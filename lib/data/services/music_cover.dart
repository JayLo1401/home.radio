import 'dart:typed_data';
import 'dart:ui' as ui;

/// Covers are kept and shown at most this big (pixels, longer side).
const musicCoverMaxSize = 512;

/// Below this a cover is kept as it is (small enough already).
const _keepBelowBytes = 160 * 1024;

/// [bytes] (JPEG/PNG/...) scaled down to [maxSize] on its longer side, as
/// PNG - decoded and encoded by the engine on its own threads, not on the
/// UI isolate. Embedded covers are often 1500-3000 px and several MB:
/// shown, kept in caches and above all handed to Android's media
/// notification at full size they cost a weak box seconds (audio_service
/// decodes the file on the main thread and posts the bitmap with every
/// notification update). Null if it can't be decoded.
Future<Uint8List?> shrinkMusicCover(Uint8List bytes, {int maxSize = musicCoverMaxSize}) async {
  ui.Codec? codec;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    if (w <= 0 || h <= 0) {
      descriptor.dispose();
      buffer.dispose();
      return null;
    }
    if (w <= maxSize && h <= maxSize && bytes.length <= _keepBelowBytes) {
      descriptor.dispose();
      buffer.dispose();
      return bytes;
    }
    final scale = maxSize / (w > h ? w : h);
    codec = await descriptor.instantiateCodec(
      targetWidth: scale < 1 ? (w * scale).round() : w,
      targetHeight: scale < 1 ? (h * scale).round() : h,
    );
    buffer.dispose();
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    descriptor.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
  }
}
