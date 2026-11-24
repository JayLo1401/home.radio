import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Haussteuerung's display on Android ("home_system/display", see
/// DisplayPlugin.kt / MotionService.kt): keep it on while the dashboard shows,
/// switch it off/on, and the camera watching for motion. Elsewhere (PC) all
/// of it does nothing.
class DisplayService {
  static const _channel = MethodChannel('home_system/display');
  static const _motion = EventChannel('home_system/motion');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      debugPrint('DisplayService.$method: ${e.message}');
      return null;
    }
  }

  Future<void> setKeepScreenOn(bool on) => _invoke<void>('setKeepScreenOn', {'on': on});

  /// The dashboard is on screen - only then the display goes off by itself.
  Future<void> setDashboardActive(bool active) => _invoke<void>('setDashboardActive', {'active': active});

  /// Display off (needs the Home-key accessibility service, Android 9+).
  Future<bool> screenOff() async => await _invoke<bool>('screenOff') ?? false;

  Future<bool> screenOn() async => await _invoke<bool>('screenOn') ?? false;

  /// Whether [screenOff] can work: the accessibility service runs.
  Future<bool> canSwitchOff() async => await _invoke<bool>('canSwitchOff') ?? false;

  Future<bool> hasCamera() async => await _invoke<bool>('hasCamera') ?? false;

  Future<bool> hasCameraPermission() async => await _invoke<bool>('hasCameraPermission') ?? false;

  Future<bool> requestCameraPermission() async => await _invoke<bool>('requestCameraPermission') ?? false;

  /// Starts (or reconfigures) display-by-motion. False without camera permission.
  Future<bool> startMotion({
    required int sensitivity,
    required int timeoutMinutes,
    required String webhookUrl,
    required String deviceName,
  }) async =>
      await _invoke<bool>('startMotion', {
        'sensitivity': sensitivity,
        'timeoutMinutes': timeoutMinutes,
        'webhookUrl': webhookUrl,
        'deviceName': deviceName,
      }) ??
      false;

  Future<void> stopMotion() => _invoke<void>('stopMotion');

  Future<bool> motionRunning() async => await _invoke<bool>('motionRunning') ?? false;

  /// The camera's motion level (0..1) and whether it counted as motion - a
  /// few times a second while display-by-motion runs.
  Stream<({double level, bool motion})> motionLevels() {
    if (!supported) return const Stream.empty();
    return _motion.receiveBroadcastStream().map((e) {
      final m = (e as Map).cast<String, Object?>();
      return (level: (m['level'] as num?)?.toDouble() ?? 0, motion: m['motion'] == true);
    });
  }
}
