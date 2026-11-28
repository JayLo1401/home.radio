import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'enigma2_service.dart' show Enigma2Config;
import 'hbbtv_ait.dart';

/// What the red key starts on a channel.
class HbbtvLaunch {
  const HbbtvLaunch({required this.app, this.apps = const [], this.fromAit = true});

  final HbbtvApp app;

  /// Every application the AIT offers (for "dvb://current.ait/..." links
  /// between them).
  final List<HbbtvApp> apps;

  /// From the channel's own signalling - else from [hbbtvFallbackUrl].
  final bool fromAit;

  String get url => app.url!;
}

/// HbbTV's user agent: what the portals look for to serve their TV app
/// (HbbTV 1.5.1 = HbbTV 2.0.1). The WebView's own part stays in front.
const hbbtvUserAgentSuffix = 'HbbTV/1.5.1 (+DRM; JayCloud; HomeSystem; 1.0; 1.0;) CE-HTML/1.0 FVC/3.0';

String hbbtvUserAgent([String? webView]) {
  final base = (webView == null || webView.isEmpty)
      ? 'Mozilla/5.0 (Linux; Android 11; TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
      : webView;
  return '$base $hbbtvUserAgentSuffix';
}

/// Well-known start addresses of the big German-language channels' HbbTV
/// apps - only used if the stream brings no AIT. The addresses are the ones
/// these channels signal themselves in their AIT on Astra 19.2° E (read
/// from the broadcast in November 2026); the ARD and ZDF start apps serve
/// every channel of their group (they ask the broadcast object which one
/// runs).
const _fallback = <(String, String)>[
  // ARD: Das Erste, the regional channels, ONE, tagesschau24, ARD-alpha.
  (r'^(das ?erste|ard|one hd|one$|tagesschau ?24|br |br$|bayerisches|swr|wdr|mdr|ndr|rbb|hr[- ]|hr$|sr |radio bremen)',
      'http://itv.ard.de/ardstart/index.html'),
  (r'^zdf', 'http://hbbtv.zdf.de/zdfstart/index.php'),
  (r'^orf', 'http://orfhbbtv.orf.at/orf/redbutton/index.html'),
  (r'^servus', 'http://hbbtv.servustv.com/content/themes/hbbtv-theme/1-0/dist/index.html?stvat-hd-sat'),
  (r'^arte', 'http://www.arte.tv/hbbtvv2/index.html'),
];

/// The fallback start address for a channel by its name, null if none known.
String? hbbtvFallbackUrl(String channelName) {
  final name = channelName.trim().toLowerCase().replaceAll('_', ' ');
  for (final (pattern, url) in _fallback) {
    if (RegExp(pattern).hasMatch(name)) return url;
  }
  return null;
}

/// Finds a receiver channel's HbbTV app: the AIT from the channel's stream
/// (the running one if there is one - [tap] - else a short read of its own),
/// the [hbbtvFallbackUrl] table if the stream has none. Found apps are kept
/// per channel for the app's run.
class HbbtvFinder {
  HbbtvFinder._();

  static final _cache = <String, HbbtvLaunch?>{};

  static String _key(String ref) => ref.replaceAll(RegExp(r':+$'), '').toUpperCase();

  /// [tap]: the channel's stream as it runs (only listened to while
  /// looking). Null: no app at all.
  static Future<HbbtvLaunch?> find({
    required Enigma2Config config,
    required String serviceRef,
    required String channelName,
    Stream<List<int>>? tap,
  }) async {
    final key = _key(serviceRef);
    if (_cache.containsKey(key)) return _cache[key];
    final sid = DvbTriplet.fromServiceRef(serviceRef)?.sid;
    var result = tap == null ? null : await _scan(tap, sid, firstData: const Duration(seconds: 2));
    // Nothing on the running stream (paused, or no data yet): a read of its own.
    if (result == null || (result.state == AitScanState.searching && result.packets == 0)) {
      result = await _readOwn(config, serviceRef, sid);
    }
    HbbtvLaunch? launch;
    if (result != null && result.state == AitScanState.found) {
      final start = pickStartApp(result.apps);
      if (start != null) launch = HbbtvLaunch(app: start, apps: result.apps);
    }
    if (launch == null) {
      final url = hbbtvFallbackUrl(channelName);
      if (url != null) {
        launch = HbbtvLaunch(
          app: HbbtvApp(orgId: 0, appId: 0, controlCode: 1, name: channelName, url: url),
          apps: result?.apps ?? const [],
          fromAit: false,
        );
      }
    }
    // Kept: what the stream said (an AIT, or a PMT without one); a stream
    // that didn't come may come next time.
    if (result != null && result.state != AitScanState.searching) _cache[key] = launch;
    debugPrint('HbbTV $channelName: ${result?.state.name ?? 'kein Stream'} -> ${launch?.url}');
    return launch;
  }

  /// Forgets what was found (a new receiver).
  static void clear() => _cache.clear();

  /// Reads [stream] until the AIT is complete, the PMT says there's none,
  /// or time is up (PMT in [pmtWithin], the AIT - repeated every second or
  /// two - in [aitWithin]).
  static Future<AitScanner> _scan(
    Stream<List<int>> stream,
    int? sid, {
    Duration firstData = const Duration(seconds: 6),
    Duration pmtWithin = const Duration(seconds: 4),
    Duration aitWithin = const Duration(seconds: 7),
  }) async {
    final scanner = AitScanner(serviceId: sid);
    final done = Completer<void>();
    final clock = Stopwatch()..start();
    StreamSubscription<List<int>>? sub;
    Timer? timer;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    void check() {
      final t = clock.elapsed;
      if (scanner.packets == 0 && t >= firstData) return finish();
      if (scanner.packets > 0 && !scanner.pmtSeen && t >= pmtWithin) return finish();
      if (t >= aitWithin) finish();
    }

    try {
      sub = stream.listen(
        (chunk) {
          if (done.isCompleted) return;
          if (scanner.add(chunk) != AitScanState.searching) finish();
        },
        onError: (Object _) => finish(),
        onDone: finish,
        cancelOnError: true,
      );
      timer = Timer.periodic(const Duration(milliseconds: 250), (_) => check());
      await done.future;
    } catch (e) {
      debugPrint('HbbTV AIT: $e');
    } finally {
      timer?.cancel();
      unawaited(sub?.cancel().catchError((_) {}));
    }
    return scanner;
  }

  static Future<AitScanner?> _readOwn(Enigma2Config config, String serviceRef, int? sid) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', config.streamUri(serviceRef))..headers.addAll(config.authHeaders);
      final response = await client.send(request).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return await _scan(response.stream, sid);
    } catch (e) {
      debugPrint('HbbTV stream: $e');
      return null;
    } finally {
      client.close();
    }
  }
}

/// A page of an HbbTV app as the WebView gets it.
class HbbtvPage {
  const HbbtvPage({required this.url, required this.html});

  /// Where it came from after redirects (the base of its relative links).
  final Uri url;
  final String? html;

  /// Not a page (a video, an image ...) - the WebView loads it itself.
  bool get isDocument => html != null;
}

/// Fetches an HbbTV app's page itself: the portals send their pages as
/// "application/vnd.hbbtv.xhtml+xml", which Android's WebView doesn't take
/// as a web page - so the page goes to it as HTML with the HbbTV objects
/// ([shim]) in front of everything else.
Future<HbbtvPage> fetchHbbtvPage(Uri url, {required String userAgent, required String shim, http.Client? client}) async {
  final own = client == null;
  final c = client ?? http.Client();
  try {
    var current = url;
    for (var hop = 0; hop < 6; hop++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers['User-Agent'] = userAgent
        ..headers['Accept'] = 'application/vnd.hbbtv.xhtml+xml,application/xhtml+xml,text/html;q=0.9,*/*;q=0.8';
      final response = await c.send(request).timeout(const Duration(seconds: 15));
      final location = response.headers['location'];
      if (response.isRedirect || (response.statusCode >= 300 && response.statusCode < 400 && location != null)) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        if (location == null) break;
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        throw http.ClientException('HTTP ${response.statusCode}', current);
      }
      final type = (response.headers['content-type'] ?? '').toLowerCase();
      final document = type.isEmpty || type.contains('html') || type.contains('xml');
      if (!document) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        return HbbtvPage(url: current, html: null);
      }
      final bytes = await response.stream.toBytes().timeout(const Duration(seconds: 20));
      final latin1Page = type.contains('iso-8859-1') || type.contains('latin1') || type.contains('windows-1252');
      final text = latin1Page ? latin1.decode(bytes, allowInvalid: true) : utf8.decode(bytes, allowMalformed: true);
      return HbbtvPage(url: current, html: prepareHbbtvPage(text, shim));
    }
    throw http.ClientException('Zu viele Weiterleitungen', url);
  } finally {
    if (own) c.close();
  }
}

/// Elements without content - a "/>" there is right in HTML too.
const _voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr', //
};

/// the first script in `<head>`: the XML declaration goes, and `<div/>`,
/// `<object .../>` (closed in XHTML, opened in HTML) get their end tag -
/// "<object .../>" (closed in XHTML, opened in HTML) get their end tag -
/// outside scripts.
String prepareHbbtvPage(String page, String shim) {
  var html = page.replaceFirst(RegExp(r'^﻿?\s*<\?xml[^>]*\?>\s*'), '');
  final selfClosed = RegExp(r'<([a-zA-Z][\w:-]*)(\s[^<>]*?)?\s*/>');
  final script = RegExp(r'<script\b[\s\S]*?</script\s*>', caseSensitive: false);
  final out = StringBuffer();
  var last = 0;
  String fix(String part) => part.replaceAllMapped(selfClosed, (m) {
        final tag = m[1]!;
        if (_voidElements.contains(tag.toLowerCase())) return m[0]!;
        return '<$tag${m[2] ?? ''}></$tag>';
      });
  for (final m in script.allMatches(html)) {
    out
      ..write(fix(html.substring(last, m.start)))
      ..write(m[0]);
    last = m.end;
  }
  out.write(fix(html.substring(last)));
  html = out.toString();
  final tag = '<script type="text/javascript">\n$shim\n</script>';
  final head = RegExp(r'<head(\s[^>]*)?>', caseSensitive: false).firstMatch(html);
  if (head != null) return html.replaceRange(head.end, head.end, tag);
  final root = RegExp(r'<html(\s[^>]*)?>', caseSensitive: false).firstMatch(html);
  if (root != null) return html.replaceRange(root.end, root.end, '<head>$tag</head>');
  return '$tag$html';
}
