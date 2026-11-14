import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart' show brandGreen, brandGreenDark;

/// A band plan part drawn under the spectrum (see BandSegment).
typedef WaterfallSegment = ({int lowHz, int highHz, String name, Color color});

/// A channel's activity: [heat] 1 = signal now, fading to 0 after it.
typedef WaterfallActivity = ({int hz, double heat});

/// Spectrum and waterfall of the receiver window, SDR style: the spectrum
/// with dB and MHz scales and the band plan underneath, below it the history
/// as a waterfall (dark blue = noise, through cyan and yellow to red =
/// strong). The colour and dB ranges follow the noise floor by themselves,
/// smoothed so they don't jump. The listened frequency is marked with its
/// filter width; tapping picks the frequency there.
///
/// A new row is added whenever [bins] is a new list (one per nbSpectrum
/// event, ~20 per second).
class WaterfallView extends StatefulWidget {
  final List<double> bins;
  final int centerHz;
  final int spanHz;
  final int markHz;
  final void Function(int freqHz)? onTapFreq;

  /// Only this part of the window is shown (e.g. just the CB band when the
  /// window is wider) - null shows the whole window.
  final ({int lowHz, int highHz})? view;

  /// Band plan parts, shown as a coloured strip with their names.
  final List<WaterfallSegment> segments;

  /// Channels with a signal now or lately, shown in the strip under the
  /// waterfall; [channelsHz] is the raster drawn there as faint ticks.
  final List<WaterfallActivity> activity;
  final List<int> channelsHz;

  /// Width of the listened channel (filter), shown as a shaded band; for
  /// [upperSideband]/[lowerSideband] on that side of [markHz] only.
  final int bandwidthHz;
  final bool upperSideband;
  final bool lowerSideband;

  const WaterfallView({
    super.key,
    required this.bins,
    required this.centerHz,
    required this.spanHz,
    required this.markHz,
    this.onTapFreq,
    this.view,
    this.segments = const [],
    this.activity = const [],
    this.channelsHz = const [],
    this.bandwidthHz = 0,
    this.upperSideband = false,
    this.lowerSideband = false,
  });

  @override
  State<WaterfallView> createState() => _WaterfallViewState();
}

class _WaterfallViewState extends State<WaterfallView> {
  static const _stripHeight = 26.0;

  // One row per screen pixel of the waterfall's height (see build), at
  // ~20 rows per second; capped so a TV box isn't swamped.
  static const _maxRows = 720;
  int _rows = 300;

  // t (0..1, 1024 steps) -> offset into [_lut], gamma applied: weak traces
  // still show, the noise around them stays dark.
  static final Int32List _gammaLut = Int32List.fromList([
    for (var i = 0; i < 1024; i++) (math.pow(i / 1023, 0.8) * 255).round() * 3,
  ]);

  // The palette as 256 RGB entries, built once.
  static final Uint8List _lut = () {
    final lut = Uint8List(256 * 3);
    for (var i = 0; i < 256; i++) {
      final c = _colour(i / 255);
      lut[i * 3] = (c.r * 255).round();
      lut[i * 3 + 1] = (c.g * 255).round();
      lut[i * 3 + 2] = (c.b * 255).round();
    }
    return lut;
  }();

  // The history as RGBA pixels in a ring: each new row goes one above the
  // last ([_head]), nothing is moved; the painter draws the ring from
  // [_head] down. Turned into an image after each row.
  Uint8List? _pixels;
  int _width = 0;
  int _head = 0;
  ui.Image? _image;
  int _imageHead = 0;
  int _generation = 0;
  bool _decoding = false;

  // Smoothed colour range (dB).
  double? _floorDb;
  double? _peakDb;

  // Smoothed dB scale of the spectrum.
  double? _scaleLo;
  double? _scaleHi;

  @override
  void didUpdateWidget(covariant WaterfallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A moved window makes the old history meaningless.
    if (oldWidget.centerHz != widget.centerHz || oldWidget.spanHz != widget.spanHz) _pixels = null;
    if (!identical(oldWidget.bins, widget.bins) && widget.bins.isNotEmpty) _addRow(widget.bins);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _addRow(List<double> bins) {
    final w = bins.length;
    if (_pixels == null || _width != w || _pixels!.length != w * _rows * 4) {
      _width = w;
      _pixels = Uint8List(w * _rows * 4);
      _head = 0;
    }
    // Range: noise floor (25th percentile) to well above it, smoothed so the
    // colours don't flicker.
    final sorted = [...bins]..sort();
    final floor = sorted[sorted.length ~/ 4];
    final peak = sorted.last;
    _floorDb = _floorDb == null ? floor : _floorDb! * 0.95 + floor * 0.05;
    _peakDb = _peakDb == null ? peak : (peak > _peakDb! ? peak : _peakDb! * 0.995 + peak * 0.005);
    // Colours start just above the noise floor - noise stays near black and
    // signals stand out.
    final lo = _floorDb! + 1;
    final range = ((_peakDb! - lo).clamp(20.0, 60.0));
    // Spectrum scale on whole 10 dB: noise near the bottom, room above for
    // signals. It only moves when the levels are clearly off (10 dB), so
    // the labels stay put.
    final wantLo = ((_floorDb! - 10) / 10).floor() * 10.0;
    final wantHi = wantLo + ((_peakDb! - wantLo + 10) / 10).ceil().clamp(5, 10) * 10.0;
    if (_scaleLo == null || (wantLo - _scaleLo!).abs() >= 10) _scaleLo = wantLo;
    if (_scaleHi == null || (wantHi - _scaleHi!).abs() >= 10 || _scaleHi! - _scaleLo! < 50) _scaleHi = wantHi;

    final px = _pixels!;
    _head = (_head - 1 + _rows) % _rows;
    final base = _head * w * 4;
    final scale = 1023 / range;
    for (var x = 0; x < w; x++) {
      final i = _gammaLut[((bins[x] - lo) * scale).round().clamp(0, 1023)];
      final o = base + x * 4;
      px[o] = _lut[i];
      px[o + 1] = _lut[i + 1];
      px[o + 2] = _lut[i + 2];
      px[o + 3] = 255;
    }
    // One image at a time: a slow device skips a frame rather than piling
    // up decodes (the rows themselves are never lost).
    if (_decoding) {
      setState(() {}); // the spectrum line still moves
      return;
    }
    _decoding = true;
    final generation = ++_generation;
    final head = _head;
    ui.decodeImageFromPixels(px, w, _rows, ui.PixelFormat.rgba8888, (image) {
      _decoding = false;
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      final old = _image;
      setState(() {
        _image = image;
        _imageHead = head;
      });
      // Freed right away (a picture keeps its own reference) - not left
      // to pile up as GPU textures on a TV box running for hours.
      old?.dispose();
    });
  }

  /// In the app's green: noise near black, weak signals dark to brand
  /// green, strong ones light green, yellow and white.
  static Color _colour(double t) {
    const stops = [
      (0.0, Color(0xFF000000)),
      (0.12, Color(0xFF031A0C)),
      (0.35, brandGreenDark),
      (0.55, brandGreen),
      (0.72, Color(0xFF9BE8B4)),
      (0.88, Color(0xFFFFE082)),
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

  /// The listened channel's passband (Hz), for the shading.
  (double, double)? get _passband {
    final bw = widget.bandwidthHz;
    if (bw <= 0) return null;
    final m = widget.markHz.toDouble();
    if (widget.upperSideband) return (m, m + bw);
    if (widget.lowerSideband) return (m - bw, m);
    return (m - bw / 2, m + bw / 2);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Given a height (the scanner page): the spectrum takes ~40 %, the
        // waterfall the rest. Else fixed sizes.
        final strip = widget.spanHz > 0 ? _stripHeight : 0.0;
        final double spectrumHeight, waterfallHeight;
        if (constraints.hasBoundedHeight) {
          final h = constraints.maxHeight;
          spectrumHeight = (h * 0.4).clamp(170.0, 340.0);
          waterfallHeight = (h - spectrumHeight - strip).clamp(60.0, double.infinity);
        } else {
          spectrumHeight = widget.segments.isEmpty ? 150 : 170;
          waterfallHeight = 220;
        }
        // As many rows as the waterfall has pixels (applied with the next
        // row; a new size starts a new history).
        final dpr = MediaQuery.devicePixelRatioOf(context);
        _rows = (waterfallHeight * dpr).round().clamp(120, _maxRows);
        return GestureDetector(
          onTapUp: (d) =>
              _tap(d.localPosition - const Offset(_SpectrumPainter.axisWidth, 0), width - _SpectrumPainter.axisWidth),
          child: Column(
            children: [
              SizedBox(
                height: spectrumHeight,
                width: width,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _SpectrumPainter(
                          bins: widget.bins,
                          centerHz: widget.centerHz,
                          spanHz: widget.spanHz,
                          markHz: widget.markHz,
                          range: _range,
                          dbLo: _scaleLo,
                          dbHi: _scaleHi,
                          hasSegments: widget.segments.isNotEmpty,
                          passband: _passband,
                        ),
                      ),
                    ),
                    // The band plan strip on its own layer: its labels are
                    // laid out only when the window moves, not with every
                    // spectrum line (amateur bands and the free scan have
                    // many parts).
                    if (widget.segments.isNotEmpty)
                      Positioned(
                        left: _SpectrumPainter.axisWidth,
                        right: 0,
                        bottom: _SpectrumPainter._axisHeight,
                        height: _SpectrumPainter._segmentHeight,
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _SegmentStripPainter(segments: widget.segments, range: _range),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                height: waterfallHeight,
                width: width,
                child: CustomPaint(
                  painter: _WaterfallPainter(
                    image: _image,
                    head: _imageHead,
                    centerHz: widget.centerHz,
                    spanHz: widget.spanHz,
                    markHz: widget.markHz,
                    range: _range,
                  ),
                ),
              ),
              if (widget.spanHz > 0)
                SizedBox(
                  height: _stripHeight,
                  width: width,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _ActivityPainter(
                        activity: widget.activity,
                        channelsHz: widget.channelsHz,
                        markHz: widget.markHz,
                        range: _range,
                      ),
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

/// The activity strip under the waterfall: a bar at every channel with a
/// signal, bright while it's on air and fading out afterwards - where there
/// is traffic, at a glance. Faint ticks show the channel raster when it's
/// coarse enough to see (CB, PMR, airband).
class _ActivityPainter extends CustomPainter {
  final List<WaterfallActivity> activity;
  final List<int> channelsHz;
  final int markHz;
  final (double, double) range;

  _ActivityPainter({required this.activity, required this.channelsHz, required this.markHz, required this.range});

  @override
  void paint(Canvas canvas, Size size) {
    const left = _SpectrumPainter.axisWidth;
    final width = size.width - left;
    final area = Rect.fromLTRB(left, 0, size.width, size.height);
    canvas.drawRect(area, Paint()..color = const Color(0xFF050807));
    if (width <= 0) return;
    canvas.save();
    canvas.clipRect(area);
    final (lo, hi) = range;
    final shown = channelsHz.where((hz) => hz >= lo && hz <= hi).length;
    final pitch = shown > 0 ? width / shown : width;
    if (pitch >= 6) {
      final tick = Paint()..color = Colors.white24;
      for (final hz in channelsHz) {
        final x = _xOf(hz, range, left, width);
        canvas.drawLine(Offset(x, size.height - 5), Offset(x, size.height), tick);
      }
    }
    // Wide enough to catch the eye, never wider than a channel.
    final barW = (pitch * 0.6).clamp(2.0, 14.0);
    for (final a in activity) {
      final x = _xOf(a.hz, range, left, width);
      final paint = Paint()
        ..color = Color.lerp(brandGreenDark, const Color(0xFFB9F6CA), a.heat)!.withValues(alpha: 0.3 + 0.7 * a.heat);
      final top = a.heat >= 1 ? 0.0 : 3.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(x - barW / 2, top, x + barW / 2, size.height), const Radius.circular(2)),
        paint,
      );
      // On air right now: a glow around it, like the tiles' flash.
      if (a.heat >= 1) {
        canvas.drawRect(
          Rect.fromLTRB(x - barW / 2 - 3, 0, x + barW / 2 + 3, size.height),
          Paint()
            ..color = const Color(0xFF69F0AE).withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }
    }
    final mx = _xOf(markHz, range, left, width);
    canvas.drawLine(Offset(mx, 0), Offset(mx, size.height), Paint()..color = Colors.redAccent.withValues(alpha: 0.6));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ActivityPainter old) =>
      !identical(old.activity, activity) ||
      !identical(old.channelsHz, channelsHz) ||
      old.markHz != markHz ||
      old.range != range;
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
  static const _segmentHeight = 20.0;

  final List<double> bins;
  final int centerHz;
  final int spanHz;
  final int markHz;
  final (double, double) range;
  final double? dbLo;
  final double? dbHi;
  final bool hasSegments;
  final (double, double)? passband;

  _SpectrumPainter({
    required this.bins,
    required this.centerHz,
    required this.spanHz,
    required this.markHz,
    required this.range,
    required this.dbLo,
    required this.dbHi,
    required this.hasSegments,
    required this.passband,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Room for the band plan strip (see _SegmentStripPainter).
    final segH = hasSegments ? _segmentHeight : 0.0;
    final plot = Rect.fromLTRB(axisWidth, 0, size.width, size.height - _axisHeight - segH);
    canvas.drawRect(plot, Paint()..color = const Color(0xFF050807));
    if (bins.length < 2 || spanHz <= 0 || dbLo == null || dbHi == null) return;
    final grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    const label = TextStyle(color: Colors.white70, fontSize: 11);

    final (b0, b1) = _binRange(bins.length, centerHz, spanHz, range);
    if (b1 - b0 < 1) return;
    final lo = dbLo!, hi = dbHi!;
    double y(double db) => (plot.bottom - (db - lo) / (hi - lo) * plot.height).clamp(plot.top, plot.bottom);
    // Every 10 dB; the label sits inside the plot's height (none cut off at
    // the top/bottom edge).
    for (var db = lo; db <= hi + 0.1; db += 10) {
      final ly = y(db);
      canvas.drawLine(Offset(plot.left, ly), Offset(plot.right, ly), grid);
      _text(canvas, db.round().toString(), Offset(2, (ly - 7).clamp(plot.top, plot.bottom - 14)), label);
    }

    // MHz scale: nice steps across the shown range.
    final (low, high) = range;
    final shownSpan = high - low;
    final stepHz = shownSpan > 1500000 ? 200000 : (shownSpan > 600000 ? 100000 : (shownSpan > 200000 ? 50000 : 10000));
    for (var f = (low / stepHz).ceil() * stepHz; f <= high; f += stepHz) {
      final x = _xOf(f, range, plot.left, plot.width);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _text(
        canvas,
        '${(f / 1e6).toStringAsFixed(stepHz < 50000 ? 2 : (stepHz < 100000 ? 2 : 1))}M',
        Offset(x - 16, size.height - _axisHeight + 3),
        label,
      );
    }

    // Listened channel: its passband shaded.
    if (passband case (final p0, final p1)) {
      final x0 = _xOf(p0, range, plot.left, plot.width), x1 = _xOf(p1, range, plot.left, plot.width);
      final w = (x1 - x0).abs() < 2 ? 2.0 : (x1 - x0);
      canvas.drawRect(
        Rect.fromLTWH(x0, plot.top, w, plot.height),
        Paint()..color = Colors.white.withValues(alpha: 0.12),
      );
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
    canvas.save();
    canvas.clipRect(plot);
    canvas.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, plot.top), Offset(0, plot.bottom), [
          brandGreen.withValues(alpha: 0.45),
          brandGreen.withValues(alpha: 0.08),
        ]),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = const Color(0xFF9BE8B4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.restore();

    final mx = _xOf(markHz, range, plot.left, plot.width);
    if (mx >= plot.left && mx <= plot.right) {
      canvas.drawLine(Offset(mx, plot.top), Offset(mx, plot.bottom), Paint()..color = Colors.redAccent);
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
      old.range != range ||
      old.passband != passband ||
      old.hasSegments != hasSegments ||
      old.dbLo != dbLo ||
      old.dbHi != dbHi;
}

/// The band plan strip right under the spectrum, like an SDR's band overlay.
class _SegmentStripPainter extends CustomPainter {
  final List<WaterfallSegment> segments;
  final (double, double) range;

  _SegmentStripPainter({required this.segments, required this.range});

  @override
  void paint(Canvas canvas, Size size) {
    const top = 1.0;
    final bottom = size.height - 1, right = size.width;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, top, right, bottom));
    for (final s in segments) {
      final x0 = _xOf(s.lowHz, range, 0, right), x1 = _xOf(s.highHz, range, 0, right);
      if (x1 < 0 || x0 > right) continue;
      canvas.drawRect(Rect.fromLTRB(x0, top, x1, bottom), Paint()..color = s.color.withValues(alpha: 0.55));
      canvas.drawLine(Offset(x0, top), Offset(x0, bottom), Paint()..color = Colors.black54);
      final visible = Rect.fromLTRB(x0.clamp(0, right), top, x1.clamp(0, right), bottom);
      if (visible.width <= 24) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: s.name,
          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: visible.width - 6);
      tp.paint(canvas, Offset(visible.center.dx - tp.width / 2, top + 2));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SegmentStripPainter old) => old.range != range || !identical(old.segments, segments);
}

class _WaterfallPainter extends CustomPainter {
  final ui.Image? image;

  /// The newest row in [image] (a ring, see _WaterfallViewState._head).
  final int head;
  final int centerHz;
  final int spanHz;
  final int markHz;
  final (double, double) range;

  _WaterfallPainter({
    required this.image,
    required this.head,
    required this.centerHz,
    required this.spanHz,
    required this.markHz,
    required this.range,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const left = _SpectrumPainter.axisWidth;
    final area = Rect.fromLTRB(left, 0, size.width, size.height);
    canvas.drawRect(area, Paint()..color = Colors.black);
    final img = image;
    if (img != null && spanHz > 0) {
      // Just the shown part of each row.
      final low = centerHz - spanHz / 2;
      final x0 = (range.$1 - low) / spanHz * img.width, x1 = (range.$2 - low) / spanHz * img.width;
      // The ring from the newest row down: [head, end) on top, then
      // [0, head) below it.
      final rows = img.height, h = head.clamp(0, rows - 1);
      final split = area.top + area.height * (rows - h) / rows;
      final paint = Paint()..filterQuality = FilterQuality.low;
      canvas.drawImageRect(
        img,
        Rect.fromLTRB(x0, h.toDouble(), x1, rows.toDouble()),
        Rect.fromLTRB(area.left, area.top, area.right, split),
        paint,
      );
      if (h > 0) {
        canvas.drawImageRect(
          img,
          Rect.fromLTRB(x0, 0, x1, h.toDouble()),
          Rect.fromLTRB(area.left, split, area.right, area.bottom),
          paint,
        );
      }
    }
    if (spanHz > 0) {
      final mx = _xOf(markHz, range, left, area.width);
      if (mx >= left && mx <= size.width) {
        canvas.drawLine(
          Offset(mx, 0),
          Offset(mx, size.height),
          Paint()..color = Colors.redAccent.withValues(alpha: 0.6),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WaterfallPainter old) =>
      old.image != image ||
      old.head != head ||
      old.markHz != markHz ||
      old.centerHz != centerHz ||
      old.spanHz != spanHz ||
      old.range != range;
}
