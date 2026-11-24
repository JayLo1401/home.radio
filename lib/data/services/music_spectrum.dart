import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The music's loudness for the visualisation: overall [level] and
/// [bass] / [mid] / [treble], each 0..1, plus [beat] (a kick just came).
@immutable
class MusicLevels {
  const MusicLevels({this.level = 0, this.bass = 0, this.mid = 0, this.treble = 0, this.beat = false});

  final double level;
  final double bass;
  final double mid;
  final double treble;
  final bool beat;

  static const silent = MusicLevels();
}

/// Where the visualisation gets its levels from: the real spectrum of the
/// music player's output (Android's Visualizer - needs RECORD_AUDIO, see
/// MusicVisualizerPlugin.kt), or - without it, and on the PC - a calm
/// generated pulse that still keeps the picture alive.
class MusicSpectrum {
  static const _channel = MethodChannel('home_system/music_visualizer');
  static const _events = EventChannel('home_system/music_visualizer/levels');

  /// Only Android has the Visualizer.
  static bool get supported => !kIsWeb && Platform.isAndroid;

  Future<bool> hasPermission() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks Android for the permission (its dialog speaks of the microphone /
  /// recording audio).
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The real spectrum of audio session [sessionId] (16 bands, 0..1, ~20/s)
  /// - errors when not available (no permission, plugin missing, device
  /// without Visualizer).
  Stream<List<double>> bands(int sessionId) =>
      _events.receiveBroadcastStream(sessionId).map((e) => [for (final v in e as List) (v as num).toDouble()]);
}

/// Smooths raw bands into [MusicLevels] with a simple beat detection
/// (bass clearly above its running average).
class MusicLevelFollower {
  double _bass = 0, _mid = 0, _treble = 0, _level = 0;
  double _bassAverage = 0.2;
  DateTime _lastBeat = DateTime.fromMillisecondsSinceEpoch(0);

  MusicLevels add(List<double> bands) {
    if (bands.isEmpty) return MusicLevels.silent;
    double mean(int from, int to) {
      var sum = 0.0;
      var n = 0;
      for (var i = from; i < to && i < bands.length; i++) {
        sum += bands[i];
        n++;
      }
      return n == 0 ? 0 : sum / n;
    }

    final third = bands.length / 3;
    final bass = mean(0, third.round());
    final mid = mean(third.round(), (2 * third).round());
    final treble = mean((2 * third).round(), bands.length);
    // Quick up, slow down.
    double follow(double old, double now) => now > old ? old + (now - old) * 0.6 : old + (now - old) * 0.15;
    _bass = follow(_bass, bass);
    _mid = follow(_mid, mid);
    _treble = follow(_treble, treble);
    _level = follow(_level, (bass + mid + treble) / 3);
    _bassAverage += (bass - _bassAverage) * 0.05;
    final now = DateTime.now();
    final beat = bass > _bassAverage * 1.25 + 0.05 && now.difference(_lastBeat) > const Duration(milliseconds: 280);
    if (beat) _lastBeat = now;
    return MusicLevels(level: _level, bass: _bass, mid: _mid, treble: _treble, beat: beat);
  }
}

/// A generated pulse for when there's no spectrum: slow, even breathing
/// while [playing] - no made-up beats (they'd never match the music) -
/// and silence within a second when paused.
class MusicPulse {
  MusicPulse([int seed = 7]) : _random = math.Random(seed);

  final math.Random _random;
  double _energy = 0;
  double _nextBeat = 0;

  /// [t]: seconds since start.
  MusicLevels at(double t, {required bool playing}) {
    _energy += ((playing ? 1.0 : 0.0) - _energy) * (playing ? 0.02 : 0.1);
    const beat = false;
    if (t >= _nextBeat) _nextBeat = t + 0.48 + _random.nextDouble() * 0.16;
    final phase = (t - (_nextBeat - 0.55)).clamp(0.0, 1.0);
    final kick = math.exp(-phase * 6);
    final breathe = 0.5 + 0.5 * math.sin(t * 0.35);
    final bass = (0.3 + 0.15 * kick) * _energy;
    final mid = (0.25 + 0.2 * breathe + 0.1 * math.sin(t * 1.7)) * _energy;
    final treble = (0.15 + 0.15 * (0.5 + 0.5 * math.sin(t * 2.9 + 1))) * _energy;
    return MusicLevels(level: (bass + mid + treble) / 3, bass: bass, mid: mid, treble: treble, beat: beat);
  }
}
