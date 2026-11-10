import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/services/rtl_sdr_service.dart';

const _hello = [0xF2, 0x52, 0x54, 0x4C, 0x32];

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
