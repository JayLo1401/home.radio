import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart' show brandGreen, brandGreenDark;

/// Spectrum and waterfall of the receiver window: the spectrum with dB and
/// MHz scales on top, below it the history as a waterfall in the app's own
/// green (near black = noise, through the brand green to mint and white =
/// strong).
/// The colour range follows the noise floor by itself. The listened
/// channel is marked amber; tapping picks the frequency there.
///
/// A new row is added whenever [bins] is a new list (one per nbSpectrum
/// event, ~5 per second).
class WaterfallView extends StatefulWidget {
  final List<double> bins;
  final int centerHz;
  final int spanHz;
  final int markHz;
  final void Function(int freqHz)? onTapFreq;

  /// Only this part of the window is shown (e.g. just the CB band when the
  /// window is wider) - null shows the whole window.
  final ({int lowHz, int highHz})? view;

  const WaterfallView({
    super.key,
    required this.bins,
    required this.centerHz,
    required this.spanHz,
    required this.markHz,
    this.onTapFreq,
    this.view,
  });

  @override
  State<WaterfallView> createState() => _WaterfallViewState();
}

class _WaterfallViewState extends State<WaterfallView> {
  static const _rows = 180;

  // The history as RGBA pixels, newest row on top; turned into an image
  // after each row (a few KB - cheap at 5 rows per second).
  Uint8List? _pixels;
  int _width = 0;
  ui.Image? _image;
  int _generation = 0;

  // Smoothed colour range (dB).
  double? _floorDb;
  double? _peakDb;

  @override
  void didUpdateWidget(covariant WaterfallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bins, widget.bins) && widget.bins.isNotEmpty) _addRow(widget.bins);
    // A moved window makes the old history meaningless.
    if (oldWidget.centerHz != widget.centerHz || oldWidget.spanHz != widget.spanHz) _pixels = null;
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _addRow(List<double> bins) {
    final w = bins.length;
    if (_pixels == null || _width != w) {
      _width = w;
      _pixels = Uint8List(w * _rows * 4);
    }
    // Range: noise floor (25th percentile) to well above it, smoothed so the
    // colours don't flicker.
    final sorted = [...bins]..sort();
    final floor = sorted[sorted.length ~/ 4];
    final peak = sorted.last;
    _floorDb = _floorDb == null ? floor : _floorDb! * 0.9 + floor * 0.1;
    _peakDb = _peakDb == null ? peak : (peak > _peakDb! ? peak : _peakDb! * 0.98 + peak * 0.02);
    final lo = _floorDb! - 3;
    final range = ((_peakDb! - lo).clamp(20.0, 70.0));

    final px = _pixels!;
    // Scroll down one row, write the new row on top.
    px.setRange(w * 4, px.length, px, 0);
    for (var x = 0; x < w; x++) {
      final c = _colour(((bins[x] - lo) / range).clamp(0.0, 1.0));
      final o = x * 4;
      px[o] = (c.r * 255).round();
      px[o + 1] = (c.g * 255).round();
      px[o + 2] = (c.b * 255).round();
      px[o + 3] = 255;
    }
    final generation = ++_generation;
    ui.decodeImageFromPixels(px, w, _rows, ui.PixelFormat.rgba8888, (image) {
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      final old = _image;
      setState(() => _image = image);
      // Freed right away (a picture keeps its own reference) - not left
      // to pile up as GPU textures on a TV box running for hours.
      old?.dispose();
    });
  }

  /// Noise stays near black to dark green (the app's colour), signals
  /// stand out in amber to light yellow and white.
  static Color _colour(double t) {
    const stops = [
      (0.0, Color(0xFF040806)),
      (0.35, brandGreenDark),
      (0.55, Color(0xFFFFB300)),
      (0.8, Color(0xFFFFE082)),
      (1.0, Colors.white),
    ];
    for (var i = 1; i < stops.length; i++) {
      final (t1, c1) = stops[i];
      if (t <= t1) {
        final (t0, c0) = stops[i - 1];
        return Color.lerp(c0, c1, (t - t0) / (t1 - t0))!;
      }
    }
    return stops.last.$2;
  }

  /// The shown frequency range: [WaterfallView.view] within the window,
  /// else the whole window.
  (double, double) get _range {
    final low = widget.centerHz - widget.spanHz / 2, high = widget.centerHz + widget.spanHz / 2;
    final v = widget.view;
    if (v == null) return (low, high);
    final lo = v.lowHz < low ? low : v.lowHz.toDouble(), hi = v.highHz > high ? high : v.highHz.toDouble();
    return hi > lo ? (lo, hi) : (low, high);
  }

  void _tap(Offset local, double width) {
    final onTap = widget.onTapFreq;
    if (onTap == null || widget.spanHz <= 0) return;
    final (lo, hi) = _range;
    onTap((lo + local.dx / width * (hi - lo)).round());
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          onTapUp: (d) =>
              _tap(d.localPosition - const Offset(_SpectrumPainter.axisWidth, 0), width - _SpectrumPainter.axisWidth),
          child: Column(
            children: [
              SizedBox(
                height: 110,
                width: width,
                child: CustomPaint(
                  painter: _SpectrumPainter(
                    bins: widget.bins,
                    centerHz: widget.centerHz,
                    spanHz: widget.spanHz,
                    markHz: widget.markHz,
                    range: _range,
                  ),
                ),
              ),
              SizedBox(
                height: 150,
                width: width,
                child: CustomPaint(
                  painter: _WaterfallPainter(
                    image: _image,
                    centerHz: widget.centerHz,
                    spanHz: widget.spanHz,
                    markHz: widget.markHz,
                    range: _range,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

double _xOf(num hz, (double, double) range, double left, double width) =>
    left + (hz - range.$1) / (range.$2 - range.$1) * width;

/// Bin index range covering [range] within the window.
(int, int) _binRange(int count, int centerHz, int spanHz, (double, double) range) {
  final low = centerHz - spanHz / 2;
  final a = ((range.$1 - low) / spanHz * (count - 1)).floor().clamp(0, count - 1);
  final b = ((range.$2 - low) / spanHz * (count - 1)).ceil().clamp(0, count - 1);
  return (a, b);
}

class _SpectrumPainter extends CustomPainter {
  static const axisWidth = 40.0;
  static const _axisHeight = 20.0;

  final List<double> bins;
  final int centerHz;
  final int spanHz;
  final int markHz;
  final (double, double) range;

  _SpectrumPainter({
    required this.bins,
    required this.centerHz,
    required this.spanHz,
    required this.markHz,
    required this.range,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(axisWidth, 0, size.width, size.height - _axisHeight);
    canvas.drawRect(plot, Paint()..color = Colors.black);
    if (bins.length < 2 || spanHz <= 0) return;
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    const label = TextStyle(color: Colors.white60, fontSize: 10);

    final (b0, b1) = _binRange(bins.length, centerHz, spanHz, range);
    final shown = bins.sublist(b0, b1 + 1);
    if (shown.length < 2) return;
    // dB scale: whole 10 dB steps around the data.
    final lo = (shown.reduce((a, b) => a < b ? a : b) / 10).floor() * 10.0 - 10;
    final hi = (shown.reduce((a, b) => a > b ? a : b) / 10).ceil() * 10.0 + 10;
    double y(double db) => plot.bottom - (db - lo) / (hi - lo) * plot.height;
    final step = (hi - lo) > 80 ? 20.0 : 10.0;
    for (var db = lo; db <= hi; db += step) {
      canvas.drawLine(Offset(plot.left, y(db)), Offset(plot.right, y(db)), grid);
      _text(canvas, db.round().toString(), Offset(2, y(db) - 6), label);
    }

    // MHz scale: nice steps across the shown range.
    final (low, high) = range;
    final shownSpan = high - low;
    final stepHz = shownSpan > 1500000 ? 200000 : (shownSpan > 600000 ? 100000 : 50000);
    for (var f = (low / stepHz).ceil() * stepHz; f <= high; f += stepHz) {
      final x = _xOf(f, range, plot.left, plot.width);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _text(canvas, '${(f / 1e6).toStringAsFixed(stepHz < 100000 ? 2 : 1)}M', Offset(x - 16, plot.bottom + 3), label);
    }

    // The spectrum, filled underneath.
    final line = Path();
    final windowLow = centerHz - spanHz / 2;
    for (var i = b0; i <= b1; i++) {
      final x = _xOf(windowLow + i / (bins.length - 1) * spanHz, range, plot.left, plot.width);
      i == b0 ? line.moveTo(x, y(bins[i])) : line.lineTo(x, y(bins[i]));
    }
    final fill = Path.from(line)
      ..lineTo(plot.right, plot.bottom)
      ..lineTo(plot.left, plot.bottom)
      ..close();
    canvas.drawPath(fill, Paint()..color = brandGreen.withValues(alpha: 0.25));
    canvas.drawPath(
      line,
      Paint()
        ..color = const Color(0xFF9BE8B4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final mx = _xOf(markHz, range, plot.left, plot.width);
    if (mx >= plot.left && mx <= plot.right) {
      canvas.drawLine(Offset(mx, plot.top), Offset(mx, plot.bottom), Paint()..color = Colors.white);
    }
  }

  static void _text(Canvas canvas, String text, Offset at, TextStyle style) {
    (TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout()).paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      !identical(old.bins, bins) ||
      old.markHz != markHz ||
      old.centerHz != centerHz ||
      old.spanHz != spanHz ||
      old.range != range;
}

class _WaterfallPainter extends CustomPainter {
  final ui.Image? image;
  final int centerHz;
  final int spanHz;
  final int markHz;
  final (double, double) range;

  _WaterfallPainter({
    required this.image,
    required this.centerHz,
    required this.spanHz,
    required this.markHz,
    required this.range,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const left = _SpectrumPainter.axisWidth;
    final area = Rect.fromLTRB(left, 0, size.width, size.height);
    canvas.drawRect(area, Paint()..color = const Color(0xFF040806));
    final img = image;
    if (img != null && spanHz > 0) {
      // Just the shown part of each row.
      final low = centerHz - spanHz / 2;
      final x0 = (range.$1 - low) / spanHz * img.width, x1 = (range.$2 - low) / spanHz * img.width;
      canvas.drawImageRect(
        img,
        Rect.fromLTRB(x0, 0, x1, img.height.toDouble()),
        area,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    if (spanHz > 0) {
      final mx = _xOf(markHz, range, left, area.width);
      if (mx >= left && mx <= size.width) {
        canvas.drawLine(Offset(mx, 0), Offset(mx, size.height), Paint()..color = Colors.white.withValues(alpha: 0.7));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WaterfallPainter old) =>
      old.image != image ||
      old.markHz != markHz ||
      old.centerHz != centerHz ||
      old.spanHz != spanHz ||
      old.range != range;
}
