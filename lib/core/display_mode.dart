import 'dart:io';

import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Full screen on or off (settings "Vollbild"): on Android the system bars
/// hide (immersive, a swipe brings them back for a moment); on Windows/Linux
/// the window covers the whole screen - on Windows on monitor [monitor]
/// (1-based, as in the settings; out of range = the first).
Future<void> applyDisplayMode({required bool fullscreen, int monitor = 1}) async {
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    return;
  }
  if (!Platform.isWindows && !Platform.isLinux) return;
  if (!fullscreen) {
    if (await windowManager.isFullScreen()) await windowManager.setFullScreen(false);
    return;
  }
  if (Platform.isWindows) {
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isNotEmpty) {
      final display = displays[(monitor - 1).clamp(0, displays.length - 1)];
      // Full screen takes the monitor the window is on - move it there first.
      if (await windowManager.isFullScreen()) await windowManager.setFullScreen(false);
      final origin = display.visiblePosition ?? Offset.zero;
      await windowManager.setBounds(null, position: origin + const Offset(50, 50));
    }
  }
  await windowManager.setFullScreen(true);
}

/// Number of monitors (Windows; 1 elsewhere).
Future<int> monitorCount() async {
  if (!Platform.isWindows) return 1;
  return (await screenRetriever.getAllDisplays()).length;
}
