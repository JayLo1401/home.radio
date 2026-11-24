import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/launcher/launcher_navigation.dart';
import 'features/launcher/launcher_providers.dart' show appNavigatorKey;
import 'features/splash/splash_screen.dart';

/// Home System: the launcher with Radio and TV as its parts (and
/// the device's apps on Android).
class HomeSystemApp extends ConsumerWidget {
  const HomeSystemApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uiScale = ref.watch(uiScaleProvider);
    return MaterialApp(
      title: 'Home System',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildTvTheme(),
      builder: (context, child) => _PcKeys(child: _UiScaleWrapper(scale: uiScale, child: child!)),
      home: const SplashScreen(),
    );
  }
}

/// The remote's Back and Home keys on the PC (Windows/Linux): Esc (and the
/// mouse's back button) goes back - from Radio and TV to the
/// launcher -, Pos1 opens the launcher. On Android the remote's own keys do
/// it.
class _PcKeys extends ConsumerWidget {
  const _PcKeys({required this.child});

  final Widget child;

  static final bool _pc = !kIsWeb && (Platform.isWindows || Platform.isLinux);

  /// Typing in a text field: Pos1 moves the cursor there.
  static bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_pc) return child;
    // Key events bubble up from the focused widget: whatever handles Esc or
    // Pos1 itself gets it first.
    return Listener(
      onPointerDown: (event) {
        if (event.buttons & kBackMouseButton != 0) appNavigatorKey.currentState?.maybePop();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            appNavigatorKey.currentState?.maybePop();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.home && !_typing) {
            showLauncher(ref);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: child,
      ),
    );
  }
}

/// Applies the user-configurable global UI scale by rendering into a larger
/// (or smaller) virtual canvas than the physical screen and then visually
/// scaling that canvas back to fit - equivalent to a zoom level, so every
/// screen's widgets shrink/grow together without per-widget scaling logic.
class _UiScaleWrapper extends StatelessWidget {
  final double scale;
  final Widget child;

  const _UiScaleWrapper({required this.scale, required this.child});

  @override
  Widget build(BuildContext context) {
    if ((scale - 1.0).abs() < 0.001) return child;
    final mediaQuery = MediaQuery.of(context);
    final physicalSize = mediaQuery.size;
    // scale < 1 means "smaller elements": lay widgets out on a larger
    // virtual canvas (more logical pixels), then visually shrink that whole
    // canvas back down to exactly fill the physical screen.
    final virtualSize = physicalSize / scale;
    return MediaQuery(
      data: mediaQuery.copyWith(size: virtualSize),
      // OverflowBox is required so the (larger) virtual-size child isn't
      // clamped back down to the physical screen's tight constraints before
      // Transform.scale ever gets a chance to compress it - without this,
      // the child stays physicalSize, gets shrunk on top of that, and the
      // result is a fully-visible-but-tiny UI with black bars around it.
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: virtualSize.width,
        maxWidth: virtualSize.width,
        minHeight: virtualSize.height,
        maxHeight: virtualSize.height,
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: virtualSize.width,
            height: virtualSize.height,
            child: child,
          ),
        ),
      ),
    );
  }
}
