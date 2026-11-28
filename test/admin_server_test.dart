import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/db/database.dart';
import 'package:home_system/data/services/admin_server.dart';
import 'package:home_system/data/services/backup_service.dart';
import 'package:home_system/data/services/nas_service.dart';

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

  test('admin page restore: read a backup (upload or NAS), show its areas, apply the selection', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final backup = BackupService(db);
    await db.setSetting('device_name', 'Altes Gerät');
    await db.setSetting('tv_reminders', '[]');
    await db.setSetting('music_shuffle', 'true');
    final (name: _, :content) = await backup.export();
    await db.setSetting('device_name', 'Wohnzimmer');

    final server = AdminServer(backup: backup, deviceName: () async => 'Wohnzimmer', version: () async => '1.23.0', bindPort: 0)
      ..nasBackups = (
        list: () async => [const NasEntry(name: 'home_system_backup_a.json', path: '/Backups/home_system_backup_a.json', isDirectory: false)],
        read: (file) async => file.path == '/Backups/home_system_backup_a.json' ? content : throw StateError('wrong file'),
      );
    await server.start();
    final client = HttpClient();
    final applied = <(String, BackupRestoreSelection)>[];
    try {
      Future<(int, Map<String, dynamic>)> call(String method, String path, [Object? body]) async {
        final request = await client.open(method, '127.0.0.1', server.boundPort!, path);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(body is String ? body : jsonEncode(body));
        }
        final response = await request.close();
        return (response.statusCode, jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>);
      }

      // Locked until the device shows "Backup wiederherstellen".
      expect((await call('POST', '/api/restore/inspect', content)).$1, 403);
      expect((await call('GET', '/api/restore/nas')).$1, 403);
      expect((await call('POST', '/api/restore/apply', {'token': 'x', 'areas': []})).$1, 403);

      server.restoreHandler = (content, selection) async => applied.add((content, selection));
      final (_, preview) = await call('POST', '/api/restore/inspect', content);
      expect(preview['ok'], isTrue);
      expect(preview['deviceName'], 'Altes Gerät');
      expect(preview['currentName'], 'Wohnzimmer');
      expect([for (final a in preview['areas'] as List) a['id']], ['tv', 'music']);
      expect((preview['areas'] as List).first['title'], isNotEmpty);

      expect((await call('POST', '/api/restore/inspect', 'kein Backup')).$2['ok'], isFalse);
      // A file read again replaces the one before - its token is void.
      final (_, again) = await call('POST', '/api/restore/inspect', content);
      expect((await call('POST', '/api/restore/apply', {'token': preview['token'], 'areas': ['tv']})).$2['ok'], isFalse);
      // Nothing ticked and the name unchanged: nothing to do.
      expect((await call('POST', '/api/restore/apply', {'token': again['token'], 'areas': [], 'deviceName': 'Wohnzimmer'})).$2['ok'],
          isFalse);
      expect(applied, isEmpty);

      final (_, done) = await call('POST', '/api/restore/apply', {
        'token': again['token'],
        'areas': ['tv', 'unknown'],
        'deviceName': ' Küche ',
      });
      expect(done['ok'], isTrue);
      expect(applied.single.$1, content);
      expect(applied.single.$2.areas, {BackupArea.tv});
      expect(applied.single.$2.deviceName, 'Küche');
      // Used up.
      expect((await call('POST', '/api/restore/apply', {'token': again['token'], 'areas': ['tv']})).$2['ok'], isFalse);

      // From the NAS: only files of the backup folder's list.
      final (_, nas) = await call('GET', '/api/restore/nas');
      expect(nas['folder'], isTrue);
      expect([for (final f in nas['files'] as List) f['name']], ['home_system_backup_a.json']);
      expect((await call('POST', '/api/restore/inspect-nas', {'name': '../../secret.json'})).$2['ok'], isFalse);
      final (_, fromNas) = await call('POST', '/api/restore/inspect-nas', {'name': 'home_system_backup_a.json'});
      expect(fromNas['ok'], isTrue);
      expect(fromNas['deviceName'], 'Altes Gerät');
    } finally {
      client.close(force: true);
      await server.stop();
      await db.close();
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
