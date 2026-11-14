import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart' show brandGreen;

/// Small equalizer bars in the Now Playing banner, shown only while audio
/// is actually playing (not during buffering/paused/error states).
///
/// Real levels wherever the app has the PCM itself: DAB+, FM and narrowband
/// go through the receiver's own player, which measures 8 octave bands on
/// what goes to the speaker ([DabRtlSdrService.audioLevels]). Internet radio
/// plays through just_audio (ExoPlayer on Android, libmpv on Windows/Linux),
/// which gives no access to its samples - there the bars fall back to a
/// made-up animation.
///
/// Cheap on purpose (the TV box is weak): no widget rebuilds, only the
/// [CustomPainter] behind a [RepaintBoundary] repaints, 25 times a second,
/// and nothing runs while the banner is hidden behind another route.
class AudioLevelBars extends ConsumerStatefulWidget {
  const AudioLevelBars({super.key});

  @override
  ConsumerState<AudioLevelBars> createState() => _AudioLevelBarsState();
}

class _AudioLevelBarsState extends ConsumerState<AudioLevelBars> {
  static const _bands = 8;

  /// Without a level update for this long (the native side sends silence
  /// once a second), the receiver's player is taken to be gone.
  static const _staleAfter = Duration(milliseconds: 2500);

  late final ValueListenable<Uint8List?> _levels;
  final _heights = _BarHeights(_bands);
  final _sinceReal = Stopwatch();
  final _clock = Stopwatch()..start();
  Timer? _timer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _levels = ref.read(dabRtlSdrServiceProvider).audioLevels;
    _levels.addListener(_onLevels);
    _onLevels();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Hidden behind another route (Offstage): stop the fallback animation
    // and ignore level updates rather than paint for nobody.
    _visible = TickerMode.valuesOf(context).enabled;
    _timer?.cancel();
    _timer = _visible ? Timer.periodic(const Duration(milliseconds: 40), (_) => _tick()) : null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _levels.removeListener(_onLevels);
    _heights.dispose();
    super.dispose();
  }

  void _onLevels() {
    final levels = _levels.value;
    if (levels == null) return;
    _sinceReal
      ..reset()
      ..start();
    if (_visible) _heights.setBytes(levels);
  }

  bool get _hasReal => _levels.value != null && _sinceReal.isRunning && _sinceReal.elapsed < _staleAfter;

  /// Fallback animation for sources without real levels: every bar its own
  /// pair of slow sines, the bass a little higher than the treble.
  void _tick() {
    if (_hasReal) return;
    final t = _clock.elapsedMicroseconds / 1e6;
    for (var i = 0; i < _bands; i++) {
      final v = 0.5 -
          i * 0.03 +
          0.22 * math.sin(t * (4.1 + i * 0.9) + i * 1.7) +
          0.12 * math.sin(t * (9.3 - i * 0.5) + i * 2.9);
      _heights.values[i] = v.clamp(0.08, 1.0);
    }
    _heights.changed();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: const Size(40, 24),
        painter: _BarsPainter(_heights),
      ),
    );
  }
}

/// Current bar heights (0..1), notifying the painter directly.
class _BarHeights extends ChangeNotifier {
  _BarHeights(int count) : values = Float32List(count);

  final Float32List values;

  void setBytes(Uint8List levels) {
    final n = math.min(levels.length, values.length);
    for (var i = 0; i < n; i++) {
      values[i] = levels[i] / 255;
    }
    notifyListeners();
  }

  void changed() => notifyListeners();
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.heights) : super(repaint: heights);

  final _BarHeights heights;

  static const _top = Color(0xFF8BE8B0);
  static const _gap = 2.0;
  Paint? _paint;
  double _paintHeight = -1;

  @override
  void paint(Canvas canvas, Size size) {
    if (_paint == null || _paintHeight != size.height) {
      _paintHeight = size.height;
      _paint = Paint()
        ..shader = ui.Gradient.linear(Offset(0, size.height), Offset.zero, const [brandGreen, _top]);
    }
    final values = heights.values;
    final n = values.length;
    final barWidth = (size.width - _gap * (n - 1)) / n;
    final radius = Radius.circular(barWidth / 2);
    for (var i = 0; i < n; i++) {
      // At least a dot, so silence still shows where the bars are.
      final h = math.max(barWidth, values[i] * size.height);
      final x = i * (barWidth + _gap);
      canvas.drawRRect(
        RRect.fromLTRBR(x, size.height - h, x + barWidth, size.height, radius),
        _paint!,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => old.heights != heights;
}
