import 'dart:async';

import 'package:flutter/services.dart';

/// Dart-side bridge to [RtlSdrPlugin] (Kotlin) - connects to an `rtl_tcp`
/// server (see RtlTcpClient.kt's doc comment for the protocol/rationale)
/// running either locally (an Android RTL-SDR driver app on this device)
/// or remotely (e.g. a Raspberry Pi with the dongle attached), configurable
/// via [connect]'s host/port.
///
/// This only covers the raw connection/tuning/byte-rate layer - enough to
/// verify the whole chain (dongle -> driver app -> network -> this app)
/// works before any DAB+/FM/AM demodulation is built on top of it.
class RtlSdrService {
  static const _methodChannel = MethodChannel('home_radio/rtlsdr');
  static const _eventChannel = EventChannel('home_radio/rtlsdr/events');

  final _statsController = StreamController<RtlSdrStats>.broadcast();
  StreamSubscription<dynamic>? _eventSub;

  /// Live byte-rate stats while connected, roughly once per second.
  Stream<RtlSdrStats> get stats => _statsController.stream;

  RtlSdrService() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen((event) {
      final map = (event as Map).cast<String, dynamic>();
      if (map['type'] == 'stats') {
        _statsController.add(
          RtlSdrStats(
            totalBytes: map['totalBytes'] as int? ?? 0,
            bytesPerSec: map['bytesPerSec'] as int? ?? 0,
          ),
        );
      }
    });
  }

  /// Connects to an `rtl_tcp` server. Defaults to localhost:1234 (a driver
  /// app running on this same device); pass a different [host] to reach a
  /// remote one (e.g. a Raspberry Pi acting as the server).
  Future<RtlConnectResult> connect({String host = '127.0.0.1', int port = 1234}) async {
    final result = await _methodChannel.invokeMapMethod<String, dynamic>(
      'rtlConnect',
      {'host': host, 'port': port},
    );
    return RtlConnectResult(
      connected: result?['connected'] as bool? ?? false,
      tunerType: result?['tunerType'] as int?,
      tunerGainCount: result?['tunerGainCount'] as int?,
      error: result?['error'] as String?,
    );
  }

  Future<void> disconnect() => _methodChannel.invokeMethod('rtlDisconnect');

  Future<void> setFrequencyHz(int hz) => _methodChannel.invokeMethod('rtlSetFrequency', {'hz': hz});

  Future<void> setSampleRateHz(int hz) => _methodChannel.invokeMethod('rtlSetSampleRate', {'hz': hz});

  Future<void> setGainMode({required bool auto}) =>
      _methodChannel.invokeMethod('rtlSetGainMode', {'auto': auto});

  Future<void> setGainTenthDb(int tenthDb) => _methodChannel.invokeMethod('rtlSetGain', {'tenthDb': tenthDb});

  Future<bool> isConnected() async {
    final result = await _methodChannel.invokeMethod<bool>('rtlIsConnected');
    return result ?? false;
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _statsController.close();
  }
}

class RtlConnectResult {
  const RtlConnectResult({
    required this.connected,
    this.tunerType,
    this.tunerGainCount,
    this.error,
  });

  final bool connected;
  final int? tunerType;
  final int? tunerGainCount;
  final String? error;
}

class RtlSdrStats {
  const RtlSdrStats({required this.totalBytes, required this.bytesPerSec});

  final int totalBytes;
  final int bytesPerSec;
}
