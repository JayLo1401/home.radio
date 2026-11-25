import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/admin_server.dart';
import 'package:home_system/data/services/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The binding fakes every HttpClient (status 400) - this test talks to the
  // real admin server on this machine.
  setUp(() => HttpOverrides.global = null);

  test('admin page: areas and settings, actions, NAS folder browsing, logos', () async {
    final source = _FakeSettings();
    final server = AdminServer(backup: _NoBackup(), deviceName: () async => 'Wohnzimmer', version: () async => '1.23.0', bindPort: 0)
      ..settings = source;
    await server.start();
    final client = HttpClient();
    try {
      Future<(int, String, List<int>)> get(String path) async {
        final response = await (await client.get('127.0.0.1', server.boundPort!, path)).close();
        final bytes = [for (final c in await response.toList()) ...c];
        return (response.statusCode, response.headers.contentType?.mimeType ?? '', bytes);
      }

      Future<Map<String, dynamic>> post(Map<String, Object?> body) async {
        final request = await client.post('127.0.0.1', server.boundPort!, '/api/settings');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
        final response = await request.close();
        return jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
      }

      final (status, type, page) = await get('/');
      expect((status, type), (200, 'text/html'));
      final html = utf8.decode(page);
      expect(html, contains('Wohnzimmer'));
      expect(html, contains('id="areas"'));

      final settings = jsonDecode(utf8.decode((await get('/api/settings')).$3)) as Map<String, dynamic>;
      expect((settings['areas'] as List).first['id'], 'system');
      expect((settings['groups'] as List).first['items'][0]['type'], 'folder');

      expect(await post({'id': 'nasTest', 'value': null}), {'ok': true, 'message': 'Verbindung OK'});
      expect((await post({'id': 'nasHost', 'value': 'nas'}))['ok'], isTrue);
      expect(source.applied['nasHost'], 'nas');
      expect((await post({'id': 'broken', 'value': 1}))['ok'], isFalse);

      final browse = jsonDecode(utf8.decode((await get('/api/browse?id=nasFolder_music&path=%2FDaten')).$3));
      expect(browse, {'path': '/Daten', 'id': 'nasFolder_music', 'folders': []});

      final (logoStatus, logoType, logo) = await get('/logo/radio_logo.png');
      expect((logoStatus, logoType), (200, 'image/png'));
      expect(logo.sublist(1, 4), ascii.encode('PNG'));
      expect((await get('/logo/secret.png')).$1, 404);
      expect((await get('/logo/../pubspec.png')).$1, 404);
    } finally {
      client.close(force: true);
      await server.stop();
    }
  });
}

class _NoBackup implements BackupService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSettings implements AdminSettingsSource {
  final applied = <String, Object?>{};

  @override
  Future<Map<String, Object?>> describe() async => {
        'areas': [
          {'id': 'system', 'logo': 'home_system_logo', 'title': 'System', 'subtitle': 'NAS, Backup', 'enabled': true},
          {'id': 'radio', 'logo': 'radio_logo', 'title': 'Radio', 'subtitle': 'aus', 'enabled': false},
        ],
        'groups': [
          {
            'area': 'system',
            'title': 'Ordner',
            'items': [
              {'id': 'nasFolder_music', 'label': 'Musik', 'type': 'folder', 'button': 'Durchsuchen…', 'value': '/Daten/Musik'},
              {'id': 'nasTest', 'label': 'Verbindung testen', 'type': 'action', 'button': 'Testen', 'value': null},
              {'id': 'device', 'label': 'Xiaomi', 'type': 'info', 'value': ['Android 14', 'System: 32-bit']},
            ],
          },
        ],
      };

  @override
  Future<AdminResult> apply(String id, Object? value) async {
    if (id == 'broken') throw StateError('broken');
    if (id == 'nasTest') return (ok: true, message: 'Verbindung OK');
    applied[id] = value;
    return (ok: true, message: null);
  }

  @override
  Future<Map<String, Object?>> browse(String id, String path) async => {'path': path, 'id': id, 'folders': []};
}
