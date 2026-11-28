import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../data/services/enigma2_service.dart';
import '../../data/services/hbbtv_ait.dart';
import '../../data/services/hbbtv_service.dart';
import '../../l10n/l10n.dart';
import 'hbbtv_shim.dart';
import 'tv_widgets.dart' show TvRow;

/// HbbTV over the live picture (the red key in TV): the channel's app -
/// red button portal, Mediathek, teletext - in a WebView with a transparent
/// background, so the broadcast stays visible under it.
///
/// The app is found in the channel's AIT ([HbbtvFinder]); its pages get
/// HbbTV's objects ([hbbtvShim]) and the remote's keys as HbbTV key events.
/// Red closes it, Back goes to the app first - if the app doesn't use it,
/// it closes too (as do the app's own "exit" and channel keys).
class HbbtvOverlay extends StatefulWidget {
  const HbbtvOverlay({
    super.key,
    required this.config,
    required this.channel,
    required this.onClose,
    required this.onLive,
    this.tap,
    this.isHbbtvKey,
  });

  final Enigma2Config config;
  final E2Channel channel;

  /// The channel's stream as it runs (for its AIT), if it runs.
  final Stream<List<int>>? tap;
  final VoidCallback onClose;

  /// The app wants the live picture and sound off (false: its own video
  /// plays) or back on (true).
  final ValueChanged<bool> onLive;

  /// The key that opened HbbTV (Einstellungen → Tasten der Fernbedienung,
  /// red by default) closes it again; red goes to the app if it's another.
  final bool Function(LogicalKeyboardKey key)? isHbbtvKey;

  static final bool supported = !kIsWeb && Platform.isAndroid;

  @override
  State<HbbtvOverlay> createState() => HbbtvOverlayState();
}

enum _Phase { searching, loading, running, failed }

class HbbtvOverlayState extends State<HbbtvOverlay> {
  final _focus = FocusNode(debugLabel: 'hbbtv');
  WebViewController? _controller;
  HbbtvLaunch? _launch;
  String _userAgent = hbbtvUserAgent();
  _Phase _phase = _Phase.searching;
  String? _message;
  Timer? _closeTimer;
  bool _closed = false;

  /// The first page gets the "red" pressed for it; later pages not.
  bool _autoRedUsed = false;

  /// Keys the viewer pressed on this page - a hide() of the app after that
  /// means it's done (before it, autostart apps hide while they wait).
  int _keysOnPage = 0;

  /// The app's own video plays (the live picture is off): a black background.
  bool _ownVideo = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _grabFocus();
    unawaited(_start());
  }

  @override
  void dispose() {
    _closed = true;
    _closeTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _grabFocus() {
    for (final delay in const [Duration.zero, Duration(milliseconds: 400), Duration(milliseconds: 1200)]) {
      Future<void>.delayed(delay, () {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _closeTimer?.cancel();
    widget.onClose();
  }

  /// A friendly note, then back to the picture.
  void _fail(String message) {
    if (!mounted || _closed) return;
    setState(() {
      _phase = _Phase.failed;
      _message = message;
    });
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(seconds: 4), _close);
  }

  Future<void> _start() async {
    final t = l10n;
    if (!HbbtvOverlay.supported) return _fail(t.hbbtvAndroidOnly);
    HbbtvLaunch? launch;
    try {
      launch = await HbbtvFinder.find(
        config: widget.config,
        serviceRef: widget.channel.ref,
        channelName: widget.channel.name,
        tap: widget.tap,
      );
    } catch (e) {
      debugPrint('HbbTV: $e');
    }
    if (!mounted || _closed) return;
    if (launch == null) return _fail(t.hbbtvNone(widget.channel.name));
    _launch = launch;
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(Colors.transparent);
      try {
        _userAgent = hbbtvUserAgent(await controller.getUserAgent());
      } catch (_) {}
      await controller.setUserAgent(_userAgent);
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        // The app starts its videos from key presses we send - no "gesture".
        await platform.setMediaPlaybackRequiresUserGesture(false);
      }
      await controller.addJavaScriptChannel('HbbtvHost', onMessageReceived: (m) => _onMessage(m.message));
      await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          // The app's pages come through fetchHbbtvPage (their content type);
          // frames and everything else load as usual.
          if (!request.isMainFrame || uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
            return NavigationDecision.navigate;
          }
          unawaited(_open(uri));
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) {
          if (!mounted || _closed) return;
          if (_phase == _Phase.loading) setState(() => _phase = _Phase.running);
          _grabFocus();
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) debugPrint('HbbTV page: ${error.errorCode} ${error.description}');
        },
      ));
      if (!mounted || _closed) return;
      setState(() {
        _controller = controller;
        _phase = _Phase.loading;
      });
      await _open(Uri.parse(launch.url));
    } catch (e) {
      debugPrint('HbbTV WebView: $e');
      _fail(t.hbbtvLoadFailed('$e'));
    }
  }

  HbbtvShimConfig _shimConfig() {
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    final german = l10n.localeName.startsWith('de');
    final launch = _launch;
    final autoRed = !_autoRedUsed && (launch?.app.autostart ?? false);
    _autoRedUsed = true;
    return HbbtvShimConfig(
      channelName: widget.channel.name,
      channelNumber: widget.channel.number,
      triplet: DvbTriplet.fromServiceRef(widget.channel.ref),
      apps: launch?.apps ?? const [],
      autoRed: autoRed,
      language: german ? 'deu' : 'eng',
      country: switch (locale.countryCode?.toUpperCase()) {
        'AT' => 'AUT',
        'CH' => 'CHE',
        'GB' => 'GBR',
        _ => 'DEU',
      },
    );
  }

  /// Loads a page of the app (the first, a link, an app it starts).
  Future<void> _open(Uri url) async {
    final controller = _controller;
    if (controller == null || _closed) return;
    final generation = ++_loadGeneration;
    _keysOnPage = 0;
    try {
      final page = await fetchHbbtvPage(url, userAgent: _userAgent, shim: hbbtvShim(_shimConfig()));
      if (!mounted || _closed || generation != _loadGeneration) return;
      if (page.isDocument) {
        await controller.loadHtmlString(page.html!, baseUrl: page.url.toString());
      } else {
        await controller.loadRequest(page.url);
      }
    } catch (e) {
      debugPrint('HbbTV $url: $e');
      if (!mounted || generation != _loadGeneration) return;
      // The first page: nothing to show. A later one: the app stays.
      if (_phase != _Phase.running) _fail(l10n.hbbtvLoadFailed(_shortError(e)));
    }
  }

  static String _shortError(Object e) {
    final s = '$e';
    if (e is SocketException || s.contains('SocketException') || s.contains('Failed host lookup')) return l10n.hbbtvOffline;
    if (e is TimeoutException) return l10n.hbbtvTimeout;
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  void _onMessage(String raw) {
    if (!mounted || _closed) return;
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final d = m['d'];
    switch (m['t']) {
      case 'launch':
        final uri = d is String ? Uri.tryParse(d) : null;
        if (uri != null) unawaited(_open(uri));
      case 'destroy':
        _close();
      case 'hide':
        // The viewer was in the app and it put itself away (Back at its top).
        if (_keysOnPage > 0) _close();
      case 'media':
        if (d == true && !_ownVideo) {
          setState(() => _ownVideo = true);
          widget.onLive(false);
        }
      case 'broadcast':
        if (d == true) {
          if (_ownVideo) setState(() => _ownVideo = false);
          widget.onLive(true);
        } else {
          setState(() => _ownVideo = true);
          widget.onLive(false);
        }
      case 'log':
        debugPrint('HbbTV: $d');
    }
  }

  /// Back (from TV's PopScope): to the app; closes if it doesn't use it.
  Future<void> back() async {
    if (_phase != _Phase.running) return _close();
    final handled = await _sendKey('back');
    if (!handled) _close();
  }

  /// Presses [name] in the page; whether the page took it (preventDefault).
  Future<bool> _sendKey(String name) async {
    final controller = _controller;
    if (controller == null) return false;
    _keysOnPage++;
    try {
      final result = await controller
          .runJavaScriptReturningResult("window.__hbb ? window.__hbb.key('$name') : 'none'")
          .timeout(const Duration(seconds: 2));
      return '$result'.contains('handled');
    } catch (e) {
      debugPrint('HbbTV key $name: $e');
      return false;
    }
  }

  static final _keys = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.select: 'enter',
    LogicalKeyboardKey.enter: 'enter',
    LogicalKeyboardKey.numpadEnter: 'enter',
    LogicalKeyboardKey.gameButtonA: 'enter',
    LogicalKeyboardKey.colorF0Red: 'red',
    LogicalKeyboardKey.colorF1Green: 'green',
    LogicalKeyboardKey.colorF2Yellow: 'yellow',
    LogicalKeyboardKey.colorF3Blue: 'blue',
    LogicalKeyboardKey.mediaPlayPause: 'playpause',
    LogicalKeyboardKey.mediaPlay: 'play',
    LogicalKeyboardKey.mediaPause: 'pause',
    LogicalKeyboardKey.mediaStop: 'stop',
    LogicalKeyboardKey.mediaFastForward: 'ffwd',
    LogicalKeyboardKey.mediaRewind: 'rew',
    LogicalKeyboardKey.mediaTrackNext: 'next',
    LogicalKeyboardKey.mediaTrackPrevious: 'prev',
    LogicalKeyboardKey.info: 'info',
    LogicalKeyboardKey.guide: 'info',
    for (var i = 0; i <= 9; i++) ...{
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i): '$i',
      LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + i): '$i',
    },
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    // Back/Esc: TV's PopScope calls [back].
    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) return KeyEventResult.handled;
    if (widget.isHbbtvKey?.call(key) ?? key == LogicalKeyboardKey.colorF0Red) {
      if (event is KeyDownEvent) _close();
      return KeyEventResult.handled;
    }
    // The channel keys leave HbbTV (the app can't switch channels here).
    if (key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.pageDown) {
      if (event is KeyDownEvent) _close();
      return KeyEventResult.handled;
    }
    final name = _keys[key];
    if (name != null && _phase == _Phase.running) {
      // Held arrows repeat; held OK or colour keys don't.
      final repeats = name == 'left' || name == 'right' || name == 'up' || name == 'down';
      if (event is KeyDownEvent || repeats) unawaited(_sendKey(name));
    }
    // Everything else stays here - nothing may reach the picture under it.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final t = context.l10n;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_ownVideo) const ColoredBox(color: Colors.black),
          if (controller != null && _phase != _Phase.failed)
            Positioned.fill(child: WebViewWidget(controller: controller)),
          if (_phase != _Phase.running)
            Positioned(
              top: 32,
              right: 40,
              child: _Note(
                icon: _phase == _Phase.failed ? Icons.info_outline : null,
                text: switch (_phase) {
                  _Phase.searching => t.hbbtvSearching,
                  _Phase.loading => t.hbbtvLoading(widget.channel.name),
                  _ => _message ?? '',
                },
                hint: _phase == _Phase.failed ? null : t.hbbtvCloseHint,
              ),
            ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.icon, this.hint});

  final String text;
  final IconData? icon;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFD32F2F), width: 2),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(icon, color: Colors.white70, size: 26)
              else
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFFD32F2F))),
              const SizedBox(width: 14),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text, style: const TextStyle(color: Colors.white, fontSize: 18)),
                    if (hint != null) ...[
                      const SizedBox(height: 4),
                      Text(hint!, style: const TextStyle(color: Colors.white54, fontSize: 14)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "HbbTV-Angebot" in TV's menus (options, a channel's options) - the way to
/// HbbTV on remotes without a red key.
Widget hbbtvOptionsRow(BuildContext context, VoidCallback onTap) => TvRow(
      onTap: onTap,
      child: ListTile(
        leading: const Icon(Icons.smart_button_outlined, color: Color(0xFFD32F2F)),
        title: Text(context.l10n.hbbtvMenuEntry),
      ),
    );
