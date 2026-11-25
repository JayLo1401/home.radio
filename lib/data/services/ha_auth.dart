import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Why logging in to Home Assistant didn't work.
enum HaAuthError {
  /// User name or password wrong.
  invalidAuth,

  /// The user has two-factor authentication - only the login page can do that.
  mfa,

  /// No answer, or not a Home Assistant.
  unreachable,
}

class HaAuthException implements Exception {
  const HaAuthException(this.error, [this.detail]);
  final HaAuthError error;
  final String? detail;

  @override
  String toString() => 'HaAuthException(${error.name}${detail == null ? '' : ': $detail'})';
}

/// Logs in to the Home Assistant at [origin] (e.g. http://192.168.1.5:8123)
/// with [user] and [password] - Home Assistant's own login flow, as its login
/// page does it - and returns what its web page keeps in localStorage
/// ("hassTokens"): with that the dashboard opens logged in, and stays so
/// (the page renews the token itself).
///
/// The client id is the page's own (origin + "/"), so the tokens are the
/// ones the page would have got.
Future<Map<String, Object?>> haLoginTokens(
  Uri origin,
  String user,
  String password, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final base = Uri(scheme: origin.scheme, host: origin.host, port: origin.hasPort ? origin.port : null);
  final hassUrl = base.toString().replaceAll(RegExp(r'/$'), '');
  final clientId = '$hassUrl/';
  final web = client ?? _defaultClient();
  try {
    Future<Map<String, dynamic>> post(String path, Map<String, Object?> body) async {
      final res = await web
          .post(Uri.parse('$hassUrl$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(timeout);
      if (res.statusCode != 200) throw HaAuthException(HaAuthError.unreachable, 'HTTP ${res.statusCode}');
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! Map<String, dynamic>) throw const HaAuthException(HaAuthError.unreachable, 'no JSON');
      return json;
    }

    final flow = await post('/auth/login_flow', {
      'client_id': clientId,
      'handler': ['homeassistant', null],
      'redirect_uri': '$clientId?auth_callback=1',
    });
    final flowId = flow['flow_id'];
    if (flowId is! String) throw const HaAuthException(HaAuthError.unreachable, 'no login flow');
    final step = await post('/auth/login_flow/$flowId', {
      'client_id': clientId,
      'username': user,
      'password': password,
    });
    if (step['type'] != 'create_entry') {
      if (step['step_id'] == 'mfa') throw const HaAuthException(HaAuthError.mfa);
      throw const HaAuthException(HaAuthError.invalidAuth);
    }
    final code = step['result'];
    if (code is! String) throw const HaAuthException(HaAuthError.unreachable, 'no code');
    final res = await web.post(
      Uri.parse('$hassUrl/auth/token'),
      body: {'grant_type': 'authorization_code', 'code': code, 'client_id': clientId},
    ).timeout(timeout);
    if (res.statusCode != 200) throw HaAuthException(HaAuthError.unreachable, 'token HTTP ${res.statusCode}');
    final token = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final expiresIn = (token['expires_in'] as num?)?.toInt() ?? 1800;
    return {
      'access_token': token['access_token'],
      'token_type': token['token_type'] ?? 'Bearer',
      'expires_in': expiresIn,
      'refresh_token': token['refresh_token'],
      'hassUrl': hassUrl,
      'clientId': clientId,
      'expires': DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
    };
  } on HaAuthException {
    rethrow;
  } on TimeoutException {
    throw const HaAuthException(HaAuthError.unreachable, 'timeout');
  } catch (e) {
    throw HaAuthException(HaAuthError.unreachable, '$e');
  } finally {
    if (client == null) web.close();
  }
}

http.Client _defaultClient() => http.Client();

/// Whether [url] is Home Assistant's login page (the dashboard without a
/// valid login lands there).
bool isHaLoginPage(String? url) {
  final uri = url == null ? null : Uri.tryParse(url);
  return uri != null && uri.path.startsWith('/auth/authorize');
}
