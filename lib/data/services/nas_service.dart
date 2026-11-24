import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:smb_connect/smb_connect.dart';
import 'package:xml/xml.dart';

import '../../l10n/l10n.dart';

/// How the app talks to the NAS. [smb]: Windows file sharing (also Samba).
enum NasProtocol { webdav, ftp, smb }

/// The NAS folders the user can pick (Settings → NAS).
/// The NAS folders: [backgrounds] for Home's background pictures, the
/// others for playing files later (and [backups]).
enum NasFolder { backgrounds, pictures, music, videos, movies, backups }

/// Login and address of the home NAS. Remote paths are POSIX style and
/// absolute ("/", "/Fotos/Wallpaper"); for WebDAV they count from
/// [basePath] (e.g. "/remote.php/dav/files/jay" on Nextcloud), for SMB the
/// first part is the share ("/Daten/Fotos").
class NasConfig {
  final NasProtocol protocol;
  final String host;

  /// null: the protocol's default (21, 80/443). SMB always uses 445.
  final int? port;

  /// WebDAV only.
  final bool https;

  /// WebDAV only.
  final String basePath;
  final String user;
  final String password;

  /// SMB only: the Windows domain or workgroup of [user]; usually empty
  /// (the server's own accounts).
  final String domain;

  const NasConfig({
    this.protocol = NasProtocol.webdav,
    this.host = '',
    this.port,
    this.https = false,
    this.basePath = '',
    this.user = '',
    this.password = '',
    this.domain = '',
  });

  bool get isConfigured => host.trim().isNotEmpty;

  /// Identifies the server and login (not the password) - e.g. to tell
  /// whether a cache was filled from the same place.
  String get identity => [
        protocol.name,
        host.trim(),
        port ?? '',
        https,
        normalizeNasPath(basePath),
        user,
        // Only when set - the identity of existing settings stays the same.
        if (domain.trim().isNotEmpty) domain.trim(),
      ].join('|');

  NasClient createClient() => switch (protocol) {
        NasProtocol.webdav => WebDavClient(this),
        NasProtocol.ftp => FtpClient(this),
        NasProtocol.smb => SmbClient(this),
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

  /// The size of the file at [path] in bytes - null if the server doesn't
  /// say. Throws [NasException] (e.g. not found).
  Future<int?> size(String path);

  /// The file's bytes from [offset] on: [length] bytes, or up to its end
  /// (fewer if the file ends before). For playing and seeking in big files
  /// (films, music): the bytes come as they arrive, nothing is held in
  /// memory. Each stream has its own transfer - FTP a connection of its
  /// own, SMB a second connection shared by the streams - so listings and
  /// other reads go on meanwhile, and several streams can run at once.
  /// Cancelling the subscription stops the transfer (FTP: ABOR). Errors
  /// come as [NasException]s on the stream.
  Stream<List<int>> openRead(String path, {int offset = 0, int? length});

  void close();
}

/// The HTTP "Range" header value for [offset] / [length] - null for the
/// whole file.
String? httpRangeHeader(int offset, int? length) {
  if (offset <= 0 && length == null) return null;
  final start = offset < 0 ? 0 : offset;
  return length == null ? 'bytes=$start-' : 'bytes=$start-${start + length - 1}';
}

/// The first byte of a "Content-Range: bytes 100-199/1000" answer.
int? contentRangeStart(String? header) {
  final m = RegExp(r'bytes\s+(\d+)-\d+').firstMatch(header ?? '');
  return m == null ? null : int.parse(m.group(1)!);
}

/// The total size in a "Content-Range: bytes 100-199/1000" answer.
int? contentRangeTotal(String? header) {
  final m = RegExp(r'/(\d+)\s*$').firstMatch(header ?? '');
  return m == null ? null : int.parse(m.group(1)!);
}

/// Cuts a byte stream to the part from [skip] on, at most [length] bytes
/// (servers that ignore the requested range send the whole file); ends
/// (cancelling [source]) as soon as [length] is through.
Stream<List<int>> sliceByteStream(Stream<List<int>> source, {int skip = 0, int? length}) async* {
  var toSkip = skip;
  var left = length;
  if (left != null && left <= 0) return;
  await for (var chunk in source) {
    if (toSkip > 0) {
      if (chunk.length <= toSkip) {
        toSkip -= chunk.length;
        continue;
      }
      chunk = chunk.sublist(toSkip);
      toSkip = 0;
    }
    if (left != null) {
      if (chunk.length >= left) {
        yield chunk.length == left ? chunk : chunk.sublist(0, left);
        return;
      }
      left -= chunk.length;
    }
    yield chunk;
  }
}

const _timeout = Duration(seconds: 20);

/// A call to a client that was closed meanwhile (nobody waits for it).
const _closedMessage = 'NAS connection closed';

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

  @override
  Future<int?> size(String path) async {
    final response = await _send('HEAD', uriFor(path));
    if (response.statusCode >= 300) throw _statusError(response.statusCode);
    final length = int.tryParse(response.headers['content-length'] ?? '');
    if (length != null) return length;
    // No length on HEAD (some servers) - the folder's listing has it.
    final name = normalizeNasPath(path).split('/').last;
    final entries = await list(parentNasPath(path));
    return entries.where((e) => e.name == name && !e.isDirectory).firstOrNull?.size;
  }

  /// GET with a "Range" header; a server that ignores it (200, the whole
  /// file) is cut to the requested part here.
  @override
  Stream<List<int>> openRead(String path, {int offset = 0, int? length}) async* {
    if (length != null && length <= 0) return;
    final abort = Completer<void>();
    final request = http.AbortableRequest('GET', uriFor(path), abortTrigger: abort.future)
      ..headers.addAll({..._auth, 'Range': ?httpRangeHeader(offset, length)});
    try {
      final http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(_timeout);
      } catch (e) {
        throw _describe(e);
      }
      if (response.statusCode == 416) return; // From behind the end.
      if (response.statusCode != 200 && response.statusCode != 206) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        throw _statusError(response.statusCode);
      }
      final start = response.statusCode == 206 ? contentRangeStart(response.headers['content-range']) ?? offset : 0;
      try {
        yield* sliceByteStream(response.stream.timeout(_transferTimeout), skip: offset - start, length: length);
      } on http.RequestAbortedException {
        return;
      } catch (e) {
        throw _describe(e);
      }
    } finally {
      if (!abort.isCompleted) abort.complete();
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

  /// After [close], calls still waiting don't open a new connection.
  bool _closed = false;

  /// Runs [action] after the previous call and turns errors into
  /// [NasException]s; a broken connection is dropped.
  Future<T> _run<T>(Future<T> Function(_FtpConnection c) action) {
    final result = _queue.then((_) async {
      if (_closed) throw const NasException(_closedMessage);
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
  Future<int?> size(String path) => _run((c) async {
        final reply = await c.command('SIZE ${normalizeNasPath(path)}');
        if (reply.code == 213) return int.tryParse(reply.text.trim());
        if (reply.code == 550) throw _FtpReplyException(reply);
        // No SIZE on this server: the folder's listing.
        final name = normalizeNasPath(path).split('/').last;
        final entries = await c.list(parentNasPath(path));
        return entries.where((e) => e.name == name && !e.isDirectory).firstOrNull?.size;
      });

  /// Logged-in connections of finished streams, for the next one (a player
  /// seeking opens one stream after the other).
  final _idle = <_FtpConnection>[];
  static const _maxIdle = 2;
  static const _idleTime = Duration(seconds: 30);

  /// "REST offset" + "RETR" on a connection of its own (the control
  /// connection of [list] & co. stays free). A server without REST sends
  /// from the start - skipped here. Stopping early closes the data
  /// connection and sends ABOR; the connection is kept for the next stream
  /// once it answers again (NOOP).
  @override
  Stream<List<int>> openRead(String path, {int offset = 0, int? length}) async* {
    if (length != null && length <= 0) return;
    if (_closed) throw const NasException(_closedMessage);
    _FtpConnection? connection;
    Socket? data;
    var usable = true; // the control connection is in a known state
    var transferring = false;
    var ended = false;
    try {
      var skip = 0;
      try {
        final pooled = _idle.isNotEmpty;
        connection = pooled ? _takeIdle() : await _FtpConnection.open(config);
        try {
          (data, skip) = await _startRetrieve(connection, path, offset);
        } catch (e) {
          // A kept connection the server has dropped meanwhile: a new one.
          if (!pooled || e is _FtpReplyException) rethrow;
          connection.destroy();
          connection = null;
          connection = await _FtpConnection.open(config);
          (data, skip) = await _startRetrieve(connection, path, offset);
        }
        transferring = true;
      } catch (e) {
        if (e is! _FtpReplyException) usable = false;
        throw e is _FtpReplyException ? e.toNas() : _describe(e);
      }
      final source = data.transform<List<int>>(StreamTransformer.fromHandlers(handleDone: (sink) {
        ended = true;
        sink.close();
      }));
      try {
        yield* sliceByteStream(source.timeout(_transferTimeout), skip: skip, length: length);
      } catch (e) {
        usable = false;
        throw _describe(e);
      }
    } finally {
      data?.destroy();
      final c = connection;
      if (c != null) {
        if (!usable) {
          c.destroy();
        } else {
          unawaited(_settle(c, transferring: transferring, aborted: transferring && !ended));
        }
      }
    }
  }

  _FtpConnection _takeIdle() {
    final c = _idle.removeLast();
    c.idleTimer?.cancel();
    return c;
  }

  static Future<(Socket, int)> _startRetrieve(_FtpConnection c, String path, int offset) async {
    final data = await c._openData();
    try {
      var skip = 0;
      if (offset > 0) {
        final rest = await c.command('REST $offset');
        if (rest.code != 350) skip = offset;
      }
      await c.command('RETR ${normalizeNasPath(path)}', ok: {125, 150});
      return (data, skip);
    } catch (_) {
      data.destroy();
      rethrow;
    }
  }

  /// After a stream: the transfer's last answer read (or the transfer
  /// aborted), then the connection is kept for the next stream.
  Future<void> _settle(_FtpConnection c, {required bool transferring, required bool aborted}) async {
    try {
      if (aborted) {
        await c.abort();
      } else if (transferring) {
        await c._reply(expect: {226, 250}, timeout: const Duration(seconds: 10));
      }
    } catch (_) {
      c.destroy();
      return;
    }
    if (_closed || _idle.length >= _maxIdle) {
      c.quit();
      return;
    }
    _idle.add(c);
    c.idleTimer = Timer(_idleTime, () {
      if (_idle.remove(c)) c.quit();
    });
  }

  @override
  void close() {
    _closed = true;
    final connection = _connection;
    _connection = null;
    connection?.quit();
    for (final c in _idle) {
      c.idleTimer?.cancel();
      c.quit();
    }
    _idle.clear();
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

  /// While kept for the next stream (FtpClient.openRead): quits it later.
  Timer? idleTimer;

  /// After a transfer was stopped early (data connection closed): ABOR,
  /// then NOOP - its "200" is the sign that every answer of the aborted
  /// transfer (426, 225/226, or 500 if it had ended anyway) is read.
  Future<void> abort() async {
    _socket.add(utf8.encode('ABOR\r\nNOOP\r\n'));
    for (var i = 0; i < 6; i++) {
      final reply = await _reply(timeout: const Duration(seconds: 5));
      if (reply.code == 200) return;
    }
    throw const SocketException('FTP: no answer after ABOR');
  }

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

// --- SMB ---

/// Windows file sharing (SMB 1, 2.0 and 2.1; also Samba) over
/// package:smb_connect. "/" lists the server's shares (without the
/// administrative ones like "C$"), below that the path is share + folder:
/// "/Daten/Fotos" is the folder "Fotos" in the share "Daten". Hidden
/// entries (desktop.ini, $RECYCLE.BIN, ...) are left out. One connection,
/// kept open between calls until [close]; calls run one after the other.
/// The port is always 445 (the package has no other).
class SmbClient implements NasClient {
  SmbClient(this.config);

  final NasConfig config;
  SmbConnect? _connection;
  bool _broken = false;
  Future<void> _queue = Future.value();

  /// After [close], calls still waiting don't open a new connection.
  bool _closed = false;

  static const port = 445;

  /// Bytes per read/write request (a request must fit into 64 KiB).
  static const _chunk = 60 * 1024;

  /// The package gives up on an unanswered request after 5 × 3 s by
  /// itself - this only stops transfers that drag on.
  static const _smbTransferTimeout = Duration(minutes: 5);

  Future<SmbConnect> _open() async {
    _broken = false;
    return _connect(() => _broken = true);
  }

  Future<SmbConnect> _connect(void Function() onDisconnect) async {
    final host = config.host.trim();
    // The package swallows the reason of a failed connection - this tells
    // "not found / refused / no answer" apart first.
    final probe = await Socket.connect(host, port, timeout: _timeout);
    probe.destroy();
    return SmbConnect.connectAuth(
      host: host,
      username: config.user.trim(),
      password: config.password,
      domain: config.domain.trim(),
      onDisconnect: (_) => onDisconnect(),
    );
  }

  /// The second connection, for [openRead]'s streams (the package sends
  /// one request at a time per connection - a running film doesn't hold up
  /// the listings).
  Future<SmbConnect>? _streamConnection;
  bool _streamBroken = false;

  Future<SmbConnect> _streams() {
    if (_streamBroken) _dropStreams();
    return _streamConnection ??= () {
      _streamBroken = false;
      return _connect(() => _streamBroken = true);
    }();
  }

  void _dropStreams() {
    final connection = _streamConnection;
    _streamConnection = null;
    if (connection != null) unawaited(connection.then((c) => c.close()).catchError((_) {}));
  }

  void _drop() {
    final connection = _connection;
    _connection = null;
    if (connection != null) unawaited(connection.close().catchError((_) {}));
  }

  /// Runs [action] after the previous call and turns errors into
  /// [NasException]s; a broken connection is dropped (the server's answers
  /// like "not found" keep it).
  Future<T> _run<T>(Future<T> Function(SmbConnect c) action, {Duration timeout = _timeout}) {
    final result = _queue.then((_) async {
      if (_closed) throw const NasException(_closedMessage);
      try {
        if (_broken) _drop();
        return await () async {
          final connection = _connection ??= await _open();
          return action(connection);
        }()
            .timeout(timeout);
      } catch (e) {
        if (!isSmbServerAnswer(e)) _drop();
        throw describeSmbError(e);
      }
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// The package's path of [path] in a share; throws for "/" (no share).
  static String _inShare(String path) {
    final location = splitSmbPath(path);
    if (location.share == null || location.path == '/') throw NasException(l10n.nasErrorNotFound);
    return '/${location.share}${location.path}';
  }

  @override
  Future<void> test() => _run((c) async {
        await c.listShares();
      });

  @override
  Future<List<NasEntry>> list(String folder) => _run((c) async {
        final location = splitSmbPath(folder);
        final share = location.share;
        if (share == null) return smbShareEntries([for (final s in await c.listShares()) s.name]);
        final path = '/$share${location.path == '/' ? '' : location.path}';
        final dir = await c.file(path);
        if (!dir.isExists || !dir.isDirectory()) throw NasException(l10n.nasErrorNotFound);
        final base = normalizeNasPath(folder);
        return _sorted([
          for (final f in await c.listFiles(dir))
            if (!f.isHidden() && f.name.isNotEmpty && f.name != '.' && f.name != '..')
              NasEntry(
                name: f.name,
                path: joinNasPath(base, f.name),
                isDirectory: f.isDirectory(),
                size: f.isDirectory() ? null : f.size,
                modified: f.lastModified > 0 ? DateTime.fromMillisecondsSinceEpoch(f.lastModified, isUtc: true) : null,
              ),
        ]);
      });

  @override
  Future<Uint8List> read(String path, {int? maxBytes}) => _run((c) async {
        final file = await c.file(_inShare(path));
        if (!file.isExists || file.isDirectory()) throw NasException(l10n.nasErrorNotFound);
        if (maxBytes != null && file.size > maxBytes) throw NasException(l10n.nasErrorTooBig);
        if (file.size <= 0) return Uint8List(0);
        final raf = await c.open(file);
        try {
          final builder = BytesBuilder(copy: false);
          while (builder.length < file.size) {
            builder.add(await raf.read(min(_chunk, file.size - builder.length)));
          }
          return builder.takeBytes();
        } finally {
          await raf.close();
        }
      }, timeout: _smbTransferTimeout);

  /// Replaces the file if it exists (the package can't truncate - the old
  /// one is deleted first).
  @override
  Future<void> write(String path, List<int> bytes) => _run((c) async {
        final target = _inShare(path);
        final existing = await c.file(target);
        if (existing.isExists) {
          if (existing.isDirectory()) throw NasException(l10n.nasErrorIsFolder);
          await c.delete(existing);
        }
        final file = await c.createFile(target);
        // The folder above doesn't exist.
        if (!file.isExists) throw NasException(l10n.nasErrorNotFound);
        if (bytes.isEmpty) return;
        final raf = await c.open(file, mode: FileMode.write);
        try {
          for (var offset = 0; offset < bytes.length; offset += _chunk) {
            // writeFrom doesn't move the position by itself.
            await raf.setPosition(offset);
            await raf.writeFrom(bytes, offset, min(offset + _chunk, bytes.length));
          }
        } finally {
          await raf.close();
        }
      }, timeout: _smbTransferTimeout);

  /// Files only - the package would delete a folder with all its content.
  @override
  Future<void> delete(String path) => _run((c) async {
        final file = await c.file(_inShare(path));
        if (!file.isExists) return;
        if (file.isDirectory()) throw NasException(l10n.nasErrorIsFolder);
        await c.delete(file);
      });

  @override
  Future<int?> size(String path) => _run((c) async {
        final file = await c.file(_inShare(path));
        if (!file.isExists || file.isDirectory()) throw NasException(l10n.nasErrorNotFound);
        return file.size;
      });

  /// Reads of [_chunk] bytes from the given place, on the second connection.
  @override
  Stream<List<int>> openRead(String path, {int offset = 0, int? length}) async* {
    if (length != null && length <= 0) return;
    if (_closed) throw const NasException(_closedMessage);
    RandomAccessFile? raf;
    try {
      final int end;
      try {
        final c = await _streams().timeout(_timeout);
        final file = await c.file(_inShare(path)).timeout(_timeout);
        if (!file.isExists || file.isDirectory()) throw NasException(l10n.nasErrorNotFound);
        end = length == null ? file.size : min(file.size, offset + length);
        if (offset >= end) return;
        raf = await c.open(file).timeout(_timeout);
        await raf.setPosition(offset);
      } catch (e) {
        if (!isSmbServerAnswer(e)) _dropStreams();
        throw describeSmbError(e);
      }
      var position = offset;
      while (position < end) {
        final Uint8List chunk;
        try {
          chunk = await raf.read(min(_chunk, end - position)).timeout(_timeout);
        } catch (e) {
          if (!isSmbServerAnswer(e)) _dropStreams();
          throw describeSmbError(e);
        }
        if (chunk.isEmpty) return;
        position += chunk.length;
        yield chunk;
      }
    } finally {
      final open = raf;
      if (open != null) unawaited(open.close().catchError((_) {}));
    }
  }

  @override
  void close() {
    _closed = true;
    // After a running call (closing under it would break it).
    _queue = _queue.then((_) => _drop());
    _dropStreams();
  }
}

/// The share and the path inside it of [path]: "/Daten/Fotos/2026" is
/// share "Daten", path "/Fotos/2026"; "/Daten" is the share's top
/// ("/"); "/" is the server itself (share null).
({String? share, String path}) splitSmbPath(String path) {
  final parts = normalizeNasPath(path).split('/').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return (share: null, path: '/');
  return (share: parts.first, path: '/${parts.skip(1).join('/')}');
}

/// Shares worth showing - not the administrative/hidden ones ending with
/// "$" (C$, ADMIN$, IPC$, print$).
bool isVisibleSmbShare(String name) => name.trim().isNotEmpty && !name.endsWith(r'$');

/// The server's top level: its visible shares as folders, sorted.
List<NasEntry> smbShareEntries(Iterable<String> shares) => _sorted([
      for (final name in shares.toSet())
        if (isVisibleSmbShare(name)) NasEntry(name: name, path: '/$name', isDirectory: true),
    ]);

/// The text of an error from package:smb_connect - it throws strings,
/// [Error]s with a message, and Exceptions.
String smbErrorText(Object e) {
  if (e is String) return e;
  if (e is Error) {
    try {
      final message = (e as dynamic).message;
      if (message is String) return message;
    } catch (_) {}
  }
  return '$e';
}

/// Whether [e] is the server's answer to a request (login refused, file
/// not found ...) - the connection itself is fine then.
bool isSmbServerAnswer(Object e) => e is NasException || e is String;

/// Turns errors of package:smb_connect into readable messages. Its errors
/// carry Windows' status texts (see its NtStatus), sometimes inside a
/// longer text ("Can't delete /a/b: Access is denied.").
NasException describeSmbError(Object e) {
  if (e is NasException) return e;
  if (e is TimeoutException || e is SocketException) return _describe(e);
  final text = smbErrorText(e);
  bool has(List<String> parts) => parts.any(text.contains);
  if (has(const [
    'Logon failure',
    'The specified network password is not correct',
    'The specified user does not exist',
    'currently locked out',
    'must change his password',
    'Access is denied',
    'Access denied',
    'Network access is denied',
  ])) {
    return NasException(l10n.nasErrorLogin);
  }
  if (has(const [
    'cannot find the file',
    'cannot find the path',
    'network name cannot be found',
    'network name is no longer available',
    'The directory name is invalid',
    'The specified path is invalid',
    "Can't open file",
  ])) {
    return NasException(l10n.nasErrorNotFound);
  }
  if (text.contains('The file system is full')) return NasException(l10n.nasErrorFull);
  // TCP to port 445 worked (see SmbClient._open), but no SMB dialect fits.
  if (text.startsWith("Can't connect to") || text.contains('not compatible with the server')) {
    return NasException(l10n.nasErrorSmbConnect);
  }
  return NasException(l10n.nasErrorSmb(text));
}