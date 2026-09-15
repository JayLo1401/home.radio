import 'dart:async';

import 'package:flutter/services.dart';

import '../models/usb_device_info.dart';

/// Dart-side bridge to [DabUsbPlugin] (Kotlin) - native, independent USB
/// Host API access to the DAB+ USB adapter. See the plugin's doc comment:
/// this only covers device discovery/permission/endpoint inspection so far;
/// the dongle's actual command protocol (scan, tune, service list, signal
/// strength, ...) still needs to be determined from a real USB capture and
/// is not implemented yet.
class DabUsbService {
  static const _methodChannel = MethodChannel('home_radio/dab_usb');
  static const _eventChannel = EventChannel('home_radio/dab_usb/events');

  final _deviceChangeController = StreamController<void>.broadcast();
  final _scanEventController = StreamController<Map<String, dynamic>>.broadcast();
  final _permissionController = StreamController<Map<String, dynamic>>.broadcast();
  final _playbackStatusController = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _eventSub;

  /// Fires whenever a USB device is attached/detached, so the UI can refresh
  /// [listDevices].
  Stream<void> get deviceChanges => _deviceChangeController.stream;

  /// Raw scan/tune progress events from [dabScanBand3]: `scanProgress`
  /// (currently trying a channel), `channelLocked` (a station was found) and
  /// `scanFinished`. See DabUsbPlugin.scanBand3's doc comment for the shape.
  Stream<Map<String, dynamic>> get scanEvents => _scanEventController.stream;

  /// Fires with `{deviceName, granted}` whenever the OS USB permission
  /// dialog (triggered by [autoRequestPermissionForAdapter] or
  /// [requestPermission]) is answered - lets the app auto-open the adapter
  /// and start playback the moment permission is granted, without the user
  /// having to open the DAB+ screen themselves.
  Stream<Map<String, dynamic>> get permissionEvents => _permissionController.stream;

  /// Fires with `{status, message?}` while DAB+ playback ([dabPlayService])
  /// is running: `tuning`, `resolvingSubchannel`, `playing`, `busy`, or
  /// `error` (with a `message` code). See DabUsbPlugin.runDabPlayback.
  Stream<Map<String, dynamic>> get playbackStatusEvents => _playbackStatusController.stream;

  DabUsbService() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen((event) {
      final map = event as Map<dynamic, dynamic>;
      switch (map['type']) {
        case 'deviceAttached':
        case 'deviceDetached':
          _deviceChangeController.add(null);
        case 'scanProgress':
        case 'channelLocked':
        case 'scanFinished':
          _scanEventController.add(map.cast<String, dynamic>());
        case 'permissionResult':
          _permissionController.add(map.cast<String, dynamic>());
        case 'playbackStatus':
          _playbackStatusController.add(map.cast<String, dynamic>());
      }
    });
  }

  Future<List<UsbDeviceInfo>> listDevices() async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>('listDevices');
    return (result ?? const [])
        .cast<Map<dynamic, dynamic>>()
        .map(UsbDeviceInfo.fromMap)
        .toList();
  }

  Future<bool> requestPermission(String deviceName) async {
    final granted = await _methodChannel.invokeMethod<bool>(
      'requestPermission',
      {'deviceName': deviceName},
    );
    return granted ?? false;
  }

  Future<({UsbDeviceInfo device, List<UsbInterfaceInfo> interfaces})?> openDevice(
    String deviceName,
  ) async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'openDevice',
      {'deviceName': deviceName},
    );
    if (result == null) return null;
    final device = UsbDeviceInfo.fromMap(result['device'] as Map<dynamic, dynamic>);
    final interfaces = (result['interfaces'] as List<dynamic>)
        .cast<Map<dynamic, dynamic>>()
        .map(UsbInterfaceInfo.fromMap)
        .toList();
    return (device: device, interfaces: interfaces);
  }

  Future<void> closeDevice() => _methodChannel.invokeMethod('closeDevice');

  /// Runs a fixed test sequence (the Raontech reference driver's power-up
  /// check) against the currently open device's bulk endpoints and logs
  /// every step natively (`adb logcat -s DabProbe`) - so this can be
  /// re-checked by reading the log instead of hand-typing hex bytes via a
  /// remote control. See DabUsbPlugin.runRaontechProbe's doc comment.
  Future<void> runRaontechProbe() => _methodChannel.invokeMethod('runRaontechProbe');

  /// Fires a whole battery of hypotheses at the device in one go (raw
  /// descriptors, string descriptors, endpoint halt-clear, a vendor
  /// control-request sweep, unsolicited bulk reads, padded/alternate bulk
  /// command variants) and logs everything natively - one round-trip
  /// instead of many. See DabUsbPlugin.runFullDiagnostics's doc comment.
  Future<void> runFullDiagnostics() => _methodChannel.invokeMethod('runFullDiagnostics');

  /// Sends one raw USB control transfer on the currently open device and
  /// returns the response as a hex string - the tool for manually probing
  /// the dongle's undocumented vendor protocol. [requestType] bit 7 selects
  /// direction (0x80+ = device-to-host/IN); [length] is the max bytes to
  /// read back for an IN transfer.
  Future<({int bytesTransferred, String dataHex})> controlTransfer({
    required int requestType,
    required int request,
    required int value,
    required int index,
    int length = 64,
    String? dataHex,
    int timeoutMs = 1000,
  }) async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'controlTransfer',
      {
        'requestType': requestType,
        'request': request,
        'value': value,
        'index': index,
        'length': length,
        'dataHex': dataHex,
        'timeoutMs': timeoutMs,
      },
    );
    return (
      bytesTransferred: result?['bytesTransferred'] as int? ?? -1,
      dataHex: result?['dataHex'] as String? ?? '',
    );
  }

  Future<({int bytesTransferred, String dataHex})> bulkTransfer({
    required int endpointAddress,
    int length = 64,
    String? dataHex,
    int timeoutMs = 1000,
  }) async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'bulkTransfer',
      {
        'endpointAddress': endpointAddress,
        'length': length,
        'dataHex': dataHex,
        'timeoutMs': timeoutMs,
      },
    );
    return (
      bytesTransferred: result?['bytesTransferred'] as int? ?? -1,
      dataHex: result?['dataHex'] as String? ?? '',
    );
  }

  /// Requests USB permission for the known DAB+ adapter (if currently
  /// attached and not yet permitted) without any UI interaction beyond the
  /// system permission dialog - meant to be called once at app startup.
  /// Never targets any other USB device (e.g. the TV's own Wi-Fi adapter).
  Future<void> autoRequestPermissionForAdapter() =>
      _methodChannel.invokeMethod('autoRequestPermission');

  /// Runs the full chip power-up/initialization sequence (ported from the
  /// Raontech reference driver) on the currently open device. Returns true
  /// if the power-up handshake succeeded.
  Future<bool> dabInitialize() async {
    final result = await _methodChannel.invokeMethod<bool>('dabInitialize');
    return result ?? false;
  }

  /// Runs a full DAB Band III scan (41 channels): initializes the chip, then
  /// tunes to each channel and checks OFDM+FEC lock. Progress/results stream
  /// via [scanEvents]; also logs everything (`adb logcat -s DabProbe`).
  Future<void> dabScanBand3() => _methodChannel.invokeMethod('dabScanBand3');

  /// Tunes to one Band III channel by index (matching the order streamed via
  /// [scanEvents] `scanProgress`/`channelLocked` events).
  Future<bool> dabTuneChannel(int index) async {
    final result = await _methodChannel.invokeMethod<bool>('dabTuneChannel', {'index': index});
    return result ?? false;
  }

  /// Tunes by frequency instead of scan-session index - works for a
  /// favorite saved in an earlier session without needing a fresh scan.
  Future<bool> dabTuneFrequency(int freqKhz) async {
    final result =
        await _methodChannel.invokeMethod<bool>('dabTuneFrequency', {'freqKhz': freqKhz});
    return result ?? false;
  }

  /// Starts full DAB+ playback of one station (tune, resolve its subchannel
  /// from FIC, decode the DAB+ superframe/AAC stream, play through the
  /// device's speakers) - progress/result via [playbackStatusEvents].
  Future<void> dabPlayService({required int freqKhz, required int serviceId}) {
    return _methodChannel.invokeMethod('dabPlayService', {
      'freqKhz': freqKhz,
      'serviceId': serviceId,
    });
  }

  Future<void> dabStopPlayback() => _methodChannel.invokeMethod('dabStopPlayback');

  /// Tunes to a single channel and logs detailed lock/antenna status every
  /// 200ms for ~8 seconds - faster to iterate on than a full scan when
  /// debugging one specific, externally-confirmed-active channel.
  Future<void> dabTestChannel(int index) => _methodChannel.invokeMethod('dabTestChannel', {'index': index});

  Future<({int lockStatus, bool antennaLocked, int antennaLevel})> dabGetStatus() async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>('dabGetStatus');
    return (
      lockStatus: result?['lockStatus'] as int? ?? 0,
      antennaLocked: result?['antennaLocked'] as bool? ?? false,
      antennaLevel: result?['antennaLevel'] as int? ?? 0,
    );
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _deviceChangeController.close();
    await _scanEventController.close();
    await _permissionController.close();
    await _playbackStatusController.close();
  }
}
