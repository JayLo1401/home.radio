import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

// Closing the window shuts the receiver down (stick / rtl_tcp connection) in
// the native runner: windows/runner/flutter_window.cpp,
// linux/runner/my_application.cc.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // just_audio has no own player on Windows/Linux - libmpv (media_kit) plays
  // the streams there.
  if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized(windows: true, linux: true);
    // Full screen and monitor choice (applyDisplayMode).
    await windowManager.ensureInitialized();
  }
  runApp(const ProviderScope(child: HomeRadioApp()));
}
