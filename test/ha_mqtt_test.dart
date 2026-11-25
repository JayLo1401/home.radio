import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/ha_providers.dart';
import 'package:home_system/data/repositories/settings_repository.dart';
import 'package:home_system/data/services/ha_mqtt_link.dart';

void main() {
  const topics = HaTopics('a1b2c3d4e5f60708');
  const device = HaDeviceInfo(
    name: 'Wandtablet Küche',
    manufacturer: 'Amazon',
    model: 'KFTUWI',
    version: '1.24.0',
    configurationUrl: 'http://192.168.100.106:1401/',
  );

  test('topics: state, command, discovery, and the key of a command', () {
    const screen = HaEntity(component: 'switch', key: 'screen', name: 'Bildschirm');
    expect(topics.state('screen'), 'homesystem/a1b2c3d4e5f60708/screen/state');
    expect(topics.command('screen'), 'homesystem/a1b2c3d4e5f60708/screen/set');
    expect(topics.config(screen), 'homeassistant/switch/a1b2c3d4e5f60708/screen/config');
    expect(topics.keyOfCommand('homesystem/a1b2c3d4e5f60708/brightness/set'), 'brightness');
    expect(topics.keyOfCommand('homesystem/a1b2c3d4e5f60708/brightness/state'), isNull);
    expect(topics.keyOfCommand('homesystem/other/brightness/set'), isNull);
    expect(topics.keyOfCommand('homesystem/a1b2c3d4e5f60708/a/b/set'), isNull);
  });

  test('discovery: the device with its name, commands only where Home Assistant sends some', () {
    final number = haDiscoveryConfig(
      const HaEntity(component: 'number', key: 'brightness', name: 'Bildschirmhelligkeit', config: {'min': 1, 'max': 100}),
      topics,
      device,
    );
    expect(number['unique_id'], 'a1b2c3d4e5f60708_brightness');
    expect(number['object_id'], 'wandtablet_kueche_brightness');
    expect(number['state_topic'], topics.state('brightness'));
    expect(number['command_topic'], topics.command('brightness'));
    expect(number['availability_topic'], 'homesystem/a1b2c3d4e5f60708/status');
    expect((number['min'], number['max']), (1, 100));
    final d = number['device'] as Map<String, Object?>;
    expect(d['identifiers'], ['homesystem_a1b2c3d4e5f60708']);
    expect((d['name'], d['manufacturer'], d['model'], d['sw_version']), ('Wandtablet Küche', 'Amazon', 'KFTUWI', '1.24.0'));
    expect(d['configuration_url'], 'http://192.168.100.106:1401/');

    final sensor = haDiscoveryConfig(const HaEntity(component: 'binary_sensor', key: 'motion', name: 'Bewegung'), topics, device);
    expect(sensor.containsKey('command_topic'), isFalse);
    expect(sensor['state_topic'], topics.state('motion'));

    final button = haDiscoveryConfig(const HaEntity(component: 'button', key: 'reload_dashboard', name: 'Neu laden'), topics, device);
    expect(button.containsKey('state_topic'), isFalse);
    expect(button['command_topic'], topics.command('reload_dashboard'));

    final notify = haDiscoveryConfig(const HaEntity(component: 'notify', key: 'tts', name: 'Sprache'), topics, device);
    expect((notify.containsKey('state_topic'), notify['command_topic']), (false, topics.command('tts')));
  });

  test('broker: its own address, else the Home Assistant of the Haussteuerung; off = none', () {
    const on = HaLinkSettings(enabled: true, user: 'homesystem', password: 'x');
    expect(haBrokerFor(on, 'http://192.168.100.202:8123/lovelace/0?kiosk'),
        const HaBroker(host: '192.168.100.202', user: 'homesystem', password: 'x'));
    expect(haBrokerFor(on.copyWith(host: 'mqtt.local', port: 1884), 'http://192.168.100.202:8123/')!.host, 'mqtt.local');
    expect(haBrokerFor(on.copyWith(host: 'mqtt.local', port: 1884), '')!.port, 1884);
    expect(haBrokerFor(on, ''), isNull);
    // Home Assistant's address pasted into the broker field: only its host.
    final pasted = haBrokerFor(on.copyWith(host: 'http://192.168.100.202:8123'), '')!;
    expect((pasted.host, pasted.port), ('192.168.100.202', 1883));
    expect(haBrokerFor(on.copyWith(host: 'https://ha.local:8123/lovelace/0'), '')!.host, 'ha.local');
    final withPort = haBrokerFor(on.copyWith(host: '192.168.100.202:1884'), '')!;
    expect((withPort.host, withPort.port), ('192.168.100.202', 1884));
    expect(haBrokerFor(on.copyWith(host: 'mqtt://broker.lan:8883'), '')!.port, 8883);
    expect(haBrokerFor(on.copyWith(host: ' 192.168.100.202 '), '')!.host, '192.168.100.202');
    expect(haBrokerFor(on.copyWith(enabled: false), 'http://192.168.100.202:8123/'), isNull);
  });
}
