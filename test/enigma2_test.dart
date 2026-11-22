import 'package:flutter_test/flutter_test.dart';
import 'package:home_radio/data/services/enigma2_service.dart';
import 'package:home_radio/features/tv/tv_providers.dart' show nowNextFor;

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
}
