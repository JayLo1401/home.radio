import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The browser's Android side (browser/BrowserPlugin.kt): what's the same
/// for every page.
abstract final class BrowserChannel {
  static const _channel = MethodChannel('home_system/browser');

  /// Only Android has the browser (the device's System WebView).
  static final bool supported = !kIsWeb && Platform.isAndroid;

  static const viewType = 'home_system/browser_view';

  static Future<bool> loadFilters(String path) async {
    try {
      return await _channel.invokeMethod<bool>('loadFilters', {'path': path}) ?? false;
    } catch (e) {
      debugPrint('browser loadFilters: $e');
      return false;
    }
  }

  static Future<void> setBlocking({required bool enabled, required Set<String> allowlist}) async {
    try {
      await _channel.invokeMethod('setBlocking', {'enabled': enabled, 'allowlist': allowlist.toList()});
    } catch (e) {
      debugPrint('browser setBlocking: $e');
    }
  }

  static Future<void> clearData({bool cookies = false, bool cache = false}) =>
      _channel.invokeMethod('clearData', {'cookies': cookies, 'cache': cache});

  static Future<String?> webViewVersion() async {
    try {
      return await _channel.invokeMethod<String>('webViewVersion');
    } catch (_) {
      return null;
    }
  }
}

/// What kind of text field has focus in the page ('' none).
enum BrowserFieldKind {
  none,
  input,
  multi,
  password,
  number;

  static BrowserFieldKind parse(String? s) =>
      BrowserFieldKind.values.firstWhere((k) => k.name == s, orElse: () => BrowserFieldKind.none);
}

/// The focused field as the page has it (for "Text eingeben").
class BrowserField {
  const BrowserField({required this.reachable, this.kind = BrowserFieldKind.none, this.value = '', this.label = ''});

  /// Inside a frame of another site the script can't read it.
  final bool reachable;
  final BrowserFieldKind kind;
  final String value;
  final String label;
}

/// One page's channel (browser/BrowserView.kt).
class BrowserViewController {
  BrowserViewController(int id) : _channel = MethodChannel('home_system/browser_view_$id') {
    _channel.setMethodCallHandler(_onEvent);
  }

  final MethodChannel _channel;

  final url = ValueNotifier('');
  final title = ValueNotifier('');
  final loading = ValueNotifier(true);
  final progress = ValueNotifier(0);
  final canGoBack = ValueNotifier(false);
  final canGoForward = ValueNotifier(false);
  final blocked = ValueNotifier(0);
  final field = ValueNotifier(BrowserFieldKind.none);
  final mediaPlaying = ValueNotifier(false);
  final fullscreen = ValueNotifier(false);

  /// Downloads the page asked for (not supported - the screen says so).
  final downloads = StreamController<String>.broadcast();

  /// Whether WebView runs our script at document start (else at page start).
  bool documentStart = true;

  bool _disposed = false;

  Future<Object?> _onEvent(MethodCall call) async {
    if (_disposed) return null;
    final args = call.arguments;
    switch (call.method) {
      case 'page':
        if (args is Map) {
          url.value = '${args['url'] ?? ''}';
          title.value = '${args['title'] ?? ''}';
          progress.value = (args['progress'] as int?) ?? progress.value;
          canGoBack.value = args['canGoBack'] == true;
          canGoForward.value = args['canGoForward'] == true;
          blocked.value = (args['blocked'] as int?) ?? blocked.value;
          documentStart = args['documentStart'] != false;
          if (args['loading'] is bool) loading.value = args['loading'] as bool;
        }
      case 'progress':
        progress.value = args as int;
        if (progress.value >= 100) loading.value = false;
      case 'blocked':
        blocked.value = args as int;
      case 'editing':
        field.value = BrowserFieldKind.parse(args as String?);
      case 'media':
        mediaPlaying.value = args == true;
      case 'fullscreen':
        fullscreen.value = args == true;
      case 'download':
        if (args is Map) downloads.add('${args['url']}');
    }
    return null;
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (_disposed) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('browser $method: $e');
      return null;
    }
  }

  Future<void> loadUrl(String url) => _call('loadUrl', {'url': url});
  Future<bool> goBack() async => await _call<bool>('goBack') ?? false;
  Future<bool> goForward() async => await _call<bool>('goForward') ?? false;
  Future<void> reload() => _call('reload');
  Future<void> stop() => _call('stop');
  Future<void> setDesktop(bool on) => _call('setDesktop', {'on': on});
  Future<void> setTextZoom(int percent) => _call('setTextZoom', {'percent': percent});

  /// Physical pixels within the page.
  Future<void> hover(Offset at) => _call('hover', {'x': at.dx, 'y': at.dy});
  Future<void> tap(Offset at) => _call('tap', {'x': at.dx, 'y': at.dy});
  Future<void> scroll(Offset at, Offset by) => _call('scroll', {'x': at.dx, 'y': at.dy, 'dx': by.dx, 'dy': by.dy});

  Future<void> focus() => _call('focus');
  Future<void> showKeyboard() => _call('showKeyboard');
  Future<void> hideKeyboard() => _call('hideKeyboard');
  Future<bool> keyboardShown() async => await _call<bool>('keyboardShown') ?? false;

  /// 'toggle', 'play', 'pause', 'seek' (+[seconds]); false if the page has no video.
  Future<bool> media(String action, {double seconds = 0}) async =>
      await _call<bool>('media', {'action': action, 'seconds': seconds}) ?? false;

  Future<BrowserField> focusedField() async {
    final raw = await _call<String>('field');
    if (raw == null) return const BrowserField(reachable: false);
    try {
      final m = jsonDecode(raw) as Map;
      return BrowserField(
        reachable: m['reach'] == true,
        kind: BrowserFieldKind.parse(m['kind'] as String?),
        value: '${m['value'] ?? ''}',
        label: '${m['label'] ?? ''}',
      );
    } catch (_) {
      return const BrowserField(reachable: false);
    }
  }

  Future<bool> insertText(String text, {bool submit = false}) async =>
      await _call<bool>('insertText', {'text': text, 'submit': submit}) ?? false;

  Future<void> blurField() => _call('blurField');
  Future<void> exitFullscreen() => _call('exitFullscreen');
  Future<void> pause() => _call('pause');
  Future<void> resume() => _call('resume');

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    downloads.close();
    for (final n in [url, title, loading, progress, canGoBack, canGoForward, blocked, field, mediaPlaying, fullscreen]) {
      n.dispose();
    }
  }
}
