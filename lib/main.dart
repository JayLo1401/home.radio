import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/native_errors.dart';
import 'app.dart';
import 'core/third_party_licenses.dart';
import 'features/tv/tv_player.dart';

// Closing the window shuts the receiver down (stick / rtl_tcp connection) in
// the native runner: windows/runner/flutter_window.cpp,
// linux/runner/my_application.cc.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The licence list (Settings → System) - also the parts outside Dart packages.
  registerThirdPartyLicenses();
  // just_audio has no own player on Windows/Linux - libmpv (media_kit) plays
  // the streams there.
  if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized(windows: true, linux: true);
    // ... and TV's picture (video_player has no player of its own here).
    MediaKit.ensureInitialized();
    // Full screen and monitor choice (applyDisplayMode).
    await windowManager.ensureInitialized();
  }
  // Which picture path TV takes on this device (Android version).
  await TvPlayer.prepare();
  // Errors caught instead of crashing: shown as a message.
  NativeErrors.install();
  runApp(const ProviderScope(child: HomeSystemApp()));
}
