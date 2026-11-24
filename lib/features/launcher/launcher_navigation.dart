import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'launcher_providers.dart';
import 'launcher_screen.dart';

const _launcherRouteName = '/launcher';

/// Opens the launcher over Radio (closing whatever else is open on top
/// of it) - or, when it's already open, goes back to it.
void showLauncher(WidgetRef ref) {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  if (ref.read(launcherVisibleProvider)) {
    nav.popUntil((r) => r.settings.name == _launcherRouteName || r.isFirst);
    return;
  }
  nav.popUntil((r) => r.isFirst);
  ref.read(launcherVisibleProvider.notifier).set(true);
  final visible = ref.read(launcherVisibleProvider.notifier);
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
void hideLauncher(WidgetRef ref) {
  final nav = appNavigatorKey.currentState;
  if (nav == null || !ref.read(launcherVisibleProvider)) return;
  nav.popUntil((r) => r.isFirst);
}
