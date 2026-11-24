import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/nas_backup_service.dart';
import 'package:home_system/data/services/nas_service.dart';
import 'package:home_system/l10n/l10n.dart';

void main() {
  group('parsePropfind', () {
    test('Nextcloud style (d: prefix, base path, encoded names)', () {
      const body = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/jay/Fotos/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getlastmodified>Mon, 24 Nov 2026 10:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/files/jay/Fotos/Urlaub%202026/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/files/jay/Fotos/Sch%C3%B6n.jpg</d:href>
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>123456</d:getcontentlength><d:getlastmodified>Tue, 25 Nov 2026 08:30:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>''';
      final entries = parsePropfind(body, '/remote.php/dav/files/jay/Fotos/', '/Fotos');
      expect(entries, hasLength(2));
      final folder = entries.firstWhere((e) => e.isDirectory);
      expect(folder.name, 'Urlaub 2026');
      expect(folder.path, '/Fotos/Urlaub 2026');
      expect(folder.size, isNull);
      final file = entries.firstWhere((e) => !e.isDirectory);
      expect(file.name, 'Schön.jpg');
      expect(file.path, '/Fotos/Schön.jpg');
      expect(file.size, 123456);
      expect(file.modified, DateTime.utc(2026, 11, 25, 8, 30));
    });

    test('Apache mod_dav style (D:/lp1: prefixes, absolute URLs, root folder)', () {
      const body = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
<D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
<D:href>http://nas.local/</D:href>
<D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response>
<D:response xmlns:lp1="DAV:">
<D:href>http://nas.local/Backups/</D:href>
<D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response>
<D:response xmlns:lp1="DAV:">
<D:href>http://nas.local/readme.txt</D:href>
<D:propstat><D:prop><lp1:resourcetype/><lp1:getcontentlength>42</lp1:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response>
</D:multistatus>''';
      final entries = parsePropfind(body, '/', '/');
      expect(entries.map((e) => (e.name, e.path, e.isDirectory, e.size)), [
        ('Backups', '/Backups', true, null),
        ('readme.txt', '/readme.txt', false, 42),
      ]);
    });

    test('self entry without trailing slash is left out', () {
      const body = '''<multistatus xmlns="DAV:">
<response><href>/dav/Musik</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response><href>/dav/Musik/a.mp3</href><propstat><prop><resourcetype/><getcontentlength>7</getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat></response>
</multistatus>''';
      final entries = parsePropfind(body, '/dav/Musik/', '/Musik');
      expect(entries, hasLength(1));
      expect(entries.single.path, '/Musik/a.mp3');
    });
  });

  group('backupsToPrune', () {
    List<String> names(String prefix, int count) => [
          for (var i = 1; i <= count; i++) '${prefix}2026-11-${i.toString().padLeft(2, '0')}_120000.json',
        ];

    test('keeps the 14 newest of this device, never other devices or files', () {
      final own = names('home_system_backup_Wohnzimmer_', 20);
      final others = [
        ...names('home_system_backup_Kueche_', 20),
        ...names('home_system_backup_Wohnzimmer_2_', 20),
        ...names('home_system_backup_', 20), // device without name
        'home_system_backup_Wohnzimmer_notes.json',
        'something_else.json',
        'home_system_backup_Wohnzimmer_2026-11-01_120000.json.bak',
      ];
      final newest = own.last;
      final prune = backupsToPrune(newest, [...others, ...own]..shuffle());
      expect(prune.toSet(), own.take(6).toSet());
    });

    test('device without a name only prunes its own unnamed backups', () {
      final own = names('home_system_backup_', 16);
      final others = names('home_system_backup_Wohnzimmer_', 20);
      final prune = backupsToPrune(own.last, [...own, ...others]);
      expect(prune.toSet(), own.take(2).toSet());
    });

    test('nothing to prune with 14 or fewer, or an unknown name', () {
      final own = names('home_system_backup_TV_', 14);
      expect(backupsToPrune(own.last, own), isEmpty);
      expect(backupsToPrune('other.json', names('home_system_backup_', 30)), isEmpty);
    });

    test('time stamp order, not list order', () {
      final own = [
        'home_system_backup_TV_2025-12-31_235959.json',
        'home_system_backup_TV_2026-01-01_000000.json',
        'home_system_backup_TV_2026-01-01_000001.json',
      ];
      expect(backupsToPrune(own[2], own.reversed, keep: 2), [own[0]]);
    });
  });

  group('FTP parsing', () {
    test('MLSD lines', () {
      final file = parseMlsdLine('type=file;size=2048;modify=20261124120000;perm=r; Bild 1.jpg', '/Fotos');
      expect((file!.name, file.path, file.isDirectory, file.size), ('Bild 1.jpg', '/Fotos/Bild 1.jpg', false, 2048));
      expect(file.modified, DateTime.utc(2026, 11, 24, 12));
      final dir = parseMlsdLine('Type=dir;Modify=20261124120000; Urlaub', '/');
      expect((dir!.path, dir.isDirectory), ('/Urlaub', true));
      expect(parseMlsdLine('type=cdir; .', '/'), isNull);
      expect(parseMlsdLine('type=pdir; ..', '/'), isNull);
    });

    test('LIST lines (Unix and DOS)', () {
      final file = parseListLine('-rw-r--r--    1 jay  users   123456 Nov 24 12:00 Mein Bild.png', '/a');
      expect((file!.name, file.isDirectory, file.size), ('Mein Bild.png', false, 123456));
      final dir = parseListLine('drwxrwxrwx+  3 admin administrators 4096 Jan  5  2025 photo', '/');
      expect((dir!.path, dir.isDirectory), ('/photo', true));
      final link = parseListLine('lrwxrwxrwx 1 root root 7 Nov 24 12:00 share -> /volume1/share', '/');
      expect((link!.name, link.isDirectory), ('share', true));
      expect(parseListLine('total 12', '/'), isNull);
      final dos = parseListLine('11-24-26  12:00PM       <DIR>          Backups', '/');
      expect((dos!.name, dos.isDirectory), ('Backups', true));
      final dosFile = parseListLine('11-24-26  12:00PM                 1024 a.json', '/Backups');
      expect((dosFile!.path, dosFile.size), ('/Backups/a.json', 1024));
    });

    test('PASV port and paths', () {
      expect(parsePasvPort('Entering Passive Mode (192,168,1,10,195,80).'), 195 * 256 + 80);
      expect(normalizeNasPath('Fotos//2026/'), '/Fotos/2026');
      expect(parentNasPath('/Fotos/2026'), '/Fotos');
      expect(parentNasPath('/'), '/');
      expect(WebDavClient(const NasConfig(host: 'nas', port: 5005, basePath: '/dav/')).uriFor('/Ä b', directory: true).toString(),
          'http://nas:5005/dav/%C3%84%20b/');
    });
  });

  group('SMB', () {
    test('path split into share and path', () {
      expect(splitSmbPath('/'), (share: null, path: '/'));
      expect(splitSmbPath(''), (share: null, path: '/'));
      expect(splitSmbPath('/Daten'), (share: 'Daten', path: '/'));
      expect(splitSmbPath('Daten/'), (share: 'Daten', path: '/'));
      expect(splitSmbPath('/Daten/Fotos/Urlaub 2026'), (share: 'Daten', path: '/Fotos/Urlaub 2026'));
      expect(splitSmbPath(r'\ftp_Folder\a\b.json'), (share: 'ftp_Folder', path: '/a/b.json'));
    });

    test('top level lists the shares without the administrative ones', () {
      final entries = smbShareEntries(['ThomasL', 'IPC\$', 'backups', 'C\$', 'ADMIN\$', 'print\$', 'Daten', 'LotzApp', 'ftp_Folder', 'Daten']);
      expect([for (final e in entries) e.name], ['backups', 'Daten', 'ftp_Folder', 'LotzApp', 'ThomasL']);
      expect(entries.every((e) => e.isDirectory && e.path == '/${e.name}'), isTrue);
      expect(isVisibleSmbShare('Fotos'), isTrue);
      expect(isVisibleSmbShare('D\$'), isFalse);
      expect(isVisibleSmbShare(' '), isFalse);
    });

    test('readable errors', () {
      expect(describeSmbError('Logon failure: unknown user name or bad password.').message, l10n.nasErrorLogin);
      expect(describeSmbError("Can't delete /a/b: Access is denied.").message, l10n.nasErrorLogin);
      expect(describeSmbError('The system cannot find the path specified.').message, l10n.nasErrorNotFound);
      expect(describeSmbError('The network name cannot be found.').message, l10n.nasErrorNotFound);
      expect(describeSmbError('The file system is full.').message, l10n.nasErrorFull);
      expect(describeSmbError("Can't connect to server").message, l10n.nasErrorSmbConnect);
      expect(describeSmbError(const SocketException('x', osError: OSError('refused', 10061))).message,
          l10n.nasErrorRefused);
      expect(describeSmbError('Something else').message, l10n.nasErrorSmb('Something else'));
      expect(isSmbServerAnswer('Access is denied.'), isTrue);
      expect(isSmbServerAnswer(TimeoutException('x')), isFalse);
    });

    test('identity unchanged without domain', () {
      const config = NasConfig(protocol: NasProtocol.ftp, host: 'nas', user: 'jay');
      expect(config.identity, 'ftp|nas||false|/|jay');
      expect(const NasConfig(protocol: NasProtocol.smb, host: 'server', domain: 'WORKGROUP').identity,
          'smb|server||false|/||WORKGROUP');
      expect(const NasConfig(protocol: NasProtocol.smb).createClient(), isA<SmbClient>());
    });
  });
}