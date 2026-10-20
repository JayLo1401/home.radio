import 'dart:async';

import 'package:flutter/services.dart';

/// Dart-side bridge to [RtlSdrUsbPlugin] (Kotlin): lists attached RTL-SDR
/// sticks, requests the USB permission and reports attach/detach events.
/// Reception itself goes through [DabRtlSdrService.useDirectUsb].
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
