import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import 'launcher_providers.dart';
import 'launcher_screen.dart';

const _launcherRouteName = '/launcher';

/// Opens the launcher over Radio (closing whatever else is open on top
/// of it) - or, when it's already open, goes back to it.
void showLauncher(WidgetRef ref) => showLauncherWith(ref.read);

/// Reads a provider - [WidgetRef.read] or [Ref.read], for code outside
/// the widgets (Home Assistant's commands).
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// [showLauncher] with any [read].
void showLauncherWith(ProviderReader read) {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  if (read(launcherVisibleProvider)) {
    nav.popUntil((r) => r.settings.name == _launcherRouteName || r.isFirst);
    return;
  }
  nav.popUntil((r) => r.isFirst);
  read(launcherVisibleProvider.notifier).set(true);
  final visible = read(launcherVisibleProvider.notifier);
  nav
      .push(
        PageRouteBuilder<void>(
          settings: const RouteSettings(name: _launcherRouteName),
          transitionDuration: const Duration(milliseconds: 250),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (_, _, _) => const LauncherScreen(),
          transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
        ),
      )
      .whenComplete(() => visible.set(false));
}

/// Back to Radio (the launcher's "Radio" tile).
void hideLauncher(WidgetRef ref) => hideLauncherWith(ref.read);

/// [hideLauncher] with any [read].
void hideLauncherWith(ProviderReader read) {
  final nav = appNavigatorKey.currentState;
  if (nav == null || !read(launcherVisibleProvider)) return;
  nav.popUntil((r) => r.isFirst);
}
