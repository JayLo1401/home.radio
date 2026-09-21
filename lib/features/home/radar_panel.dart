import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Embeds the wo-cloud interactive rain radar (the same widget/URL used at
/// e.g. https://radar.wo-cloud.com/desktop/wr/interactive) centered on
/// [lat]/[lon]. No public API exists for this radar - it's a full
/// interactive map product, so a webview embed (as originally planned) is
/// the only practical option, unlike the hourly forecast (see WeatherPanel)
/// which has a real data API to build a native UI on top of.
class RadarPanel extends StatefulWidget {
  const RadarPanel({super.key, required this.lat, required this.lon, this.zoom = 9, this.dimming = 0.0});

  final double lat;
  final double lon;
  final int zoom;

  /// 0.0 = no dimming, 1.0 = fully black. A plain overlay rather than a
  /// CSS/colour-invert dark mode, which would risk distorting the map's own
  /// precipitation-intensity colour coding - see WeatherDisplaySettings'
  /// doc comment for why.
  final double dimming;

  @override
  State<RadarPanel> createState() => _RadarPanelState();
}

class _RadarPanelState extends State<RadarPanel> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            debugPrint('DabProbe: RadarPanel loaded $url');
            _controller.runJavaScript(_hideControlsJs);
          },
          onWebResourceError: (error) => debugPrint(
            'DabProbe: RadarPanel error: ${error.errorCode} ${error.description} (${error.url})',
          ),
        ),
      )
      ..loadRequest(_radarUri(widget.lat, widget.lon, widget.zoom));
  }

  /// wo-cloud's own on-map UI chrome (zoom +/-, layer switcher, the bottom
  /// time-scrubber/playback bar, the fullscreen toggle, the legend/info
  /// button, the distance scale bar and the "Impressum" link) - identified
  /// via a headless-Chrome DOM dump of the live page (2026-09-21), since
  /// it's an Angular SPA and nothing in its shipped bundles is visible from
  /// the raw HTML/CSS alone. These are Angular custom-element tag names, not
  /// generated/obfuscated class names, so they're stable across the app's
  /// own minified builds. Injected as a stylesheet (not removed from the
  /// DOM) so it keeps applying as Angular renders the page after this
  /// point, and so the underlying widget stays fully functional (e.g.
  /// pinch-zoom gestures) - only its own drawn controls disappear.
  ///
  /// The top-left clock badge is deliberately kept - it's how you can tell
  /// the radar frame on screen is actually current, not a stale/cached one
  /// - but its little drag-to-scrub mini-timeline underneath the time text
  /// is itself a control, so just that part is hidden and the badge is made
  /// non-interactive (`pointer-events: none`) so it can't be dragged.
  static const _hideControlsJs = '''
    (function() {
      var css = 'wo-control-container.top-right,'
        + 'wo-control-container.bottom,'
        + 'wo-distance-indicator,'
        + '.wo-imprint { display: none !important; }'
        + 'wo-control-container.top-left wo-time-control-slider { display: none !important; }'
        + 'wo-control-container.top-left { pointer-events: none !important; }';
      var style = document.createElement('style');
      style.textContent = css;
      document.head.appendChild(style);
    })();
  ''';

  @override
  void didUpdateWidget(covariant RadarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lat != widget.lat || oldWidget.lon != widget.lon || oldWidget.zoom != widget.zoom) {
      _controller.loadRequest(_radarUri(widget.lat, widget.lon, widget.zoom));
    }
  }

  Uri _radarUri(double lat, double lon, int zoom) {
    return Uri.parse(
      'https://radar.wo-cloud.com/desktop/wr/interactive'
      '?wrx=$lat,$lon&wrm=$zoom&timeZone=Europe/Vienna',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      child: Stack(
        fit: StackFit.expand,
        children: [
          WebViewWidget(controller: _controller),
          if (widget.dimming > 0)
            IgnorePointer(
              child: Container(color: Colors.black.withValues(alpha: widget.dimming)),
            ),
        ],
      ),
    );
  }
}
