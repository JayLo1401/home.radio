import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

/// Weather radar from a configurable URL - the radar itself is no longer
/// drawn in the app (it runs as its own server, see
/// github.com/JayLo1401/weather.radar), so any radar source works: a plain
/// image, or with [isWebPage] a web page (e.g. an interactive radar map) in
/// an embedded browser.
///
/// The URL may contain placeholders, filled in per request: `{lat}`, `{lon}`
/// (the configured location), `{r}` (radius in km), `{zoom}` (the web-map
/// zoom level showing about that radius), `{w}`, `{h}` (the tile's size in
/// physical pixels) and `{scale}` (device pixel ratio). With a [token], it's
/// sent as `Authorization: Bearer <token>`.
class RadarPanel extends StatefulWidget {
  const RadarPanel({
    super.key,
    required this.urlTemplate,
    this.isWebPage = false,
    this.webCss = '',
    this.token,
    required this.lat,
    required this.lon,
    this.radiusKm = 50,
    this.dimming = 0.0,
  });

  final String urlTemplate;
  final bool isWebPage;

  /// The user's own CSS for a web page (see [isWebPage]) - e.g. to hide
  /// parts of it, like a user stylesheet in a browser.
  final String webCss;
  final String? token;
  final double lat;
  final double lon;

  /// Distance (km) from the location to the top/bottom edge of the map.
  final double radiusKm;

  /// 0.0 = no dimming, 1.0 = fully black; a plain overlay so the intensity
  /// colours keep their meaning.
  final double dimming;

  static String buildUrl(
    String template, {
    required double lat,
    required double lon,
    required double radiusKm,
    required int width,
    required int height,
    required double scale,
  }) =>
      template
          .trim()
          .replaceAll('{lat}', lat.toStringAsFixed(4))
          .replaceAll('{lon}', lon.toStringAsFixed(4))
          .replaceAll('{r}', radiusKm.round().toString())
          .replaceAll('{zoom}', '${zoomFor(lat: lat, radiusKm: radiusKm, logicalHeight: height / scale)}')
          .replaceAll('{w}', '$width')
          .replaceAll('{h}', '$height')
          .replaceAll('{scale}', scale.toStringAsFixed(2));

  /// The usual web-map zoom level (256 px tiles, Web Mercator) at which
  /// [logicalHeight] pixels span about 2 x [radiusKm] at [lat].
  static int zoomFor({required double lat, required double radiusKm, required double logicalHeight}) {
    final metersPerPixel = 2000 * radiusKm / logicalHeight;
    final zoom = math.log(156543.03 * math.cos(lat * math.pi / 180) / metersPerPixel) / math.ln2;
    return zoom.round().clamp(3, 18);
  }

  @override
  State<RadarPanel> createState() => _RadarPanelState();
}

class _RadarPanelState extends State<RadarPanel> {
  static const _refreshInterval = Duration(seconds: 150);

  ui.Image? _image;
  DateTime? _loadedAt;
  String? _error;
  String? _url;
  Timer? _timer;
  bool _loading = false;
  int _failedAttempts = 0;

  @override
  void didUpdateWidget(covariant RadarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same URL but different credentials - load again on the next build.
    if (oldWidget.token != widget.token) _url = null;
    // Switched to a web page: stop loading images in the background.
    if (widget.isWebPage && !oldWidget.isWebPage) {
      _timer?.cancel();
      _url = null;
      _image?.dispose();
      _image = null;
      _error = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  /// Called during build with the URL for the current size - a new URL
  /// (size, location or setting changed) loads right away.
  void _setUrl(String url) {
    if (url == _url) return;
    _url = url;
    _failedAttempts = 0;
    // Deferred: this is called during build.
    scheduleMicrotask(_load);
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _load);
  }

  Future<void> _load() async {
    final url = _url;
    if (url == null || _loading || !mounted) return;
    _loading = true;
    try {
      final token = widget.token;
      final response = await http
          .get(Uri.parse(url), headers: {
            'User-Agent': 'home_radio/1.0',
            if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
          })
          // Generous: a radar server may need 20-30 s to gather the data
          // for an area it hasn't served before.
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw Exception(response.statusCode == 401 || response.statusCode == 403
            ? 'Anmeldung abgelehnt (HTTP ${response.statusCode})'
            : 'HTTP ${response.statusCode}');
      }
      if ((response.headers['content-type'] ?? '').contains('text/html')) {
        throw Exception('die Adresse ist eine Webseite, kein Bild - als Art „Webseite“ wählen');
      }
      final codec = await ui.instantiateImageCodec(response.bodyBytes);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      if (!mounted || url != _url) {
        image.dispose();
        return;
      }
      // The previous image is freed right away rather than left to the
      // garbage collector - on a TV box running for days, a new GPU texture
      // every few minutes otherwise piles up. Safe while a frame still shows
      // it: a picture keeps its own reference to the underlying image.
      final old = _image;
      setState(() {
        _image = image;
        _loadedAt = DateTime.now();
        _error = null;
      });
      old?.dispose();
      _failedAttempts = 0;
      _scheduleNext(_refreshInterval);
    } catch (e) {
      debugPrint('RadarPanel: $url failed: $e');
      if (!mounted || url != _url) return;
      setState(() => _error = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e');
      // 10s, 20s, 40s, ... capped at the normal refresh interval.
      final delaySeconds = (10 * (1 << _failedAttempts)).clamp(10, _refreshInterval.inSeconds);
      _failedAttempts = (_failedAttempts + 1).clamp(0, 4);
      _scheduleNext(Duration(seconds: delaySeconds));
    } finally {
      _loading = false;
      // The URL changed while this one was loading.
      if (mounted && _url != url) unawaited(_load());
    }
  }

  String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    const hint = TextStyle(color: Colors.white54, fontSize: 12);
    if (widget.urlTemplate.trim().isEmpty) {
      return const ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Kein Wetterradar eingerichtet -\nEinstellungen → Wetterradar → Quelle',
              textAlign: TextAlign.center,
              style: hint,
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
        final url = RadarPanel.buildUrl(
          widget.urlTemplate,
          lat: widget.lat,
          lon: widget.lon,
          radiusKm: widget.radiusKm,
          width: (size.width * dpr).round(),
          height: (size.height * dpr).round(),
          scale: dpr,
        );
        // webview_flutter only exists on Android here.
        if (widget.isWebPage && !Platform.isAndroid) {
          return const ColoredBox(
            color: Colors.black54,
            child: Center(
              child: Text(
                'Webseiten als Radarquelle gibt es nur in der Android-Version.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ),
          );
        }
        if (widget.isWebPage) {
          return Stack(
            fit: StackFit.expand,
            children: [
              _RadarWebView(url: url, token: widget.token, css: widget.webCss),
              if (widget.dimming > 0)
                IgnorePointer(child: Container(color: Colors.black.withValues(alpha: widget.dimming))),
            ],
          );
        }
        _setUrl(url);
        final image = _image;
        final error = _error;
        return ColoredBox(
          color: Colors.black54,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (image != null)
                RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium)
              else
                Center(
                  child: error != null
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('Radar nicht erreichbar: $error', textAlign: TextAlign.center, style: hint),
                        )
                      : const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                        ),
                ),
              // A stale image stays up while the source is unreachable,
              // with a small note so it isn't mistaken for the current one.
              if (image != null && error != null && _loadedAt != null)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      'Stand ${_hhmm(_loadedAt!)} · nicht erreichbar',
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ),
              if (widget.dimming > 0)
                IgnorePointer(child: Container(color: Colors.black.withValues(alpha: widget.dimming))),
            ],
          ),
        );
      },
    );
  }
}

/// A web page as the radar (e.g. an interactive radar map) in an embedded
/// browser. Display only: it takes neither touch nor D-Pad focus, so the
/// remote keeps working the home screen instead of getting stuck in the map.
/// Reloaded now and then in case the page itself stops updating.
class _RadarWebView extends StatefulWidget {
  const _RadarWebView({required this.url, this.token, this.css = ''});

  final String url;
  final String? token;

  /// The user's own CSS, added after every load - see
  /// SettingsRepository.getRadarWebCss.
  final String css;

  @override
  State<_RadarWebView> createState() => _RadarWebViewState();
}

class _RadarWebViewState extends State<_RadarWebView> {
  static const _reloadInterval = Duration(minutes: 15);

  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(Colors.black)
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) {
          _applyCss();
          if (mounted && _error != null) setState(() => _error = null);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame != true || !mounted) return;
          debugPrint('RadarPanel: ${widget.url} failed: ${error.description}');
          setState(() => _error = error.description);
        },
        onHttpError: (error) {
          final code = error.response?.statusCode;
          if (code == null || !mounted || error.request?.uri.toString() != widget.url) return;
          setState(() => _error = code == 401 || code == 403 ? 'Anmeldung abgelehnt (HTTP $code)' : 'HTTP $code');
        },
      ),
    );
  Timer? _timer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(_reloadInterval, (_) => _load());
  }

  @override
  void didUpdateWidget(covariant _RadarWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.token != widget.token) {
      _load();
    } else if (oldWidget.css != widget.css) {
      _applyCss();
    }
  }

  /// Puts [_RadarWebView.css] into a style element of its own (replacing
  /// the previous one), like a user stylesheet in a browser.
  void _applyCss() {
    const id = 'home-radio-user-css';
    unawaited(_controller
        .runJavaScript('(function(){var s=document.getElementById("$id");'
            'if(!s){s=document.createElement("style");s.id="$id";'
            '(document.head||document.documentElement).appendChild(s);}'
            's.textContent=${jsonEncode(widget.css)};})();')
        .catchError((Object e) => debugPrint('RadarPanel: CSS not applied: $e')));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _load() {
    final token = widget.token;
    unawaited(_controller.loadRequest(
      Uri.parse(widget.url),
      headers: {if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token'},
    ));
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(child: IgnorePointer(child: WebViewWidget(controller: _controller))),
        if (error != null)
          Positioned(
            left: 6,
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text(
                'Radar nicht erreichbar: $error',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
          ),
      ],
    );
  }
}
