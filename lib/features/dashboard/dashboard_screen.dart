import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/providers.dart';
import '../../data/services/ha_auth.dart';

import '../../core/dashboard_providers.dart';
import '../../core/loading_wave.dart';
import '../../core/remote_keys.dart';
import '../../l10n/l10n.dart';
import '../launcher/launcher_providers.dart';
import '../settings/settings_screen.dart';

/// Opens the Haussteuerung over Home (the radio pauses, like for TV).
Future<void> openDashboard(BuildContext context, WidgetRef ref) async {
  ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DashboardScreen()));
}

/// The Haussteuerung: the Home Assistant dashboard full screen. The login
/// stays (the WebView keeps Home Assistant's cookies and stored token), a
/// lost connection reloads by itself, and the display stays on while it
/// shows - off/on by motion is MotionService's job.
///
/// Remote: Back closes it, the menu key (☰) reloads.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  static const _retry = Duration(seconds: 15);

  static final bool _webViewSupported = !kIsWeb && Platform.isAndroid;

  WebViewController? _controller;
  String _url = '';
  bool _loading = true;
  bool _failed = false;
  Timer? _retryTimer;

  /// Holds the keys - also when Home (opened under it at the start) or the
  /// WebView reach for the focus.
  final _focus = FocusNode(debugLabel: 'dashboard');
  late final _display = ref.read(displayServiceProvider);

  /// Updates from the admin page / Home Assistant ("open this page", "reload").
  ProviderSubscription<int>? _commands;

  @override
  void initState() {
    super.initState();
    _display.setKeepScreenOn(true);
    _display.setDashboardActive(true);
    _commands = ref.listenManual(dashboardReloadProvider, (_, _) => _load(), fireImmediately: false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _grabFocus();
  }

  /// Now and once more after the transitions are through.
  void _grabFocus() {
    for (final delay in const [Duration.zero, Duration(milliseconds: 400), Duration(milliseconds: 1200)]) {
      Future<void>.delayed(delay, () {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _retryTimer?.cancel();
    _commands?.close();
    _display.setKeepScreenOn(false);
    _display.setDashboardActive(false);
    super.dispose();
  }

  /// Logged in by itself once per load - a wrong password doesn't loop.
  bool _autoLoginTried = false;

  /// Home Assistant's login page and a login in the settings (System → Home
  /// Assistant): log in with it and open the dashboard again. Without one,
  /// or if it fails (wrong password, two-factor), the login page stays.
  Future<bool> _autoLogin(String? pageUrl) async {
    final controller = _controller;
    if (controller == null || _autoLoginTried || !isHaLoginPage(pageUrl)) return false;
    final ha = await ref.read(settingsRepositoryProvider).getHaLink();
    if (ha.user.trim().isEmpty || ha.password.isEmpty) return false;
    _autoLoginTried = true;
    final page = Uri.tryParse(pageUrl!);
    if (page == null) return false;
    try {
      final tokens = await haLoginTokens(page, ha.user.trim(), ha.password);
      if (!mounted) return true;
      final json = jsonEncode(jsonEncode(tokens));
      await controller.runJavaScript('localStorage.setItem("hassTokens", $json);');
      final target = Uri.tryParse(_url);
      if (target != null) await controller.loadRequest(target);
      return true;
    } on HaAuthException catch (e) {
      debugPrint('dashboard: automatic login failed ($e)');
      return false;
    } catch (e) {
      debugPrint('dashboard: automatic login: $e');
      return false;
    }
  }

  void _load() {
    final url = ref.read(dashboardUrlProvider);
    _autoLoginTried = false;
    _retryTimer?.cancel();
    setState(() {
      _url = url;
      _failed = false;
      _loading = url.isNotEmpty;
    });
    if (url.isEmpty || !_webViewSupported) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      setState(() {
        _failed = true;
        _loading = false;
      });
      return;
    }
    final controller = _controller ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (pageUrl) async {
            if (!mounted) return;
            if (await _autoLogin(pageUrl)) return;
            if (!mounted) return;
            setState(() => _loading = false);
            _grabFocus();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != true || !mounted) return;
            debugPrint('dashboard: ${error.errorCode} ${error.description}');
            setState(() {
              _failed = true;
              _loading = false;
            });
            // Home Assistant restarting, Wi-Fi gone: try again by itself.
            _retryTimer?.cancel();
            _retryTimer = Timer(_retry, () {
              if (mounted) _load();
            });
          },
        ),
      );
    controller.loadRequest(uri);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    // The remote in the page: arrows move a green frame from button to
    // button, OK clicks (see dashboardRemoteScript).
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => 'up',
      LogicalKeyboardKey.arrowDown => 'down',
      LogicalKeyboardKey.arrowLeft => 'left',
      LogicalKeyboardKey.arrowRight => 'right',
      LogicalKeyboardKey.select || LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 'ok',
      _ => null,
    };
    final controller = _controller;
    if (direction != null && controller != null && !_loading && !_failed) {
      if (direction == 'ok' && event is KeyRepeatEvent) return KeyEventResult.handled;
      controller
          .runJavaScript("$dashboardRemoteScript;window.__hsNav('$direction');")
          .catchError((Object e) => debugPrint('dashboard remote: $e'));
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (ref.read(remoteKeysProvider).matches(RemoteAction.options, event.logicalKey)) {
      _load();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openSettings() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const SettingsScreen(section: SettingsSection.dashboard)))
      .then((_) => _load());

  @override
  Widget build(BuildContext context) {
    // A new address from the settings or the admin page.
    ref.listen(dashboardUrlProvider, (prev, next) {
      if (next != _url) _load();
    });
    final l = context.l10n;
    final controller = _controller;
    Widget body;
    if (!_webViewSupported) {
      body = _Message(text: l.dashboardAndroidOnly);
    } else if (_url.isEmpty) {
      body = _Message(text: l.dashboardNoAddress, action: l.dashboardOpenSettings, onAction: _openSettings);
    } else {
      body = Stack(
        children: [
          if (controller != null) Positioned.fill(child: WebViewWidget(controller: controller)),
          if (_loading) const ColoredBox(color: Colors.black, child: Center(child: LoadingWave())),
          if (_failed)
            ColoredBox(
              color: Colors.black,
              child: _Message(
                text: l.dashboardUnreachable(_url),
                action: l.dashboardOpenSettings,
                onAction: _openSettings,
              ),
            ),
        ],
      );
    }
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(backgroundColor: Colors.black, body: body),
    );
  }
}

/// Bumped to reload the dashboard (admin page, Home Assistant).
class DashboardReloadNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void reload() => state++;
}

final dashboardReloadProvider = NotifierProvider<DashboardReloadNotifier, int>(DashboardReloadNotifier.new);

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icon/dashboard_logo.png', width: 96, height: 96),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, color: Colors.white70)),
            if (action != null) ...[
              const SizedBox(height: 20),
              FilledButton(autofocus: true, onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Remote control inside the web page (Home Assistant's cards and buttons
/// are spread over shadow DOMs; web pages know no arrow-key navigation):
/// `__hsNav('up'|'down'|'left'|'right')` frames the nearest control in that
/// direction, `__hsNav('ok')` clicks the framed one. Installed once per page.
const dashboardRemoteScript = r"""
(function () {
  if (window.__hsNav) return;
  var SEL = 'button,a[href],input,select,textarea,[role=button],[role=switch],[role=checkbox],[role=slider],' +
    '[tabindex]:not([tabindex="-1"])';
  function collect(root, out) {
    var all = root.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var e = all[i];
      if (e.matches && e.matches(SEL)) out.push(e);
      if (e.shadowRoot) collect(e.shadowRoot, out);
    }
    return out;
  }
  function shown(e) {
    var r = e.getBoundingClientRect();
    if (r.width < 6 || r.height < 6) return false;
    var s = getComputedStyle(e);
    return s.visibility !== 'hidden' && s.display !== 'none' && s.pointerEvents !== 'none';
  }
  var cur = null;
  var box = document.createElement('div');
  box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:3px solid #4caf50;' +
    'border-radius:12px;box-shadow:0 0 14px #4caf50;display:none';
  document.documentElement.appendChild(box);
  function frame() {
    if (!cur || !cur.isConnected) { box.style.display = 'none'; return; }
    var r = cur.getBoundingClientRect();
    box.style.display = 'block';
    box.style.left = (r.left - 4) + 'px';
    box.style.top = (r.top - 4) + 'px';
    box.style.width = (r.width + 2) + 'px';
    box.style.height = (r.height + 2) + 'px';
  }
  function show(e) {
    cur = e;
    try { e.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch (_) {}
    try { e.focus({ preventScroll: true }); } catch (_) {}
    frame();
    setTimeout(frame, 350);
  }
  window.addEventListener('scroll', frame, true);
  window.__hsNav = function (dir) {
    if (dir === 'ok') { if (cur && cur.isConnected) cur.click(); setTimeout(frame, 400); return; }
    var all = collect(document, []).filter(shown);
    if (!cur || !cur.isConnected) {
      var first = all.filter(function (e) {
        var r = e.getBoundingClientRect();
        return r.top >= 0 && r.left >= 0 && r.top < innerHeight;
      });
      first.sort(function (a, b) {
        var p = a.getBoundingClientRect(), q = b.getBoundingClientRect();
        return (p.top - q.top) || (p.left - q.left);
      });
      if (first.length) show(first[0]);
      return;
    }
    var a = cur.getBoundingClientRect();
    var ax = a.left + a.width / 2, ay = a.top + a.height / 2;
    var best = null, bestScore = Infinity;
    for (var i = 0; i < all.length; i++) {
      var e = all[i];
      if (e === cur || e.contains(cur) || cur.contains(e)) continue;
      var r = e.getBoundingClientRect();
      var dx = r.left + r.width / 2 - ax, dy = r.top + r.height / 2 - ay;
      var main, cross;
      if (dir === 'down') { main = dy; cross = dx; }
      else if (dir === 'up') { main = -dy; cross = dx; }
      else if (dir === 'right') { main = dx; cross = dy; }
      else { main = -dx; cross = dy; }
      if (main < 8) continue;
      var score = main + Math.abs(cross) * 2.5;
      if (score < bestScore) { bestScore = score; best = e; }
    }
    if (best) show(best);
  };
})()
""";
