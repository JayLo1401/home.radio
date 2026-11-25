import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Haussteuerung's display on Android ("home_system/display", see
/// DisplayPlugin.kt / MotionService.kt): keep it on while the dashboard shows,
/// switch it off/on, and the camera watching for motion. Elsewhere (PC) all
/// of it does nothing.
class DisplayService {
  DisplayService() {
    if (supported) {
      _channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'dimmed':
            dimmed.value = call.arguments == true;
          case 'motion':
            motion.value = call.arguments == true;
          case 'screen':
            screenIsOn.value = call.arguments == true;
          case 'cameraFrame':
            final jpeg = call.arguments;
            if (jpeg is Uint8List) _frames.add(jpeg);
        }
      });
    }
  }

  static const _channel = MethodChannel('home_system/display');

  /// The display is darkened ("off" without locking, see startMotion's
  /// dimOnly) - app.dart lays a black page over everything meanwhile.
  final dimmed = ValueNotifier(false);
  static const _motion = EventChannel('home_system/motion');

  /// The camera saw motion (on) - off after a minute without (MotionService).
  final motion = ValueNotifier(false);

  final _frames = StreamController<Uint8List>.broadcast();

  /// The camera's picture (JPEG) every 2 seconds while sharing is on and
  /// display-by-motion runs (see setCameraSharing).
  Stream<Uint8List> get cameraFrames => _frames.stream;

  /// The display is on (Android's screen on/off) - null until it changed once.
  final screenIsOn = ValueNotifier<bool?>(null);

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
    required bool dimOnly,
  }) async =>
      await _invoke<bool>('startMotion', {
        'sensitivity': sensitivity,
        'timeoutMinutes': timeoutMinutes,
        'webhookUrl': webhookUrl,
        'deviceName': deviceName,
        'dimOnly': dimOnly,
      }) ??
      false;

  Future<void> stopMotion() => _invoke<void>('stopMotion');

  /// The window's brightness (see BrightnessController.kt).
  Future<void> setBrightness({
    required String mode,
    required int level,
    required int min,
    required int max,
    required int luxForMax,
  }) =>
      _invoke<void>('setBrightness', {'mode': mode, 'level': level, 'min': min, 'max': max, 'luxForMax': luxForMax});

  /// The light sensor now: null without a sensor, -1 before its first reading.
  Future<double?> ambientLight() async {
    final m = await _invoke<Map<Object?, Object?>>('ambientLight');
    if (m == null || m['hasSensor'] != true) return null;
    return (m['lux'] as num?)?.toDouble() ?? -1;
  }

  /// Battery, light, memory, storage and display for Home Assistant (see
  /// DisplayPlugin.deviceStatus) - empty elsewhere.
  Future<Map<String, Object?>> deviceStatus() async =>
      (await _invoke<Map<Object?, Object?>>('deviceStatus'))?.map((k, v) => MapEntry('$k', v)) ?? const {};

  /// The media volume in percent.
  Future<bool> setVolume(int percent) async => await _invoke<bool>('setVolume', {'percent': percent}) ?? false;

  /// Pictures of the camera for Home Assistant on/off ([cameraFrames]).
  Future<void> setCameraSharing(bool on) => _invoke<void>('setCameraSharing', {'on': on});

  /// Says [text] with Android's text to speech.
  Future<void> speak(String text) => _invoke<void>('speak', {'text': text});

  /// Home System in front again (display on, over another app).
  Future<bool> bringToFront() async => await _invoke<bool>('bringToFront') ?? false;

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
