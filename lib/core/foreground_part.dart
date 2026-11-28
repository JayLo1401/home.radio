import 'package:flutter/widgets.dart';

import '../data/models/launcher_tile.dart';
import '../features/browser/browser_screen.dart' show BrowserScreen;
import '../features/dashboard/dashboard_screen.dart' show DashboardScreen;
import '../features/home/home_screen.dart' show HomeScreen;
import '../features/launcher/launcher_screen.dart' show LauncherScreen;
import '../features/movies/movies_screen.dart' show MoviesScreen;
import '../features/music/music_screen.dart' show MusicScreen;
import '../features/pictures/pictures_screen.dart' show PicturesScreen;
import '../features/tv/tv_screen.dart' show TvScreen;

/// The launcher itself (see [ForegroundPartObserver.classify]) - no part.
const launcherKind = '';

/// Which of Home System's parts a page is: the LauncherTile type of its
/// tile (Radio's screen is the radio's), [launcherKind] for Home, null for
/// any other page (settings, a film's player ...) - it belongs to the page
/// under it.
String? homeSystemPartOf(Widget page) => switch (page) {
      HomeScreen() => LauncherTile.radioType,
      TvScreen() => LauncherTile.tvType,
      DashboardScreen() => LauncherTile.dashboardType,
      PicturesScreen() => LauncherTile.picturesType,
      MoviesScreen() => LauncherTile.moviesType,
      MusicScreen() => LauncherTile.musicType,
      BrowserScreen() => LauncherTile.browserType,
      LauncherScreen() => launcherKind,
      _ => null,
    };

/// Follows the app's navigator and tells which part is on screen ([part]:
/// a LauncherTile type, null on Home or before the start) - for Home
/// Assistant's switches per app. Cheap: a page is looked at once, a few
/// widgets deep, after the frame that built it; dialogs over a part leave
/// it in front.
class ForegroundPartObserver extends NavigatorObserver {
  ForegroundPartObserver({this.classify = homeSystemPartOf});

  /// See [homeSystemPartOf].
  final String? Function(Widget page) classify;

  final part = ValueNotifier<String?>(null);

  final _routes = <Route<dynamic>>[];

  /// What a page was found to be; [_other] for none of the parts.
  final _kinds = Expando<String>();
  static const _other = '?';

  /// How deep a page's widget lies under its route (Builder, Semantics ...).
  static const _depth = 6;

  bool _scheduled = false;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (newRoute != null) {
      if (i >= 0) {
        _routes[i] = newRoute;
      } else {
        _routes.add(newRoute);
      }
    } else if (i >= 0) {
      _routes.removeAt(i);
    }
    _changed();
  }

  /// A new page is built in the next frame - it's looked at after that.
  void _changed({bool retry = false}) {
    if (!retry) _retries = 0;
    if (_scheduled) return;
    _scheduled = true;
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        update();
      });
      WidgetsBinding.instance.scheduleFrame();
    } catch (e) {
      _scheduled = false;
      debugPrint('ForegroundPartObserver: $e');
    }
  }

  /// Looks again now (tests; otherwise after each change by itself).
  @visibleForTesting
  void update() {
    String? found;
    for (final route in _routes.reversed) {
      // Dialogs and menus: the part under them stays in front.
      if (route is! PageRoute) continue;
      if (route.subtreeContext == null && _kinds[route] == null && _retries < 10) {
        // On top but not built yet: a frame later (the part shown stays
        // until then rather than flicker to the page underneath).
        _retries++;
        _changed(retry: true);
        return;
      }
      final kind = _kindOf(route);
      if (kind != null) {
        found = kind;
        break;
      }
    }
    _retries = 0;
    part.value = found == null || found == launcherKind ? null : found;
  }

  int _retries = 0;

  String? _kindOf(PageRoute<dynamic> route) {
    final known = _kinds[route];
    if (known != null) return known == _other ? null : known;
    final context = route.subtreeContext;
    // Not built yet - looked at again after the next frame.
    if (context is! Element) return null;
    String? kind;
    void visit(Element element, int depth) {
      if (kind != null) return;
      kind = classify(element.widget);
      if (kind == null && depth < _depth) element.visitChildElements((child) => visit(child, depth + 1));
    }

    try {
      visit(context, 0);
    } catch (e) {
      debugPrint('ForegroundPartObserver: $e');
    }
    _kinds[route] = kind ?? _other;
    return kind;
  }
}

/// The one for the app's navigator (MaterialApp.navigatorObservers).
final foregroundPartObserver = ForegroundPartObserver();
