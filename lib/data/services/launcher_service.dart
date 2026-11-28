import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/launcher_tile.dart';
import 'desktop/windows_apps.dart';

/// An app installed on the device, as the launcher lists it.
class InstalledApp {
  const InstalledApp({required this.package, required this.label, required this.tv});

  final String package;
  final String label;

  /// Has a TV launcher entry (Android TV / Fire TV app), not only a phone one.
  final bool tv;
}

/// An app's picture for its tile: the 16:9 TV banner, or its icon.
class AppImage {
  const AppImage(this.bytes, {required this.banner});

  final Uint8List bytes;
  final bool banner;
}

/// State of the Home key redirect (see HomeButtonService.kt).
class HomeButtonStatus {
  const HomeButtonStatus({
    required this.serviceEnabled,
    required this.canEnable,
    required this.redirect,
    this.serviceRunning = false,
  });

  /// Switched on in the device's accessibility settings.
  final bool serviceEnabled;

  /// Actually running: Android can leave it switched on but not run it
  /// (after the app's process died).
  final bool serviceRunning;

  /// WRITE_SECURE_SETTINGS was granted over adb - the app can switch the
  /// service on by itself.
  final bool canEnable;

  /// "Home-Taste öffnet Home System" - the service only acts while this is on.
  final bool redirect;
}

/// The device side of Home System's launcher on Android (LauncherPlugin.kt):
/// installed apps, starting them, icon packs and the Home key. The launcher
/// itself (Radio, TV) is there on every platform; elsewhere
/// [supported] is false and everything here answers "nothing" - except the
/// installed apps on Windows ([appsSupported], see WindowsApps).
class LauncherService {
  LauncherService() {
    if (supported) _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('home_system/launcher');

  /// The Home key, the device's settings, icon packs, App-Info - Android only.
  static bool get supported => !kIsWeb && Platform.isAndroid;

  static bool get _windows => !kIsWeb && Platform.isWindows;

  /// Installed apps as tiles (favourites, groups, "Alle Apps"): Android and
  /// Windows.
  static bool get appsSupported => supported || _windows;

  /// Whether an app tile's [package] belongs to this platform - tiles from a
  /// backup of the other one (an Android package on the PC, a Windows app on
  /// the TV box) are left out.
  static bool ownsApp(String package) => appIdBelongsHere(package, android: supported, windows: _windows);

  /// Whether [tile] can be shown here: Home System's own parts always, apps
  /// of this platform ([ownsApp]), the device's settings on Android.
  static bool keepsTile(LauncherTile tile) {
    if (tile.isBuiltIn) return true;
    if (tile.isApp) return ownsApp(tile.package ?? '');
    return supported;
  }

  WindowsApps? _windowsApps;
  WindowsApps get _win => _windowsApps ??= WindowsApps();

  /// Windows: reads the installed apps in the background, so the first tile
  /// started doesn't wait for the list.
  void warmUpApps() {
    if (_windows) _win.warmUp();
  }

  final _showRequests = StreamController<void>.broadcast();

  /// The Home key was pressed while the app runs.
  Stream<void> get showRequests => _showRequests.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'showLauncher') _showRequests.add(null);
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      debugPrint('launcher $method: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether the app was started by the Home key (shown with the launcher
  /// then, whatever the start setting says). Answers true only once.
  Future<bool> takeLaunchRequest() async => await _invoke<bool>('takeLaunchRequest') ?? false;

  Future<List<InstalledApp>> listApps() async {
    if (_windows) return _win.list();
    final list = await _invoke<List<Object?>>('listApps') ?? const [];
    return [
      for (final e in list.whereType<Map<Object?, Object?>>())
        InstalledApp(
          package: e['package'] as String,
          label: e['label'] as String? ?? e['package'] as String,
          tv: e['tv'] == true,
        ),
    ];
  }

  Future<AppImage?> appImage(String package) async {
    if (_windows) return _win.icon(package);
    if (!ownsApp(package)) return null;
    final m = await _invoke<Map<Object?, Object?>>('appImage', {'package': package});
    final bytes = m?['bytes'];
    if (bytes is! Uint8List) return null;
    return AppImage(bytes, banner: m?['banner'] == true);
  }

  /// Installed icon packs (ADW/Nova format) - package and name.
  Future<List<({String package, String label})>> listIconPacks() async {
    final list = await _invoke<List<Object?>>('listIconPacks') ?? const [];
    return [
      for (final e in list.whereType<Map<Object?, Object?>>())
        (package: e['package'] as String, label: e['label'] as String? ?? e['package'] as String),
    ];
  }

  /// The icon [pack] has for [package], null if it has none.
  Future<AppImage?> iconPackImage(String pack, String package) async {
    final m = await _invoke<Map<Object?, Object?>>('iconPackImage', {'pack': pack, 'package': package});
    final bytes = m?['bytes'];
    if (bytes is! Uint8List) return null;
    return AppImage(bytes, banner: false);
  }

  Future<bool> launchApp(String package) async {
    if (_windows) return _win.launch(package);
    if (!ownsApp(package)) return false;
    return await _invoke<bool>('launchApp', {'package': package}) ?? false;
  }

  Future<bool> openSystemSettings() async => await _invoke<bool>('openSystemSettings') ?? false;

  /// The system's page for [package]: force stop, uninstall, storage.
  Future<bool> openAppInfo(String package) async => await _invoke<bool>('openAppInfo', {'package': package}) ?? false;

  Future<bool> isFireTv() async => await _invoke<bool>('isFireTv') ?? false;

  Future<bool> isDefaultHome() async => await _invoke<bool>('isDefaultHome') ?? false;

  Future<bool> openHomeSettings() async => await _invoke<bool>('openHomeSettings') ?? false;

  Future<HomeButtonStatus> homeButtonStatus() async {
    final m = await _invoke<Map<Object?, Object?>>('homeButtonStatus');
    return HomeButtonStatus(
      serviceEnabled: m?['serviceEnabled'] == true,
      serviceRunning: m?['serviceRunning'] == true,
      canEnable: m?['canEnable'] == true,
      redirect: m?['redirect'] != false,
    );
  }

  Future<bool> enableHomeButtonService() async => await _invoke<bool>('enableHomeButtonService') ?? false;

  Future<bool> openAccessibilitySettings() async => await _invoke<bool>('openAccessibilitySettings') ?? false;

  Future<void> setHomeRedirect(bool enabled) => _invoke<void>('setHomeRedirect', {'enabled': enabled});
}
