import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/ha_discovery.dart';
import 'package:home_system/data/services/rtl_sdr_service.dart';
import 'package:home_system/data/services/rtl_tcp_discovery.dart';

/// A web server answering /manifest.json with [name].
Future<HttpServer> _web(String name) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((r) {
    if (r.uri.path == '/manifest.json') {
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({'name': name, 'short_name': name}));
    } else {
      r.response.statusCode = 404;
    }
    r.response.close();
  });
  return server;
}

/// A classic rtl_tcp: "RTL0", tuner type 5 (R820T), 29 gains - then I/Q.
Future<ServerSocket> _rtlTcp({bool garbage = false}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    socket.listen((_) {}, onError: (_) {}, cancelOnError: true);
    socket.add(garbage ? utf8.encode('HTTP/1.1 400 Bad\r\n\r\n') : [...ascii.encode('RTL0'), 0, 0, 0, 5, 0, 0, 0, 29]);
  });
  return server;
}

void main() {
  test('Home Assistant: recognised by its manifest, with or without MQTT on the machine', () async {
    final ha = await _web('Home Assistant');
    final other = await _web('Some NAS');
    final mqtt = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    mqtt.listen((s) => s.destroy());
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();
    try {
      final found = await checkHomeAssistant('127.0.0.1', port: ha.port, mqttPort: mqtt.port);
      expect(found, isNotNull);
      expect((found!.host, found.port, found.mqtt, found.url), ('127.0.0.1', ha.port, true, 'http://127.0.0.1:${ha.port}'));
      expect((await checkHomeAssistant('127.0.0.1', port: ha.port, mqttPort: closedPort))!.mqtt, isFalse);
      expect(await checkHomeAssistant('127.0.0.1', port: other.port), isNull);
      expect(await checkHomeAssistant('127.0.0.1', port: closedPort), isNull);
    } finally {
      await ha.close(force: true);
      await other.close(force: true);
      await mqtt.close();
    }
  });

  test('rtl_tcp: a classic server answers RTL0; anything else is no rtl_tcp', () async {
    final rtl = await _rtlTcp();
    final web = await _rtlTcp(garbage: true);
    try {
      final found = await checkRtlTcp('127.0.0.1', port: rtl.port);
      expect(found, hasLength(1));
      expect((found!.single.host, found.single.port, found.single.protocol), ('127.0.0.1', rtl.port, RtlTcpProtocol.classic));
      expect(await checkRtlTcp('127.0.0.1', port: web.port), isNull);
    } finally {
      await rtl.close();
      await web.close();
    }
  });
}
