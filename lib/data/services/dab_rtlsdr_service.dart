import 'dart:async';

import 'package:flutter/services.dart';

/// Dart bridge to [DabRtlSdrPlugin] (Kotlin) - DAB+ reception with the
/// app's own receiver (cpp/hrdab) on an RTL-SDR stick, opened either
/// directly over USB ([useDirectUsb]) or through an rtl_tcp server
/// ([setServer]: an external driver app or a network service).
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

  /// Points the receiver at the rtl_tcp server [host]:[port]. Must be called
  /// (at least once) before [scanBand3]/[tuneFrequency]/[playService].
  /// Returns whether something actually listens there.
  Future<bool> setServer({String host = '127.0.0.1', int port = 1234}) async {
    final result = await _methodChannel.invokeMethod<bool>('setServer', {'host': host, 'port': port});
    return result ?? false;
  }

  /// "RTL-SDR-USB" mode's alternative to [setServer]: opens the stick
  /// directly over USB (asking for the permission if needed).
  Future<bool> useDirectUsb() async {
    final result = await _methodChannel.invokeMethod<bool>('useDirectUsb');
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

  /// Tears down the native DAB+ session (direct-USB mode's rtlsdr_dev_t /
  /// UsbDeviceConnection, or the rtl_tcp client) so a later play/scan
  /// attempt starts fresh - call this once RtlSdrUsbService reports the
  /// known RTL-SDR dongle was unplugged. Without it, a direct-USB session
  /// left pointing at now-gone hardware never recovers on its own; every
  /// later attempt just silently fails until the app is force-stopped.
  Future<void> resetSession() => _methodChannel.invokeMethod('resetSession');

  Future<String> getEnsembleLabel() async {
    final result = await _methodChannel.invokeMethod<String>('getEnsembleLabel');
    return result ?? '';
  }

  /// Tunes to each station in turn and waits for a real DAB+ MOT slideshow
  /// image (the actual broadcast logo/cover art) - a dedicated, separate,
  /// slower action from [scanBand3] (some stations take 10-30s to send a
  /// slide, some never do). Progress/results arrive via [events]
  /// (`logoScanProgress`, `logoFound`, `logoNotFound`, `logoScanFinished`).
  Future<void> fetchLogos(List<({int freqKhz, int serviceId})> stations) {
    return _methodChannel.invokeMethod('fetchLogos', {
      'stations': stations.map((s) => {'freqKhz': s.freqKhz, 'serviceId': s.serviceId}).toList(),
    });
  }

  Future<void> stopLogoFetch() => _methodChannel.invokeMethod('stopLogoFetch');

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _eventsController.close();
  }
}
