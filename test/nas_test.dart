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

  group('ranged reads', () {
    test('range header and content range', () {
      expect(httpRangeHeader(0, null), isNull);
      expect(httpRangeHeader(100, null), 'bytes=100-');
      expect(httpRangeHeader(0, 10), 'bytes=0-9');
      expect(httpRangeHeader(2048, 2048), 'bytes=2048-4095');
      expect(contentRangeStart('bytes 100-199/1000'), 100);
      expect(contentRangeTotal('bytes 100-199/1000'), 1000);
      expect(contentRangeTotal('bytes 100-199/*'), isNull);
      expect(contentRangeStart(null), isNull);
    });

    test('slicing a stream', () async {
      Stream<List<int>> source() => Stream.fromIterable([
            [0, 1, 2],
            [3, 4],
            [5, 6, 7, 8],
          ]);
      expect(await _collect(sliceByteStream(source())), [0, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(await _collect(sliceByteStream(source(), skip: 4)), [4, 5, 6, 7, 8]);
      expect(await _collect(sliceByteStream(source(), skip: 2, length: 4)), [2, 3, 4, 5]);
      expect(await _collect(sliceByteStream(source(), length: 3)), [0, 1, 2]);
      expect(await _collect(sliceByteStream(source(), skip: 20)), isEmpty);
    });

    final file = List<int>.generate(100000, (i) => (i * 7) & 0xFF);

    test('FTP: REST + RETR, ABOR when stopped early, connection kept', () async {
      final server = await _FakeFtpServer.start({'/Filme/a.iso': file});
      final client = FtpClient(NasConfig(protocol: NasProtocol.ftp, host: '127.0.0.1', port: server.port));
      try {
        expect(await client.size('/Filme/a.iso'), file.length);
        final part = await _collect(client.openRead('/Filme/a.iso', offset: 1000, length: 5000));
        expect(part, file.sublist(1000, 6000));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(server.commands, contains('REST 1000'));
        expect(server.commands, contains('ABOR'));
        // The rest of the file: read to the end, no ABOR needed.
        server.commands.clear();
        final rest = await _collect(client.openRead('/Filme/a.iso', offset: 99000));
        expect(rest, file.sublist(99000));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(server.commands, isNot(contains('ABOR')));
        // SIZE on the control connection, the streams on one more (kept
        // between them).
        expect(server.logins, 2);
        // Cancelling a running stream.
        server.commands.clear();
        final received = <int>[];
        final done = Completer<void>();
        late StreamSubscription<List<int>> sub;
        sub = client.openRead('/Filme/a.iso').listen((chunk) {
          received.addAll(chunk);
          if (!done.isCompleted) {
            done.complete();
            sub.cancel();
          }
        });
        await done.future;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(server.commands, contains('ABOR'));
        expect(received, file.sublist(0, received.length));
        expect(server.logins, 2);
      } finally {
        client.close();
        await server.close();
      }
    });

    test('FTP: server without REST - skipped on this side', () async {
      final server = await _FakeFtpServer.start({'/a.mpg': file}, rest: false);
      final client = FtpClient(NasConfig(protocol: NasProtocol.ftp, host: '127.0.0.1', port: server.port));
      try {
        expect(await _collect(client.openRead('/a.mpg', offset: 50000, length: 10)), file.sublist(50000, 50010));
        await expectLater(_collect(client.openRead('/missing.mpg')), throwsA(isA<NasException>()));
      } finally {
        client.close();
        await server.close();
      }
    });

    test('WebDAV: Range request, and servers that ignore it', () async {
      var honourRange = true;
      String? lastRange;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        lastRange = request.headers.value('range');
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(lastRange ?? '');
        if (request.method == 'HEAD') {
          response.contentLength = file.length;
        } else if (m != null && honourRange) {
          final start = int.parse(m.group(1)!);
          final end = m.group(2)!.isEmpty ? file.length - 1 : int.parse(m.group(2)!);
          response
            ..statusCode = 206
            ..headers.set('content-range', 'bytes $start-$end/${file.length}')
            ..add(file.sublist(start, end + 1));
        } else {
          response.add(file);
        }
        await response.close();
      });
      final client = WebDavClient(NasConfig(host: '127.0.0.1', port: server.port));
      try {
        expect(await client.size('/Filme/b.mp4'), file.length);
        expect(await _collect(client.openRead('/Filme/b.mp4', offset: 300, length: 700)), file.sublist(300, 1000));
        expect(lastRange, 'bytes=300-999');
        expect(await _collect(client.openRead('/Filme/b.mp4', offset: 99990)), file.sublist(99990));
        honourRange = false;
        expect(await _collect(client.openRead('/Filme/b.mp4', offset: 300, length: 700)), file.sublist(300, 1000));
      } finally {
        client.close();
        await server.close(force: true);
      }
    });
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async => [for (final c in await stream.toList()) ...c];

/// A tiny FTP server for the tests: login, TYPE, EPSV, SIZE, REST, RETR,
/// ABOR, NOOP, QUIT.
class _FakeFtpServer {
  _FakeFtpServer._(this._server, this.files, this.rest);

  final ServerSocket _server;
  final Map<String, List<int>> files;
  final bool rest;
  final commands = <String>[];
  final _clients = <Socket>[];
  int logins = 0;

  int get port => _server.port;

  static Future<_FakeFtpServer> start(Map<String, List<int>> files, {bool rest = true}) async {
    final server = _FakeFtpServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), files, rest);
    server._server.listen(server._serve);
    return server;
  }

  Future<void> _serve(Socket control) async {
    _clients.add(control);
    void reply(String line) {
      try {
        control.write('$line\r\n');
      } catch (_) {}
    }

    reply('220 fake');
    ServerSocket? passive;
    var offset = 0;
    Future<void>? transfer;
    var aborted = false;
    var pending = '';
    await for (final chunk in control) {
      pending += String.fromCharCodes(chunk);
      while (pending.contains('\r\n')) {
        final i = pending.indexOf('\r\n');
        final line = pending.substring(0, i);
        pending = pending.substring(i + 2);
        commands.add(line);
        final space = line.indexOf(' ');
        final verb = (space < 0 ? line : line.substring(0, space)).toUpperCase();
        final arg = space < 0 ? '' : line.substring(space + 1);
        switch (verb) {
          case 'USER':
            reply('331 password');
          case 'PASS':
            logins++;
            reply('230 ok');
          case 'TYPE' || 'OPTS':
            reply('200 ok');
          case 'NOOP':
            await transfer;
            reply('200 noop');
          case 'EPSV':
            passive = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
            reply('229 Entering Extended Passive Mode (|||${passive.port}|)');
          case 'SIZE':
            final f = files[arg];
            reply(f == null ? '550 not found' : '213 ${f.length}');
          case 'REST':
            if (rest) {
              offset = int.parse(arg);
              reply('350 restarting');
            } else {
              reply('502 not implemented');
            }
          case 'RETR':
            final f = files[arg];
            final p = passive;
            passive = null;
            if (f == null || p == null) {
              await p?.close();
              reply('550 not found');
              continue;
            }
            reply('150 opening');
            final start = offset;
            offset = 0;
            aborted = false;
            transfer = () async {
              final data = await p.first;
              await p.close();
              try {
                for (var pos = start; pos < f.length && !aborted; pos += 4096) {
                  data.add(f.sublist(pos, pos + 4096 > f.length ? f.length : pos + 4096));
                  await data.flush();
                }
                await data.close();
                reply(aborted ? '426 aborted' : '226 done');
              } catch (_) {
                data.destroy();
                reply('426 connection closed');
              }
            }();
          case 'ABOR':
            aborted = true;
            await transfer;
            reply('226 abort ok');
          case 'QUIT':
            reply('221 bye');
            await control.close();
          default:
            reply('502 unknown');
        }
      }
    }
  }

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _server.close();
  }
}
