import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/services/rtl_sdr_service.dart';

const _hello = [0xF2, 0x52, 0x54, 0x4C, 0x32];
const _helloInfo = [0xF2, 0x52, 0x54, 0x4C, 0x49];

Uint8List _rtl0() {
  final h = ByteData(12)
    ..setUint32(4, 5)
    ..setUint32(8, 29);
  h.buffer.asUint8List().setRange(0, 4, 'RTL0'.codeUnits);
  return h.buffer.asUint8List();
}

/// A fake server for any number of connections: [script] gets each
/// connection and the HELLO it started with.
Future<ServerSocket> _multiServer(void Function(Socket s, List<int> hello) script) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((s) {
    final got = <int>[];
    var started = false;
    s.listen((data) {
      got.addAll(data);
      if (!started && got.length >= 5) {
        started = true;
        script(s, got.sublist(0, 5));
      }
    }, onError: (_) {});
  });
  return server;
}

Uint8List _frame(int type, List<int> payload) {
  final b = ByteData(5 + payload.length)
    ..setUint8(0, type)
    ..setUint32(1, payload.length);
  return b.buffer.asUint8List()..setRange(5, 5 + payload.length, payload);
}

Uint8List _json(Map<String, dynamic> msg) => _frame(0x02, utf8.encode(jsonEncode(msg)));

/// A one-connection fake server: checks the HELLO, then runs [script].
Future<ServerSocket> _server(void Function(Socket s) script, {Completer<List<int>>? received}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((s) {
    final got = <int>[];
    var started = false;
    s.listen((data) {
      got.addAll(data);
      if (!started && got.length >= 5) {
        started = true;
        expect(got.sublist(0, 5), _hello);
        script(s);
      }
      if (received != null && got.length >= 15 && !received.isCompleted) received.complete(got.sublist(5));
    });
  });
  return server;
}

void main() {
  test('inspect: info HELLO lists all sticks without taking one', () async {
    final hellos = <List<int>>[];
    final server = await _multiServer((s, hello) {
      hellos.add(hello);
      s.add(Uint8List(12)..setRange(0, 4, 'RTL2'.codeUnits));
      s.add(_json({
        'type': 'server_info',
        'auth': 'none',
        'device': {
          'name': 'Standort1 Stick 1',
          'port': 1235,
          'source': 'remote',
          'remote': {'instance': 'Funkfreund Max', 'site': 'Standort1'},
          'location': 'Wien Dach',
          'antenna': 'DAB-Rundstrahler',
        },
      }));
      s.add(_json({
        'type': 'devices',
        'devices': [
          {'port': 1234, 'name': 'Dach', 'source': 'usb', 'state': 'idle'},
          {
            'port': 1235,
            'name': 'Standort1 Stick 1',
            'source': 'remote',
            'location': 'Wien Dach',
            'antenna': 'DAB-Rundstrahler',
            'state': 'ready',
            'busy_by': '192.168.1.20',
          },
        ],
      }));
      s.close();
    });
    final service = RtlSdrService();
    final r = await service.inspect(host: '127.0.0.1', port: server.port);
    expect(hellos, [_helloInfo]);
    expect(r.connected, isTrue);
    expect(r.protocol, RtlTcpProtocol.jayExtended);
    expect(r.device!.remoteInstance, 'Funkfreund Max');
    expect(r.location, 'Wien Dach');
    expect(r.devices!.map((d) => d.port), [1234, 1235]);
    expect(r.devices![0].antenna, isNull);
    expect(r.devices![0].stateText, 'ruht');
    expect(r.devices![1].busyBy, '192.168.1.20');
    await service.dispose();
    await server.close();
  });

  test('inspect: RTL0 to the info HELLO falls back to a normal connect', () async {
    final hellos = <List<int>>[];
    final server = await _multiServer((s, hello) {
      hellos.add(hello);
      s.add(_rtl0());
    });
    final service = RtlSdrService();
    final r = await service.inspect(host: '127.0.0.1', port: server.port);
    expect(hellos, [_helloInfo, _hello]);
    expect(r.connected, isTrue);
    expect(r.protocol, RtlTcpProtocol.classic);
    expect(r.devices, isNull);
    expect(await service.isConnected(), isFalse);
    await service.dispose();
    await server.close();
  });

  test('classic rtl_tcp: RTL0 header, raw commands', () async {
    final received = Completer<List<int>>();
    final server = await _server((s) {
      final h = ByteData(12)
        ..setUint32(4, 5)
        ..setUint32(8, 29);
      h.buffer.asUint8List().setRange(0, 4, 'RTL0'.codeUnits);
      s.add(h.buffer.asUint8List());
    }, received: received);
    final service = RtlSdrService();
    final r = await service.connect(host: '127.0.0.1', port: server.port);
    expect(r.connected, isTrue);
    expect(r.protocol, RtlTcpProtocol.classic);
    expect(r.protocol!.label, 'rtl_tcp');
    expect(r.tunerType, 5);
    expect(r.tunerGainCount, 29);
    await service.setFrequencyHz(100000000);
    await service.setSampleRateHz(2048000);
    // Two raw 5-byte commands, no framing.
    expect((await received.future).sublist(0, 5), [0x01, 0x05, 0xF5, 0xE1, 0x00]);
    await service.dispose();
    await server.close();
  });

  test('rtl_tcp Jay extended: server_info + status, framed commands', () async {
    final received = Completer<List<int>>();
    final server = await _server((s) {
      final h = Uint8List(12)..setRange(0, 4, 'RTL2'.codeUnits);
      h[5] = 1;
      s.add(h);
      s.add(_json({
        'type': 'server_info',
        'server': 'rtltcp.server',
        'version': '1.5.0',
        'device': {
          'name': 'Standort1 Stick 1',
          'serial': '1',
          'source': 'usb',
          'location': 'Wien Dach',
          'antenna': 'DAB-Rundstrahler',
        },
        'auth': 'none',
        'future_field': 42,
      }));
      s.add(_frame(0x7F, [1, 2, 3])); // unknown frame type: skipped
      s.add(_json({
        'type': 'status',
        'state': 'ready',
        'tuner': {'type': 5, 'name': 'R820T', 'gains': [0, 9, 14]},
      }));
      s.add(_frame(0x01, List.filled(1000, 127)));
    }, received: received);
    final service = RtlSdrService();
    final r = await service.connect(host: '127.0.0.1', port: server.port);
    expect(r.connected, isTrue);
    expect(r.protocol, RtlTcpProtocol.jayExtended);
    expect(r.protocol!.label, 'rtl_tcp Jay extended');
    expect(r.deviceName, 'Standort1 Stick 1');
    expect(r.location, 'Wien Dach');
    expect(r.antenna, 'DAB-Rundstrahler');
    expect(r.server, 'rtltcp.server 1.5.0');
    expect(r.tunerType, 5);
    expect(r.tunerGainCount, 3);
    await service.setFrequencyHz(100000000);
    // One command frame: type 3, length 5, then the v1 command.
    expect((await received.future).sublist(0, 10), [0x03, 0, 0, 0, 5, 0x01, 0x05, 0xF5, 0xE1, 0x00]);
    await service.dispose();
    await server.close();
  });

  test('remote stick without location: remote.site stands in', () async {
    final server = await _server((s) {
      s.add(Uint8List(12)..setRange(0, 4, 'RTL2'.codeUnits));
      s.add(_json({
        'type': 'server_info',
        'device': {
          'name': 'Stick 1',
          'source': 'remote',
          'remote': {'instance': 'abc', 'site': 'Graz'},
        },
        'auth': 'none',
      }));
      s.add(_json({'type': 'status', 'state': 'starting'}));
    });
    final service = RtlSdrService();
    final r = await service.connect(host: '127.0.0.1', port: server.port);
    expect(r.connected, isTrue);
    expect(r.location, 'Graz');
    expect(r.antenna, isNull);
    await service.dispose();
    await server.close();
  });

  test('busy server: message names the stick and the owner', () async {
    final server = await _server((s) {
      s.add(Uint8List(12)..setRange(0, 4, 'RTL2'.codeUnits));
      s.add(_json({
        'type': 'server_info',
        'device': {'name': 'Dach'},
        'auth': 'none',
      }));
      s.add(_json({'type': 'error', 'code': 'BUSY', 'fatal': true, 'client': '192.168.1.20'}));
      s.close(); // flushes first, unlike destroy()
    });
    final service = RtlSdrService();
    final r = await service.connect(host: '127.0.0.1', port: server.port);
    expect(r.connected, isFalse);
    expect(r.error, '„Dach“ wird bereits von 192.168.1.20 verwendet');
    await service.dispose();
    await server.close();
  });

  test('a server that still wants a login is refused with a hint', () async {
    final server = await _server((s) {
      s.add(Uint8List(12)..setRange(0, 4, 'RTL2'.codeUnits));
      s.add(_json({'type': 'server_info', 'auth': 'required'}));
    });
    final service = RtlSdrService();
    final r = await service.connect(host: '127.0.0.1', port: server.port);
    expect(r.connected, isFalse);
    expect(r.error, contains('nicht mehr unterstützt'));
    await service.dispose();
    await server.close();
  });

  test('closed without a word = refused', () async {
    final server = await _server((s) => s.destroy());
    final service = RtlSdrService();
    final r = await service.connect(host: '127.0.0.1', port: server.port);
    expect(r.connected, isFalse);
    expect(r.error, contains('abgelehnt'));
    await service.dispose();
    await server.close();
  });
}
