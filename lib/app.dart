import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/splash/splash_screen.dart';

class HomeRadioApp extends ConsumerWidget {
  const HomeRadioApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uiScale = ref.watch(uiScaleProvider);
    return MaterialApp(
      title: 'Home Radio',
      debugShowCheckedModeBanner: false,
      theme: buildTvTheme(),
      builder: (context, child) => _UiScaleWrapper(scale: uiScale, child: child!),
      home: const SplashScreen(),
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
