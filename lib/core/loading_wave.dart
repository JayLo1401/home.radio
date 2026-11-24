import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Home System's loading sign: two glowing waves in the logo's lime-to-green
/// gradient, drifting across - on the start screen and wherever something
/// takes a moment.
class LoadingWave extends StatefulWidget {
  const LoadingWave({super.key, this.width = 220, this.height = 40});

  final double width;
  final double height;

  @override
  State<LoadingWave> createState() => _LoadingWaveState();
}

class _LoadingWaveState extends State<LoadingWave> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(painter: _WavePainter(_controller.value)),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.t);

  /// 0..1, one full drift of the waves.
  final double t;

  static const _lime = Color(0xFFCDFF23);
  static const _green = Color(0xFF00C450);

  @override
  void paint(Canvas canvas, Size size) {
    final shader = const LinearGradient(colors: [_lime, _green]).createShader(Offset.zero & size);
    // The back wave: slower, wider, faint.
    _wave(canvas, size, shader,
        phase: -t * 2 * math.pi, waves: 1.5, amplitude: 0.28, stroke: 2.5, opacity: 0.35, glow: false);
    // The front wave: brighter, with a soft glow.
    _wave(canvas, size, shader,
        phase: t * 4 * math.pi, waves: 2, amplitude: 0.36, stroke: 3.5, opacity: 1, glow: true);
  }

  void _wave(Canvas canvas, Size size, Shader shader,
      {required double phase,
      required double waves,
      required double amplitude,
      required double stroke,
      required double opacity,
      required bool glow}) {
    final path = Path();
    final mid = size.height / 2;
    const steps = 96;
    for (var i = 0; i <= steps; i++) {
      final x = size.width * i / steps;
      // Tapered at both ends: the wave grows out of a flat line and back.
      final envelope = math.sin(math.pi * i / steps);
      final y = mid + math.sin(phase + 2 * math.pi * waves * i / steps) * mid * 2 * amplitude * envelope;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    if (glow) {
      canvas.drawPath(
        path,
        Paint()
          ..shader = shader
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 3
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    canvas.saveLayer(Offset.zero & size, Paint()..color = Colors.white.withValues(alpha: opacity));
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.t != t;
}
