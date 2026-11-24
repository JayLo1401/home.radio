import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

import '../../l10n/l10n.dart';

/// How the app talks to the NAS.
enum NasProtocol { webdav, ftp }

/// The NAS folders the user can pick (Settings → NAS).
enum NasFolder { pictures, music, videos, movies, backups }

/// Login and address of the home NAS. Remote paths are POSIX style and
/// absolute ("/", "/Fotos/Wallpaper"); for WebDAV they count from
/// [basePath] (e.g. "/remote.php/dav/files/jay" on Nextcloud).
class NasConfig {
  final NasProtocol protocol;
  final String host;

  /// null: the protocol's default (21, 80/443).
  final int? port;

  /// WebDAV only.
  final bool https;

  /// WebDAV only.
  final String basePath;
  final String user;
  final String password;

  const NasConfig({
    this.protocol = NasProtocol.webdav,
    this.host = '',
    this.port,
    this.https = false,
    this.basePath = '',
    this.user = '',
    this.password = '',
  });

  bool get isConfigured => host.trim().isNotEmpty;

  /// Identifies the server and login (not the password) - e.g. to tell
  /// whether a cache was filled from the same place.
  String get identity => '${protocol.name}|${host.trim()}|${port ?? ''}|$https|${normalizeNasPath(basePath)}|$user';

  NasClient createClient() => switch (protocol) {
        NasProtocol.webdav => WebDavClient(this),
        NasProtocol.ftp => FtpClient(this),
      };
}

/// A file or folder on the NAS.
class NasEntry {
  final String name;

  /// Absolute remote path (see [NasConfig]).
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;

  const NasEntry({required this.name, required this.path, required this.isDirectory, this.size, this.modified});

  @override
  String toString() => 'NasEntry($path${isDirectory ? '/' : ''}, $size)';
}

/// A user-facing (localized) error message.
class NasException implements Exception {
  final String message;
  const NasException(this.message);

  @override
  String toString() => message;
}

/// "/a/b" from "a/b/", "\\a\\b", "" ...
String normalizeNasPath(String path) {
  final parts = path.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty && p != '.').toList();
  return '/${parts.join('/')}';
}

/// [folder] + "/" + [name], normalized.
String joinNasPath(String folder, String name) => normalizeNasPath('$folder/$name');

/// The folder above [path] ("/" stays "/").
String parentNasPath(String path) {
  final parts = normalizeNasPath(path).split('/').where((p) => p.isNotEmpty).toList();
  if (parts.isNotEmpty) parts.removeLast();
  return '/${parts.join('/')}';
}

/// Access to the NAS over one protocol. A client may keep a connection open
/// between calls (FTP) - [close] it when done.
abstract class NasClient {
  /// Logs in and lists the root folder; throws [NasException].
  Future<void> test();

  /// Folders and files in [folder] (not the folder itself), folders first,
  /// then by name.
  Future<List<NasEntry>> list(String folder);

  /// The file's content. [maxBytes]: give up on bigger files.
  Future<Uint8List> read(String path, {int? maxBytes});

  Future<void> write(String path, List<int> bytes);

  Future<void> delete(String path);

  void close();
}

const _timeout = Duration(seconds: 20);

/// Large transfers (backups, pictures) - the per-request timeout is longer.
const _transferTimeout = Duration(seconds: 60);

List<NasEntry> _sorted(List<NasEntry> entries) => entries
  ..sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

/// Turns low-level errors into readable messages.
NasException _describe(Object e) {
  if (e is NasException) return e;
  if (e is TimeoutException) return NasException(l10n.nasErrorTimeout);
  if (e is HandshakeException || e is TlsException) return NasException(l10n.nasErrorTls);
  if (e is SocketException) {
    final code = e.osError?.errorCode;
    // Refused: Linux 111, Windows 10061/1225, macOS 61.
    if (code == 111 || code == 10061 || code == 1225 || code == 61) return NasException(l10n.nasErrorRefused);
    if (e.message.contains('Failed host lookup') || code == 7 || code == 11001) {
      return NasException(l10n.nasErrorHostNotFound);
    }
    return NasException(l10n.nasErrorUnreachable);
  }
  if (e is http.ClientException) return NasException(l10n.nasErrorUnreachable);
  return NasException(l10n.nasErrorOther('$e'));
}

// --- WebDAV ---

/// WebDAV over package:http: PROPFIND (Depth 1) to list, GET, PUT, DELETE,
/// MKCOL. Basic auth. A NAS in the home network usually has a self-signed
/// certificate - for https the configured host's certificate is accepted
/// as is.
class WebDavClient implements NasClient {
  WebDavClient(this.config, {http.Client? client}) : _client = client ?? _createClient(config);

  final NasConfig config;
  final http.Client _client;

  static http.Client _createClient(NasConfig config) {
    final io = HttpClient()
      ..connectionTimeout = _timeout
      ..badCertificateCallback = (cert, host, port) => host == config.host.trim();
    return IOClient(io);
  }

  /// The address of [path] (folders end with "/").
  Uri uriFor(String path, {bool directory = false}) {
    final host = config.host.trim();
    final segments = [
      ...normalizeNasPath(config.basePath).split('/').where((s) => s.isNotEmpty),
      ...normalizeNasPath(path).split('/').where((s) => s.isNotEmpty),
    ];
    final encoded = segments.map(Uri.encodeComponent).join('/');
    final scheme = config.https ? 'https' : 'http';
    final port = config.port;
    final authority = port == null ? host : '$host:$port';
    return Uri.parse('$scheme://$authority/$encoded${directory && segments.isNotEmpty ? '/' : ''}');
  }

  Map<String, String> get _auth => {
        if (config.user.isNotEmpty || config.password.isNotEmpty)
          'Authorization': 'Basic ${base64.encode(utf8.encode('${config.user}:${config.password}'))}',
      };

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    Duration timeout = _timeout,
  }) async {
    final request = http.Request(method, uri)..headers.addAll({..._auth, ...headers});
    if (body != null) request.bodyBytes = body;
    try {
      return await http.Response.fromStream(await _client.send(request).timeout(timeout)).timeout(timeout);
    } catch (e) {
      throw _describe(e);
    }
  }

  NasException _statusError(int status) => switch (status) {
        401 || 403 => NasException(l10n.nasErrorLogin),
        404 || 409 => NasException(l10n.nasErrorNotFound),
        405 || 501 => NasException(l10n.nasErrorNoWebDav),
        507 => NasException(l10n.nasErrorFull),
        _ => NasException(l10n.nasErrorHttp(status)),
      };

  static const _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>'
      '</d:prop></d:propfind>';

  @override
  Future<void> test() async => list('/');

  @override
  Future<List<NasEntry>> list(String folder) async {
    final uri = uriFor(folder, directory: true);
    final response = await _send(
      'PROPFIND',
      uri,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: utf8.encode(_propfindBody),
    );
    if (response.statusCode != 207) throw _statusError(response.statusCode);
    try {
      return _sorted(parsePropfind(utf8.decode(response.bodyBytes, allowMalformed: true), uri.path, folder));
    } on XmlException {
      throw NasException(l10n.nasErrorNoWebDav);
    }
  }

  @override
  Future<Uint8List> read(String path, {int? maxBytes}) async {
    final response = await _send('GET', uriFor(path), timeout: _transferTimeout);
    if (response.statusCode != 200) throw _statusError(response.statusCode);
    if (maxBytes != null && response.bodyBytes.length > maxBytes) throw NasException(l10n.nasErrorTooBig);
    return response.bodyBytes;
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    final response = await _send(
      'PUT',
      uriFor(path),
      headers: {'Content-Type': 'application/octet-stream'},
      body: bytes,
      timeout: _transferTimeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) throw _statusError(response.statusCode);
  }

  @override
  Future<void> delete(String path) async {
    final response = await _send('DELETE', uriFor(path));
    if (response.statusCode != 404 && (response.statusCode < 200 || response.statusCode >= 300)) {
      throw _statusError(response.statusCode);
    }
  }

  /// Creates [folder] (its parent must exist).
  Future<void> createFolder(String folder) async {
    final response = await _send('MKCOL', uriFor(folder, directory: true));
    // 405: exists already.
    if (response.statusCode != 405 && (response.statusCode < 200 || response.statusCode >= 300)) {
      throw _statusError(response.statusCode);
    }
  }

  @override
  void close() => _client.close();
}

/// The entries of a PROPFIND (Depth 1) answer for [folder] (the remote
/// path as the app knows it), whose address path was [requestPath]. The
/// folder itself (the answer's own entry) is left out. Namespace prefixes
/// differ between servers ("d:", "D:", "lp1:", none) - elements are matched
/// by local name.
List<NasEntry> parsePropfind(String body, String requestPath, String folder) {
  final document = XmlDocument.parse(body);
  String key(String path) {
    var decoded = path;
    try {
      decoded = Uri.decodeFull(path);
    } catch (_) {}
    return decoded.replaceAll(RegExp(r'/+$'), '');
  }

  Iterable<XmlElement> children(XmlElement e, String local) =>
      e.childElements.where((c) => c.name.local.toLowerCase() == local);
  XmlElement? child(XmlElement e, String local) => children(e, local).firstOrNull;

  final self = key(requestPath);
  final entries = <NasEntry>[];
  for (final response in document.descendants.whereType<XmlElement>().where((e) => e.name.local == 'response')) {
    final hrefText = child(response, 'href')?.innerText.trim();
    if (hrefText == null || hrefText.isEmpty) continue;
    // Absolute URL or absolute path.
    final hrefPath = Uri.tryParse(hrefText)?.path ?? hrefText;
    final path = key(hrefPath);
    // The folder itself (or anything not below it).
    if (path.length <= self.length) continue;
    final name = path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '');
    if (name.isEmpty) continue;

    var isDirectory = hrefText.endsWith('/');
    int? size;
    DateTime? modified;
    for (final propstat in children(response, 'propstat')) {
      final status = child(propstat, 'status')?.innerText ?? '';
      if (status.isNotEmpty && !status.contains(' 200')) continue;
      final prop = child(propstat, 'prop');
      if (prop == null) continue;
      final type = child(prop, 'resourcetype');
      if (type != null) isDirectory = child(type, 'collection') != null;
      size = int.tryParse(child(prop, 'getcontentlength')?.innerText.trim() ?? '') ?? size;
      final lastModified = child(prop, 'getlastmodified')?.innerText.trim();
      if (lastModified != null && lastModified.isNotEmpty) {
        try {
          modified = HttpDate.parse(lastModified);
        } catch (_) {
          modified = DateTime.tryParse(lastModified);
        }
      }
    }
    entries.add(NasEntry(
      name: name,
      path: joinNasPath(folder, name),
      isDirectory: isDirectory,
      size: isDirectory ? null : size,
      modified: modified,
    ));
  }
  return entries;
}

// --- FTP ---

/// A small passive-mode FTP client (dart:io): one control connection, kept
/// open between calls until [close]; calls run one after the other.
/// EPSV, falling back to PASV (whose address is ignored - the data
/// connection goes to the configured host, which also works behind NAT).
/// MLSD for listings, falling back to LIST (Unix and DOS style).
class FtpClient implements NasClient {
  FtpClient(this.config);

  final NasConfig config;
  _FtpConnection? _connection;
  Future<void> _queue = Future.value();

  /// Runs [action] after the previous call and turns errors into
  /// [NasException]s; a broken connection is dropped.
  Future<T> _run<T>(Future<T> Function(_FtpConnection c) action) {
    final result = _queue.then((_) async {
      try {
        final connection = _connection ??= await _FtpConnection.open(config);
        return await action(connection);
      } catch (e) {
        if (e is! _FtpReplyException) {
          _connection?.destroy();
          _connection = null;
        }
        throw e is _FtpReplyException ? e.toNas() : _describe(e);
      }
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> test() => _run((c) async {
        await c.list('/');
      });

  @override
  Future<List<NasEntry>> list(String folder) => _run((c) async => _sorted(await c.list(folder)));

  @override
  Future<Uint8List> read(String path, {int? maxBytes}) => _run((c) => c.retrieve(path, maxBytes));

  @override
  Future<void> write(String path, List<int> bytes) => _run((c) => c.store(path, bytes));

  @override
  Future<void> delete(String path) => _run((c) async {
        await c.command('DELE ${normalizeNasPath(path)}', ok: {250});
      });

  @override
  void close() {
    final connection = _connection;
    _connection = null;
    connection?.quit();
  }
}

class _FtpReply {
  final int code;
  final String text;
  const _FtpReply(this.code, this.text);
}

class _FtpReplyException implements Exception {
  final _FtpReply reply;
  const _FtpReplyException(this.reply);

  NasException toNas() => switch (reply.code) {
        530 => NasException(l10n.nasErrorLogin),
        550 => NasException(l10n.nasErrorNotFound),
        552 => NasException(l10n.nasErrorFull),
        _ => NasException(l10n.nasErrorFtp('${reply.code} ${reply.text}'.trim())),
      };

  @override
  String toString() => 'FTP ${reply.code} ${reply.text}';
}

class _FtpConnection {
  _FtpConnection._(this._host, this._socket) : _lines = StreamIterator(_decodeLines(_socket));

  final String _host;
  final Socket _socket;
  final StreamIterator<String> _lines;
  bool _mlsd = true;

  /// UTF-8, or Latin-1 for lines that aren't (older servers).
  static Stream<String> _decodeLines(Stream<List<int>> bytes) async* {
    final buffer = <int>[];
    await for (final chunk in bytes) {
      for (final b in chunk) {
        if (b == 10) {
          if (buffer.isNotEmpty && buffer.last == 13) buffer.removeLast();
          yield decodeFtpText(buffer);
          buffer.clear();
        } else {
          buffer.add(b);
        }
      }
    }
    if (buffer.isNotEmpty) yield decodeFtpText(buffer);
  }

  static Future<_FtpConnection> open(NasConfig config) async {
    final host = config.host.trim();
    final socket = await Socket.connect(host, config.port ?? 21, timeout: _timeout);
    final connection = _FtpConnection._(host, socket);
    try {
      await connection._reply(expect: {220});
      final user = config.user.isEmpty ? 'anonymous' : config.user;
      final reply = await connection.command('USER $user', ok: {230, 331});
      if (reply.code == 331) await connection.command('PASS ${config.password}', ok: {230, 202});
      await connection.command('TYPE I', ok: {200});
      // Names as UTF-8 where the server can (no matter if it can't).
      await connection.command('OPTS UTF8 ON');
      return connection;
    } catch (_) {
      connection.destroy();
      rethrow;
    }
  }

  Future<_FtpReply> _reply({Set<int>? expect, Duration timeout = _timeout}) async {
    Future<String> next() async {
      if (!await _lines.moveNext().timeout(timeout)) throw const SocketException('FTP connection closed');
      return _lines.current;
    }

    var line = await next();
    final text = StringBuffer();
    final code = int.tryParse(line.length >= 3 ? line.substring(0, 3) : '');
    if (code == null) throw SocketException('Bad FTP reply: $line');
    text.write(line.length > 4 ? line.substring(4) : '');
    // Multi-line reply: "123-..." up to "123 ...".
    if (line.length > 3 && line[3] == '-') {
      do {
        line = await next();
      } while (!(line.startsWith('$code ') || line == '$code'));
    }
    final reply = _FtpReply(code, text.toString().trim());
    if (expect != null && !expect.contains(code)) throw _FtpReplyException(reply);
    return reply;
  }

  /// Sends [line]; with [ok], other reply codes throw.
  Future<_FtpReply> command(String line, {Set<int>? ok}) async {
    _socket.add(utf8.encode('$line\r\n'));
    return _reply(expect: ok);
  }

  Future<Socket> _openData() async {
    var reply = await command('EPSV');
    int? port;
    if (reply.code == 229) {
      port = int.tryParse(RegExp(r'\(\|\|\|(\d+)\|\)').firstMatch(reply.text)?.group(1) ?? '');
    }
    if (port == null) {
      reply = await command('PASV', ok: {227});
      port = parsePasvPort(reply.text);
      if (port == null) throw _FtpReplyException(reply);
    }
    return Socket.connect(_host, port, timeout: _timeout);
  }

  /// Runs [line] over a new data connection; [use] gets the data socket.
  Future<T> _transfer<T>(String line, Future<T> Function(Socket data) use) async {
    final data = await _openData();
    try {
      await command(line, ok: {125, 150});
      final result = await use(data);
      await _reply(expect: {226, 250}, timeout: _transferTimeout);
      return result;
    } finally {
      data.destroy();
    }
  }

  Future<List<int>> _readAll(Socket data, int? maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in data.timeout(_transferTimeout)) {
      builder.add(chunk);
      if (maxBytes != null && builder.length > maxBytes) throw NasException(l10n.nasErrorTooBig);
    }
    return builder.takeBytes();
  }

  Future<List<NasEntry>> list(String folder) async {
    final path = normalizeNasPath(folder);
    // CWD + list without argument: names with spaces work everywhere.
    await command('CWD $path', ok: {250});
    if (_mlsd) {
      final data = await _openData();
      try {
        final reply = await command('MLSD');
        if (reply.code == 125 || reply.code == 150) {
          final bytes = await _readAll(data, null);
          await _reply(expect: {226, 250}, timeout: _transferTimeout);
          return [
            for (final line in const LineSplitter().convert(decodeFtpText(bytes)))
              ?parseMlsdLine(line, path),
          ];
        }
        // 500/501/502/504: no MLSD on this server - LIST from now on.
        if (!const {500, 501, 502, 504}.contains(reply.code)) throw _FtpReplyException(reply);
        _mlsd = false;
      } finally {
        data.destroy();
      }
    }
    final bytes = await _transfer('LIST', (data) => _readAll(data, null));
    return [
      for (final line in const LineSplitter().convert(decodeFtpText(bytes)))
        ?parseListLine(line, path),
    ];
  }

  Future<Uint8List> retrieve(String path, int? maxBytes) async {
    final bytes = await _transfer('RETR ${normalizeNasPath(path)}', (data) => _readAll(data, maxBytes));
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }

  Future<void> store(String path, List<int> bytes) => _transfer('STOR ${normalizeNasPath(path)}', (data) async {
        data.add(bytes);
        await data.flush().timeout(_transferTimeout);
        await data.close().timeout(_transferTimeout);
      });

  void quit() {
    try {
      _socket.add(utf8.encode('QUIT\r\n'));
    } catch (_) {}
    Future<void>.delayed(const Duration(milliseconds: 300), destroy);
  }

  void destroy() {
    _lines.cancel();
    _socket.destroy();
  }
}

/// UTF-8 text, or Latin-1 if the bytes aren't UTF-8.
String decodeFtpText(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// The data port of a "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)" reply.
int? parsePasvPort(String text) {
  final m = RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(text);
  if (m == null) return null;
  return int.parse(m.group(5)!) * 256 + int.parse(m.group(6)!);
}

/// One MLSD line ("type=file;size=12;modify=20261124120000; name.jpg");
/// null for "." / ".." and unknown types.
NasEntry? parseMlsdLine(String line, String folder) {
  final space = line.indexOf(' ');
  if (space <= 0) return null;
  final name = line.substring(space + 1);
  final facts = <String, String>{};
  for (final fact in line.substring(0, space).split(';')) {
    final eq = fact.indexOf('=');
    if (eq > 0) facts[fact.substring(0, eq).toLowerCase()] = fact.substring(eq + 1);
  }
  final type = facts['type']?.toLowerCase();
  if (type != 'file' && type != 'dir' && !(type?.startsWith('os.unix=symlink') ?? false)) return null;
  if (name.isEmpty || name == '.' || name == '..') return null;
  DateTime? modified;
  final m = facts['modify'];
  if (m != null && m.length >= 14) {
    modified = DateTime.tryParse('${m.substring(0, 8)}T${m.substring(8, 14)}Z');
  }
  return NasEntry(
    name: name,
    path: joinNasPath(folder, name),
    isDirectory: type == 'dir',
    size: type == 'file' ? int.tryParse(facts['size'] ?? '') : null,
    modified: modified,
  );
}

final _unixList = RegExp(r'^([dl-])\S{9}\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\w{3}\s+\d{1,2}\s+[\d:]{4,5}\s(.+)$');
final _dosList = RegExp(r'^\d{2}-\d{2}-\d{2,4}\s+\d{1,2}:\d{2}(?:AM|PM)?\s+(<DIR>|\d+)\s+(.+)$', caseSensitive: false);

/// One LIST line, Unix ("drwxr-xr-x 2 user group 4096 Nov 24 12:00 Name")
/// or DOS style (`11-24-26  12:00PM  <DIR>  Name`); null for "." / "..",
/// "total 12" and anything unknown. Symlinks count as folders (usually
/// shares on a NAS) with the target cut off.
NasEntry? parseListLine(String line, String folder) {
  final unix = _unixList.firstMatch(line);
  if (unix != null) {
    var name = unix.group(3)!;
    final kind = unix.group(1)!;
    if (kind == 'l') {
      final arrow = name.indexOf(' -> ');
      if (arrow > 0) name = name.substring(0, arrow);
    }
    if (name == '.' || name == '..') return null;
    final isDirectory = kind != '-';
    return NasEntry(
      name: name,
      path: joinNasPath(folder, name),
      isDirectory: isDirectory,
      size: isDirectory ? null : int.tryParse(unix.group(2)!),
    );
  }
  final dos = _dosList.firstMatch(line.trim());
  if (dos != null) {
    final name = dos.group(2)!;
    if (name == '.' || name == '..') return null;
    final isDirectory = dos.group(1)!.toUpperCase() == '<DIR>';
    return NasEntry(
      name: name,
      path: joinNasPath(folder, name),
      isDirectory: isDirectory,
      size: isDirectory ? null : int.tryParse(dos.group(1)!),
    );
  }
  return null;
}
