import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/ha_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Home Assistant's login flow as the real one answers.
MockClient _ha({String password = 'geheim', bool mfa = false, List<String>? log}) => MockClient((request) async {
      log?.add('${request.method} ${request.url.path}');
      switch (request.url.path) {
        case '/auth/login_flow':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['client_id'], 'http://192.168.100.202:8123/');
          expect(body['handler'], ['homeassistant', null]);
          return http.Response(jsonEncode({'type': 'form', 'flow_id': 'f1', 'step_id': 'init'}), 200);
        case '/auth/login_flow/f1':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['password'] != password) {
            return http.Response(jsonEncode({'type': 'form', 'step_id': 'init', 'errors': {'base': 'invalid_auth'}}), 200);
          }
          if (mfa) return http.Response(jsonEncode({'type': 'form', 'step_id': 'mfa', 'flow_id': 'f1'}), 200);
          return http.Response(jsonEncode({'type': 'create_entry', 'result': 'code123'}), 200);
        case '/auth/token':
          expect(request.bodyFields, {'grant_type': 'authorization_code', 'code': 'code123', 'client_id': 'http://192.168.100.202:8123/'});
          return http.Response(
            jsonEncode({'access_token': 'A', 'token_type': 'Bearer', 'expires_in': 1800, 'refresh_token': 'R'}),
            200,
          );
      }
      return http.Response('not found', 404);
    });

void main() {
  final page = Uri.parse('http://192.168.100.202:8123/auth/authorize?response_type=code&client_id=x');

  test('login flow: the tokens as Home Assistant\'s page keeps them', () async {
    final log = <String>[];
    final tokens = await haLoginTokens(page, 'homesystem', 'geheim', client: _ha(log: log));
    expect(log, ['POST /auth/login_flow', 'POST /auth/login_flow/f1', 'POST /auth/token']);
    expect(tokens['access_token'], 'A');
    expect(tokens['refresh_token'], 'R');
    expect(tokens['hassUrl'], 'http://192.168.100.202:8123');
    expect(tokens['clientId'], 'http://192.168.100.202:8123/');
    expect(tokens['expires'] as int, greaterThan(DateTime.now().millisecondsSinceEpoch));
  });

  test('wrong password and two-factor say so', () async {
    await expectLater(
      haLoginTokens(page, 'homesystem', 'falsch', client: _ha()),
      throwsA(isA<HaAuthException>().having((e) => e.error, 'error', HaAuthError.invalidAuth)),
    );
    await expectLater(
      haLoginTokens(page, 'homesystem', 'geheim', client: _ha(mfa: true)),
      throwsA(isA<HaAuthException>().having((e) => e.error, 'error', HaAuthError.mfa)),
    );
    await expectLater(
      haLoginTokens(page, 'homesystem', 'geheim', client: MockClient((_) async => http.Response('', 502))),
      throwsA(isA<HaAuthException>().having((e) => e.error, 'error', HaAuthError.unreachable)),
    );
  });

  test('the login page is recognised', () {
    expect(isHaLoginPage(page.toString()), isTrue);
    expect(isHaLoginPage('http://192.168.100.202:8123/lovelace/0?kiosk'), isFalse);
    expect(isHaLoginPage(null), isFalse);
  });
}
