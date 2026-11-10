import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Test connection to an rtl_tcp server (Settings → Radio-Empfänger): connects
/// to [connect]'s host/port - a driver app on this device, a Raspberry Pi,
/// rtltcp.server - tunes it and counts the I/Q bytes, enough to verify the
/// whole chain (stick -> server -> network -> this app) independently of the
/// DAB+/FM receiver.
///
/// Pure dart:io, the same on every platform. Like the receiver
/// (cpp/hrdab/rtltcp_source.cpp) it sends HELLO_V2 first and takes whatever
/// the server answers (rtltcp.server docs/protocol-v2.md §2): "RTL2" = rtl_tcp
/// Jay extended (framed, with status messages), "RTL0" = classic rtl_tcp.
class RtlSdrService {
  final _statsController = StreamController<RtlSdrStats>.broadcast();
  final _messageController = StreamController<RtlServerMessage>.broadcast();
  _RtlTcpTestClient? _client;

  /// Live byte-rate stats while connected, roughly once per second.
  Stream<RtlSdrStats> get stats => _statsController.stream;

  /// Status and error messages of an rtl_tcp Jay extended server while
  /// connected (stick lost / back, kicked, ...).
  Stream<RtlServerMessage> get messages => _messageController.stream;

  /// Connects to an rtl_tcp server. Defaults to localhost:1234 (a driver app
  /// running on this same device).
  Future<RtlConnectResult> connect({String host = '127.0.0.1', int port = 1234}) async {
    await _client?.close();
    _client = null;
    final client = _RtlTcpTestClient(_statsController, _messageController);
    final result = await client.connect(host, port);
    if (result.connected) _client = client;
    return result;
  }

  Future<void> disconnect() async {
    await _client?.close();
    _client = null;
  }

  /// "Testen": what is behind host:port, without taking the stick where
  /// possible. First the info HELLO ("RTLI", rtltcp.server ≥ 1.8:
  /// server_info and all sticks of the server, nothing is opened). A server
  /// answering "RTL0" to that is classic rtl_tcp or an older rtltcp.server -
  /// a normal connect tells them apart (and briefly takes the stick).
  Future<RtlConnectResult> inspect({required String host, required int port}) async {
    final info = await _RtlTcpTestClient(_statsController, _messageController, info: true).connect(host, port);
    if (!info.connected || info.protocol == RtlTcpProtocol.jayExtended) return info;
    final result = await connect(host: host, port: port);
    await disconnect();
    return result;
  }

  Future<void> setFrequencyHz(int hz) async => _client?.command(0x01, hz);

  Future<void> setSampleRateHz(int hz) async => _client?.command(0x02, hz);

  Future<void> setGainMode({required bool auto}) async => _client?.command(0x03, auto ? 0 : 1);

  Future<void> setGainTenthDb(int tenthDb) async => _client?.command(0x04, tenthDb);

  Future<bool> isConnected() async => _client?.connected ?? false;

  Future<void> dispose() async {
    await _client?.close();
    await _statsController.close();
    await _messageController.close();
  }
}

/// The two protocols an rtl_tcp server can speak; [label] is what the UI
/// shows (the wire names RTL0/RTL2 stay internal).
enum RtlTcpProtocol {
  classic('rtl_tcp'),
  jayExtended('rtl_tcp Jay extended');

  const RtlTcpProtocol(this.label);
  final String label;
}

/// One connection: HELLO_V2, header, then either the raw v1 stream or the
/// framed v2 stream (u8 type | u32 length | payload), parsed byte by byte as
/// it arrives - I/Q payloads are only counted.
class _RtlTcpTestClient {
  _RtlTcpTestClient(this._stats, this._messages, {this.info = false});

  static const _helloV2 = [0xF2, 0x52, 0x54, 0x4C, 0x32]; // F2 "RTL2"
  static const _helloInfo = [0xF2, 0x52, 0x54, 0x4C, 0x49]; // F2 "RTLI"

  // Info HELLO: server_info + devices, then the server closes.
  final bool info;
  List<RtlStick>? _devices;
  static const _frameIq = 0x01;
  static const _frameJson = 0x02;
  static const _frameCommand = 0x03;
  static const _maxFrame = 16 << 20;
  static const _maxJsonFrame = 1 << 20;
  // A server whose stick idles opens it on connect and only then answers -
  // up to 10 s (rtltcp.server's "v1 client waits for stick").
  static const _handshakeTimeout = Duration(seconds: 12);

  final StreamController<RtlSdrStats> _stats;
  final StreamController<RtlServerMessage> _messages;
  Socket? _socket;
  Timer? _timer;
  var _total = 0;
  var _lastTotal = 0;

  RtlTcpProtocol? _protocol;
  final _header = BytesBuilder(copy: false);
  // v2 frame parser state.
  final _frameHead = BytesBuilder(copy: false);
  var _frameType = 0;
  var _frameRemaining = 0;
  final _json = BytesBuilder(copy: false);

  // v2 handshake: server_info first, then the first status (or I/Q).
  Map<String, dynamic>? _serverInfo;
  Map<String, dynamic>? _tuner;
  Completer<RtlConnectResult>? _handshake;

  bool get connected => _socket != null;

  Future<RtlConnectResult> connect(String host, int port) async {
    final Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    } catch (e) {
      return RtlConnectResult(connected: false, error: 'rtl_tcp-Server $host:$port nicht erreichbar ($e)');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final handshake = _handshake = Completer<RtlConnectResult>();
    // HELLO before reading anything; a classic server ignores it as an
    // unknown command.
    socket.add(info ? _helloInfo : _helloV2);
    socket.listen(
      _onData,
      onError: (Object e) => _end('Verbindung zum rtl_tcp-Server unterbrochen ($e)'),
      onDone: () {
        // The info answer ends with the server closing - normal there.
        if (info && _serverInfo != null) _completeV2();
        _end(_protocol == null
            ? 'rtl_tcp-Server hat die Verbindung abgelehnt (belegt oder kein Stick bereit)'
            : 'Verbindung zum rtl_tcp-Server beendet');
      },
      cancelOnError: true,
    );
    _socket = socket;
    final result = await handshake.future.timeout(
      _handshakeTimeout,
      onTimeout: () => const RtlConnectResult(connected: false, error: 'rtl_tcp-Server antwortet nicht'),
    );
    if (!result.connected || info) {
      await close();
      return result;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_stats.isClosed) return;
      _stats.add(RtlSdrStats(totalBytes: _total, bytesPerSec: _total - _lastTotal));
      _lastTotal = _total;
    });
    return result;
  }

  void _finishHandshake(RtlConnectResult result) {
    final h = _handshake;
    _handshake = null;
    if (h != null && !h.isCompleted) h.complete(result);
  }

  // Connection gone: fails a pending handshake, otherwise tells the screen.
  void _end(String message) {
    if (_handshake != null) {
      _finishHandshake(RtlConnectResult(connected: false, error: message));
    } else if (_socket != null && !info && !_messages.isClosed) {
      _messages.add(RtlServerMessage(isError: true, text: message));
    }
    close();
  }

  void _onData(Uint8List data) {
    var offset = 0;
    if (_protocol == null) {
      final need = 12 - _header.length;
      _header.add(data.sublist(0, need.clamp(0, data.length)));
      offset = need.clamp(0, data.length);
      if (_header.length < 12) return;
      final header = _header.takeBytes();
      final magic = String.fromCharCodes(header.sublist(0, 4));
      if (magic == 'RTL0') {
        _protocol = RtlTcpProtocol.classic;
        final dongle = ByteData.sublistView(header, 4, 12);
        _finishHandshake(RtlConnectResult(
          connected: true,
          protocol: RtlTcpProtocol.classic,
          tunerType: dongle.getUint32(0),
          tunerGainCount: dongle.getUint32(4),
        ));
      } else if (magic == 'RTL2') {
        _protocol = RtlTcpProtocol.jayExtended;
      } else {
        _finishHandshake(const RtlConnectResult(connected: false, error: 'Kein rtl_tcp-Server (unbekannte Begrüßung)'));
        close();
        return;
      }
    }
    if (_protocol == RtlTcpProtocol.classic) {
      _total += data.length - offset;
      return;
    }
    while (offset < data.length && _socket != null) {
      if (_frameHead.length < 5) {
        final take = (5 - _frameHead.length).clamp(0, data.length - offset);
        _frameHead.add(data.sublist(offset, offset + take));
        offset += take;
        if (_frameHead.length < 5) return;
        final head = ByteData.sublistView(_frameHead.toBytes());
        _frameType = head.getUint8(0);
        _frameRemaining = head.getUint32(1);
        if (_frameRemaining > _maxFrame) {
          _end('rtl_tcp-Server: Datenstrom fehlerhaft');
          return;
        }
        if (_frameRemaining == 0) _frameDone();
        continue;
      }
      final take = (data.length - offset).clamp(0, _frameRemaining);
      if (_frameType == _frameIq) {
        _total += take;
        // I/Q before any status: the stick is ours.
        if (_serverInfo != null) _completeV2();
      } else if (_frameType == _frameJson && _json.length + take <= _maxJsonFrame) {
        _json.add(data.sublist(offset, offset + take));
      }
      offset += take;
      _frameRemaining -= take;
      if (_frameRemaining == 0) _frameDone();
    }
  }

  void _frameDone() {
    _frameHead.clear();
    if (_frameType != _frameJson) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(_json.takeBytes(), allowMalformed: true));
    } catch (_) {
      return;
    }
    if (decoded is Map<String, dynamic>) _onMessage(decoded);
  }

  RtlStick? get _device => RtlStick.fromJson(_serverInfo?['device']);

  String? get _deviceName => _device?.name;

  String get _stick => _deviceName == null ? 'USB-Stick am rtl_tcp-Server' : '„$_deviceName“';

  void _onMessage(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'server_info':
        if (msg['auth'] == 'required') {
          _end('rtl_tcp-Server verlangt eine Anmeldung, das wird nicht mehr unterstützt. '
              'Bitte den rtltcp.server im lokalen Netz verwenden.');
          return;
        }
        _serverInfo = msg;
      case 'devices':
        final list = msg['devices'];
        _devices = list is List ? list.map(RtlStick.fromJson).whereType<RtlStick>().toList() : const [];
        if (info && _serverInfo != null) _completeV2();
      case 'status':
        final tuner = msg['tuner'];
        if (tuner is Map<String, dynamic>) _tuner = tuner;
        final state = msg['state'];
        final ready = state == 'ready' || state == 'device_restored';
        final text = switch (state) {
          'ready' || 'device_restored' => '$_stick bereit',
          'starting' => '$_stick startet …',
          'device_not_ready' => '$_stick nicht bereit',
          'device_lost' => '$_stick getrennt – der Server verbindet neu …',
          _ => null,
        };
        if (_serverInfo != null) _completeV2();
        if (text != null && !_messages.isClosed) {
          _messages.add(RtlServerMessage(isError: !ready, text: text));
        }
      case 'error':
        final text = _errorText(msg);
        if (msg['fatal'] != false) {
          _end(text);
        } else if (!_messages.isClosed) {
          _messages.add(RtlServerMessage(isError: true, text: text));
        }
      case 'ping':
        _send(_frameJson, utf8.encode(jsonEncode({'type': 'pong', 'id': msg['id'] ?? 0})));
    }
  }

  String _errorText(Map<String, dynamic> msg) {
    final code = msg['code'];
    final message = msg['message'] is String ? msg['message'] as String : '';
    final client = msg['client'] is String ? msg['client'] as String : '';
    final who = _deviceName == null ? 'rtl_tcp-Server' : '„$_deviceName“';
    return switch (code) {
      'BUSY' => client.isEmpty
          ? '$who wird bereits von einem anderen Gerät verwendet'
          : '$who wird bereits von $client verwendet',
      'AUTH_REQUIRED' || 'AUTH_FAILED' => 'rtl_tcp-Server verlangt eine Anmeldung, das wird nicht mehr unterstützt. '
          'Bitte den rtltcp.server im lokalen Netz verwenden.',
      'KICKED' => 'Vom rtl_tcp-Server getrennt',
      'PROTOCOL_ERROR' => 'rtl_tcp-Server meldet einen Protokollfehler${message.isEmpty ? '' : ': $message'}',
      _ => 'rtl_tcp-Server: ${message.isEmpty ? '$code' : message}',
    };
  }

  void _completeV2() {
    if (_handshake == null) return;
    final gains = _tuner?['gains'];
    final tunerType = _tuner?['type'];
    _finishHandshake(RtlConnectResult(
      connected: true,
      protocol: RtlTcpProtocol.jayExtended,
      tunerType: tunerType is int ? tunerType : null,
      tunerGainCount: gains is List ? gains.length : null,
      device: _device,
      devices: _devices,
      server: [_serverInfo?['server'], _serverInfo?['version']].whereType<String>().join(' '),
    ));
  }

  void _send(int type, List<int> payload) {
    final frame = ByteData(5 + payload.length)
      ..setUint8(0, type)
      ..setUint32(1, payload.length);
    final bytes = frame.buffer.asUint8List()..setRange(5, 5 + payload.length, payload);
    _socket?.add(bytes);
  }

  void command(int cmd, int param) {
    final buf = (ByteData(5)
          ..setUint8(0, cmd)
          ..setUint32(1, param & 0xFFFFFFFF))
        .buffer
        .asUint8List();
    if (_protocol == RtlTcpProtocol.jayExtended) {
      _send(_frameCommand, buf);
    } else {
      _socket?.add(buf);
    }
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
    this.protocol,
    this.tunerType,
    this.tunerGainCount,
    this.device,
    this.devices,
    this.server,
    this.error,
  });

  final bool connected;

  /// What the server answered to the HELLO.
  final RtlTcpProtocol? protocol;
  final int? tunerType;
  final int? tunerGainCount;

  /// rtl_tcp Jay extended only: the stick behind this port (server_info).
  final RtlStick? device;

  /// Info HELLO on rtltcp.server ≥ 1.8 only: all sticks of the server.
  final List<RtlStick>? devices;

  String? get deviceName => device?.name;
  String? get location => device?.location;
  String? get antenna => device?.antenna;

  /// rtl_tcp Jay extended only: e.g. "rtltcp.server 1.5.0".
  final String? server;
  final String? error;
}

/// One stick as rtl_tcp Jay extended describes it - server_info.device or an
/// entry of `devices` (rtltcp.server docs/protocol-v2.md §4.1, §4.5). Empty
/// strings count as not set.
class RtlStick {
  const RtlStick({
    this.name,
    this.serial,
    this.port,
    this.source,
    this.remoteInstance,
    this.remoteSite,
    this.location,
    this.antenna,
    this.state,
    this.busyBy,
    this.tuner,
  });

  final String? name;
  final String? serial;
  final int? port;

  /// "usb" (at the server) or "remote" (shared from another site).
  final String? source;
  final String? remoteInstance;
  final String? remoteSite;

  /// Location name; a remote stick's site stands in when it is missing.
  final String? location;
  final String? antenna;

  /// `devices` only: ready | starting | device_not_ready | device_lost | idle.
  final String? state;

  /// `devices` only: who holds the stick; null = free.
  final String? busyBy;
  final String? tuner;

  bool get isRemote => source == 'remote';

  static String? _str(Object? map, String key) {
    final value = map is Map ? map[key] : null;
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  static RtlStick? fromJson(Object? json) {
    if (json is! Map) return null;
    final remote = json['remote'];
    final port = json['port'];
    return RtlStick(
      name: _str(json, 'name'),
      serial: _str(json, 'serial'),
      port: port is int ? port : null,
      source: _str(json, 'source'),
      remoteInstance: _str(remote, 'instance'),
      remoteSite: _str(remote, 'site'),
      location: _str(json, 'location') ?? _str(remote, 'site'),
      antenna: _str(json, 'antenna'),
      state: _str(json, 'state'),
      busyBy: _str(json, 'busy_by'),
      tuner: _str(json, 'tuner'),
    );
  }

  /// German text for [state], null when there is nothing to say.
  String? get stateText => switch (state) {
        'starting' => 'startet',
        'device_not_ready' => 'nicht bereit',
        'device_lost' => 'getrennt',
        'idle' => 'ruht',
        _ => null,
      };
}

class RtlServerMessage {
  const RtlServerMessage({required this.isError, required this.text});

  final bool isError;
  final String text;
}

class RtlSdrStats {
  const RtlSdrStats({required this.totalBytes, required this.bytesPerSec});

  final int totalBytes;
  final int bytesPerSec;
}
