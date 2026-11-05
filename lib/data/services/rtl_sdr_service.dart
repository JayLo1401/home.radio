import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  static final bool _desktop = Platform.isWindows || Platform.isLinux;

  // Desktop: the same test client in Dart (dart:io), see [_DesktopRtlTcp].
  _DesktopRtlTcp? _tcp;

  RtlSdrService() {
    if (_desktop) return;
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
    if (_desktop) {
      await _tcp?.close();
      final tcp = _DesktopRtlTcp(_statsController);
      final result = await tcp.connect(host, port);
      if (result.connected) _tcp = tcp;
      return result;
    }
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

  Future<void> disconnect() async {
    if (_desktop) {
      await _tcp?.close();
      _tcp = null;
      return;
    }
    await _methodChannel.invokeMethod('rtlDisconnect');
  }

  Future<void> setFrequencyHz(int hz) async =>
      _desktop ? _tcp?.command(0x01, hz) : await _methodChannel.invokeMethod('rtlSetFrequency', {'hz': hz});

  Future<void> setSampleRateHz(int hz) async =>
      _desktop ? _tcp?.command(0x02, hz) : await _methodChannel.invokeMethod('rtlSetSampleRate', {'hz': hz});

  Future<void> setGainMode({required bool auto}) async => _desktop
      ? _tcp?.command(0x03, auto ? 0 : 1)
      : await _methodChannel.invokeMethod('rtlSetGainMode', {'auto': auto});

  Future<void> setGainTenthDb(int tenthDb) async => _desktop
      ? _tcp?.command(0x04, tenthDb)
      : await _methodChannel.invokeMethod('rtlSetGain', {'tenthDb': tenthDb});

  Future<bool> isConnected() async {
    if (_desktop) return _tcp?.connected ?? false;
    final result = await _methodChannel.invokeMethod<bool>('rtlIsConnected');
    return result ?? false;
  }

  Future<void> dispose() async {
    await _tcp?.close();
    await _eventSub?.cancel();
    await _statsController.close();
  }
}

/// Desktop stand-in for RtlTcpClient.kt + RtlSdrPlugin.kt: connects, reads
/// the 12-byte "RTL0" header, counts the I/Q bytes (stats once per second)
/// and sends 5-byte big-endian commands.
class _DesktopRtlTcp {
  _DesktopRtlTcp(this._stats);

  final StreamController<RtlSdrStats> _stats;
  Socket? _socket;
  Timer? _timer;
  var _total = 0;
  var _lastTotal = 0;

  bool get connected => _socket != null;

  Future<RtlConnectResult> connect(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      socket.setOption(SocketOption.tcpNoDelay, true);
      final header = BytesBuilder();
      final headerDone = Completer<List<int>>();
      socket.listen(
        (data) {
          if (!headerDone.isCompleted) {
            header.add(data);
            if (header.length >= 12) {
              final bytes = header.takeBytes();
              headerDone.complete(bytes);
              _total += bytes.length - 12;
            }
          } else {
            _total += data.length;
          }
        },
        onError: (Object e) {
          if (!headerDone.isCompleted) headerDone.completeError(e);
          close();
        },
        onDone: () {
          if (!headerDone.isCompleted) headerDone.completeError('rtl_tcp connection closed while reading header');
          close();
        },
        cancelOnError: true,
      );
      final bytes = await headerDone.future.timeout(const Duration(seconds: 5));
      if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RTL0') {
        socket.destroy();
        return RtlConnectResult(connected: false, error: 'Unexpected rtl_tcp header magic');
      }
      final info = ByteData.sublistView(Uint8List.fromList(bytes), 4, 12);
      _socket = socket;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_stats.isClosed) return;
        _stats.add(RtlSdrStats(totalBytes: _total, bytesPerSec: _total - _lastTotal));
        _lastTotal = _total;
      });
      return RtlConnectResult(
        connected: true,
        tunerType: info.getUint32(0),
        tunerGainCount: info.getUint32(4),
      );
    } catch (e) {
      return RtlConnectResult(connected: false, error: '$e');
    }
  }

  void command(int cmd, int param) {
    final buf = ByteData(5)
      ..setUint8(0, cmd)
      ..setUint32(1, param & 0xFFFFFFFF);
    _socket?.add(buf.buffer.asUint8List());
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    final s = _socket;
    _socket = null;
    s?.destroy();
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
