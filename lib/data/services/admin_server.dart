import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;

import '../../l10n/l10n.dart';
import 'backup_service.dart';

/// Called with an uploaded backup while the restore screen is open. Throws
/// [BackupFormatException] if the file isn't a usable backup.
typedef WebRestoreHandler = Future<void> Function(String content);

/// The settings the admin page can change (see AdminSettings).
abstract interface class AdminSettingsSource {
  /// Groups of settings: `{title, items: [{id, label, type, value, ...}]}`.
  Future<List<Map<String, Object?>>> describe();

  /// Sets [id] to [value]; an error message, or null when it was taken.
  Future<String?> apply(String id, Object? value);
}

/// The Haussteuerung's display, for Home Assistant (see DisplayService).
typedef AdminDisplayHooks = ({
  Future<bool> Function() on,
  Future<bool> Function() off,
  void Function() reload,
  bool Function() available,
});

/// The device's admin page, `http://<ip>:1401/` in the home network:
/// create and download a backup at any time; upload one only while the
/// device shows "Backup wiederherstellen" ([restoreHandler] is set) - from
/// the setup wizard or Settings → System. Change settings ([settings]), and
/// for the Haussteuerung switch the display (`POST /api/display/on|off`,
/// `/api/dashboard/reload` - e.g. Home Assistant's rest_command).
class AdminServer {
  AdminServer({required this.backup, required this.deviceName, required this.version});

  static const port = 1401;
  static const _maxUpload = 32 * 1024 * 1024;

  final BackupService backup;
  final Future<String> Function() deviceName;
  final Future<String> Function() version;

  HttpServer? _server;
  bool _stopped = false;

  /// Set by the restore screen while it is open.
  WebRestoreHandler? restoreHandler;

  /// Set by the app once it runs (app.dart).
  AdminSettingsSource? settings;
  AdminDisplayHooks? display;

  bool get running => _server != null;

  /// Binds the port; retried for a while if it's still taken (a restart
  /// on the PC starts the new instance before the old one has quit).
  Future<void> start() async {
    for (var attempt = 0; attempt < 12 && !_stopped; attempt++) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
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
          _json(response, {'groups': await settings?.describe() ?? const []});
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
        case ('POST', '/api/restore'):
          await _restore(request);
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
    final error = await source.apply(body['id'] as String, body['value']);
    if (error != null) response.statusCode = HttpStatus.badRequest;
    _json(response, {'ok': error == null, 'message': error ?? l10n.adminSaved});
  }

  Future<void> _restore(HttpRequest request) async {
    final response = request.response;
    final handler = restoreHandler;
    if (handler == null) {
      response.statusCode = HttpStatus.forbidden;
      _json(response, {
        'ok': false,
        'message': l10n.adminRestoreLocked,
      });
      return;
    }
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
    try {
      await handler(content);
      _json(response, {'ok': true, 'message': l10n.adminRestored});
    } on BackupFormatException catch (e) {
      response.statusCode = HttpStatus.badRequest;
      _json(response, {'ok': false, 'message': e.message});
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
      'confirmRestore': l.adminConfirmRestore('%FILE%'),
      'unchanged': l.adminSecretPlaceholder,
      'on': l.commonOn,
      'off': l.commonOff,
    }).replaceAll('</', r'<\/');
    return '''<!doctype html>
<html lang="${l.localeName}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
  :root { color-scheme: dark; --green: #4caf50; --bg: #05070a; --card: #12171b; --line: #263036; --muted: #9aa5ab; }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: #fff; font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  header { padding: 20px 24px; background: #000; border-bottom: 1px solid var(--line); }
  header h1 { margin: 0; font-size: 22px; }
  header .by { color: var(--green); font-size: 13px; font-weight: 600; }
  main { max-width: 720px; margin: 0 auto; padding: 24px 16px 48px; }
  .device { font-size: 28px; font-weight: 700; margin: 0 0 4px; }
  .muted { color: var(--muted); font-size: 14px; }
  section { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 20px; margin-top: 20px; }
  section h2 { margin: 0 0 8px; font-size: 19px; }
  .btn { display: inline-block; margin: 12px 8px 0 0; padding: 12px 20px; border-radius: 10px; border: 0; background: var(--green); color: #05070a; font-weight: 700; font-size: 16px; text-decoration: none; cursor: pointer; }
  .btn.alt { background: #263036; color: #fff; }
  .btn[disabled] { opacity: .5; cursor: default; }
  input[type=file] { display: block; margin-top: 12px; color: var(--muted); max-width: 100%; }
  .msg { margin-top: 12px; font-weight: 600; }
  .ok { color: var(--green); }
  .err { color: #ffb74d; }
  .facts { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; margin: 12px 0 0; font-size: 15px; }
  .facts dt { color: var(--muted); }
  .facts dd { margin: 0; font-family: ui-monospace, Consolas, monospace; word-break: break-all; }
  .row { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.2fr); gap: 4px 16px; align-items: center; padding: 10px 0; border-top: 1px solid var(--line); }
  .row:first-of-type { border-top: 0; }
  .row label { font-weight: 600; }
  .row .help { grid-column: 1 / -1; color: var(--muted); font-size: 13px; margin-top: -2px; }
  .row .state { grid-column: 1 / -1; font-size: 13px; min-height: 0; }
  .row input[type=text], .row input[type=number], .row input[type=password], .row select {
    width: 100%; padding: 9px 10px; border-radius: 8px; border: 1px solid var(--line); background: #0b0f12; color: #fff; font: inherit; }
  .row input[type=checkbox] { width: 22px; height: 22px; accent-color: var(--green); justify-self: start; }
  @media (max-width: 520px) { .row { grid-template-columns: 1fr; } }
  footer { text-align: center; color: var(--muted); font-size: 13px; margin-top: 32px; }
</style>
</head>
<body>
<header>
  <h1>Home System</h1>
  <div class="by">Powered by jaycloud.at</div>
</header>
<main>
  <p class="device" id="name">${name.isEmpty ? 'Home System' : e(name)}</p>
  <p class="muted">${e(l.adminSubtitle)}</p>
  <dl class="facts">
    <dt>${e(l.adminHostname)}</dt><dd id="host">$host</dd>
    <dt>${e(l.adminIpAddress)}</dt><dd id="ips">$ips</dd>
  </dl>

  <div id="settings"></div>

  <section id="display" hidden>
    <h2>${e(l.adminDisplayHeading)}</h2>
    <p class="muted">${e(l.adminDisplayHelp)}</p>
    <button class="btn" data-display="/api/display/on">${e(l.adminDisplayOn)}</button>
    <button class="btn alt" data-display="/api/display/off">${e(l.adminDisplayOff)}</button>
    <button class="btn alt" data-display="/api/dashboard/reload">${e(l.adminDashboardReload)}</button>
    <p class="msg" id="displayMsg"></p>
  </section>

  <section>
    <h2>${e(l.adminBackupHeading)}</h2>
    <p class="muted">${e(l.adminBackupHelp)}</p>
    <a class="btn" href="/backup" download>${e(l.adminBackupDownload)}</a>
  </section>

  <section>
    <h2>${e(l.adminRestoreHeading)}</h2>
    <div id="locked">
      <p class="muted">${e(l.adminRestoreHow)}</p>
    </div>
    <div id="open" hidden>
      <p class="muted">${e(l.adminRestoreReady)}</p>
      <input type="file" id="file" accept=".json,application/json">
      <button class="btn" id="send" disabled>${e(l.adminRestoreButton)}</button>
    </div>
    <p class="msg" id="msg"></p>
  </section>

  <footer>Home System <span id="version">${e(version)}</span></footer>
</main>
<script>
  const T = $t;
  const el = (id) => document.getElementById(id);
  let done = false;
  let editing = false;
  async function status() {
    if (done) return;
    try {
      const s = await (await fetch('/api/status', { cache: 'no-store' })).json();
      if (s.name) { el('name').textContent = s.name; document.title = s.name + ' · Home System'; }
      el('version').textContent = s.version;
      el('host').textContent = s.hostname || '–';
      el('ips').textContent = (s.addresses || []).join(', ') || '–';
      el('open').hidden = !s.restore;
      el('locked').hidden = s.restore;
      el('display').hidden = !s.display;
    } catch (e) { /* device restarting or offline */ }
  }

  // Settings: one row per setting, saved as soon as it changes.
  function input(item) {
    let i;
    if (item.type === 'bool') {
      i = document.createElement('input'); i.type = 'checkbox'; i.checked = !!item.value;
    } else if (item.type === 'choice') {
      i = document.createElement('select');
      for (const o of item.options || []) {
        const opt = document.createElement('option'); opt.value = o.value; opt.textContent = o.label;
        if (o.value === item.value) opt.selected = true;
        i.appendChild(opt);
      }
    } else {
      i = document.createElement('input');
      i.type = item.type === 'int' ? 'number' : item.type === 'secret' ? 'password' : 'text';
      if (item.min != null) i.min = item.min;
      if (item.max != null) i.max = item.max;
      i.value = item.value ?? '';
      if (item.type === 'secret') { i.placeholder = T.unchanged; i.autocomplete = 'new-password'; }
    }
    i.id = 'set-' + item.id;
    return i;
  }
  async function save(item, i, state) {
    let value = item.type === 'bool' ? i.checked : item.type === 'int' ? Number(i.value) : i.value;
    state.className = 'state'; state.textContent = '…';
    try {
      const r = await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: item.id, value }) });
      const j = await r.json();
      state.className = 'state ' + (j.ok ? 'ok' : 'err');
      state.textContent = j.message;
      if (j.ok) { if (item.type === 'secret') i.value = ''; setTimeout(() => { if (state.textContent === j.message) state.textContent = ''; }, 2500); }
      // Choices depend on each other (parts on/off -> start options).
      if (j.ok && (item.type === 'bool' || item.type === 'choice')) loadSettings();
    } catch (e) {
      state.className = 'state err'; state.textContent = T.offline;
    }
  }
  async function loadSettings() {
    if (editing) return;
    let data;
    try { data = await (await fetch('/api/settings', { cache: 'no-store' })).json(); } catch (e) { return; }
    const box = el('settings');
    box.textContent = '';
    for (const g of data.groups || []) {
      const s = document.createElement('section');
      const h = document.createElement('h2'); h.textContent = g.title; s.appendChild(h);
      for (const item of g.items) {
        const row = document.createElement('div'); row.className = 'row';
        const label = document.createElement('label'); label.textContent = item.label; label.htmlFor = 'set-' + item.id;
        const i = input(item);
        const state = document.createElement('div'); state.className = 'state';
        i.addEventListener('focus', () => { editing = true; });
        i.addEventListener('blur', () => { editing = false; });
        i.addEventListener('change', () => save(item, i, state));
        row.append(label, i);
        if (item.help) { const help = document.createElement('div'); help.className = 'help'; help.textContent = item.help; row.appendChild(help); }
        row.appendChild(state);
        s.appendChild(row);
      }
      box.appendChild(s);
    }
  }

  for (const b of document.querySelectorAll('[data-display]')) {
    b.addEventListener('click', async () => {
      try {
        const j = await (await fetch(b.dataset.display, { method: 'POST' })).json();
        el('displayMsg').className = 'msg ' + (j.ok ? 'ok' : 'err');
        el('displayMsg').textContent = j.ok ? T.saved : '–';
      } catch (e) { el('displayMsg').className = 'msg err'; el('displayMsg').textContent = T.offline; }
    });
  }

  el('file').addEventListener('change', () => { el('send').disabled = !el('file').files.length; });
  el('send').addEventListener('click', async () => {
    const file = el('file').files[0];
    if (!file) return;
    if (!confirm(T.confirmRestore.replace('%FILE%', file.name))) return;
    el('send').disabled = true;
    el('msg').className = 'msg';
    el('msg').textContent = T.restoring;
    try {
      const r = await fetch('/api/restore', { method: 'POST', body: file, headers: { 'Content-Type': 'application/json' } });
      const j = await r.json();
      el('msg').className = 'msg ' + (j.ok ? 'ok' : 'err');
      el('msg').textContent = j.message;
      if (j.ok) { done = true; el('open').hidden = true; setTimeout(() => { done = false; }, 15000); }
      else el('send').disabled = false;
    } catch (e) {
      el('msg').className = 'msg err';
      el('msg').textContent = T.offline;
      el('send').disabled = false;
    }
  });
  status();
  loadSettings();
  setInterval(status, 2000);
</script>
</body>
</html>''';
  }
}
