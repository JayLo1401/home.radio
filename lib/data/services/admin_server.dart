import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel, rootBundle;

import '../../l10n/l10n.dart';
import 'backup_service.dart';
import 'nas_service.dart';

/// Called with a backup chosen on the admin page and what to take over from
/// it, while the restore screen is open. Throws [BackupFormatException] if
/// the file isn't a usable backup.
typedef WebRestoreHandler = Future<void> Function(String content, BackupRestoreSelection selection);

/// The backups in the NAS backup folder for the admin page's restore:
/// [list] newest first, null if no backup folder is set (throws
/// [NasException]); [read] one of them.
typedef AdminNasBackupHooks = ({
  Future<List<NasEntry>?> Function() list,
  Future<String> Function(NasEntry file) read,
});

/// How a change or an action on the admin page went; [message] null: the
/// page says "saved".
typedef AdminResult = ({bool ok, String? message});

/// The settings the admin page can change (see AdminSettings).
abstract interface class AdminSettingsSource {
  /// `{areas: [{id, logo, title, subtitle, enabled}], groups: [{area,
  /// title, help, items: [{id, label, type, value, ...}]}]}` - the areas
  /// and headings of the device's own settings.
  Future<Map<String, Object?>> describe();

  /// Sets [id] to [value], or runs the action [id].
  Future<AdminResult> apply(String id, Object? value);

  /// The subfolders of [path] on the NAS for the folder setting [id]:
  /// `{path, parent, folders: [{name, path}], files}` or `{error}`.
  Future<Map<String, Object?>> browse(String id, String path);
}

/// The app logos the page shows (`assets/icon/<name>.png`).
const _logos = {
  'home_system_logo',
  'radio_logo',
  'tv_logo',
  'dashboard_logo',
  'pictures_logo',
  'music_logo',
  'movies_logo',
  'browser_logo',
};

/// The Haussteuerung's display, for Home Assistant (see DisplayService).
typedef AdminDisplayHooks = ({
  Future<bool> Function() on,
  Future<bool> Function() off,
  void Function() reload,
  bool Function() available,
});

/// The device's admin page, `http://<ip>:1401/` in the home network:
/// create and download a backup at any time; restore one (uploaded or from
/// the NAS backup folder, [nasBackups]) only while the device shows "Backup
/// wiederherstellen" ([restoreHandler] is set) - from the setup wizard or
/// Settings → System: the page first shows what the backup contains, per
/// area (see BackupArea), and only the ticked areas are applied. Change
/// settings ([settings]), and
/// for the Haussteuerung switch the display (`POST /api/display/on|off`,
/// `/api/dashboard/reload` - e.g. Home Assistant's rest_command).
class AdminServer {
  AdminServer({required this.backup, required this.deviceName, required this.version, this.bindPort = port});

  static const port = 1401;
  static const _maxUpload = 32 * 1024 * 1024;

  final BackupService backup;

  /// [port]; tests take 0 (any free one, see [boundPort]).
  final int bindPort;
  final Future<String> Function() deviceName;
  final Future<String> Function() version;

  HttpServer? _server;
  bool _stopped = false;

  /// Set by the restore screen while it is open.
  WebRestoreHandler? restoreHandler;

  /// Set by the app once it runs (app.dart).
  AdminSettingsSource? settings;
  AdminDisplayHooks? display;
  AdminNasBackupHooks? nasBackups;

  /// The backup read for the selection (uploaded or from the NAS) until
  /// it's applied - one at a time, [token] ties the selection to it.
  ({String token, String content, DateTime at})? _pending;
  static const _pendingFor = Duration(minutes: 30);

  bool get running => _server != null;

  /// The port it listens on (null while not running).
  int? get boundPort => _server?.port;

  /// Binds the port; retried for a while if it's still taken (a restart
  /// on the PC starts the new instance before the old one has quit).
  Future<void> start() async {
    for (var attempt = 0; attempt < 12 && !_stopped; attempt++) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, bindPort);
        if (_stopped) {
          await server.close(force: true);
          return;
        }
        _server = server;
        server.listen(_handle, onError: (Object e) => debugPrint('AdminServer: $e'));
        return;
      } on SocketException catch (e) {
        debugPrint('AdminServer: port $port not free ($e)');
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }

  Future<void> stop() async {
    _stopped = true;
    await _server?.close(force: true);
    _server = null;
  }

  /// The device's addresses in the home network, for `http://<ip>:1401/`.
  static Future<List<String>> addresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final virtual = RegExp('vmware|virtualbox|vbox|hyper-v|vethernet|docker|wsl|tap|tun', caseSensitive: false);
      interfaces.sort((a, b) => (virtual.hasMatch(a.name) ? 1 : 0).compareTo(virtual.hasMatch(b.name) ? 1 : 0));
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.isLinkLocal) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// "http://192.168.1.20:1401/" - the first address, or null without network.
  static Future<String?> url() async {
    final list = await addresses();
    return list.isEmpty ? null : 'http://${list.first}:$port/';
  }

  static ({String? dns, String? name, DateTime at})? _hostCache;

  /// [dns]: the device's name in the home network's DNS - what the router
  /// has for its address (e.g. "MiTV-AFMU0.fritz.box"), usable in a link;
  /// null if the router names nothing. [name]: what the admin page shows as
  /// host name - [dns], else on Android the device's name from its settings
  /// ("Jürgens FireTVStick" - Android itself is just "localhost"), on the PC
  /// the computer's name.
  static Future<({String? dns, String? name})> _host() async {
    final cached = _hostCache;
    if (cached != null && DateTime.now().difference(cached.at) < const Duration(minutes: 5)) {
      return (dns: cached.dns, name: cached.name);
    }
    final ip = (await addresses()).firstOrNull;
    String? dns;
    if (ip != null) {
      try {
        final host = (await InternetAddress(ip).reverse().timeout(const Duration(seconds: 3))).host;
        if (host != ip && host.toLowerCase() != 'localhost') dns = host;
      } catch (_) {}
    }
    String? name = dns;
    if (name == null && Platform.isAndroid) {
      try {
        name = await const MethodChannel('home_system/launcher').invokeMethod<String>('deviceName');
      } catch (_) {}
    } else if (name == null) {
      final local = Platform.localHostname;
      if (local.isNotEmpty && local.toLowerCase() != 'localhost') name = local;
    }
    _hostCache = (dns: dns, name: name, at: DateTime.now());
    return (dns: dns, name: name);
  }

  /// The host name shown on the admin page (see [_host]), null if none.
  static Future<String?> hostname() async => (await _host()).name;

  /// The admin page's addresses: by IP and, if the network's DNS knows the
  /// device, by host name - e.g. ["http://192.168.1.20:1401/",
  /// "http://mitv.fritz.box:1401/"].
  static Future<List<String>> urls() async {
    final ips = await addresses();
    final dns = (await _host()).dns;
    return [if (ips.isNotEmpty) 'http://${ips.first}:$port/', if (dns != null) 'http://$dns:$port/'];
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      final path = request.uri.path;
      switch ((request.method, path)) {
        case ('GET', '/'):
          response.headers.contentType = ContentType.html;
          response.write(_page(await deviceName(), await version(), await hostname(), await addresses()));
        case ('GET', '/api/status'):
          _json(response, {
            'name': await deviceName(),
            'version': await version(),
            'hostname': await hostname(),
            'addresses': await addresses(),
            'restore': restoreHandler != null,
            'display': display?.available() ?? false,
          });
        case ('GET', '/api/settings'):
          _json(response, await settings?.describe() ?? const {'areas': [], 'groups': []});
        case ('GET', '/api/browse'):
          final q = request.uri.queryParameters;
          final source = settings;
          _json(
            response,
            source == null ? {'error': l10n.adminUnknownSetting} : await source.browse(q['id'] ?? '', q['path'] ?? '/'),
          );
        case ('GET', final logo) when logo.startsWith('/logo/') && logo.endsWith('.png'):
          final name = logo.substring(6, logo.length - 4);
          if (!_logos.contains(name)) {
            response.statusCode = HttpStatus.notFound;
            break;
          }
          final bytes = await rootBundle.load('assets/icon/$name.png');
          response.headers
            ..contentType = ContentType('image', 'png')
            ..set('Cache-Control', 'max-age=86400');
          response.add(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
        case ('POST', '/api/settings'):
          await _setSetting(request);
        case ('POST', '/api/display/on'):
          _json(response, {'ok': await _displayAction((d) => d.on())});
        case ('POST', '/api/display/off'):
          _json(response, {'ok': await _displayAction((d) => d.off())});
        case ('POST', '/api/dashboard/reload'):
          _json(response, {
            'ok': await _displayAction((d) async {
              d.reload();
              return true;
            }),
          });
        case ('GET', '/backup'):
          final (:name, :content) = await backup.export();
          response.headers.contentType = ContentType.json;
          response.headers.set('Content-Disposition', 'attachment; filename="$name"');
          response.write(content);
        case ('POST', '/api/restore/inspect'):
          await _inspectUpload(request);
        case ('GET', '/api/restore/nas'):
          await _listNasBackups(response);
        case ('POST', '/api/restore/inspect-nas'):
          await _inspectNas(request);
        case ('POST', '/api/restore/apply'):
          await _applyRestore(request);
        default:
          response.statusCode = HttpStatus.notFound;
          response.write(l10n.adminNotFound);
      }
    } catch (e) {
      debugPrint('AdminServer: $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.write(l10n.commonError('$e'));
      } catch (_) {}
    } finally {
      await response.close();
    }
  }

  Future<bool> _displayAction(Future<bool> Function(AdminDisplayHooks d) action) async {
    final d = display;
    if (d == null || !d.available()) return false;
    return action(d);
  }

  Future<void> _setSetting(HttpRequest request) async {
    final response = request.response;
    final source = settings;
    Object? body;
    try {
      body = jsonDecode(await utf8.decodeStream(request));
    } on FormatException {
      body = null;
    }
    if (source == null || body is! Map || body['id'] is! String) {
      response.statusCode = HttpStatus.badRequest;
      _json(response, {'ok': false, 'message': l10n.adminInvalidValue});
      return;
    }
    final AdminResult result;
    try {
      result = await source.apply(body['id'] as String, body['value']);
    } catch (e) {
      debugPrint('AdminServer: ${body['id']}: $e');
      _json(response, {'ok': false, 'message': l10n.commonError('$e')});
      return;
    }
    _json(response, {'ok': result.ok, 'message': result.message ?? (result.ok ? l10n.adminSaved : l10n.adminInvalidValue)});
  }

  // ---- restore: read a backup, show what's in it, apply the selection ----

  /// Refuses (403) unless the device shows "Backup wiederherstellen".
  bool _restoreLocked(HttpResponse response) {
    if (restoreHandler != null) return false;
    response.statusCode = HttpStatus.forbidden;
    _json(response, {'ok': false, 'message': l10n.adminRestoreLocked});
    return true;
  }

  static Future<Object?> _jsonBody(HttpRequest request) async {
    try {
      return jsonDecode(await utf8.decodeStream(request));
    } on FormatException {
      return null;
    }
  }

  /// An uploaded backup file: checked and kept for the selection.
  Future<void> _inspectUpload(HttpRequest request) async {
    final response = request.response;
    if (_restoreLocked(response)) return;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > _maxUpload) {
        response.statusCode = HttpStatus.requestEntityTooLarge;
        _json(response, {'ok': false, 'message': l10n.adminFileTooBig});
        return;
      }
    }
    final String content;
    try {
      content = utf8.decode(bytes.takeBytes());
    } on FormatException {
      response.statusCode = HttpStatus.badRequest;
      _json(response, {'ok': false, 'message': l10n.adminFileInvalid});
      return;
    }
    await _preview(response, content);
  }

  /// `{ok, folder, files: [{name, modified}]}` - the NAS backup folder's
  /// backups; folder false if none is set.
  Future<void> _listNasBackups(HttpResponse response) async {
    if (_restoreLocked(response)) return;
    final hooks = nasBackups;
    try {
      final files = hooks == null ? null : await hooks.list().timeout(const Duration(seconds: 30));
      _json(response, {
        'ok': true,
        'folder': files != null,
        'files': [
          for (final f in files ?? const <NasEntry>[]) {'name': f.name, 'modified': f.modified?.toIso8601String()},
        ],
      });
    } catch (e) {
      final message = switch (e) {
        NasException() => e.message,
        TimeoutException() => l10n.nasErrorTimeout,
        _ => '$e',
      };
      _json(response, {'ok': false, 'message': l10n.nasRestoreLoadFailed(message)});
    }
  }

  /// A backup from the NAS backup folder (`{name}`): loaded, checked and
  /// kept for the selection. Only names in the folder's list are read.
  Future<void> _inspectNas(HttpRequest request) async {
    final response = request.response;
    if (_restoreLocked(response)) return;
    final body = await _jsonBody(request);
    final name = body is Map ? body['name'] : null;
    final hooks = nasBackups;
    if (name is! String || hooks == null) {
      response.statusCode = HttpStatus.badRequest;
      _json(response, {'ok': false, 'message': l10n.adminInvalidValue});
      return;
    }
    final String content;
    try {
      final file = (await hooks.list().timeout(const Duration(seconds: 30)) ?? const <NasEntry>[])
          .where((f) => f.name == name)
          .firstOrNull;
      if (file == null) {
        _json(response, {'ok': false, 'message': l10n.nasRestoreDownloadFailed(l10n.adminNotFound)});
        return;
      }
      content = await hooks.read(file).timeout(const Duration(minutes: 2));
    } catch (e) {
      final message = switch (e) {
        NasException() => e.message,
        TimeoutException() => l10n.nasErrorTimeout,
        _ => '$e',
      };
      _json(response, {'ok': false, 'message': l10n.nasRestoreDownloadFailed(message)});
      return;
    }
    await _preview(response, content);
  }

  /// Checks [content] and answers with what it contains - `{ok, token,
  /// deviceName, currentName, createdAt, areas: [{id, title, summary}]}`;
  /// the backup is kept until it's applied or another one is read.
  Future<void> _preview(HttpResponse response, String content) async {
    final BackupPreview preview;
    try {
      preview = backup.inspect(content);
    } on BackupFormatException catch (e) {
      response.statusCode = HttpStatus.badRequest;
      _json(response, {'ok': false, 'message': e.message});
      return;
    }
    final l = l10n;
    final random = Random.secure();
    final token = [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    _pending = (token: token, content: content, at: DateTime.now());
    _json(response, {
      'ok': true,
      'token': token,
      'deviceName': preview.deviceName,
      'currentName': await deviceName(),
      'createdAt': preview.createdAt?.toIso8601String(),
      'areas': [
        for (final a in preview.areas) {'id': a.name, 'title': backupAreaTitle(l, a), 'summary': backupAreaSummary(l, a, preview)},
      ],
    });
  }

  /// `{token, areas: [id, ...], deviceName}`: restores the chosen areas of
  /// the backup read before, through the restore screen.
  Future<void> _applyRestore(HttpRequest request) async {
    final response = request.response;
    if (_restoreLocked(response)) return;
    final handler = restoreHandler!;
    final body = await _jsonBody(request);
    if (body is! Map || body['token'] is! String || body['areas'] is! List) {
      response.statusCode = HttpStatus.badRequest;
      _json(response, {'ok': false, 'message': l10n.adminInvalidValue});
      return;
    }
    final pending = _pending;
    if (pending == null || pending.token != body['token'] || DateTime.now().difference(pending.at) > _pendingFor) {
      _json(response, {'ok': false, 'message': l10n.backupExpired});
      return;
    }
    final areas = <BackupArea>{
      for (final id in body['areas'] as List)
        if (id is String) ?BackupArea.byName(id),
    };
    final name = body['deviceName'] is String ? (body['deviceName'] as String).trim() : '';
    if (areas.isEmpty && (name.isEmpty || name == (await deviceName()).trim())) {
      _json(response, {'ok': false, 'message': l10n.backupNothingSelected});
      return;
    }
    try {
      await handler(pending.content, BackupRestoreSelection(areas: areas, deviceName: name));
      _pending = null;
      _json(response, {'ok': true, 'message': l10n.adminRestored});
    } on BackupFormatException catch (e) {
      response.statusCode = HttpStatus.badRequest;
      _json(response, {'ok': false, 'message': e.message});
    } catch (e) {
      debugPrint('AdminServer: restore: $e');
      _json(response, {'ok': false, 'message': l10n.commonError('$e')});
    }
  }

  static void _json(HttpResponse response, Map<String, Object?> data) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
  }

  static String _escape(String s) => const HtmlEscape().convert(s);

  static String _page(String name, String version, String? hostname, List<String> addresses) {
    final l = l10n;
    String e(String s) => _escape(s);
    final title = name.isEmpty ? 'Home System' : '${e(name)} · Home System';
    final host = hostname == null ? '–' : e(hostname);
    final ips = addresses.isEmpty ? '–' : e(addresses.join(', '));
    // Texts the script needs, in the app's language.
    final t = jsonEncode({
      'saved': l.adminSaved,
      'offline': l.adminOffline,
      'restoring': l.adminRestoring,
      'reading': l.backupReading,
      'created': l.backupSelectCreated('%DATE%'),
      'nameHelp': l.backupDeviceNameHelp('%NAME%'),
      'nameHelpNone': l.backupDeviceNameHelpNone,
      'nothingSelected': l.backupNothingSelected,
      'nothingInside': l.backupNothingInside,
      'nasNone': l.nasRestoreNone,
      'unchanged': l.adminSecretPlaceholder,
      'settings': l.systemTileSettingsShort,
      'notChosen': l.nasFolderNotChosen,
      'clear': l.nasFolderClear,
      'up': l.nasUp,
      'choose': l.nasChooseThisFolder,
      'noSubfolders': l.nasNoSubfolders,
      'browseTitle': l.nasBrowseTitle('%FOLDER%'),
      'close': l.adminClose,
      'areaOff': l.settingsAreaOff,
      'deviceOnly': l.adminDeviceOnly,
      'restoreOpen': l.adminRestoreOpenBanner,
    }).replaceAll('</', r'<\/');
    return '''<!doctype html>
<html lang="${l.localeName}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<link rel="icon" href="/logo/home_system_logo.png">
<style>
  /* The app's look: black, the seeded green of the TV theme, the focus ring
     with its glow, list rows like the device's settings pages. */
  :root { color-scheme: dark; --primary: #8bd6a1; --brand: #2f9e5c; --bg: #000; --bar: #111813; --line: #1e2a22;
    --muted: rgba(255,255,255,.6); --faint: rgba(255,255,255,.38); --field: #0d130f; --warn: #ffb74d; }
  * { box-sizing: border-box; }
  [hidden] { display: none !important; }
  body { margin: 0; background: var(--bg); color: #fff; font: 16px/1.45 Roboto, system-ui, -apple-system, "Segoe UI", sans-serif; }
  .bar { position: sticky; top: 0; z-index: 5; display: flex; align-items: center; gap: 8px; min-height: 64px; padding: 0 12px;
    background: var(--bar); }
  .bar h1 { margin: 0 0 0 8px; font-size: 22px; font-weight: 400; flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .bar .who { color: var(--muted); font-size: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 40%; }
  .icon-btn { width: 44px; height: 44px; border-radius: 50%; border: 2px solid transparent; background: none; color: #fff;
    font-size: 24px; line-height: 1; cursor: pointer; display: grid; place-items: center; }
  .icon-btn:hover { background: rgba(255,255,255,.08); }
  .icon-btn:focus-visible { outline: none; border-color: var(--primary); }
  main { max-width: 1100px; margin: 0 auto; padding: 24px 24px 48px; }
  .device { font-size: 28px; font-weight: 700; margin: 0 0 2px; }
  .muted { color: var(--muted); font-size: 14px; margin: 0; }
  .facts { display: grid; grid-template-columns: max-content 1fr; gap: 2px 16px; margin: 12px 0 20px; font-size: 15px; }
  .facts dt { color: var(--muted); }
  .facts dd { margin: 0; font-family: ui-monospace, Consolas, monospace; word-break: break-all; }
  /* Overview: one tile per area, as on the device's first settings page. */
  .area { display: flex; align-items: center; gap: 18px; width: 100%; margin: 0 0 12px; padding: 14px; border-radius: 12px;
    border: 3px solid transparent; background: none; color: inherit; text-align: left; font: inherit; cursor: pointer; transition: background .12s, box-shadow .12s; }
  .area img { width: 64px; height: 64px; border-radius: 14px; flex: none; }
  .area .t { font-size: 22px; font-weight: 700; display: block; }
  .area .s { color: var(--muted); font-size: 15px; display: block; margin-top: 2px; }
  .area .chev { margin-left: auto; color: var(--faint); font-size: 26px; }
  .area:hover, .area:focus-visible { outline: none; border-color: var(--primary); background: rgba(139,214,161,.28);
    box-shadow: 0 0 12px rgba(139,214,161,.5); }
  .area.off { opacity: .4; }
  .banner { display: block; margin: 0 0 16px; padding: 14px 16px; border-radius: 12px; background: rgba(139,214,161,.15);
    border: 2px solid var(--primary); color: #fff; text-decoration: none; font-weight: 600; }
  /* An area's page: headings and rows like ListTiles. */
  h2 { font-size: 22px; font-weight: 400; margin: 28px 0 4px; }
  h2:first-child { margin-top: 0; }
  .ghelp { color: var(--muted); font-size: 14px; margin: 0 0 6px; }
  .row { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 2px 24px; align-items: center;
    padding: 12px 16px; border-radius: 10px; border: 2px solid transparent; }
  .row:focus-within { border-color: rgba(139,214,161,.6); background: rgba(139,214,161,.07); }
  .row label, .row .label { font-size: 17px; }
  .row .help { color: var(--muted); font-size: 14px; }
  .row .left { display: flex; flex-direction: column; min-width: 0; }
  .row .right { display: flex; justify-content: flex-end; align-items: center; gap: 8px; min-width: 0; }
  .row .state { grid-column: 1 / -1; font-size: 14px; min-height: 0; font-weight: 600; }
  .row.info { grid-template-columns: minmax(0, 1fr); }
  .row.info .lines { color: var(--muted); font-size: 15px; }
  .row.info .lines div + div { margin-top: 2px; }
  .row.wide .right { justify-content: stretch; }
  input[type=text], input[type=number], input[type=password], select {
    width: 100%; max-width: 100%; min-width: 0; padding: 10px 12px; border-radius: 8px; border: 1px solid #33413a; background: var(--field); color: #fff; font: inherit; }
  input:focus, select:focus { outline: none; border-color: var(--primary); box-shadow: 0 0 0 1px var(--primary); }
  /* Material switch. */
  .switch { position: relative; width: 52px; height: 32px; flex: none; }
  .switch input { opacity: 0; width: 100%; height: 100%; margin: 0; position: absolute; cursor: pointer; z-index: 1; }
  .switch span { position: absolute; inset: 0; border-radius: 16px; background: #1b231e; border: 2px solid #8a948d; transition: .15s; }
  .switch span::after { content: ""; position: absolute; top: 6px; left: 6px; width: 16px; height: 16px; border-radius: 50%; background: #8a948d; transition: .15s; }
  .switch input:checked + span { background: var(--primary); border-color: var(--primary); }
  .switch input:checked + span::after { left: 22px; top: 2px; width: 24px; height: 24px; background: #003919; }
  .switch input:focus-visible + span { box-shadow: 0 0 0 3px rgba(139,214,161,.5); }
  .btn { display: inline-block; padding: 10px 22px; border-radius: 22px; border: 3px solid transparent; background: var(--primary);
    color: #003919; font: inherit; font-weight: 600; text-decoration: none; cursor: pointer; white-space: nowrap; }
  .btn.alt { background: none; color: var(--primary); border-color: #4b5a51; }
  .btn:hover { filter: brightness(1.1); }
  .btn:focus-visible { outline: none; border-color: #fff; }
  .btn.alt:focus-visible { border-color: var(--primary); }
  .btn[disabled] { opacity: .45; cursor: default; }
  .path { font-family: ui-monospace, Consolas, monospace; font-size: 14px; color: var(--muted); word-break: break-all; }
  input[type=file] { display: block; margin-top: 12px; color: var(--muted); max-width: 100%; }
  .msg { margin-top: 12px; font-weight: 600; }
  .ok { color: var(--primary); }
  .err { color: var(--warn); }
  .block { padding: 12px 16px; }
  h3.sub { font-size: 18px; font-weight: 600; margin: 22px 0 6px; }
  /* Restore: the areas to take over. */
  .row.check { cursor: pointer; }
  input[type=checkbox] { width: 24px; height: 24px; margin: 0; accent-color: var(--primary); cursor: pointer; flex: none; }
  input[type=checkbox]:focus-visible { outline: 3px solid var(--primary); outline-offset: 3px; }
  .actions { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 16px; }
  .note { color: var(--faint); font-size: 14px; margin-top: 28px; }
  /* Folder browser (like the device's: up, subfolders, choose). */
  dialog { width: min(560px, calc(100% - 32px)); max-height: 80vh; padding: 0; border: 0; border-radius: 24px; background: #1a211c; color: #fff; }
  dialog::backdrop { background: rgba(0,0,0,.6); }
  dialog header { padding: 20px 24px 8px; }
  dialog header h3 { margin: 0; font-size: 22px; font-weight: 400; }
  dialog .list { max-height: 50vh; overflow: auto; padding: 0 12px; }
  .item { display: flex; gap: 14px; align-items: center; width: 100%; padding: 12px; border-radius: 10px; border: 2px solid transparent;
    background: none; color: #fff; font: inherit; text-align: left; cursor: pointer; }
  .item:hover, .item:focus-visible { outline: none; border-color: var(--primary); background: rgba(139,214,161,.15); }
  dialog footer { display: flex; justify-content: flex-end; gap: 8px; padding: 12px 24px 20px; flex-wrap: wrap; }
  footer.page { text-align: center; color: var(--muted); font-size: 13px; margin-top: 40px; }
  footer.page .by { color: var(--brand); font-weight: 600; }
  @media (max-width: 640px) {
    main { padding: 16px 16px 40px; }
    .row { grid-template-columns: minmax(0, 1fr); padding: 12px 8px; }
    .facts { grid-template-columns: minmax(0, max-content) minmax(0, 1fr); }
    .row .right { justify-content: flex-start; }
    .area { gap: 14px; padding: 10px; } .area img { width: 52px; height: 52px; } .area .t { font-size: 19px; }
  }
</style>
</head>
<body>
<div class="bar">
  <button class="icon-btn" id="back" title="${e(l.adminBack)}" aria-label="${e(l.adminBack)}" hidden>&#8592;</button>
  <h1 id="title">${e(l.systemTileSettingsShort)}</h1>
  <span class="who" id="who">${name.isEmpty ? 'Home System' : e(name)}</span>
</div>
<main>
  <div id="overview">
    <p class="device" id="name">${name.isEmpty ? 'Home System' : e(name)}</p>
    <p class="muted">${e(l.adminSubtitle)}</p>
    <dl class="facts">
      <dt>${e(l.adminHostname)}</dt><dd id="host">$host</dd>
      <dt>${e(l.adminIpAddress)}</dt><dd id="ips">$ips</dd>
    </dl>
    <a class="banner" id="restoreBanner" href="#system/restore" hidden>${e(l.adminRestoreOpenBanner)}</a>
    <div id="areas"></div>
  </div>
  <div id="page" hidden></div>
  <footer class="page">Home System <span id="version">${e(version)}</span> · <span class="by">Powered by jaycloud.at</span></footer>
</main>

<!-- Pieces placed into an area's page. -->
<div hidden>
  <div id="displayBox">
    <h2>${e(l.adminDisplayHeading)}</h2>
    <p class="ghelp">${e(l.adminDisplayHelp)}</p>
    <div class="block">
      <button class="btn" data-display="/api/display/on">${e(l.adminDisplayOn)}</button>
      <button class="btn alt" data-display="/api/display/off">${e(l.adminDisplayOff)}</button>
      <button class="btn alt" data-display="/api/dashboard/reload">${e(l.adminDashboardReload)}</button>
      <p class="msg" id="displayMsg"></p>
    </div>
  </div>
  <div id="backupBox">
    <h2>${e(l.adminBackupHeading)}</h2>
    <p class="ghelp">${e(l.adminBackupHelp)}</p>
    <div class="block"><a class="btn" href="/backup" download>${e(l.adminBackupDownload)}</a></div>
    <h2 id="restore">${e(l.adminRestoreHeading)}</h2>
    <div class="block">
      <div id="locked"><p class="muted">${e(l.adminRestoreHow)}</p></div>
      <div id="open" hidden>
        <div id="pick">
          <p class="muted">${e(l.backupAdminReady)}</p>
          <input type="file" id="file" accept=".json,application/json">
          <button class="btn" id="send" disabled style="margin-top:12px">${e(l.backupAdminOpen)}</button>
          <div id="nasBox" hidden>
            <h3 class="sub">${e(l.nasRestoreSection)}</h3>
            <div id="nasList"></div>
          </div>
        </div>
        <div id="select" hidden>
          <h3 class="sub">${e(l.backupSelectTitle)}</h3>
          <p class="path" id="selFrom"></p>
          <p class="ghelp">${e(l.backupSelectHint)}</p>
          <div class="row">
            <div class="left"><label class="label" for="selName">${e(l.adminDeviceName)}</label><span class="help" id="selNameHelp"></span></div>
            <div class="right"><input type="text" id="selName" maxlength="60" autocomplete="off"></div>
          </div>
          <h3 class="sub">${e(l.backupSelectAreas)}</h3>
          <div id="selAreas"></div>
          <div class="actions">
            <button class="btn" id="selApply">${e(l.backupApply)}</button>
            <button class="btn alt" id="selCancel">${e(l.commonCancel)}</button>
          </div>
        </div>
      </div>
      <p class="msg" id="msg"></p>
    </div>
  </div>
</div>

<dialog id="browser">
  <header><h3 id="bTitle"></h3><div class="path" id="bPath"></div></header>
  <div class="list" id="bList"></div>
  <p class="msg err block" id="bErr" hidden></p>
  <footer>
    <button class="btn alt" id="bClose"></button>
    <button class="btn" id="bChoose"></button>
  </footer>
</dialog>

<script>
  const T = $t;
  const el = (id) => document.getElementById(id);
  let done = false;
  let editing = false;
  let data = { areas: [], groups: [] };
  let status = {};
  let restoreOpen = false;

  async function loadStatus() {
    if (done) return;
    try {
      status = await (await fetch('/api/status', { cache: 'no-store' })).json();
      if (status.name) { el('name').textContent = status.name; el('who').textContent = status.name; document.title = status.name + ' · Home System'; }
      el('version').textContent = status.version;
      el('host').textContent = status.hostname || '–';
      el('ips').textContent = (status.addresses || []).join(', ') || '–';
      el('open').hidden = !status.restore;
      el('locked').hidden = status.restore;
      el('restoreBanner').hidden = !status.restore;
      if (status.restore && !restoreOpen) loadNasBackups();
      if (!status.restore && restoreOpen) closeSelection();
      restoreOpen = !!status.restore;
      const box = el('displayBox');
      if (box.parentElement && box.parentElement.id === 'page') box.hidden = !status.display;
    } catch (e) { /* device restarting or offline */ }
  }

  // ---- controls ----
  function control(item, state) {
    if (item.type === 'bool') {
      const w = document.createElement('label'); w.className = 'switch';
      const i = document.createElement('input'); i.type = 'checkbox'; i.checked = !!item.value; i.id = 'set-' + item.id;
      i.setAttribute('role', 'switch');
      const s = document.createElement('span'); w.append(i, s);
      i.addEventListener('change', () => save(item, i.checked, state, i));
      return w;
    }
    if (item.type === 'choice') {
      const i = document.createElement('select'); i.id = 'set-' + item.id;
      for (const o of item.options || []) {
        const opt = document.createElement('option'); opt.value = o.value; opt.textContent = o.label;
        if (o.value === item.value) opt.selected = true;
        i.appendChild(opt);
      }
      i.addEventListener('change', () => save(item, i.value, state, i));
      return i;
    }
    if (item.type === 'action') {
      const b = document.createElement('button'); b.className = 'btn alt'; b.textContent = item.button; b.id = 'set-' + item.id;
      b.addEventListener('click', async () => { b.disabled = true; await save(item, null, state, b); b.disabled = false; });
      return b;
    }
    if (item.type === 'folder') {
      const wrap = document.createElement('div'); wrap.className = 'right';
      const browse = document.createElement('button'); browse.className = 'btn alt'; browse.textContent = item.button; browse.id = 'set-' + item.id;
      browse.addEventListener('click', () => openBrowser(item, state));
      wrap.appendChild(browse);
      if (item.value) {
        const clear = document.createElement('button'); clear.className = 'icon-btn'; clear.textContent = '×'; clear.title = T.clear;
        clear.setAttribute('aria-label', T.clear);
        clear.addEventListener('click', () => save(item, '', state, clear));
        wrap.appendChild(clear);
      }
      return wrap;
    }
    const i = document.createElement('input'); i.id = 'set-' + item.id;
    i.type = item.type === 'int' ? 'number' : item.type === 'secret' ? 'password' : 'text';
    if (item.min != null) i.min = item.min;
    if (item.max != null) i.max = item.max;
    i.value = item.value ?? '';
    if (item.type === 'secret') { i.placeholder = T.unchanged; i.autocomplete = 'new-password'; }
    i.addEventListener('focus', () => { editing = true; });
    i.addEventListener('blur', () => { editing = false; });
    i.addEventListener('change', () => save(item, item.type === 'int' ? Number(i.value) : i.value, state, i));
    i.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') i.blur(); });
    return i;
  }

  async function save(item, value, state, i) {
    state.className = 'state'; state.textContent = '…';
    try {
      const r = await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: item.id, value }) });
      const j = await r.json();
      state.className = 'state ' + (j.ok ? 'ok' : 'err');
      state.textContent = j.message;
      if (j.ok && item.type === 'secret') i.value = '';
      if (j.ok && item.type !== 'action') setTimeout(() => { if (state.textContent === j.message) state.textContent = ''; }, 2500);
      // Settings depend on each other (parts on/off, the NAS protocol's fields).
      if (j.ok && item.type !== 'action' && item.type !== 'text' && item.type !== 'secret' && item.type !== 'int') {
        const focus = document.activeElement && document.activeElement.id;
        await loadSettings();
        const again = focus && el(focus);
        if (again) again.focus();
        const s = el('state-' + item.id);
        if (s && j.message) { s.className = 'state ok'; s.textContent = j.message; setTimeout(() => { s.textContent = ''; }, 2500); }
      }
    } catch (e) {
      state.className = 'state err'; state.textContent = T.offline;
    }
  }

  function row(item) {
    const r = document.createElement('div');
    const state = document.createElement('div'); state.className = 'state'; state.id = 'state-' + item.id;
    if (item.type === 'info') {
      r.className = 'row info';
      const t = document.createElement('div'); t.className = 'label'; t.textContent = item.label; r.appendChild(t);
      const lines = document.createElement('div'); lines.className = 'lines';
      for (const line of item.value || []) { const d = document.createElement('div'); d.textContent = line; lines.appendChild(d); }
      r.appendChild(lines);
      return r;
    }
    r.className = 'row';
    const left = document.createElement('div'); left.className = 'left';
    const label = document.createElement(item.type === 'action' || item.type === 'folder' ? 'span' : 'label');
    label.className = 'label'; label.textContent = item.label;
    if (label.tagName === 'LABEL') label.htmlFor = 'set-' + item.id;
    left.appendChild(label);
    const helpText = item.type === 'folder' ? (item.value || T.notChosen) : item.help;
    if (helpText) { const h = document.createElement('span'); h.className = item.type === 'folder' ? 'path' : 'help'; h.textContent = helpText; left.appendChild(h); }
    if (item.type === 'folder' && item.help) { const h = document.createElement('span'); h.className = 'help'; h.textContent = item.help; left.appendChild(h); }
    const right = document.createElement('div'); right.className = 'right';
    const c = control(item, state);
    if (c.className === 'right') r.append(left, c); else { right.appendChild(c); r.append(left, right); }
    r.appendChild(state);
    return r;
  }

  // ---- views ----
  function areaTile(a) {
    const b = document.createElement('button'); b.className = 'area' + (a.enabled ? '' : ' off');
    const img = document.createElement('img'); img.src = '/logo/' + a.logo + '.png'; img.alt = '';
    const text = document.createElement('span');
    const t = document.createElement('span'); t.className = 't'; t.textContent = a.title;
    const s = document.createElement('span'); s.className = 's'; s.textContent = a.subtitle;
    text.append(t, s);
    const chev = document.createElement('span'); chev.className = 'chev'; chev.textContent = '›';
    b.append(img, text, chev);
    b.addEventListener('click', () => { location.hash = a.enabled ? a.id : 'system'; });
    return b;
  }

  function render() {
    const [areaId, anchor] = location.hash.replace(/^#/, '').split('/');
    const area = data.areas.find((a) => a.id === areaId);
    const page = el('page');
    // Bring the pieces home before the page is rebuilt.
    const holder = el('browser').previousElementSibling;
    for (const id of ['displayBox', 'backupBox']) { const b = el(id); if (b.parentElement !== holder) holder.appendChild(b); }
    if (!area) {
      el('overview').hidden = false; page.hidden = true; el('back').hidden = true;
      el('title').textContent = T.settings;
      const box = el('areas'); box.textContent = '';
      for (const a of data.areas) box.appendChild(areaTile(a));
      return;
    }
    el('overview').hidden = true; page.hidden = false; el('back').hidden = false;
    el('title').textContent = area.title;
    page.textContent = '';
    if (!area.enabled) { const p = document.createElement('p'); p.className = 'muted'; p.textContent = T.areaOff; page.appendChild(p); }
    for (const g of data.groups.filter((g) => g.area === area.id)) {
      const h = document.createElement('h2'); h.textContent = g.title; page.appendChild(h);
      if (g.help) { const p = document.createElement('p'); p.className = 'ghelp'; p.textContent = g.help; page.appendChild(p); }
      for (const item of g.items) page.appendChild(row(item));
    }
    if (area.id === 'dashboard') { const b = el('displayBox'); b.hidden = !status.display; page.appendChild(b); }
    if (area.id === 'system') { const b = el('backupBox'); b.hidden = false; page.appendChild(b); }
    const note = document.createElement('p'); note.className = 'note'; note.textContent = T.deviceOnly; page.appendChild(note);
    if (anchor) { const target = el(anchor); if (target) target.scrollIntoView(); }
  }

  async function loadSettings() {
    if (editing) return;
    try { data = await (await fetch('/api/settings', { cache: 'no-store' })).json(); } catch (e) { return; }
    render();
  }

  // ---- NAS folder browser ----
  let browsing = null;
  async function showFolder(path) {
    el('bErr').hidden = true;
    el('bPath').textContent = path;
    const list = el('bList'); list.textContent = '…';
    let j;
    try { j = await (await fetch('/api/browse?id=' + encodeURIComponent(browsing.item.id) + '&path=' + encodeURIComponent(path), { cache: 'no-store' })).json(); }
    catch (e) { j = { error: T.offline, path }; }
    browsing.path = j.path || path;
    el('bPath').textContent = browsing.path;
    list.textContent = '';
    if (j.error) { el('bErr').textContent = j.error; el('bErr').hidden = false; }
    const add = (icon, text, go) => {
      const b = document.createElement('button'); b.className = 'item';
      const ic = document.createElement('span'); ic.textContent = icon;
      const tx = document.createElement('span'); tx.textContent = text;
      b.append(ic, tx); b.addEventListener('click', go); list.appendChild(b); return b;
    };
    if (j.parent != null) add('↑', T.up, () => showFolder(j.parent));
    for (const f of j.folders || []) add('📁', f.name, () => showFolder(f.path));
    if (!j.error && !(j.folders || []).length) { const p = document.createElement('p'); p.className = 'muted block'; p.textContent = T.noSubfolders; list.appendChild(p); }
    const first = list.querySelector('button'); (first || el('bChoose')).focus();
  }
  function openBrowser(item, state) {
    browsing = { item, state, path: item.value || '/' };
    el('bTitle').textContent = T.browseTitle.replace('%FOLDER%', item.label);
    el('bChoose').textContent = T.choose;
    el('bClose').textContent = T.close;
    el('browser').showModal();
    showFolder(browsing.path);
  }
  el('bClose').addEventListener('click', () => el('browser').close());
  el('bChoose').addEventListener('click', async () => {
    const { item, state, path } = browsing;
    el('browser').close();
    await save(item, path, state, null);
  });

  // ---- display, restore ----
  for (const b of document.querySelectorAll('[data-display]')) {
    b.addEventListener('click', async () => {
      try {
        const j = await (await fetch(b.dataset.display, { method: 'POST' })).json();
        el('displayMsg').className = 'msg ' + (j.ok ? 'ok' : 'err');
        el('displayMsg').textContent = j.ok ? T.saved : '–';
      } catch (e) { el('displayMsg').className = 'msg err'; el('displayMsg').textContent = T.offline; }
    });
  }
  // Restore: read a backup (file or NAS), choose what to take over, apply.
  let pending = null;
  function msg(text, cls) { el('msg').className = 'msg' + (cls ? ' ' + cls : ''); el('msg').textContent = text || ''; }
  function fmtDate(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    return isNaN(d) ? iso : d.toLocaleString(document.documentElement.lang, { dateStyle: 'medium', timeStyle: 'short' });
  }
  async function loadNasBackups() {
    let j;
    try { j = await (await fetch('/api/restore/nas', { cache: 'no-store' })).json(); } catch (e) { return; }
    el('nasBox').hidden = !!j.ok && !j.folder;
    const list = el('nasList'); list.textContent = '';
    const note = (cls, text) => { const p = document.createElement('p'); p.className = cls; p.textContent = text; list.appendChild(p); };
    if (!j.ok) { note('msg err', j.message); return; }
    if (!(j.files || []).length) { note('muted', T.nasNone); return; }
    for (const f of j.files) {
      const b = document.createElement('button'); b.className = 'item';
      const ic = document.createElement('span'); ic.textContent = '☁';
      const tx = document.createElement('span');
      const t = document.createElement('span'); t.textContent = f.modified ? fmtDate(f.modified) : f.name; tx.appendChild(t);
      if (f.modified) { const n = document.createElement('span'); n.className = 'path'; n.style.display = 'block'; n.textContent = f.name; tx.appendChild(n); }
      b.append(ic, tx);
      b.addEventListener('click', () => inspect('/api/restore/inspect-nas', JSON.stringify({ name: f.name }), f.name));
      list.appendChild(b);
    }
  }
  async function inspect(url, body, fileName) {
    msg(T.reading);
    el('send').disabled = true;
    try {
      const j = await (await fetch(url, { method: 'POST', body, headers: { 'Content-Type': 'application/json' } })).json();
      if (!j.ok) { msg(j.message, 'err'); return; }
      msg('');
      showSelection(j, fileName);
    } catch (e) {
      msg(T.offline, 'err');
    } finally {
      el('send').disabled = !el('file').files.length;
    }
  }
  function showSelection(j, fileName) {
    pending = j;
    el('pick').hidden = true; el('select').hidden = false;
    el('selFrom').textContent = fileName + (j.createdAt ? ' · ' + T.created.replace('%DATE%', fmtDate(j.createdAt)) : '');
    const name = el('selName');
    name.value = j.deviceName || '';
    name.placeholder = j.currentName || '';
    el('selNameHelp').textContent = j.currentName ? T.nameHelp.replace('%NAME%', j.currentName) : T.nameHelpNone;
    const box = el('selAreas'); box.textContent = '';
    if (!j.areas.length) { const p = document.createElement('p'); p.className = 'muted block'; p.textContent = T.nothingInside; box.appendChild(p); }
    for (const a of j.areas) {
      const r = document.createElement('label'); r.className = 'row check';
      const left = document.createElement('span'); left.className = 'left';
      const t = document.createElement('span'); t.className = 'label'; t.textContent = a.title;
      const h = document.createElement('span'); h.className = 'help'; h.textContent = a.summary;
      left.append(t, h);
      const right = document.createElement('span'); right.className = 'right';
      const c = document.createElement('input'); c.type = 'checkbox'; c.checked = true; c.dataset.area = a.id;
      right.appendChild(c);
      r.append(left, right);
      box.appendChild(r);
    }
    el('select').scrollIntoView({ block: 'start' });
    name.focus();
  }
  function closeSelection() { pending = null; el('select').hidden = true; el('pick').hidden = false; }
  el('selCancel').addEventListener('click', () => { closeSelection(); msg(''); el('send').focus(); });
  el('selName').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') el('selApply').focus(); });
  el('selApply').addEventListener('click', async () => {
    if (!pending) return;
    const areas = [...el('selAreas').querySelectorAll('input[type=checkbox]')].filter((c) => c.checked).map((c) => c.dataset.area);
    const name = el('selName').value.trim();
    if (!areas.length && (!name || name === (pending.currentName || '').trim())) { msg(T.nothingSelected, 'err'); return; }
    el('selApply').disabled = true;
    msg(T.restoring);
    try {
      const r = await fetch('/api/restore/apply', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: pending.token, areas, deviceName: name }) });
      const j = await r.json();
      msg(j.message, j.ok ? 'ok' : 'err');
      if (j.ok) { done = true; closeSelection(); el('open').hidden = true; setTimeout(() => { done = false; }, 15000); }
    } catch (e) {
      msg(T.offline, 'err');
    } finally {
      el('selApply').disabled = false;
    }
  });
  el('file').addEventListener('change', () => { el('send').disabled = !el('file').files.length; });
  el('send').addEventListener('click', () => {
    const file = el('file').files[0];
    if (file) inspect('/api/restore/inspect', file, file.name);
  });

  el('back').addEventListener('click', () => { location.hash = ''; });
  window.addEventListener('hashchange', () => { render(); window.scrollTo(0, 0); });
  loadStatus();
  loadSettings();
  setInterval(loadStatus, 2000);
</script>
</body>
</html>''';
  }
}
