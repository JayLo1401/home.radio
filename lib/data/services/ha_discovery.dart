import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lan_scan.dart';

/// A Home Assistant found in the home network.
class FoundHomeAssistant {
  const FoundHomeAssistant({required this.host, this.port = 8123, this.name, this.mqtt = false});

  final String host;
  final int port;

  /// What the network's DNS calls it ("homeassistant.fritz.box"), or null.
  final String? name;

  /// An MQTT broker answers on the same machine (port 1883) - usually the
  /// Mosquitto add-on.
  final bool mqtt;

  /// The address of its web page, e.g. "http://192.168.1.5:8123".
  String get url => 'http://$host:$port';
}

/// Whether [host] runs Home Assistant on [port]: its web page answers with
/// Home Assistant's manifest.
Future<FoundHomeAssistant?> checkHomeAssistant(
  String host, {
  int port = 8123,
  int mqttPort = 1883,
  http.Client? client,
}) async {
  if (!await LanScan.isOpen(host, port)) return null;
  final web = client ?? http.Client();
  try {
    final response = await web.get(Uri.http('$host:$port', '/manifest.json')).timeout(const Duration(seconds: 3));
    if (response.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    if (json is! Map || !'${json['name'] ?? ''}'.contains('Home Assistant')) return null;
    final results = await Future.wait([LanScan.isOpen(host, mqttPort), LanScan.nameOf(host)]);
    return FoundHomeAssistant(host: host, port: port, mqtt: results[0] as bool, name: results[1] as String?);
  } catch (_) {
    return null;
  } finally {
    if (client == null) web.close();
  }
}

/// Looks for Home Assistant (port 8123) in the home network.
Stream<FoundHomeAssistant> findHomeAssistant({void Function(int done, int total)? onProgress}) =>
    LanScan.scan(checkHomeAssistant, onProgress: onProgress);
