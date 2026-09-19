import 'dart:async';

import 'package:flutter/services.dart';

/// Dart-side bridge to [RtlSdrUsbPlugin] (Kotlin) - our own, direct-USB
/// RTL-SDR service ("unser eigener USB-TCP Dienst"): opens the dongle over
/// Android's USB Host API and native libusb/librtlsdr, then serves it as a
/// local `rtl_tcp`-protocol TCP server. Once started, [RtlSdrService] (the
/// generic rtl_tcp client) can connect to it exactly like it would to an
/// external driver app or a network rtl_tcp server - this class only covers
/// getting our own server running, not the client side.
class RtlSdrUsbService {
  static const _methodChannel = MethodChannel('home_radio/rtlsdr_usb');
  static const _eventChannel = EventChannel('home_radio/rtlsdr_usb/events');

  StreamSubscription<dynamic>? _eventSub;
  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();

  /// Raw device attach/detach/permission events, e.g. `{"type": "deviceAttached", ...}`.
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  RtlSdrUsbService() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen((event) {
      _eventsController.add((event as Map).cast<String, dynamic>());
    });
  }

  Future<List<RtlSdrUsbDevice>> listDevices() async {
    final result = await _methodChannel.invokeListMethod<dynamic>('listDevices');
    return (result ?? [])
        .map((e) => RtlSdrUsbDevice.fromMap((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<bool> requestPermission(String deviceName) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'requestPermission',
      {'deviceName': deviceName},
    );
    return result ?? false;
  }

  /// Starts the native rtl_tcp server against whichever known RTL-SDR
  /// dongle is currently attached and permitted. Returns the bind
  /// address/port actually used on success, throws a [PlatformException]
  /// otherwise (e.g. `not_found`, `no_permission`, `open_failed`).
  Future<({String bindAddr, int port})> startServer({
    String bindAddr = '127.0.0.1',
    int port = 1234,
    int frequencyHz = 100000000,
    int sampleRateHz = 2048000,
    int gainTenthsDb = 0,
    int ppmError = 0,
    bool directSampling = false,
    bool biasTee = false,
  }) async {
    final result = await _methodChannel.invokeMapMethod<String, dynamic>('startServer', {
      'bindAddr': bindAddr,
      'port': port,
      'frequencyHz': frequencyHz,
      'sampleRateHz': sampleRateHz,
      'gainTenthsDb': gainTenthsDb,
      'ppmError': ppmError,
      'directSampling': directSampling,
      'biasTee': biasTee,
    });
    return (bindAddr: result?['bindAddr'] as String? ?? bindAddr, port: result?['port'] as int? ?? port);
  }

  Future<void> stopServer() => _methodChannel.invokeMethod('stopServer');

  Future<bool> isServerRunning() async {
    final result = await _methodChannel.invokeMethod<bool>('isServerRunning');
    return result ?? false;
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _eventsController.close();
  }
}

class RtlSdrUsbDevice {
  const RtlSdrUsbDevice({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    this.productName,
    this.manufacturerName,
    required this.hasPermission,
  });

  factory RtlSdrUsbDevice.fromMap(Map<String, dynamic> map) => RtlSdrUsbDevice(
        deviceName: map['deviceName'] as String? ?? '',
        vendorId: map['vendorId'] as int? ?? 0,
        productId: map['productId'] as int? ?? 0,
        productName: map['productName'] as String?,
        manufacturerName: map['manufacturerName'] as String?,
        hasPermission: map['hasPermission'] as bool? ?? false,
      );

  final String deviceName;
  final int vendorId;
  final int productId;
  final String? productName;
  final String? manufacturerName;
  final bool hasPermission;

  String get label => productName ?? 'VID 0x${vendorId.toRadixString(16)} / PID 0x${productId.toRadixString(16)}';
}
