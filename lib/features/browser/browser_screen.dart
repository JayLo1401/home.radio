import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../core/remote_keys.dart';
import '../../l10n/l10n.dart';
import '../launcher/launcher_providers.dart' show RadioCommand, radioCommandProvider;
import 'browser_channel.dart';
import 'browser_menu.dart';
import 'browser_pointer.dart';
import 'browser_settings.dart';
import 'browser_settings_screen.dart';

/// Opens the browser - at [url], else where it was left (or the home page).
Future<void> openBrowser(BuildContext context, {String? url}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => BrowserScreen(initialUrl: url)));

/// The browser: web pages full screen in the device's System WebView, with
/// the ad/tracker blocker.
///
/// Remote: the D-Pad moves a mouse pointer (faster when held; at the edge
/// the page scrolls), OK clicks, OK held clicks and opens the text entry,
/// the menu key opens the bar (address, back/forward, bookmarks, blocker,
/// desktop view, text size), Back goes back a page - on the first page it
/// asks to close. In a text field: OK shows the keyboard, the menu key
/// "Text eingeben", Back leaves the field. Play/Pause, ⏪/⏩ for videos.
/// Touch works on the page as usual.
class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };
  static const _longPress = Duration(milliseconds: 600);

  BrowserViewController? _c;
  late final BrowserPointer _pointer;
  final _pageFocus = FocusNode(debugLabel: 'browser page');
  final _menuFocus = FocusScopeNode(debugLabel: 'browser bar');

  BrowserSettings? _start;
  String? _startUrl;
  bool _menuOpen = false;
  bool _showHint = true;
  DateTime? _okDownAt;
  double _dpr = 1;
  Timer? _hintTimer;
  Timer? _saveUrl;
  StreamSubscription<String>? _downloads;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pointer = BrowserPointer(
      vsync: this,
      onHover: (at) => _c?.hover(at * _dpr),
      onEdgeScroll: (at, by) => _c?.scroll(at * _dpr, by * _dpr),
    );
    _hintTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showHint = false);
    });
    _prepare();
  }

  Future<void> _prepare() async {
    if (!BrowserChannel.supported) return;
    final settings = await ref.read(browserSettingsProvider.notifier).loaded();
    unawaited(ref.read(adblockProvider.notifier).prepare());
    if (!mounted) return;
    setState(() {
      _start = settings;
      _startUrl = widget.initialUrl ?? (settings.lastUrl.isNotEmpty ? settings.lastUrl : settings.home);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _c;
    if (c == null) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      c.pause();
    } else if (state == AppLifecycleState.resumed) {
      c.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hintTimer?.cancel();
    _saveUrl?.cancel();
    _downloads?.cancel();
    _c?.dispose();
    _pointer.dispose();
    _pageFocus.dispose();
    _menuFocus.dispose();
    super.dispose();
  }

  void _onCreated(int id) {
    final c = BrowserViewController(id);
    _c = c;
    c.field.addListener(() => setState(() {}));
    c.fullscreen.addListener(() {
      if (!c.fullscreen.value) _pageFocus.requestFocus();
      setState(() {});
    });
    c.mediaPlaying.addListener(() {
      // A page starts playing sound: the radio makes way (as for TV).
      if (c.mediaPlaying.value) ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
    });
    c.url.addListener(() {
      _saveUrl?.cancel();
      _saveUrl = Timer(const Duration(seconds: 2), () {
        final url = c.url.value;
        if (url.startsWith('http')) {
          ref.read(browserSettingsProvider.notifier).update((s) => s.copyWith(lastUrl: url));
        }
      });
    });
    _downloads = c.downloads.stream.listen((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.browserDownloadUnsupported)));
    });
    c.focus();
    setState(() {});
  }

  // --- keys ---------------------------------------------------------------------

  bool _isMenuKey(LogicalKeyboardKey key) {
    if (isBrowserMenuKey(key)) return true;
    // A key the user set for "Optionen" - not the PC keyboard's letter,
    // that one types into the page.
    final keys = ref.read(remoteKeysProvider);
    return keys.isCustom(RemoteAction.options) && keys.matches(RemoteAction.options, key);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final c = _c;
    if (c == null || _menuOpen) return KeyEventResult.ignored;
    if (c.fullscreen.value) return KeyEventResult.skipRemainingHandlers;
    final key = event.logicalKey;
    final down = event is KeyDownEvent;

    if (_isMenuKey(key)) {
      if (down) c.field.value == BrowserFieldKind.none ? _openMenu() : _enterText();
      return KeyEventResult.handled;
    }
    if (c.field.value != BrowserFieldKind.none) return _onKeyInField(c, event);

    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => PointerDirection.up,
      LogicalKeyboardKey.arrowDown => PointerDirection.down,
      LogicalKeyboardKey.arrowLeft => PointerDirection.left,
      LogicalKeyboardKey.arrowRight => PointerDirection.right,
      _ => null,
    };
    if (direction != null) {
      if (down) {
        _hideHint();
        _pointer.press(direction);
      } else if (event is KeyUpEvent) {
        _pointer.release(direction);
      }
      return KeyEventResult.handled;
    }
    if (_okKeys.contains(key)) {
      if (down) {
        _okDownAt = DateTime.now();
      } else if (event is KeyUpEvent) {
        final at = _okDownAt;
        _okDownAt = null;
        if (at != null) _ok(long: DateTime.now().difference(at) >= _longPress);
      }
      return KeyEventResult.handled;
    }
    if (!down) {
      return _mediaKeys.contains(key) || _pageKeys.contains(key)
          ? KeyEventResult.handled
          : KeyEventResult.skipRemainingHandlers;
    }
    switch (key) {
      case LogicalKeyboardKey.mediaPlayPause:
        c.media('toggle');
      case LogicalKeyboardKey.mediaPlay:
        c.media('play');
      case LogicalKeyboardKey.mediaPause || LogicalKeyboardKey.mediaStop:
        c.media('pause');
      case LogicalKeyboardKey.mediaFastForward:
        c.media('seek', seconds: 10);
      case LogicalKeyboardKey.mediaRewind:
        c.media('seek', seconds: -10);
      case LogicalKeyboardKey.channelUp || LogicalKeyboardKey.pageUp:
        _scrollPage(-1);
      case LogicalKeyboardKey.channelDown || LogicalKeyboardKey.pageDown:
        _scrollPage(1);
      default:
        // Letters, digits, space ...: the page's (a keyboard's shortcuts).
        return KeyEventResult.skipRemainingHandlers;
    }
    return KeyEventResult.handled;
  }

  static final _mediaKeys = {
    LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlay,
    LogicalKeyboardKey.mediaPause,
    LogicalKeyboardKey.mediaStop,
    LogicalKeyboardKey.mediaFastForward,
    LogicalKeyboardKey.mediaRewind,
  };
  static final _pageKeys = {
    LogicalKeyboardKey.channelUp,
    LogicalKeyboardKey.channelDown,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
  };

  /// In a text field the keys are the field's: the D-Pad moves the text
  /// cursor, keyboards type. Up/down leave a one-line field.
  KeyEventResult _onKeyInField(BrowserViewController c, KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      if (c.field.value == BrowserFieldKind.multi) return KeyEventResult.skipRemainingHandlers;
      if (down) _leaveField();
      return KeyEventResult.handled;
    }
    // The remote's OK: the keyboard (a keyboard's Enter goes to the page).
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.gameButtonA) {
      if (down) c.showKeyboard();
      return KeyEventResult.handled;
    }
    return KeyEventResult.skipRemainingHandlers;
  }

  void _ok({required bool long}) {
    final c = _c;
    if (c == null) return;
    _hideHint();
    if (!_pointer.visible) {
      // After touch: the first OK only brings the pointer back.
      _pointer.visible = true;
      return;
    }
    c.tap(_pointer.position * _dpr);
    if (long) {
      // Held: into the field and straight to the text entry.
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        if (mounted && c.field.value != BrowserFieldKind.none) _enterText();
      });
    }
  }

  void _scrollPage(int direction) {
    final size = _pageSize;
    _c?.scroll(_pointer.position * _dpr, Offset(0, direction * size.height * 0.8 * _dpr));
  }

  Size _pageSize = Size.zero;

  void _hideHint() {
    if (_showHint) setState(() => _showHint = false);
  }

  Future<void> _leaveField() async {
    final c = _c;
    if (c == null) return;
    await c.blurField();
    c.field.value = BrowserFieldKind.none;
  }

  /// "Text eingeben": our own text entry for the focused field.
  Future<void> _enterText() async {
    final c = _c;
    if (c == null) return;
    final field = await c.focusedField();
    if (!mounted) return;
    if (field.reachable && field.kind == BrowserFieldKind.none && c.field.value == BrowserFieldKind.none) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.browserNoField)));
      return;
    }
    final kind = field.kind != BrowserFieldKind.none ? field.kind : c.field.value;
    await c.hideKeyboard();
    if (!mounted) return;
    final result = await showBrowserTextEntry(
      context,
      initial: kind == BrowserFieldKind.password ? '' : field.value,
      label: field.label,
      password: kind == BrowserFieldKind.password,
      number: kind == BrowserFieldKind.number,
    );
    _pageFocus.requestFocus();
    if (result == null) {
      c.focus();
      return;
    }
    await c.insertText(result.text, submit: result.submit);
  }

  // --- back ------------------------------------------------------------------------

  Future<void> _back() async {
    final c = _c;
    if (c == null) {
      Navigator.of(context).pop();
      return;
    }
    if (c.fullscreen.value) return c.exitFullscreen();
    if (_menuOpen) return _closeMenu();
    if (c.field.value != BrowserFieldKind.none) return _leaveField();
    if (await c.goBack()) return;
    if (!mounted) return;
    final l = context.l10n;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.browserLeaveTitle),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: Text(l.browserStay)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l.browserLeave)),
        ],
      ),
    );
    if (leave == true && mounted) {
      Navigator.of(context).pop();
    } else {
      _pageFocus.requestFocus();
      c.focus();
    }
  }

  // --- the bar -------------------------------------------------------------------

  void _openMenu() {
    _pointer.releaseAll();
    _hideHint();
    setState(() => _menuOpen = true);
  }

  void _closeMenu() {
    if (!_menuOpen) return;
    setState(() => _menuOpen = false);
    _pageFocus.requestFocus();
    _c?.focus();
  }

  Future<void> _editAddress() async {
    final c = _c;
    if (c == null) return;
    final settings = ref.read(browserSettingsProvider);
    final text = await showTextInputDialog(
      context,
      title: context.l10n.browserAddress,
      initialValue: c.url.value,
      hint: context.l10n.browserAddressHint,
      keyboardType: TextInputType.url,
    );
    if (text == null || text.isEmpty) return;
    _closeMenu();
    await c.loadUrl(browserUrlFor(text, settings.searchEngine));
  }

  Future<void> _bookmarks() async {
    final notifier = ref.read(browserSettingsProvider.notifier);
    final url = await showBrowserBookmarks(
      context,
      bookmarks: () => ref.read(browserSettingsProvider).bookmarks,
      onRemove: notifier.removeBookmark,
    );
    if (url == null) return;
    _closeMenu();
    await _c?.loadUrl(url);
  }

  Future<void> _settings() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BrowserSettingsScreen()));
    // A blocker change applies to the page after a reload.
    await _c?.reload();
  }

  Future<void> _setTextZoom(int step) async {
    const steps = BrowserSettings.textZoomSteps;
    final s = ref.read(browserSettingsProvider);
    var i = steps.indexOf(s.textZoom);
    if (i < 0) i = steps.indexOf(100);
    final next = steps[(i + step).clamp(0, steps.length - 1)];
    await ref.read(browserSettingsProvider.notifier).update((s) => s.copyWith(textZoom: next));
    await _c?.setTextZoom(next);
  }

  Widget _bar(BrowserViewController c) {
    final l = context.l10n;
    final settings = ref.watch(browserSettingsProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([c.url, c.title, c.canGoBack, c.canGoForward, c.blocked]),
      builder: (context, _) {
        final url = c.url.value;
        final host = browserHostOf(url);
        final siteOff = host.isNotEmpty && settings.allowlist.contains(host);
        final bookmarked = settings.bookmarks.any((b) => b.url == url);
        final blockerLabel = !settings.blocker
            ? l.browserBlockerOff
            : (siteOff ? l.browserBlockerSiteOff : l.browserBlockedCount(c.blocked.value));
        return Material(
          color: const Color(0xEE15181A),
          elevation: 8,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      BrowserBarButton(
                        icon: Icons.arrow_back,
                        tooltip: l.browserBack,
                        onPressed: c.canGoBack.value ? c.goBack : null,
                      ),
                      BrowserBarButton(
                        icon: Icons.arrow_forward,
                        tooltip: l.browserForward,
                        onPressed: c.canGoForward.value ? c.goForward : null,
                      ),
                      BrowserBarButton(icon: Icons.refresh, tooltip: l.browserReload, onPressed: c.reload),
                      BrowserBarButton(
                        icon: Icons.home_outlined,
                        tooltip: l.browserHome,
                        onPressed: () {
                          _closeMenu();
                          c.loadUrl(settings.home);
                        },
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: BrowserAddressButton(
                          url: url,
                          title: c.title.value,
                          autofocus: true,
                          onPressed: _editAddress,
                        ),
                      ),
                      const SizedBox(width: 6),
                      BrowserBarButton(
                        icon: Icons.close,
                        tooltip: l.browserClose,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        BrowserBarButton(
                          icon: bookmarked ? Icons.star : Icons.star_border,
                          tooltip: bookmarked ? l.browserBookmarkRemove : l.browserBookmarkAdd,
                          active: bookmarked,
                          onPressed: url.startsWith('http')
                              ? () => ref.read(browserSettingsProvider.notifier).toggleBookmark(url, c.title.value)
                              : null,
                        ),
                        BrowserBarButton(
                          icon: Icons.bookmarks_outlined,
                          tooltip: l.browserBookmarks,
                          label: l.browserBookmarks,
                          onPressed: _bookmarks,
                        ),
                        BrowserBarButton(
                          icon: settings.blocker && !siteOff ? Icons.shield : Icons.shield_outlined,
                          tooltip: siteOff ? l.browserBlockerSiteOn : l.browserBlockerSiteOff,
                          label: blockerLabel,
                          active: settings.blocker && !siteOff,
                          onPressed: settings.blocker && host.isNotEmpty
                              ? () async {
                                  await ref.read(browserSettingsProvider.notifier).setAllowed(host, !siteOff);
                                  await c.reload();
                                }
                              : null,
                        ),
                        BrowserBarButton(
                          icon: Icons.desktop_windows_outlined,
                          tooltip: l.browserDesktop,
                          label: l.browserDesktop,
                          active: settings.desktop,
                          onPressed: () async {
                            final on = !settings.desktop;
                            await ref.read(browserSettingsProvider.notifier).update((s) => s.copyWith(desktop: on));
                            await c.setDesktop(on);
                          },
                        ),
                        BrowserBarButton(icon: Icons.text_decrease, tooltip: l.browserSmaller, onPressed: () => _setTextZoom(-1)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(l.browserTextSize(settings.textZoom),
                              style: const TextStyle(color: Colors.white70, fontSize: 14)),
                        ),
                        BrowserBarButton(icon: Icons.text_increase, tooltip: l.browserLarger, onPressed: () => _setTextZoom(1)),
                        BrowserBarButton(
                          icon: Icons.settings_outlined,
                          tooltip: l.browserSettings,
                          label: l.browserSettings,
                          onPressed: _settings,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // --- build ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    _dpr = MediaQuery.devicePixelRatioOf(context);
    if (!BrowserChannel.supported) {
      return Scaffold(
        appBar: AppBar(title: Text(l.browserTitle)),
        body: Center(child: Text(l.browserAndroidOnly, textAlign: TextAlign.center)),
      );
    }
    final start = _start;
    final c = _c;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: start == null
            ? const SizedBox.shrink()
            : Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = constraints.biggest;
                        if (size != _pageSize) {
                          _pageSize = size;
                          // Not during layout: the pointer's painter listens.
                          WidgetsBinding.instance.addPostFrameCallback((_) => _pointer.setBounds(size));
                        }
                        return Focus(
                          focusNode: _pageFocus,
                          autofocus: true,
                          onKeyEvent: _onKey,
                          child: Listener(
                            // A touch hides the remote's pointer until the next key.
                            onPointerDown: (e) {
                              if (e.kind == PointerDeviceKind.touch) _pointer.visible = false;
                              _hideHint();
                            },
                            child: AndroidView(
                              viewType: BrowserChannel.viewType,
                              layoutDirection: TextDirection.ltr,
                              creationParams: {
                                'url': _startUrl,
                                'desktop': start.desktop,
                                'textZoom': start.textZoom,
                              },
                              creationParamsCodec: const StandardMessageCodec(),
                              onPlatformViewCreated: _onCreated,
                              gestureRecognizers: {
                                Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (c != null && !c.fullscreen.value) Positioned.fill(child: BrowserPointerOverlay(pointer: _pointer)),
                  if (c != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: c.loading,
                        builder: (context, loading, _) => loading
                            ? ValueListenableBuilder<int>(
                                valueListenable: c.progress,
                                builder: (context, p, _) => LinearProgressIndicator(
                                  value: p <= 0 || p >= 100 ? null : p / 100,
                                  minHeight: 3,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  if (c != null && c.field.value != BrowserFieldKind.none && !_menuOpen)
                    _Hint(text: l.browserFieldHint),
                  if (c != null && _showHint && !_menuOpen && c.field.value == BrowserFieldKind.none)
                    _Hint(text: l.browserPointerHint),
                  if (c != null && _menuOpen)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: FocusScope(
                        node: _menuFocus,
                        autofocus: true,
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent && _isMenuKey(event.logicalKey)) {
                            _closeMenu();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: FocusTraversalGroup(child: _bar(c)),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 24,
      right: 24,
      bottom: 24,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(color: const Color(0xDD15181A), borderRadius: BorderRadius.circular(22)),
            child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ),
      ),
    );
  }
}
