import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/settings_repository.dart';
import '../data/services/display_service.dart';
import 'providers.dart';
import 'system_providers.dart';

final displayServiceProvider = Provider<DisplayService>((ref) => DisplayService());

/// The Haussteuerung's dashboard address ('' = not set up).
class DashboardUrlNotifier extends Notifier<String> {
  @override
  String build() {
    ref.read(settingsRepositoryProvider).getDashboardUrl().then((v) => state = v);
    return '';
  }

  Future<void> set(String url) async {
    state = url.trim();
    await ref.read(settingsRepositoryProvider).setDashboardUrl(url);
  }
}

final dashboardUrlProvider = NotifierProvider<DashboardUrlNotifier, String>(DashboardUrlNotifier.new);

/// Display on/off by motion (camera), see [DashboardDisplaySettings].
class DashboardDisplayNotifier extends Notifier<DashboardDisplaySettings> {
  @override
  DashboardDisplaySettings build() {
    ref.read(settingsRepositoryProvider).getDashboardDisplay().then((v) => state = v);
    return const DashboardDisplaySettings();
  }

  Future<void> set(DashboardDisplaySettings value) async {
    state = value;
    await ref.read(settingsRepositoryProvider).setDashboardDisplay(value);
  }
}

final dashboardDisplayProvider =
    NotifierProvider<DashboardDisplayNotifier, DashboardDisplaySettings>(DashboardDisplayNotifier.new);

/// The display's brightness (Settings → Haussteuerung).
class DisplayBrightnessNotifier extends Notifier<DisplayBrightness> {
  @override
  DisplayBrightness build() {
    ref.read(settingsRepositoryProvider).getDisplayBrightness().then((v) => state = v);
    return const DisplayBrightness();
  }

  Future<void> set(DisplayBrightness value) async {
    state = value;
    await ref.read(settingsRepositoryProvider).setDisplayBrightness(value);
  }
}

final displayBrightnessProvider =
    NotifierProvider<DisplayBrightnessNotifier, DisplayBrightness>(DisplayBrightnessNotifier.new);

/// Hands the brightness setting to Android (app.dart watches it).
final brightnessControllerProvider = Provider<void>((ref) {
  if (!DisplayService.supported) return;
  final b = ref.watch(displayBrightnessProvider);
  ref.read(displayServiceProvider).setBrightness(
        mode: b.mode.name,
        level: b.level,
        min: b.min,
        max: b.max,
        luxForMax: b.luxForMax,
      );
});

/// Runs display-by-motion while the Haussteuerung is on and motion is
/// switched on - started with the app (app.dart), while it's in front, as
/// Android wants for a camera service.
final motionControllerProvider = Provider<void>((ref) {
  if (!DisplayService.supported) return;
  final on = ref.watch(systemPartsProvider.select((p) => p.dashboard));
  final display = ref.watch(dashboardDisplayProvider);
  final device = ref.watch(deviceNameProvider);
  final service = ref.read(displayServiceProvider);
  if (on && display.motion) {
    service
        .startMotion(
          sensitivity: display.sensitivity,
          timeoutMinutes: display.timeoutMinutes,
          webhookUrl: display.webhookUrl,
          deviceName: device,
          dimOnly: display.dimOnly,
        )
        .then((ok) => ok ? null : debugPrint('motion: not started (camera permission?)'))
        .catchError((Object e) => debugPrint('motion: $e'));
  } else {
    service.stopMotion();
  }
});
