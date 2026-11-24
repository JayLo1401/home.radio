import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A direction of the remote's D-Pad.
enum PointerDirection {
  up(Offset(0, -1)),
  down(Offset(0, 1)),
  left(Offset(-1, 0)),
  right(Offset(1, 0));

  const PointerDirection(this.vector);
  final Offset vector;
}

/// The remote's mouse pointer in the browser: moved with the D-Pad, smooth
/// (every frame) and faster the longer a key is held; at the edge of the
/// page it scrolls the page instead.
class BrowserPointer extends ChangeNotifier {
  BrowserPointer({required TickerProvider vsync, required this.onHover, required this.onEdgeScroll}) {
    _ticker = vsync.createTicker(_tick);
  }

  /// The pointer moved (logical pixels in the page) - throttled.
  final void Function(Offset at) onHover;

  /// The pointer pushes against an edge: scroll by [by] (logical pixels).
  final void Function(Offset at, Offset by) onEdgeScroll;

  late final Ticker _ticker;
  final _held = <PointerDirection, Duration>{};
  Duration _now = Duration.zero;
  Duration _lastTick = Duration.zero;
  Duration _lastHover = Duration.zero;
  bool _movedSinceHover = false;

  Offset _position = Offset.zero;
  Size _bounds = Size.zero;
  bool _visible = false;

  Offset get position => _position;
  bool get visible => _visible;

  /// After this long a held key moves continuously.
  static const _holdDelay = Duration(milliseconds: 110);
  static const _nudge = 9.0;

  double get _short => math.max(200, math.min(_bounds.width, _bounds.height));
  double get _baseSpeed => _short * 0.5;
  double get _maxSpeed => _short * 2.0;

  /// The page's size; the pointer starts in the middle.
  void setBounds(Size size) {
    if (size == _bounds) return;
    final first = _bounds == Size.zero;
    _bounds = size;
    _position = first ? size.center(Offset.zero) : _clamp(_position);
    notifyListeners();
  }

  set visible(bool v) {
    if (v == _visible) return;
    _visible = v;
    if (!v) releaseAll();
    notifyListeners();
  }

  void moveTo(Offset at) {
    _position = _clamp(at);
    notifyListeners();
  }

  Offset _clamp(Offset o) => Offset(o.dx.clamp(0.0, math.max(0.0, _bounds.width - 1)), o.dy.clamp(0.0, math.max(0.0, _bounds.height - 1)));

  bool _atEdge(PointerDirection d) => switch (d) {
        PointerDirection.up => _position.dy <= 1,
        PointerDirection.down => _position.dy >= _bounds.height - 2,
        PointerDirection.left => _position.dx <= 1,
        PointerDirection.right => _position.dx >= _bounds.width - 2,
      };

  void press(PointerDirection d) {
    final wasVisible = _visible;
    _visible = true;
    if (_held.containsKey(d)) return;
    _held[d] = _now;
    if (wasVisible) {
      if (_atEdge(d)) {
        // One press at the edge: a good step of the page.
        final step = (d.vector.dy != 0 ? _bounds.height : _bounds.width) * 0.2;
        onEdgeScroll(_position, d.vector * step);
      } else {
        _position = _clamp(_position + d.vector * _nudge);
        _movedSinceHover = true;
      }
    }
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _now = Duration.zero;
      _held.updateAll((_, _) => Duration.zero);
      _ticker.start();
    }
    notifyListeners();
  }

  void release(PointerDirection d) {
    _held.remove(d);
    if (_held.isEmpty) _stop();
  }

  void releaseAll() {
    _held.clear();
    _stop();
  }

  void _stop() {
    if (_ticker.isActive) _ticker.stop();
    if (_movedSinceHover) {
      _movedSinceHover = false;
      onHover(_position);
    }
  }

  void _tick(Duration elapsed) {
    _now = elapsed;
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 0.25) return;
    var velocity = Offset.zero;
    var edge = Offset.zero;
    for (final e in _held.entries) {
      final held = elapsed - e.value;
      if (held < _holdDelay) continue;
      final t = (held - _holdDelay).inMicroseconds / 1e6;
      // Accelerates over ~1.2 s from the base to the top speed.
      final speed = _baseSpeed + (_maxSpeed - _baseSpeed) * math.min(1.0, t / 1.2);
      if (_atEdge(e.key)) {
        edge += e.key.vector * speed * 1.4 * dt;
      } else {
        velocity += e.key.vector * speed;
      }
    }
    if (velocity != Offset.zero) {
      final next = _clamp(_position + velocity * dt);
      if (next != _position) {
        _position = next;
        _movedSinceHover = true;
        notifyListeners();
      }
    }
    if (edge != Offset.zero) onEdgeScroll(_position, edge);
    if (_movedSinceHover && elapsed - _lastHover > const Duration(milliseconds: 50)) {
      _lastHover = elapsed;
      _movedSinceHover = false;
      onHover(_position);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// Draws [pointer]: a white arrow with a dark outline and shadow - visible on
/// white pages as on dark ones.
class BrowserPointerOverlay extends StatelessWidget {
  const BrowserPointerOverlay({super.key, required this.pointer, this.scale = 1.6});

  final BrowserPointer pointer;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: pointer,
        builder: (context, _) => pointer.visible
            ? CustomPaint(painter: _ArrowPainter(pointer.position, scale), size: Size.infinite)
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.at, this.scale);

  final Offset at;
  final double scale;

  static final Path _arrow = Path()
    ..moveTo(0, 0)
    ..lineTo(0, 18)
    ..lineTo(4.6, 13.8)
    ..lineTo(7.8, 21)
    ..lineTo(10.6, 19.8)
    ..lineTo(7.5, 12.8)
    ..lineTo(13.4, 12.8)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(scale);
    canvas.drawShadow(_arrow.shift(const Offset(0.6, 0.8)), const Color(0xFF000000), 2.5, false);
    canvas.drawPath(_arrow, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawPath(
      _arrow,
      Paint()
        ..color = const Color(0xFF111111)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.at != at || old.scale != scale;
}
