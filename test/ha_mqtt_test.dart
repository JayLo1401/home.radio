import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/ha_providers.dart';
import 'package:home_system/data/models/launcher_group.dart';
import 'package:home_system/data/models/launcher_tile.dart';
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

  test('switches per app: a key of its own for every part of Home', () {
    final builtIn = [
      LauncherTile.radioType,
      LauncherTile.tvType,
      LauncherTile.dashboardType,
      LauncherTile.picturesType,
      LauncherTile.moviesType,
      LauncherTile.musicType,
      LauncherTile.browserType,
    ];
    expect(HaKeys.appSwitches.keys.toSet(), builtIn.toSet());
    expect(HaKeys.appSwitches[LauncherTile.radioType], 'app_radio');
    expect(HaKeys.appSwitches[LauncherTile.dashboardType], 'app_dashboard');
    final keys = HaKeys.appSwitches.values.toSet();
    expect(keys.length, builtIn.length);
    // Not one of the buttons that open a part (kept as they are).
    expect(keys.intersection({HaKeys.openRadio, HaKeys.openTv, HaKeys.openMusic, HaKeys.openDashboard, HaKeys.openHome}),
        isEmpty);
    expect(keys.contains(HaKeys.launchApp), isFalse);
    final config = haDiscoveryConfig(
      const HaEntity(component: 'switch', key: HaKeys.appTv, name: 'TV', config: {'icon': 'mdi:television'}),
      topics,
      device,
    );
    expect(config['state_topic'], topics.state('app_tv'));
    expect(config['command_topic'], topics.command('app_tv'));
    expect(config['icon'], 'mdi:television');
  });

  test('"App starten": the apps on Home, each once, with labels of their own', () {
    final apps = haLauncherApps(
      const [
        LauncherTile.radio(),
        LauncherTile.tv(),
        LauncherTile.app(package: 'com.netflix.ninja', label: 'Netflix'),
        LauncherTile.app(package: 'com.spotify.tv.android', label: 'Spotify'),
      ],
      const [
        LauncherGroup(id: 'g1', name: 'Mediatheken', tiles: [
          LauncherTile.app(package: 'com.netflix.ninja', label: 'Netflix'),
          LauncherTile.app(package: 'de.orf.tvthek', label: 'ORF ON'),
          LauncherTile.app(package: 'com.other.netflix', label: 'Netflix'),
          LauncherTile.music(),
        ]),
      ],
    );
    expect(apps.map((a) => a.label), ['Netflix', 'Spotify', 'ORF ON', 'Netflix (com.other.netflix)']);
    expect(apps.map((a) => a.package), ['com.netflix.ninja', 'com.spotify.tv.android', 'de.orf.tvthek', 'com.other.netflix']);
    expect(haLauncherApps(const [LauncherTile.radio()], const []), isEmpty);
  });
}
