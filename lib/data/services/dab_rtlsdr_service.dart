import 'dart:async';

import 'package:flutter/services.dart';

/// Dart bridge to [DabRtlSdrPlugin] (Kotlin) - real DAB+ decoding "so wie
/// welle.io" on top of the RTL-SDR stick, via the vendored welle.io DAB
/// core (see cpp/dabcore/). This replaces the old Raontech-chip-only
/// [DabUsbService] for actual DAB+ reception; that class is kept only for
/// its still-useful low-level USB diagnostics (see its own doc comment).
///
/// The decoder connects to an rtl_tcp-protocol source (see [setServer]) -
/// our own USB-TCP service, an external driver app, or a network service,
/// same three options already offered on RtlSdrTestScreen.
class DabRtlSdrService {
  static const _methodChannel = MethodChannel('home_radio/dab_rtlsdr');
  static const _eventChannel = EventChannel('home_radio/dab_rtlsdr/events');

  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _eventSub;

  /// Raw scan/sync/playback events - see DabRtlSdrPlugin.kt for the exact
  /// shapes (`scanProgress`, `channelLocked`, `scanFinished`, `syncChange`,
  /// `serviceDetected`, `ensembleLabel`, `dynamicLabel`, `rsErrors`,
  /// `aacErrors`, `playbackStatus`).
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  DabRtlSdrService() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen((event) {
      _eventsController.add((event as Map).cast<String, dynamic>());
    });
  }

  /// Points the decoder's rtl_tcp client at [host]:[port]. Must be called
  /// (at least once) before [scanBand3]/[tuneFrequency]/[playService].
  Future<bool> setServer({String host = '127.0.0.1', int port = 1234}) async {
    final result = await _methodChannel.invokeMethod<bool>('setServer', {'host': host, 'port': port});
    return result ?? false;
  }

  Future<void> scanBand3() => _methodChannel.invokeMethod('scanBand3');

  Future<void> stopScan() => _methodChannel.invokeMethod('stopScan');

  Future<void> tuneFrequency(int freqKhz) => _methodChannel.invokeMethod('tuneFrequency', {'freqKhz': freqKhz});

  /// Tunes to [freqKhz], waits for sync, then decodes+plays [serviceId]'s
  /// audio component. Returns whether playback actually started.
  Future<bool> playService({required int freqKhz, required int serviceId}) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'playService',
      {'freqKhz': freqKhz, 'serviceId': serviceId},
    );
    return result ?? false;
  }

  Future<void> stopPlayback() => _methodChannel.invokeMethod('stopPlayback');

  Future<String> getEnsembleLabel() async {
    final result = await _methodChannel.invokeMethod<String>('getEnsembleLabel');
    return result ?? '';
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _eventsController.close();
  }
}
