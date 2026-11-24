import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/enigma2_service.dart';
import 'package:home_system/features/tv/tv_providers.dart' show nowNextFor;
import 'package:home_system/features/tv/tv_widgets.dart' show shortChannelName;

void main() {
  test('picon names: fields with _, TV service types as 1, no trailing part', () {
    expect(piconName('1:0:19:283D:3FB:1:C00000:0:0:0:'), '1_0_1_283D_3FB_1_C00000_0_0_0');
    expect(piconName('1:0:1:6DCA:44D:1:C00000:0:0:0:'), '1_0_1_6DCA_44D_1_C00000_0_0_0');
    expect(piconName('4097:0:1:0:0:0:0:0:0:0:http%3a//x/y:Name'), '4097_0_1_0_0_0_0_0_0_0');
  });

  test('channels: markers and placeholders skipped, numbered from 1', () {
    final channels = parseChannels({
      'services': [
        {'servicereference': '1:64:1:0:0:0:0:0:0:0::--- Österreich ---', 'servicename': '--- Österreich ---'},
        {'servicereference': '1:0:19:132F:3EF:1:C00000:0:0:0:', 'servicename': 'ORF1 HD', 'picon': '/picon/1_0_19.png'},
        {'servicereference': '1:832:D:0:0:0:0:0:0:0:', 'servicename': '<n/a>'},
        {'servicereference': '1:0:19:1330:3EF:1:C00000:0:0:0:', 'servicename': 'ORF2W HD'},
        {'servicereference': '1:0:2:6F:3F3:1:C00000:0:0:0:', 'servicename': 'Ö1'},
      ],
    });
    expect(channels.map((c) => c.name), ['ORF1 HD', 'ORF2W HD', 'Ö1']);
    expect(channels.map((c) => c.number), [1, 2, 3]);
    expect(channels.first.piconPath, '/picon/1_0_19.png');
    expect(channels.last.isRadio, isTrue);
  });

  test('events from OpenWebif JSON, now and next per channel', () {
    final base = DateTime(2026, 11, 22, 20, 0).millisecondsSinceEpoch ~/ 1000;
    final now = E2Event.fromJson({
      'sref': '1:0:19:132F:3EF:1:C00000:0:0:0:',
      'title': 'Tatort',
      'begin_timestamp': base,
      'duration_sec': 5400,
      'shortdesc': 'Krimi',
      'longdesc': 'Krimi aus Wien.',
    })!;
    final next = E2Event.fromJson({
      'sref': '1:0:19:132F:3EF:1:C00000:0:0:0',
      'title': 'ZIB 2',
      'begin_timestamp': base + 5400,
      'duration_sec': 1800,
    })!;
    expect(E2Event.fromJson({'title': '', 'begin_timestamp': base, 'duration_sec': 60}), isNull);
    expect(now.description, 'Krimi aus Wien.');
    final t = DateTime(2026, 11, 22, 20, 45);
    expect(now.progressAt(t), closeTo(0.5, 0.001));

    const channel = E2Channel(ref: '1:0:19:132f:3ef:1:c00000:0:0:0:', name: 'ORF1 HD', number: 1);
    // Keys as tvNowNextProvider builds them: no trailing ':', upper case.
    final map = {'1:0:19:132F:3EF:1:C00000:0:0:0': [now, next]};
    final nn = nowNextFor(map, channel, t);
    expect(nn.now?.title, 'Tatort');
    expect(nn.next?.title, 'ZIB 2');
  });

  test('stream address and login header', () {
    const config = Enigma2Config(host: ' 192.168.1.50 ', user: 'root', password: 'geheim');
    expect(config.streamUri('1:0:19:132F:3EF:1:C00000:0:0:0:').toString(),
        'http://192.168.1.50:8001/1:0:19:132F:3EF:1:C00000:0:0:0:');
    expect(config.authHeaders['Authorization'], 'Basic cm9vdDpnZWhlaW0=');
    expect(const Enigma2Config().authHeaders, isEmpty);
    expect(config.piconUri('1:0:19:132F:3EF:1:C00000:0:0:0:').toString(),
        'http://192.168.1.50/picon/1_0_1_132F_3EF_1_C00000_0_0_0.png');
  });

  group('stream probe (MPEG-TS scrambling bits)', () {
    List<int> packet(int pid, {bool scrambled = false}) =>
        [0x47, (pid >> 8) & 0x1F, pid & 0xFF, scrambled ? 0x90 : 0x10, ...List.filled(184, 0xAB)];
    List<int> packets(int pid, int n, {bool scrambled = false}) =>
        [for (var i = 0; i < n; i++) ...packet(pid, scrambled: scrambled)];

    test('clear picture: clear, also when packets are split across chunks', () {
      final probe = TsScramblingProbe();
      final data = [...packets(0x12, 50), ...packets(5101, 200), ...packets(5102, 20)];
      expect(probe.add(data.sublist(0, 1000)), isNull);
      expect(probe.add(data.sublist(1000)), StreamScrambling.clear);
      expect(probe.sawScrambled, isFalse);
    });

    test('scrambled picture with clear audio: scrambled as soon as enough picture packets came', () {
      final probe = TsScramblingProbe();
      expect(probe.add([...packets(1921, 100), ...packets(1920, 200, scrambled: true)]), isNull);
      expect(probe.add(packets(1920, 200, scrambled: true)), StreamScrambling.scrambled);
      expect(probe.sawScrambled, isTrue);
    });

    test('descrambling starts (after switching the receiver): clear once the picture runs clear', () {
      final probe = TsScramblingProbe();
      expect(probe.add(packets(511, 300, scrambled: true)), StreamScrambling.scrambled);
      expect(probe.add(packets(511, 100)), isNot(StreamScrambling.clear));
      expect(probe.add(packets(511, 100)), StreamScrambling.clear);
    });

    test('scrambled picture with some clear timing packets (ORF): still scrambled', () {
      final probe = TsScramblingProbe();
      final mixed = [
        for (var i = 0; i < 400; i++) ...packet(1920, scrambled: i % 3 != 0),
      ];
      expect(probe.add(mixed), StreamScrambling.scrambled);
    });

    test('garbage before the first sync byte is skipped', () {
      final probe = TsScramblingProbe();
      expect(probe.add([1, 2, 3, ...packets(300, 160)]), StreamScrambling.clear);
    });
  });

  test('OpenWebif placeholder (no picon on the receiver): no picon, not its logo', () {
    final channels = parseChannels({
      'services': [
        {'servicereference': '1:0:19:14B7:407:1:C00000:0:0:0:', 'servicename': 'PULS 4 HD Austria', 'picon': '/images/default_picon.png'},
        {'servicereference': '1:0:19:132F:3EF:1:C00000:0:0:0:', 'servicename': 'ORF1 HD', 'picon': '/picon/1_0_19_132F_3EF_1_C00000_0_0_0.png'},
      ],
    });
    expect(channels[0].hasPicon, isFalse);
    expect(channels[0].piconPath, isNull);
    expect(channels[1].hasPicon, isTrue);
    expect(channels[1].piconPath, '/picon/1_0_19_132F_3EF_1_C00000_0_0_0.png');
  });

  test('channel name for a missing picon: without HD/Austria, two lines', () {
    expect(shortChannelName('PULS 4 HD Austria'), 'PULS 4');
    expect(shortChannelName('Comedy Central HD Austria'), 'Comedy\nCentral');
    expect(shortChannelName('RTL Super Austria'), 'RTL\nSuper');
    expect(shortChannelName('ORF1 HD'), 'ORF1');
    expect(shortChannelName('HD'), 'HD');
  });

  test('HTML-escaped texts from OpenWebif', () {
    expect(htmlUnescape('Disneys Lilo &amp; Stitch'), 'Disneys Lilo & Stitch');
    expect(htmlUnescape('&quot;Tatort&quot; &#228;rgert &#x2013; sch&ouml;n'), '"Tatort" ärgert – sch&ouml;n');
    expect(htmlUnescape('ohne'), 'ohne');
  });
}
