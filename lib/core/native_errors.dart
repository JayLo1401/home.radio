import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// Shows app-wide messages (SnackBars) over whatever screen is open.
final appMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Errors the Android side caught instead of crashing (CrashGuard.kt) - and
/// uncaught Dart errors: logged, and shown as a short error message. The app
/// goes on either way.
class NativeErrors {
  NativeErrors._();

  static const _channel = MethodChannel('home_system/errors');
  static DateTime _lastShown = DateTime.fromMillisecondsSinceEpoch(0);

  static void install() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'nativeError') show('${call.arguments}');
        return null;
      });
    }
    // Dart doesn't end the app on these - they are only logged.
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('uncaught: $error\n$stack');
      return true;
    };
  }

  /// A short error message at the bottom - at most one every few seconds.
  static void show(String message) {
    debugPrint('caught native error: $message');
    final now = DateTime.now();
    if (now.difference(_lastShown) < const Duration(seconds: 4)) return;
    _lastShown = now;
    final messenger = appMessengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          backgroundColor: const Color(0xFF3A2A12),
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.amber),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.errorCaught(message),
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      );
  }
}
