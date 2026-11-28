import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/enigma2_bouquet_editor.dart';
import 'package:home_system/data/services/enigma2_service.dart';
import 'package:home_system/features/tv/tv_channel_order.dart';
import 'package:home_system/features/tv/tv_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _bouquet = '1:7:1:0:0:0:0:0:0:0:FROM BOUQUET "userbouquet.favourites.tv" ORDER BY bouquet';

String _tv(String id) => '1:0:19:$id:3EF:1:C00000:0:0:0:';
String _marker(String name) => '1:64:1:0:0:0:0:0:0:0::$name';
const _radio = '1:0:2:6F:3F3:1:C00000:0:0:0:';
const _hidden = '1:512:19:9999:3EF:1:C00000:0:0:0:';

/// Enigma2's eBouquet::moveService(ref, pos): the entry ends up at index
/// [pos] (swapped along one by one) - written independently of the app's
/// own simulation.
void _enigma2Move(List<String> services, String ref, int pos) {
  if (pos < 0 || pos >= services.length) return;
  final source = services.indexOf(ref);
  if (source < 0 || source == pos) return;
  var s = source;
  while (s != pos) {
    final next = s < pos ? s + 1 : s - 1;
    final tmp = services[s];
    services[s] = services[next];
    services[next] = tmp;
    s = next;
  }
}

List<String> _apply(List<String> raw, List<BouquetMove> moves) {
  final list = List<String>.of(raw);
  for (final m in moves) {
    _enigma2Move(list, m.ref, m.position);
  }
  return list;
}

/// A fake OpenWebif: /api/getservices and /bouqueteditor/api/moveservice
/// working on [services] like the real receiver.
class _FakeReceiver {
  _FakeReceiver(this.services, {this.editor = 'ok'});

  final List<String> services;

  /// 'ok', 'missing' (404), 'plugin' (controller without its plugin),
  /// 'ignores' (answers true, changes nothing), 'refuses' (answers false).
  String editor;
  final requests = <Uri>[];

  String _name(String ref) => ref.startsWith('1:64:') ? ref.split('::').last : 'Sender ${ref.split(':')[3]}';

  late final client = MockClient((request) async {
    requests.add(request.url);
    switch (request.url.path) {
      case '/api/getservices':
        final sRef = request.url.queryParameters['sRef'];
        if (sRef == null || sRef.isEmpty) {
          return http.Response(
              jsonEncode({
                'services': [
                  {'servicereference': _bouquet, 'servicename': 'Favoriten'},
                ],
              }),
              200);
        }
        expect(sRef, _bouquet);
        final hidden = request.url.queryParameters['hidden'] == '1';
        return http.Response.bytes(
            utf8.encode(jsonEncode({
              'services': [
                for (final s in services)
                  if (hidden || int.parse(s.split(':')[1]) & 512 == 0) {'servicereference': s, 'servicename': _name(s)},
              ],
            })),
            200);
      case '/bouqueteditor/api/moveservice':
        final q = request.url.queryParameters;
        switch (editor) {
          case 'missing':
            return http.Response('<html><body><h1>Error 404: Not found</h1></body></html>', 404);
          case 'plugin':
            return http.Response(jsonEncode({'Result': [false, 'BouquetEditor plugin not found']}), 200);
          case 'refuses':
            return http.Response(jsonEncode({'Result': [false, 'Service can not be moved.']}), 200);
          case 'ignores':
            return http.Response(jsonEncode({'Result': [true, 'Service moved.']}), 200);
        }
        expect(q.keys.toSet(), {'sBouquetRef', 'sRef', 'mode', 'position'});
        expect(q['sBouquetRef'], _bouquet);
        expect(q['mode'], '0');
        _enigma2Move(services, q['sRef']!, int.parse(q['position']!));
        return http.Response(jsonEncode({'Result': [true, 'Service ${q['sRef']} moved.']}), 200);
    }
    return http.Response('not found', 404);
  });
}

const _config = Enigma2Config(host: '192.168.100.206');

void main() {
  group('planBouquetMoves', () {
    test('one channel down past a marker: right behind the channel it passed', () {
      final raw = [_tv('A'), _marker('Sport'), _tv('B'), _tv('C')];
      final moves = planBouquetMoves(raw, [_tv('B'), _tv('A'), _tv('C')], moved: _tv('A'));
      expect(moves, [(ref: _tv('A'), position: 2)]);
      expect(_apply(raw, moves), [_marker('Sport'), _tv('B'), _tv('A'), _tv('C')]);
    });

    test('one channel up past a marker: right before the channel it passed', () {
      final raw = [_tv('A'), _marker('Sport'), _tv('B'), _tv('C')];
      final moves = planBouquetMoves(raw, [_tv('B'), _tv('A'), _tv('C')], moved: _tv('B'));
      expect(moves, [(ref: _tv('B'), position: 0)]);
      expect(_apply(raw, moves), [_tv('B'), _tv('A'), _marker('Sport'), _tv('C')]);
    });

    test('several places at once is still one move; radio, hidden and markers stay', () {
      final raw = [_tv('A'), _radio, _tv('B'), _marker('X'), _tv('C'), _hidden, _tv('D')];
      final moves = planBouquetMoves(raw, [_tv('B'), _tv('C'), _tv('D'), _tv('A')], moved: _tv('A'));
      expect(moves, hasLength(1));
      expect(_apply(raw, moves), [_radio, _tv('B'), _marker('X'), _tv('C'), _hidden, _tv('D'), _tv('A')]);
      final up = planBouquetMoves(raw, [_tv('D'), _tv('A'), _tv('B'), _tv('C')], moved: _tv('D'));
      expect(up, [(ref: _tv('D'), position: 0)]);
    });

    test('nothing to do when the order is already right', () {
      final raw = [_marker('X'), _tv('A'), _tv('B')];
      expect(planBouquetMoves(raw, [_tv('A'), _tv('B')], moved: _tv('A')), isEmpty);
      expect(planBouquetMoves(raw, [_tv('A'), _tv('B')]), isEmpty);
    });

    test('service references compared without the trailing ":" and case', () {
      final raw = ['1:0:19:a:3ef:1:c00000:0:0:0:', _tv('B')];
      final moves = planBouquetMoves(raw, [_tv('B'), '1:0:19:A:3EF:1:C00000:0:0:0'], moved: _tv('B'));
      expect(moves, [(ref: _tv('B'), position: 0)]);
    });

    test('any new order (an app-only one): reached, the rest keeps its order', () {
      final random = Random(7);
      for (var round = 0; round < 300; round++) {
        final channels = [for (var i = 0; i < 2 + random.nextInt(12); i++) _tv('${i + 10}')];
        final others = [_marker('M1'), _marker('M2'), _radio, _hidden];
        final raw = [...channels];
        for (final o in others) {
          raw.insert(random.nextInt(raw.length + 1), o);
        }
        final desired = [...channels]..shuffle(random);
        final moved = random.nextBool() ? desired[random.nextInt(desired.length)] : null;
        final result = _apply(raw, planBouquetMoves(raw, desired, moved: moved));
        expect(result.where(channels.contains).toList(), desired, reason: 'round $round');
        expect(result.where(others.contains).toList(), raw.where(others.contains).toList());
        expect(result.length, raw.length);

        // One channel moved in the list: one move on the receiver.
        final single = [...channels];
        final from = random.nextInt(single.length), to = random.nextInt(single.length);
        final c = single.removeAt(from);
        single.insert(to, c);
        final moves = planBouquetMoves(raw, single, moved: c);
        expect(moves.length, from == to ? 0 : 1);
        expect(_apply(raw, moves).where(channels.contains).toList(), single);
      }
    });
  });

  group('applyChannelOrder', () {
    List<E2Channel> channels(List<String> ids) => [
          for (var i = 0; i < ids.length; i++) E2Channel(ref: _tv(ids[i]), name: ids[i], number: i + 1),
        ];

    test('the app order, numbered in it', () {
      final ordered = applyChannelOrder(channels(['A', 'B', 'C']), [serviceKey(_tv('C')), serviceKey(_tv('A')), serviceKey(_tv('B'))]);
      expect(ordered.map((c) => c.name), ['C', 'A', 'B']);
      expect(ordered.map((c) => c.number), [1, 2, 3]);
    });

    test('a channel new in the bouquet stays behind the one it follows; gone ones are skipped', () {
      final ordered = applyChannelOrder(
        channels(['A', 'N', 'B', 'C']),
        [serviceKey(_tv('C')), serviceKey(_tv('GONE')), serviceKey(_tv('A')), serviceKey(_tv('B'))],
      );
      expect(ordered.map((c) => c.name), ['C', 'A', 'N', 'B']);
      expect(ordered.map((c) => c.number), [1, 2, 3, 4]);
    });

    test('no order: the bouquet as it is', () {
      final list = channels(['A', 'B']);
      expect(applyChannelOrder(list, null), same(list));
    });
  });

  group('Enigma2BouquetEditor', () {
    test('writes the move and reads the bouquet back', () async {
      final receiver = _FakeReceiver([_tv('A'), _marker('Sport'), _tv('B'), _tv('C')]);
      final editor = Enigma2BouquetEditor(_config, client: receiver.client);
      final after = await editor.applyOrder(_bouquet, [_tv('B'), _tv('C'), _tv('A')], moved: _tv('A'));
      expect(receiver.services, [_marker('Sport'), _tv('B'), _tv('C'), _tv('A')]);
      expect(after.map((c) => c.ref), [_tv('B'), _tv('C'), _tv('A')]);
      expect(after.map((c) => c.number), [1, 2, 3]);
      final move = receiver.requests.singleWhere((u) => u.path == '/bouqueteditor/api/moveservice');
      expect(move.queryParameters, {'sBouquetRef': _bouquet, 'sRef': _tv('A'), 'mode': '0', 'position': '3'});
      // Every entry counts: the bouquet is read with the hidden ones.
      expect(receiver.requests.first.queryParameters['hidden'], '1');
    });

    test('hidden entries count for the position', () {
      final receiver = _FakeReceiver([_tv('A'), _hidden, _tv('B')]);
      final editor = Enigma2BouquetEditor(_config, client: receiver.client);
      return editor.applyOrder(_bouquet, [_tv('B'), _tv('A')], moved: _tv('B')).then((after) {
        expect(receiver.services, [_tv('B'), _tv('A'), _hidden]);
        expect(after.map((c) => c.ref), [_tv('B'), _tv('A')]);
      });
    });

    test('no bouquet editor: 404, or the controller without its plugin', () async {
      for (final kind in ['missing', 'plugin']) {
        final receiver = _FakeReceiver([_tv('A'), _tv('B')], editor: kind);
        final editor = Enigma2BouquetEditor(_config, client: receiver.client);
        await expectLater(editor.applyOrder(_bouquet, [_tv('B'), _tv('A')], moved: _tv('B')),
            throwsA(isA<BouquetEditorUnavailable>()));
        expect(receiver.services, [_tv('A'), _tv('B')]);
      }
    });

    test('the receiver says yes but keeps its order: noticed', () async {
      final receiver = _FakeReceiver([_tv('A'), _tv('B')], editor: 'ignores');
      final editor = Enigma2BouquetEditor(_config, client: receiver.client);
      await expectLater(
        editor.applyOrder(_bouquet, [_tv('B'), _tv('A')], moved: _tv('B')),
        throwsA(isA<BouquetOrderMismatch>().having((e) => e.channels.map((c) => c.ref), 'channels', [_tv('A'), _tv('B')])),
      );
    });

    test('the receiver refuses, or is unreachable: an Enigma2Exception', () async {
      final receiver = _FakeReceiver([_tv('A'), _tv('B')], editor: 'refuses');
      await expectLater(
        Enigma2BouquetEditor(_config, client: receiver.client).applyOrder(_bouquet, [_tv('B'), _tv('A')]),
        throwsA(isA<Enigma2Exception>().having((e) => e.message, 'message', 'Service can not be moved.')),
      );
      final offline = MockClient((_) async => throw http.ClientException('No route to host'));
      await expectLater(
        Enigma2BouquetEditor(_config, client: offline).applyOrder(_bouquet, [_tv('B'), _tv('A')]),
        throwsA(isA<Enigma2Exception>()),
      );
    });
  });

  group('TvChannelOrderNotifier', () {
    ProviderContainer container(_FakeReceiver receiver, Map<String, String> settings) {
      final c = ProviderContainer(overrides: [
        enigma2ConfigProvider.overrideWith(_FixedConfig.new),
        tvBouquetProvider.overrideWith(_NoBouquetChoice.new),
        enigma2ServiceProvider.overrideWithValue(Enigma2Service(_config, client: receiver.client)),
        enigma2BouquetEditorProvider.overrideWithValue(Enigma2BouquetEditor(_config, client: receiver.client)),
        tvChannelOrderStoreProvider.overrideWithValue(
          TvChannelOrderStore((k) async => settings[k], (k, v) async => settings[k] = v),
        ),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    List<String> names(List<E2Channel> list) => [for (final c in list) '${c.number} ${c.name}'];

    test('written to the receiver: the new order and numbers, from the receiver', () async {
      final receiver = _FakeReceiver([_tv('A'), _tv('B'), _tv('C')]);
      final c = container(receiver, {});
      c.listen(tvChannelsProvider, (_, _) {});
      final before = await c.read(tvChannelsProvider.future);
      final order = [before[1], before[2], before[0]];
      final pending = c.read(tvChannelOrderProvider.notifier).commit(_bouquet, order, moved: before[0]);
      // Shown at once, before the receiver answered.
      expect(names(c.read(tvChannelsProvider).requireValue), ['1 Sender B', '2 Sender C', '3 Sender A']);
      final result = await pending;
      expect(result.outcome, TvOrderOutcome.receiver);
      expect(receiver.services, [_tv('B'), _tv('C'), _tv('A')]);
      expect(names(c.read(tvChannelsProvider).requireValue), ['1 Sender B', '2 Sender C', '3 Sender A']);
      expect(c.read(tvChannelOrderProvider).pending, isEmpty);
      expect(c.read(tvChannelOrderProvider).local, isEmpty);
    });

    test('writing fails: the old order is back', () async {
      final receiver = _FakeReceiver([_tv('A'), _tv('B'), _tv('C')], editor: 'refuses');
      final c = container(receiver, {});
      c.listen(tvChannelsProvider, (_, _) {});
      final before = await c.read(tvChannelsProvider.future);
      final result =
          await c.read(tvChannelOrderProvider.notifier).commit(_bouquet, [before[1], before[0], before[2]], moved: before[1]);
      expect(result.outcome, TvOrderOutcome.failed);
      expect(result.error, 'Service can not be moved.');
      expect(names(c.read(tvChannelsProvider).requireValue), ['1 Sender A', '2 Sender B', '3 Sender C']);
    });

    test('no bouquet editor: kept in the app (told once), numbers follow it', () async {
      final receiver = _FakeReceiver([_tv('A'), _tv('B'), _tv('C')], editor: 'missing');
      final settings = <String, String>{};
      final c = container(receiver, settings);
      c.listen(tvChannelsProvider, (_, _) {});
      final before = await c.read(tvChannelsProvider.future);
      final notifier = c.read(tvChannelOrderProvider.notifier);
      final first = await notifier.commit(_bouquet, [before[2], before[0], before[1]], moved: before[2]);
      expect(first.outcome, TvOrderOutcome.localOnly);
      expect(first.firstTime, isTrue);
      expect(names(c.read(tvChannelsProvider).requireValue), ['1 Sender C', '2 Sender A', '3 Sender B']);
      expect(receiver.services, [_tv('A'), _tv('B'), _tv('C')]);
      expect(settings['tv_channel_orders'], contains('userbouquet.favourites.tv'));
      final now = c.read(tvChannelsProvider).requireValue;
      final second = await notifier.commit(_bouquet, [now[1], now[0], now[2]], moved: now[1]);
      expect(second.outcome, TvOrderOutcome.localOnly);
      expect(second.firstTime, isFalse);
      expect(names(c.read(tvChannelsProvider).requireValue), ['1 Sender A', '2 Sender C', '3 Sender B']);

      // Kept: a new start of the app has it again.
      final again = container(receiver, settings);
      again.listen(tvChannelsProvider, (_, _) {});
      expect(names(await again.read(tvChannelsProvider.future)), ['1 Sender A', '2 Sender C', '3 Sender B']);
      // "Reihenfolge des Receivers übernehmen".
      await again.read(tvChannelOrderProvider.notifier).resetLocal(_bouquet);
      expect(names(again.read(tvChannelsProvider).requireValue), ['1 Sender A', '2 Sender B', '3 Sender C']);
    });
  });
}

class _FixedConfig extends Enigma2ConfigNotifier {
  @override
  Enigma2Config? build() => _config;
}

class _NoBouquetChoice extends TvBouquetNotifier {
  @override
  String? build() => null;
}
