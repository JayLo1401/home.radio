import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/repositories/music_settings_repository.dart';
import '../../data/services/music_spectrum.dart';

/// How the visualisation is drawn. The lines themselves are always drawn
/// sharp at the screen's own resolution; only their glow and trails (the
/// "halo") come from a small picture fed back frame to frame and stretched
/// to the screen - [haloHeight] is its height.
@immutable
class MusicVisualizerProfile {
  const MusicVisualizerProfile({required this.haloHeight, required this.fps, required this.detail});

  final int haloHeight;
  final int fps;

  /// 0..1 - mesh density.
  final double detail;

  /// Fire TV Stick & co: small halo, 30 frames, coarser meshes.
  static const low = MusicVisualizerProfile(haloHeight: 300, fps: 30, detail: 0.5);
  static const high = MusicVisualizerProfile(haloHeight: 540, fps: 60, detail: 1);

  static MusicVisualizerProfile of(MusicVisualizerQuality quality) => switch (quality) {
        MusicVisualizerQuality.low => low,
        MusicVisualizerQuality.high => high,
        MusicVisualizerQuality.auto => isWeakDevice() ? low : high,
      };
}

bool? _weak;

/// A weak box: 32-bit Android (Fire TV Stick) or under 1.6 GB of memory.
bool isWeakDevice() {
  if (_weak != null) return _weak!;
  var weak = false;
  if (!kIsWeb && Platform.isAndroid) {
    if (Platform.version.contains('android_arm"') || Platform.version.contains('android_ia32')) weak = true;
    try {
      final line = File('/proc/meminfo').readAsLinesSync().firstWhere((l) => l.startsWith('MemTotal'));
      final kb = int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!);
      if (kb < 1600 * 1024) weak = true;
    } catch (_) {}
  }
  return _weak = weak;
}

/// The colour worlds of the visualisation (lime→green first).
const musicVisualizerPalettes = <List<Color>>[
  [Color(0xFFCDFF23), Color(0xFF00C450), Color(0xFF00BFA5)],
  [Color(0xFF40E0FF), Color(0xFF2962FF), Color(0xFFAA00FF)],
  [Color(0xFFFFD600), Color(0xFFFF6D00), Color(0xFFFF1744)],
  [Color(0xFF00E5A0), Color(0xFF00B8D4), Color(0xFFD500F9)],
  [Color(0xFFFF80AB), Color(0xFFEA80FC), Color(0xFF8C9EFF)],
  [Color(0xFFB2FF59), Color(0xFF18FFFF), Color(0xFF448AFF)],
  [Color(0xFFFFFFFF), Color(0xFF80D8FF), Color(0xFF7C4DFF)],
];

/// A colour of [palette] at [u] (cyclic).
Color _paletteAt(List<Color> palette, double u) {
  final n = palette.length;
  final x = (u % 1.0 + 1.0) % 1.0 * n;
  final i = x.floor() % n;
  return Color.lerp(palette[i], palette[(i + 1) % n], x - x.floor())!;
}

/// Segments with colours at both ends, as quads for one drawVertices call
/// (additive) - far cheaper on a weak box than stroking paths.
class _LineBatch {
  _LineBatch(int capacity)
      : _pos = Float32List(capacity * 8),
        _col = Int32List(capacity * 4),
        _idx = Uint16List(capacity * 6),
        _capacity = capacity;

  final Float32List _pos;
  final Int32List _col;
  final Uint16List _idx;
  final int _capacity;
  int _n = 0;

  bool get full => _n >= _capacity;

  void add(double x0, double y0, double x1, double y1, int c0, int c1, double width) {
    if (_n >= _capacity) return;
    final dx = x1 - x0, dy = y1 - y0;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.01) return;
    final h = width / 2 / len;
    final nx = -dy * h, ny = dx * h;
    final p = _n * 8;
    _pos[p] = x0 + nx;
    _pos[p + 1] = y0 + ny;
    _pos[p + 2] = x0 - nx;
    _pos[p + 3] = y0 - ny;
    _pos[p + 4] = x1 + nx;
    _pos[p + 5] = y1 + ny;
    _pos[p + 6] = x1 - nx;
    _pos[p + 7] = y1 - ny;
    final c = _n * 4;
    _col[c] = c0;
    _col[c + 1] = c0;
    _col[c + 2] = c1;
    _col[c + 3] = c1;
    final v = _n * 4, i = _n * 6;
    _idx[i] = v;
    _idx[i + 1] = v + 1;
    _idx[i + 2] = v + 2;
    _idx[i + 3] = v + 1;
    _idx[i + 4] = v + 3;
    _idx[i + 5] = v + 2;
    _n++;
  }

  /// What was added, as vertices (null if nothing) - and empty again.
  ui.Vertices? take() {
    if (_n == 0) return null;
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_pos, 0, _n * 8),
      colors: Int32List.sublistView(_col, 0, _n * 4),
      indices: Uint16List.sublistView(_idx, 0, _n * 6),
    );
    _n = 0;
    return vertices;
  }
}

/// A camera circling the origin: yaw, pitch down, perspective.
class _Camera {
  double yaw = 0, pitch = 0.5, distance = 3, focal = 1, cx = 0, cy = 0;
  double _cy = 1, _sy = 0, _cp = 1, _sp = 0;

  void update() {
    _cy = math.cos(yaw);
    _sy = math.sin(yaw);
    _cp = math.cos(pitch);
    _sp = math.sin(pitch);
  }

  /// Screen x, y, and the fade by distance (1 near, fainter far) into [out].
  void project(double x, double y, double z, Float64List out, int at) {
    final x1 = x * _cy - z * _sy;
    final z1 = x * _sy + z * _cy;
    final y2 = y * _cp - z1 * _sp;
    final z2 = y * _sp + z1 * _cp + distance;
    final d = z2 < 0.1 ? 0.1 : z2;
    out[at] = cx + focal * x1 / d;
    out[at + 1] = cy - focal * y2 / d;
    out[at + 2] = (1.6 - (z2 - distance) * 0.45).clamp(0.15, 1.0);
  }
}

/// A ripple from a beat: born at [born], as strong as the bass then.
class _Ripple {
  _Ripple(this.born, this.strength);
  final double born;
  final double strength;
}

/// One stretch of the show: a scene with its own shape parameters
/// ([p], 0..1, each drifting slowly), palette and camera phase.
class _Episode {
  _Episode(this.scene, this.palette, this.start, math.Random r)
      : p = List.generate(8, (_) => r.nextDouble()),
        phase = List.generate(8, (_) => r.nextDouble() * 2 * math.pi),
        rate = List.generate(8, (_) => 0.05 + r.nextDouble() * 0.12);

  final int scene;
  final int palette;
  final double start;
  final List<double> p;
  final List<double> phase;
  final List<double> rate;

  /// Parameter [i] at time [t]: its value, drifting ±0.2 - the shape keeps
  /// changing within the scene.
  double at(int i, double t) => (p[i] + 0.2 * math.sin(t * rate[i] + phase[i])).clamp(0.0, 1.0);
}

/// The scenes: glowing 3D wire structures in perspective, flowing and
/// rippling with the music.
/// 0 the chute: flying down a channel of lines; 1 a rippling sheet;
/// 2 concentric ribbons; 3 a twisting bloom of spokes; 4 a breathing torus.
/// Every [interval] seconds (0: only by [nextScene]) another scene with
/// new shape parameters and colours fades in - never the same scene twice
/// in a row, all of them before one comes again.
class MusicVisualizerEngine {
  MusicVisualizerEngine({required this.detail, math.Random? random, this.interval = 45})
      : _random = random ?? math.Random() {
    // It opens with the chute in the brand's lime and green.
    _current = _Episode(0, 0, 0, _random);
  }

  final double detail;
  final math.Random _random;

  /// Seconds per scene; 0 = only by [nextScene].
  double interval;

  late _Episode _current;
  _Episode? _previous;
  final _bag = <int>[];
  bool _skip = false;

  final _ripples = <_Ripple>[];
  final _glow = _LineBatch(9000);
  final _core = _LineBatch(9000);
  final _cam = _Camera();
  double _lastRipple = -10;
  Float64List _pts = Float64List(0);
  double _gain = 1;
  double _widthScale = 1;

  /// The scenes move on their own clock: at full speed while there's
  /// sound, nearly still when it's quiet or paused.
  double _motion = 0;
  double _activity = 1;
  double? _lastT;

  /// A flash on each beat, fading within a fraction of a second.
  double _kick = 0;

  static const sceneCount = 5;
  static const fadeSeconds = 3.5;

  int get scene => _current.scene;

  /// The next scene now (the remote's ↑).
  void nextScene() => _skip = true;

  int _pickScene() {
    if (_bag.isEmpty) {
      _bag.addAll(List.generate(sceneCount, (i) => i)..shuffle(_random));
      // Not the one showing now right away again.
      if (_bag.last == _current.scene && _bag.length > 1) {
        _bag.insert(0, _bag.removeLast());
      }
    }
    return _bag.removeLast();
  }

  void _advance(double t) {
    var palette = _random.nextInt(musicVisualizerPalettes.length);
    if (palette == _current.palette) palette = (palette + 1) % musicVisualizerPalettes.length;
    _previous = _current;
    _current = _Episode(_pickScene(), palette, t, _random);
  }

  /// The lines of second [t] for a picture of [size]: glow (for the halo)
  /// and cores (sharp). The caller draws and disposes them.
  ({List<ui.Vertices> glow, List<ui.Vertices> core}) frame(Size size, double t, MusicLevels l) {
    if (_skip || (interval > 0 && t - _current.start >= interval)) {
      _skip = false;
      _advance(t);
    }
    final dt = _lastT == null ? 0.0 : (t - _lastT!).clamp(0.0, 0.25);
    _lastT = t;
    final target = l.level > 0.03 ? 1.0 : 0.02;
    _activity += (target - _activity) * (1 - math.exp(-dt * 4));
    _motion += dt * _activity;
    _kick = l.beat ? 1.0 : _kick * math.exp(-dt * 7);
    final m = _motion;
    _updateRipples(m, l);
    final glow = <ui.Vertices>[];
    final core = <ui.Vertices>[];
    _widthScale = (size.height / 540).clamp(0.6, 2.0);
    final brightness = 0.55 + 0.45 * l.level + 0.35 * _kick;
    final previous = _previous;
    final f = previous == null ? 1.0 : ((t - _current.start) / fadeSeconds).clamp(0.0, 1.0);
    // Smooth in and out.
    final w = f * f * (3 - 2 * f);
    if (previous != null && w < 1) {
      _scene(previous, size, m, l, brightness * (1 - w));
      _collect(glow, core);
    } else {
      _previous = null;
    }
    _scene(_current, size, m, l, brightness * w);
    _collect(glow, core);
    return (glow: glow, core: core);
  }

  void _collect(List<ui.Vertices> glow, List<ui.Vertices> core) {
    final g = _glow.take();
    final c = _core.take();
    if (g != null) glow.add(g);
    if (c != null) core.add(c);
  }

  void _updateRipples(double t, MusicLevels l) {
    _ripples.removeWhere((r) => t - r.born > 8);
    final gap = t - _lastRipple;
    // On beats - and now and then while there's sound, never in silence.
    if ((l.beat && gap > 0.25) || (gap > 2.4 && l.level > 0.08)) {
      _ripples.add(_Ripple(t, 0.07 + 0.22 * l.bass));
      _lastRipple = t;
    }
  }

  /// The height of the rippling field at radius [r] (and angle [a]).
  double _field(double r, double a, double t, MusicLevels l, double waves) {
    var h = 0.05 * math.sin(r * (5 + 5 * waves) - t * 1.6 + math.sin(a * 3 + t * 0.3) * 0.6) * (0.4 + l.mid);
    for (final rp in _ripples) {
      final age = t - rp.born;
      final d = r - age * 0.55;
      if (d.abs() > 0.5) continue;
      h += rp.strength * math.exp(-d * d * 18) * math.exp(-age * 0.55) * math.cos(d * 22);
    }
    h += 0.025 * l.treble * math.sin(a * 9 + t * 3.1) * math.sin(r * 13 - t * 2.3);
    return h * (1.15 - r * 0.45);
  }

  static int _color(List<Color> palette, double u) {
    final c = _paletteAt(palette, u);
    return ((c.r * 255).round() << 16) | ((c.g * 255).round() << 8) | (c.b * 255).round();
  }

  void _scene(_Episode e, Size size, double t, MusicLevels l, double alpha) {
    if (alpha <= 0.01) return;
    final palette = musicVisualizerPalettes[e.palette];
    _cam
      ..cx = size.width / 2
      ..cy = size.height * 0.54
      ..focal = size.height * 1.05;
    switch (e.scene) {
      case 0:
        _gain = 0.8;
        _chute(e, size, t, l, palette, alpha);
      case 1:
        _gain = 0.6;
        _sheet(e, t, l, palette, alpha);
      case 2:
        _gain = 0.9;
        _rings(e, t, l, palette, alpha);
      case 3:
        _gain = 0.55;
        _bloom(e, t, l, palette, alpha);
      default:
        _gain = 0.85;
        _torus(e, t, l, palette, alpha);
    }
  }

  /// A segment between points [a] and [b] of [_pts] (x, y, fade each).
  void _seg(int a, int b, int c0, int c1, double alpha, double width) {
    if (_glow.full || _core.full) return;
    final pts = _pts;
    final fade = pts[a + 2] < pts[b + 2] ? pts[a + 2] : pts[b + 2];
    final ga = (fade * alpha * _gain * 0.16 * 255).round().clamp(0, 255);
    final ca = (fade * alpha * _gain * 255).round().clamp(0, 255);
    if (ca < 3) return;
    // Never thinner than a pixel or so: hair lines flicker and look washed out.
    final w = math.max(width * _widthScale, 1.0);
    // A narrow soft edge around the core - drawn at full resolution, it
    // makes the line glow without blurring it.
    _glow.add(pts[a], pts[a + 1], pts[b], pts[b + 1], c0 | (ga << 24), c1 | (ga << 24), w * 2.6);
    _core.add(pts[a], pts[a + 1], pts[b], pts[b + 1], c0 | (ca << 24), c1 | (ca << 24), w);
  }

  Float64List _points(int count) => _pts.length >= count * 3 ? _pts : (_pts = Float64List(count * 3));

  /// Scene 0, the chute: a channel of lines - from a half pipe to a closed
  /// tube - running from the distance towards the viewer, bending and
  /// twisting; cross ribs fly past, waves run along it, beats come down it
  /// as bulges.
  void _chute(_Episode e, Size size, double t, MusicLevels l, List<Color> palette, double alpha) {
    final radius = 0.9 + 0.5 * e.at(0, t);
    // How far the walls go up each side: from a flat chute to a deep half
    // pipe (never closed - it's a chute, not a tunnel).
    final span = math.pi * (0.36 + 0.4 * e.at(1, t));
    final bend = 0.5 + 1.3 * e.at(2, t);
    final twist = (e.p[3] - 0.5) * 2.4;
    final speed = 2.2 + 3.0 * e.p[4];
    final spacing = 0.55 + 0.6 * e.p[6];
    final waveK = 1.2 + 2.0 * e.at(7, t);
    const zNear = 0.35, zFar = 17.0;
    final lines = ((14 + 16 * detail) * (0.75 + 0.5 * e.p[5])).round().clamp(10, 34);
    final steps = (20 + 16 * detail).round();
    final ribSteps = (16 + 14 * detail).round();
    final focal = size.height * 0.85;
    // The horizon a little high: more of the chute in view.
    final cx = size.width / 2, cy = size.height * 0.4;
    // The viewer flies low in the channel, rising and sinking a little.
    final eyeY = -radius * (0.45 + 0.2 * math.sin(t * 0.11 + e.phase[0]));
    final roll = 0.25 * math.sin(t * 0.07 + e.phase[1]);
    final cr = math.cos(roll), sr = math.sin(roll);

    // Bulges coming down the channel on beats.
    double surface(double theta, double z) {
      var w = 0.06 * (0.5 + l.mid) * math.sin(z * waveK + t * 3.2 + theta * 2);
      for (final rp in _ripples) {
        // Starting a little way off, not at the far end: the beat shows
        // right away, not seconds later.
        final zr = 7.0 - (t - rp.born) * speed * 1.4;
        final d = z - zr;
        if (d.abs() > 2) continue;
        w += rp.strength * 1.3 * math.exp(-d * d * 1.5);
      }
      w += 0.03 * l.treble * math.sin(theta * 11 + z * 3 - t * 6);
      return w;
    }

    /// Projects the channel's point at [theta] (0 = bottom) and depth [z].
    void point(double theta, double z, Float64List out, int at) {
      final far = (z / 6) * (z / 6);
      final centerX = bend * far * 0.35 * math.sin(t * 0.21 + e.phase[2] + z * 0.08);
      final centerY = bend * far * 0.22 * math.sin(t * 0.16 + e.phase[3] + z * 0.06);
      final rot = twist * (z / zFar) * math.sin(t * 0.13 + e.phase[4]) + twist * 0.3 * math.sin(t * 0.05);
      final r = radius * (1 + surface(theta, z));
      final a = theta + rot;
      var x = centerX + r * math.sin(a);
      var y = centerY - r * math.cos(a) - eyeY;
      final xr = x * cr - y * sr;
      y = x * sr + y * cr;
      x = xr;
      out[at] = cx + focal * x / z;
      out[at + 1] = cy - focal * y / z;
      // Fades in right in front of the eyes and away into the distance.
      final near = ((z - zNear) / 0.5).clamp(0.0, 1.0);
      final away = (1 - (z - zNear) / (zFar - zNear)).clamp(0.0, 1.0);
      out[at + 2] = near * math.pow(away, 1.3).toDouble();
    }

    double depthWidth(double z) => (1.8 / z).clamp(0.55, 2.2);
    final flow = t * speed;

    // The lines along the channel.
    final pts = _points(math.max(steps, ribSteps + 1));
    for (var i = 0; i < lines; i++) {
      final theta = -span + 2 * span * i / (lines - 1);
      for (var k = 0; k < steps; k++) {
        final z = zNear * math.pow(zFar / zNear, k / (steps - 1));
        point(theta, z, pts, k * 3);
      }
      for (var k = 0; k < steps - 1; k++) {
        final z = zNear * math.pow(zFar / zNear, k / (steps - 1));
        // Colour bands flow towards the viewer with the channel.
        final c0 = _color(palette, i / lines * 0.6 + (z + flow) * 0.035);
        final z1 = zNear * math.pow(zFar / zNear, (k + 1) / (steps - 1));
        final c1 = _color(palette, i / lines * 0.6 + (z1 + flow) * 0.035);
        _seg(k * 3, (k + 1) * 3, c0, c1, alpha * 0.85, 1.0 * depthWidth(z));
      }
    }
    // The ribs across, flying past.
    final offset = flow % spacing;
    for (var z = zNear + spacing - offset; z < zFar; z += spacing) {
      for (var k = 0; k <= ribSteps; k++) {
        point(-span + 2 * span * k / ribSteps, z, pts, k * 3);
      }
      final c = _color(palette, (z + flow) * 0.035 + 0.3);
      final c2 = _color(palette, (z + flow) * 0.035 + 0.5);
      for (var k = 0; k < ribSteps; k++) {
        _seg(k * 3, (k + 1) * 3, c, c2, alpha, (1.1 + 0.9 * l.bass) * depthWidth(z));
      }
    }
  }

  /// Scene 1: a wide rippling sheet seen from above at an angle, turning.
  void _sheet(_Episode e, double t, MusicLevels l, List<Color> palette, double alpha) {
    final n = ((16 + 16 * detail) * (0.8 + 0.4 * e.p[0])).round();
    final extent = 1.1 + 0.5 * e.p[1];
    _cam
      ..yaw = t * (0.03 + 0.04 * e.p[2]) + e.phase[0]
      ..pitch = 0.4 + 0.35 * e.at(3, t)
      ..distance = 3.0 + 0.6 * e.at(4, t)
      ..update();
    final waves = e.at(5, t);
    final pts = _points(n * n);
    final colors = Int32List(n * n);
    final edges = Float64List(n * n);
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        final x = -extent + 2 * extent * i / (n - 1);
        final z = -extent + 2 * extent * j / (n - 1);
        final r = math.sqrt(x * x + z * z);
        final h = _field(r, math.atan2(z, x), t, l, waves);
        final k = j * n + i;
        _cam.project(x, h, z, pts, k * 3);
        edges[k] = 1.0 - (r - extent * 0.75).clamp(0.0, 0.6) / 0.6;
        colors[k] = _color(palette, t * 0.03 + r * 0.35 + h * 2.5);
      }
    }
    final width = 1.0 + 0.8 * l.bass;
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n - 1; i++) {
        final a = j * n + i;
        _seg(a * 3, (a + 1) * 3, colors[a], colors[a + 1], alpha * edges[a], width);
      }
    }
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n - 1; j++) {
        final a = j * n + i;
        _seg(a * 3, (a + n) * 3, colors[a], colors[a + n], alpha * 0.55 * edges[a], width * 0.8);
      }
    }
  }

  /// Scene 2: concentric ribbons on the ripple field, tilted and turning.
  void _rings(_Episode e, double t, MusicLevels l, List<Color> palette, double alpha) {
    final rings = ((12 + 12 * detail) * (0.7 + 0.6 * e.p[0])).round();
    final steps = (36 + 28 * detail).round();
    final lobes = 1 + (e.p[1] * 4).floor();
    _cam
      ..yaw = -t * (0.03 + 0.06 * e.p[2]) + e.phase[0]
      ..pitch = 0.55 + 0.45 * e.at(3, t)
      ..distance = 2.4 + 0.4 * e.at(4, t)
      ..update();
    final waves = e.at(5, t);
    final pts = _points(steps);
    for (var j = 0; j < rings; j++) {
      final r = 0.08 + 1.15 * j / (rings - 1);
      final c0 = _color(palette, t * 0.03 + j / rings * 0.9);
      final c1 = _color(palette, t * 0.03 + j / rings * 0.9 + 0.25);
      for (var k = 0; k < steps; k++) {
        final a = 2 * math.pi * k / steps;
        final h = _field(r, a, t, l, waves) * 1.4 + 0.05 * math.sin(a * lobes + t * 0.4 + j * 0.3);
        _cam.project(r * math.cos(a), h, r * math.sin(a), pts, k * 3);
      }
      final ringAlpha = alpha * (1.0 - j / rings * 0.5);
      for (var k = 0; k < steps; k++) {
        final m = (k + 1) % steps;
        _seg(k * 3, m * 3, k.isEven ? c0 : c1, m.isEven ? c0 : c1, ringAlpha, 1.2 + 0.8 * l.bass);
      }
    }
  }

  /// Scene 3: lines radiating from the centre like a sea flower, twisting,
  /// mirrored faintly below.
  void _bloom(_Episode e, double t, MusicLevels l, List<Color> palette, double alpha) {
    final spokes = ((26 + 26 * detail) * (0.7 + 0.6 * e.p[0])).round();
    final steps = (12 + 12 * detail).round();
    final petals = 2 + (e.p[1] * 5).floor();
    _cam
      ..yaw = t * (0.04 + 0.07 * e.p[2]) + e.phase[0]
      ..pitch = 0.3 + 0.5 * e.at(3, t)
      ..distance = 2.5
      ..update();
    final pts = _points(steps);
    final twist = 1.6 * (e.at(4, t) - 0.5) * 2 + 0.8 * l.mid;
    final waves = e.at(5, t);
    for (var mirror = 0; mirror < 2; mirror++) {
      final sign = mirror == 0 ? 1.0 : -0.55;
      final spokeAlpha = alpha * (mirror == 0 ? 1 : 0.3);
      for (var s = 0; s < spokes; s++) {
        final base = 2 * math.pi * s / spokes;
        for (var k = 0; k < steps; k++) {
          final r = 0.05 + 1.2 * k / (steps - 1);
          final a = base + twist * r * r;
          final h = (_field(r, a, t, l, waves) * 1.6 + 0.18 * r * math.sin(base * petals + t * 0.5)) * sign;
          _cam.project(r * math.cos(a), h, r * math.sin(a), pts, k * 3);
        }
        final c = _color(palette, t * 0.03 + s / spokes);
        final c2 = _color(palette, t * 0.03 + s / spokes + 0.33);
        for (var k = 0; k < steps - 1; k++) {
          final f = k / steps;
          final a = spokeAlpha * (f < 0.25 ? f / 0.25 : 1 - (f - 0.25) * 0.6);
          _seg(k * 3, (k + 1) * 3, k == 0 ? c : c2, c2, a, 1.1 + 0.7 * l.treble);
        }
      }
    }
  }

  /// Scene 4: a breathing wire torus - or a twisted knot of one - its tube
  /// swelling with the bass and rippling along its ring.
  void _torus(_Episode e, double t, MusicLevels l, List<Color> palette, double alpha) {
    final around = (32 + 28 * detail).round();
    final tube = (10 + 10 * detail).round();
    // Turns of the tube's twist around the ring (0 = plain torus).
    final twists = (e.p[0] * 4).floor();
    final major = 0.7 + 0.25 * e.at(1, t);
    _cam
      ..yaw = t * (0.06 + 0.08 * e.p[2]) + e.phase[0]
      ..pitch = 0.6 + 0.6 * e.at(3, t)
      ..distance = 3.0
      ..update();
    final pts = _points(around * tube);
    final colors = Int32List(around * tube);
    for (var i = 0; i < around; i++) {
      final u = 2 * math.pi * i / around;
      for (var j = 0; j < tube; j++) {
        final v = 2 * math.pi * j / tube + twists * u / 2;
        final ripple = _field((u / (2 * math.pi)) * 1.2, v, t, l, e.p[5]);
        final minor = 0.2 + 0.12 * l.bass + ripple * 0.9 + 0.06 * math.sin(v * 2 + t);
        final x = (major + minor * math.cos(v)) * math.cos(u);
        final z = (major + minor * math.cos(v)) * math.sin(u);
        final y = minor * math.sin(v);
        final k = i * tube + j;
        _cam.project(x, y, z, pts, k * 3);
        colors[k] = _color(palette, t * 0.03 + i / around + 0.2 * math.sin(v));
      }
    }
    for (var i = 0; i < around; i++) {
      for (var j = 0; j < tube; j++) {
        final a = i * tube + j;
        final b = i * tube + (j + 1) % tube;
        final c = ((i + 1) % around) * tube + j;
        _seg(a * 3, b * 3, colors[a], colors[b], alpha * 0.8, 1.0 + 0.5 * l.bass);
        _seg(a * 3, c * 3, colors[a], colors[c], alpha * 0.45, 0.9);
      }
    }
  }
}

/// Puts the engine's lines on screen: glow and sharp cores straight at the
/// screen's resolution; under them a faint trail - a small picture fed back
/// frame to frame (last one darker, a little zoomed and turned) and
/// stretched to the screen.
///
/// The trail is made with the asynchronous [ui.Picture.toImage], one at a
/// time: a `toImageSync` picture keeps the picture it came from - which
/// holds the previous trail image, which holds its picture ... - an endless
/// chain that ate the memory of a TV box within minutes.
class MusicVisualizerRenderer {
  MusicVisualizerRenderer({required this.profile, math.Random? random, double interval = 45})
      : engine = MusicVisualizerEngine(detail: profile.detail, random: random, interval: interval);

  final MusicVisualizerProfile profile;
  final MusicVisualizerEngine engine;
  ui.Image? _halo;
  ui.Picture? _sharp;
  Size _haloSize = Size.zero;
  bool _haloPending = false;
  bool _disposed = false;

  static final _additive = Paint()..blendMode = BlendMode.plus;
  static final _black = Paint()..color = Colors.black;

  /// How strong the trail shows under the lines.
  static const haloOpacity = 0.45;

  /// Renders second [t] for a screen area of [size] (logical pixels).
  void frame(Size size, double t, MusicLevels levels) {
    if (size.isEmpty || _disposed) return;
    final lines = engine.frame(size, t, levels);

    // The trail: only when the last one is done.
    final h = profile.haloHeight.toDouble().clamp(120.0, size.height);
    final haloSize = Size((h * size.width / size.height).roundToDouble(), h.roundToDouble());
    if (haloSize != _haloSize) {
      _haloSize = haloSize;
      _halo?.dispose();
      _halo = null;
    }
    if (!_haloPending) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Offset.zero & haloSize);
      canvas.drawRect(Offset.zero & haloSize, _black);
      final previous = _halo;
      if (previous != null) {
        canvas.save();
        canvas.translate(haloSize.width / 2, haloSize.height / 2);
        canvas.rotate(0.0025 * math.sin(t * 0.11));
        canvas.scale(1.006 + 0.012 * levels.bass);
        canvas.translate(-haloSize.width / 2, -haloSize.height / 2);
        canvas.drawImage(
          previous,
          Offset.zero,
          Paint()
            ..filterQuality = FilterQuality.low
            ..color = Color.fromRGBO(255, 255, 255, 0.62 + 0.08 * levels.level),
        );
        canvas.restore();
      }
      canvas.scale(haloSize.height / size.height);
      for (final v in lines.core) {
        canvas.drawVertices(v, BlendMode.dst, _additive);
      }
      final picture = recorder.endRecording();
      _haloPending = true;
      final size0 = haloSize;
      picture.toImage(haloSize.width.toInt(), haloSize.height.toInt()).then((image) {
        picture.dispose();
        _haloPending = false;
        if (_disposed || size0 != _haloSize) {
          image.dispose();
          return;
        }
        final old = _halo;
        _halo = image;
        old?.dispose();
      }, onError: (Object _) {
        picture.dispose();
        _haloPending = false;
      });
    }

    // Glow and cores, full resolution.
    final sharp = ui.PictureRecorder();
    final sharpCanvas = Canvas(sharp, Offset.zero & size);
    for (final v in lines.glow) {
      sharpCanvas.drawVertices(v, BlendMode.dst, _additive);
    }
    for (final v in lines.core) {
      sharpCanvas.drawVertices(v, BlendMode.dst, _additive);
    }
    _sharp?.dispose();
    _sharp = sharp.endRecording();
    for (final v in [...lines.glow, ...lines.core]) {
      v.dispose();
    }
  }

  static final _haloPaint = Paint()
    ..filterQuality = FilterQuality.low
    ..color = const Color.fromRGBO(255, 255, 255, haloOpacity);

  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _black);
    final halo = _halo;
    if (halo != null) {
      canvas.drawImageRect(
        halo,
        Rect.fromLTWH(0, 0, halo.width.toDouble(), halo.height.toDouble()),
        Offset.zero & size,
        _haloPaint,
      );
    }
    final sharp = _sharp;
    if (sharp != null) canvas.drawPicture(sharp);
  }

  void dispose() {
    _disposed = true;
    _halo?.dispose();
    _halo = null;
    _sharp?.dispose();
    _sharp = null;
  }
}

/// Where the visualisation gets the music's levels each frame (seconds
/// since start).
typedef MusicLevelSource = MusicLevels Function(double t);

/// Lets the screen switch to the next scene (the remote's ↑).
class MusicVisualizerController {
  MusicVisualizerRenderer? _renderer;
  void nextScene() => _renderer?.engine.nextScene();
}

/// The visualisation itself, filling its box; frame rate capped by the
/// profile. Lives on across tracks - nothing is rebuilt on a track change.
class MusicVisualizerView extends StatefulWidget {
  const MusicVisualizerView({
    super.key,
    required this.profile,
    required this.levels,
    this.interval = 45,
    this.controller,
  });

  final MusicVisualizerProfile profile;
  final MusicLevelSource levels;

  /// Seconds per scene, 0 = only by [MusicVisualizerController.nextScene].
  final int interval;
  final MusicVisualizerController? controller;

  @override
  State<MusicVisualizerView> createState() => _MusicVisualizerViewState();
}

class _MusicVisualizerViewState extends State<MusicVisualizerView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late MusicVisualizerRenderer _renderer = _create();
  final _frameCount = ValueNotifier(0);
  Duration _last = Duration.zero;
  Size _size = Size.zero;

  MusicVisualizerRenderer _create() {
    final r = MusicVisualizerRenderer(profile: widget.profile, interval: widget.interval.toDouble());
    widget.controller?._renderer = r;
    return r;
  }

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void didUpdateWidget(covariant MusicVisualizerView old) {
    super.didUpdateWidget(old);
    if (old.profile != widget.profile) {
      _renderer.dispose();
      _renderer = _create();
    } else {
      _renderer.engine.interval = widget.interval.toDouble();
      widget.controller?._renderer = _renderer;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _renderer.dispose();
    _frameCount.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final minGap = Duration(microseconds: 1000000 ~/ widget.profile.fps - 2000);
    if (elapsed - _last < minGap) return;
    _last = elapsed;
    _renderer.frame(_size, elapsed.inMicroseconds / 1e6, widget.levels(elapsed.inMicroseconds / 1e6));
    _frameCount.value++;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _size = Size(c.maxWidth.isFinite ? c.maxWidth : 0, c.maxHeight.isFinite ? c.maxHeight : 0);
        return RepaintBoundary(
          child: CustomPaint(size: _size, painter: _FramePainter(this)),
        );
      },
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this._state) : super(repaint: _state._frameCount);

  final _MusicVisualizerViewState _state;

  @override
  void paint(Canvas canvas, Size size) => _state._renderer.paint(canvas, size);

  @override
  bool shouldRepaint(_FramePainter old) => old._state != _state;
}
