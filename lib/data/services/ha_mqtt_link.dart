import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:path/path.dart' as p;
import 'package:typed_data/typed_data.dart' as typed;
import 'package:path_provider/path_provider.dart';

/// One entity of the device in Home Assistant (MQTT discovery): a switch,
/// number, select, button, notify, sensor or binary_sensor.
@immutable
class HaEntity {
  const HaEntity({
    required this.component,
    required this.key,
    required this.name,
    this.config = const {},
  });

  /// Home Assistant's platform: switch, number, select, button, notify,
  /// sensor, binary_sensor.
  final String component;

  /// Unique within the device - part of the topics and the unique_id.
  final String key;

  /// Shown after the device's name ("Wandtablet Küche Bildschirm").
  final String name;

  /// More discovery fields: device_class, unit_of_measurement, icon, min,
  /// max, step, options, entity_category, state_class ...
  final Map<String, Object?> config;

  /// Home Assistant sends to its command topic (switch, number, select,
  /// button, notify).
  bool get commands => const {'switch', 'number', 'select', 'button', 'notify', 'text'}.contains(component);

  /// It has a state the device publishes (not button / notify; a camera's
  /// pictures go to its `topic`).
  bool get hasState => component != 'button' && component != 'notify' && component != 'camera';
}

/// What the device is, for Home Assistant's device page.
@immutable
class HaDeviceInfo {
  const HaDeviceInfo({required this.name, this.manufacturer, this.model, this.version, this.configurationUrl});

  final String name;
  final String? manufacturer;
  final String? model;
  final String? version;

  /// The admin page (`http://<ip>:1401/`) - "Besuchen" on the device page.
  final String? configurationUrl;
}

/// The topics of a device with [deviceId].
class HaTopics {
  const HaTopics(this.deviceId, {this.discoveryPrefix = 'homeassistant'});

  final String deviceId;
  final String discoveryPrefix;

  String get base => 'homesystem/$deviceId';
  String get availability => '$base/status';
  String state(String key) => '$base/$key/state';
  String command(String key) => '$base/$key/set';
  String get commandFilter => '$base/+/set';
  String config(HaEntity e) => '$discoveryPrefix/${e.component}/$deviceId/${e.key}/config';

  /// Home Assistant says "online" here after a restart - the discovery is
  /// sent again then.
  String get haStatus => '$discoveryPrefix/status';

  /// The entity key of a command topic, or null.
  String? keyOfCommand(String topic) {
    if (!topic.startsWith('$base/') || !topic.endsWith('/set')) return null;
    final key = topic.substring(base.length + 1, topic.length - 4);
    return key.isEmpty || key.contains('/') ? null : key;
  }
}

/// The discovery message of [e] (published retained on [HaTopics.config]).
Map<String, Object?> haDiscoveryConfig(HaEntity e, HaTopics topics, HaDeviceInfo device) => {
      'name': e.name,
      'unique_id': '${topics.deviceId}_${e.key}',
      'object_id': '${_slug(device.name)}_${e.key}',
      'availability_topic': topics.availability,
      if (e.hasState) 'state_topic': topics.state(e.key),
      if (e.commands) 'command_topic': topics.command(e.key),
      if (e.component == 'camera') 'topic': topics.state(e.key),
      ...e.config,
      'device': {
        'identifiers': ['homesystem_${topics.deviceId}'],
        'name': device.name,
        'manufacturer': ?device.manufacturer,
        'model': ?device.model,
        'sw_version': ?device.version,
        'configuration_url': ?device.configurationUrl,
      },
      'origin': {'name': 'Home System', 'sw_version': ?device.version, 'support_url': 'https://jaycloud.at'},
    };

/// "Wandtablet Küche" -> "wandtablet_kuche" (Home Assistant's entity ids).
String _slug(String name) {
  const umlauts = {'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss'};
  final lower = name.toLowerCase().split('').map((c) => umlauts[c] ?? c).join();
  final slug = lower.replaceAll(RegExp('[^a-z0-9]+'), '_').replaceAll(RegExp('^_+|_+\$'), '');
  return slug.isEmpty ? 'home_system' : slug;
}

/// The device behind the link: its entities, their states and what to do
/// with Home Assistant's commands (see core/ha_providers.dart).
abstract interface class HaDevice {
  Future<HaDeviceInfo> info();

  /// The entities this device has now (they may depend on the hardware).
  Future<List<HaEntity>> entities();

  /// The current state of every entity with a state, by key.
  Future<Map<String, String>> states();

  /// Home Assistant's [payload] for the entity [key].
  Future<void> command(String key, String payload);
}

/// Where the link stands - for the settings.
enum HaLinkState { off, connecting, connected, failed }

/// The broker and login, see HaLinkSettings.
@immutable
class HaBroker {
  const HaBroker({required this.host, this.port = 1883, this.user = '', this.password = ''});

  final String host;
  final int port;
  final String user;
  final String password;

  @override
  bool operator ==(Object other) =>
      other is HaBroker && other.host == host && other.port == port && other.user == user && other.password == password;

  @override
  int get hashCode => Object.hash(host, port, user, password);
}

/// Home System as a device in Home Assistant, over MQTT discovery - like
/// Zigbee2MQTT or ESPHome: switches, numbers, buttons, notify and sensors
/// under the device's name, without any setup in Home Assistant beyond the
/// MQTT integration (the Mosquitto add-on). The broker keeps the device's
/// availability: "offline" as the last will when the app goes away.
///
/// Switched off ([setBroker] null), the entities are removed from Home
/// Assistant (empty retained discovery messages) and the device goes.
/// Never throws; errors land in [state] / [error].
class HaMqttLink {
  HaMqttLink(this.device);

  final HaDevice device;

  final state = ValueNotifier(HaLinkState.off);

  /// The last error (connecting, login) - null while all is well.
  final error = ValueNotifier<String?>(null);

  HaBroker? _broker;
  MqttServerClient? _client;
  HaTopics? _topics;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  Timer? _retry;
  Timer? _poll;
  List<HaEntity> _published = const [];
  final _lastStates = <String, String>{};
  bool _disposed = false;
  Future<void> _queue = Future.value();

  static const _pollEvery = Duration(seconds: 60);
  static const _retryAfter = Duration(seconds: 30);

  /// Connects to [broker] (again, if it changed); null switches the link off
  /// and removes the device from Home Assistant.
  Future<void> setBroker(HaBroker? broker) => _serial(() async {
        if (broker == _broker && (broker == null || state.value != HaLinkState.failed)) return;
        final wasOn = _client != null;
        _broker = broker;
        if (broker == null) {
          if (wasOn) await _removeFromHa();
          await _disconnect();
          state.value = HaLinkState.off;
          error.value = null;
          return;
        }
        await _disconnect();
        await _connect();
      });

  /// Publishes the states again now (something changed); only what's new
  /// goes out.
  Future<void> refresh() => _serial(() async {
        if (state.value == HaLinkState.connected) await _publishStates();
      });

  /// A picture of the camera entity [key] (JPEG) - not kept by the broker.
  void publishImage(String key, Uint8List jpeg) {
    final client = _client;
    final topics = _topics;
    if (client == null || topics == null || state.value != HaLinkState.connected) return;
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addBuffer(typed.Uint8Buffer()..addAll(jpeg));
      client.publishMessage(topics.state(key), MqttQos.atMostOnce, builder.payload!);
    } catch (e) {
      debugPrint('HaMqttLink: picture: $e');
    }
  }

  /// The entities may have changed (device name, hardware): discovery again.
  Future<void> rediscover() => _serial(() async {
        if (state.value == HaLinkState.connected) await _publishDiscovery();
      });

  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    _poll?.cancel();
    await _disconnect();
    state.dispose();
    error.dispose();
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action()).catchError((Object e) {
      debugPrint('HaMqttLink: $e');
    });
    _queue = next;
    return next;
  }

  Future<void> _connect() async {
    final broker = _broker;
    if (broker == null || _disposed) return;
    _retry?.cancel();
    state.value = HaLinkState.connecting;
    final topics = HaTopics(await haDeviceId());
    _topics = topics;
    final client = MqttServerClient.withPort(broker.host, 'homesystem-${topics.deviceId}', broker.port)
      ..logging(on: false)
      ..setProtocolV311()
      ..keepAlivePeriod = 60
      ..connectTimeoutPeriod = 10000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true;
    var message = MqttConnectMessage()
        .withClientIdentifier('homesystem-${topics.deviceId}')
        .withWillTopic(topics.availability)
        .withWillMessage('offline')
        .withWillRetain()
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();
    if (broker.user.isNotEmpty) message = message.authenticateAs(broker.user, broker.password);
    client.connectionMessage = message;
    client.onAutoReconnected = () => unawaited(_serial(_onConnected));
    client.onDisconnected = () {
      if (_client == client && _broker != null && state.value == HaLinkState.connected) {
        state.value = HaLinkState.connecting;
      }
    };
    _client = client;
    try {
      final status = await client.connect();
      if (status?.state != MqttConnectionState.connected) {
        throw HaLinkException(_describe(status?.returnCode));
      }
    } catch (e) {
      final text = e is HaLinkException ? e.message : _describeError(e);
      debugPrint('HaMqttLink: $text');
      _client = null;
      try {
        client.disconnect();
      } catch (_) {}
      error.value = text;
      state.value = HaLinkState.failed;
      // The broker restarting, Wi-Fi gone: again in a while.
      _retry = Timer(_retryAfter, () => unawaited(_serial(_connect)));
      return;
    }
    _updates = client.updates?.listen(_onMessages);
    await _onConnected();
  }

  Future<void> _onConnected() async {
    final client = _client;
    final topics = _topics;
    if (client == null || topics == null) return;
    error.value = null;
    client.subscribe(topics.commandFilter, MqttQos.atLeastOnce);
    client.subscribe(topics.haStatus, MqttQos.atLeastOnce);
    await _publishDiscovery();
    _publish(topics.availability, 'online');
    _lastStates.clear();
    await _publishStates();
    state.value = HaLinkState.connected;
    _poll?.cancel();
    _poll = Timer.periodic(_pollEvery, (_) => unawaited(refresh()));
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    final topics = _topics;
    if (topics == null) return;
    for (final m in messages) {
      final publish = m.payload;
      if (publish is! MqttPublishMessage) continue;
      final payload = utf8.decode(publish.payload.message, allowMalformed: true);
      if (m.topic == topics.haStatus) {
        // Home Assistant restarted: it needs the discovery again.
        if (payload == 'online') {
          unawaited(_serial(() async {
            await _publishDiscovery();
            _publish(topics.availability, 'online');
            _lastStates.clear();
            await _publishStates();
          }));
        }
        continue;
      }
      final key = topics.keyOfCommand(m.topic);
      if (key == null) continue;
      unawaited(() async {
        try {
          await device.command(key, payload);
        } catch (e) {
          debugPrint('HaMqttLink: command $key: $e');
        }
        // What it did shows at once.
        await refresh();
      }());
    }
  }

  Future<void> _publishDiscovery() async {
    final topics = _topics;
    if (topics == null) return;
    final info = await device.info();
    final entities = await device.entities();
    // Entities the device no longer has (e.g. no camera any more) go.
    for (final old in _published) {
      if (!entities.any((e) => e.component == old.component && e.key == old.key)) {
        _publish(topics.config(old), '');
      }
    }
    for (final e in entities) {
      _publish(topics.config(e), jsonEncode(haDiscoveryConfig(e, topics, info)));
    }
    _published = entities;
  }

  Future<void> _publishStates() async {
    final topics = _topics;
    if (topics == null) return;
    final states = await device.states();
    for (final MapEntry(:key, :value) in states.entries) {
      if (_lastStates[key] == value) continue;
      _lastStates[key] = value;
      _publish(topics.state(key), value);
    }
  }

  /// Switched off: the entities go from Home Assistant, the device with them.
  Future<void> _removeFromHa() async {
    final topics = _topics;
    if (topics == null || _client?.connectionStatus?.state != MqttConnectionState.connected) return;
    final entities = {..._published, ...await device.entities()};
    for (final e in entities) {
      _publish(topics.config(e), '');
    }
    _publish(topics.availability, 'offline');
    _published = const [];
    // Let the messages leave before the connection closes.
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  void _publish(String topic, String payload, {bool retain = true}) {
    final client = _client;
    if (client == null || client.connectionStatus?.state != MqttConnectionState.connected) return;
    try {
      final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!, retain: retain);
    } catch (e) {
      debugPrint('HaMqttLink: publish $topic: $e');
    }
  }

  Future<void> _disconnect() async {
    _poll?.cancel();
    _poll = null;
    _retry?.cancel();
    await _updates?.cancel();
    _updates = null;
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      client.autoReconnect = false;
      if (client.connectionStatus?.state == MqttConnectionState.connected && _topics != null) {
        _publishTo(client, _topics!.availability, 'offline');
      }
      client.disconnect();
    } catch (_) {}
  }

  static void _publishTo(MqttServerClient client, String topic, String payload) {
    try {
      final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!, retain: true);
    } catch (_) {}
  }

  static String _describe(MqttConnectReturnCode? code) => switch (code) {
        MqttConnectReturnCode.badUsernameOrPassword || MqttConnectReturnCode.notAuthorized => 'login',
        MqttConnectReturnCode.brokerUnavailable => 'unavailable',
        _ => 'refused (${code?.name ?? '?'})',
      };

  static String _describeError(Object e) {
    if (e is NoConnectionException) {
      final text = '$e';
      if (text.contains('badUsernameOrPassword') || text.contains('notAuthorized')) return 'login';
      return 'unreachable';
    }
    if (e is SocketException) return 'unreachable';
    return '$e';
  }
}

class HaLinkException implements Exception {
  const HaLinkException(this.message);
  final String message;

  @override
  String toString() => message;
}

String? _deviceId;

/// This device's id for Home Assistant: random once, kept in a file of its
/// own - not in the settings, so a backup restored on another device
/// doesn't take over this one in Home Assistant.
Future<String> haDeviceId() async {
  final known = _deviceId;
  if (known != null) return known;
  try {
    final file = File(p.join((await getApplicationSupportDirectory()).path, 'ha_device_id'));
    if (await file.exists()) {
      final id = (await file.readAsString()).trim();
      if (RegExp(r'^[a-f0-9]{12,32}$').hasMatch(id)) return _deviceId = id;
    }
    final random = Random.secure();
    final id = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await file.writeAsString(id);
    return _deviceId = id;
  } catch (e) {
    debugPrint('haDeviceId: $e');
    return _deviceId = 'unknown';
  }
}
