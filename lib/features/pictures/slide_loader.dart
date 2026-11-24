import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../data/services/nas_picture_cache.dart';
import '../../data/services/nas_service.dart';
import '../../data/services/picture_library.dart';

/// A picture of the slideshow, decoded at (at most) screen size - never a
/// 24-megapixel photo whole in memory - and, for the blurred background, a
/// tiny copy of it.
class SlideImage {
  SlideImage(this.entry, this.image, this.cover);

  final NasEntry entry;
  final ui.Image image;

  /// About 32 pixels wide, already blurred - shown stretched over the
  /// screen it's a soft background for next to nothing (no blur filter
  /// each frame, no second big picture in memory).
  final ui.Image? cover;

  void dispose() {
    image.dispose();
    cover?.dispose();
  }
}

/// The largest size a slide is decoded at for a screen of [physical]
/// pixels: the screen itself, but no more than 1920x1080 (portrait
/// 1080x1920) - a 4K box would need four times the memory for little gain.
({int width, int height}) slideBox(ui.Size physical) {
  var w = physical.width.round(), h = physical.height.round();
  if (w <= 0 || h <= 0) (w, h) = (1920, 1080);
  final scale = min(1.0, min(1920 / max(w, h), 1080 / min(w, h)));
  return (width: max(1, (w * scale).round()), height: max(1, (h * scale).round()));
}

/// Reads [entry] from the NAS (one more try when the connection broke) and
/// decodes it to fit [box]. Null if it isn't a usable picture (too big,
/// broken, unreadable) - the slideshow skips it.
Future<SlideImage?> loadSlide(
  NasClient client,
  NasEntry entry, {
  required ({int width, int height}) box,
  required bool cover,
}) async {
  if ((entry.size ?? 0) > NasPictureCache.maxFileBytes) return null;
  Uint8List bytes;
  try {
    bytes = await client.read(entry.path, maxBytes: NasPictureCache.maxFileBytes);
  } on NasException catch (e) {
    debugPrint('slideshow ${entry.path}: $e - once more');
    try {
      bytes = await client.read(entry.path, maxBytes: NasPictureCache.maxFileBytes);
    } on NasException catch (e) {
      debugPrint('slideshow ${entry.path}: $e - skipped');
      return null;
    }
  }
  return decodeSlide(entry, bytes, box: box, cover: cover);
}

/// [bytes] decoded by the engine (off the UI thread) straight at the size it
/// is shown at; GIFs give their first frame.
Future<SlideImage?> decodeSlide(
  NasEntry entry,
  Uint8List bytes, {
  required ({int width, int height}) box,
  required bool cover,
}) async {
  var tooBig = false;
  ui.Codec? codec;
  ui.Image? image;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // Disposes the buffer.
    codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      if (w * h > NasPictureCache.maxPixels) {
        tooBig = true;
        return ui.TargetImageSize(width: 1, height: 1);
      }
      final size = fitWithin(w, h, box.width, box.height);
      return ui.TargetImageSize(width: size.width, height: size.height);
    });
    if (tooBig) {
      debugPrint('slideshow ${entry.path}: too many pixels - skipped');
      return null;
    }
    image = (await codec.getNextFrame()).image;
    final small = cover ? await _coverOf(image) : null;
    final slide = SlideImage(entry, image, small);
    image = null;
    return slide;
  } catch (e) {
    debugPrint('slideshow ${entry.path}: not a usable picture ($e)');
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// A tiny, blurred copy of [image] (drawn by the GPU into 32 pixels).
Future<ui.Image?> _coverOf(ui.Image image) async {
  const width = 32;
  final height = max(1, (width * image.height / image.width).round());
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()
      ..filterQuality = ui.FilterQuality.medium
      ..imageFilter = ui.ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5, tileMode: ui.TileMode.clamp),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } catch (e) {
    debugPrint('slideshow: no background ($e)');
    return null;
  } finally {
    picture.dispose();
  }
}
