import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'backup_service.dart';
import 'display_service.dart';
import 'launcher_service.dart';
import 'music_spectrum.dart';
import 'update_service.dart';

/// The Android permissions Home System uses - each for one feature, none of
/// them required (see PermissionsScreen).
enum PermissionKind {
  /// The accessibility service "Home System: Home-Taste" (or Home System as
  /// the default launcher).
  homeKey,

  /// Haussteuerung: display by motion.
  camera,

  /// Updates: "install unknown apps".
  installApps,

  /// Backups in Download/HomeSystem: legacy storage below Android 11,
  /// "all files access" from Android 11 on (only for an earlier
  /// installation's backups).
  storage,

  /// Nothing to allow - the playback controls need no permission.
  notifications,

  /// Musik: the visualisation follows the music (RECORD_AUDIO).
  recordAudio,

  /// The RTL-SDR stick: Android asks when it's plugged in.
  usb,

  /// WRITE_SECURE_SETTINGS - over adb only.
  secureSettings,
}

enum PermissionStatus {
  granted,
  missing,

  /// Not used on this device, or by a part that's switched off - see
  /// [PermissionEntry.notNeeded].
  notNeeded,

  /// Nothing to allow here, only to know (USB, notifications).
  info,
}

/// Why a permission isn't needed right now.
enum PermissionNotNeeded { device, partOff, noCamera }

@immutable
class PermissionEntry {
  const PermissionEntry(this.kind, this.status, {this.notNeeded, this.part, this.optional = false});

  final PermissionKind kind;
  final PermissionStatus status;
  final PermissionNotNeeded? notNeeded;

  /// The part this permission is for (when [notNeeded] is partOff):
  /// 'dashboard', 'music', 'radio'.
  final String? part;

  /// Nice to have, not counted in "x von y erteilt" (all files access on
  /// Android 11+: only for an earlier installation's backups).
  final bool optional;

  /// Something to allow (now or already).
  bool get actionable => status == PermissionStatus.granted || status == PermissionStatus.missing;
}

/// What the device says - collected by [PermissionsService.facts].
@immutable
class PermissionFacts {
  const PermissionFacts({
    this.android = true,
    this.sdkInt = 0,
    this.fireTv = false,
    this.homeService = false,
    this.defaultHome = false,
    this.secureSettings = false,
    this.hasCamera = false,
    this.camera = false,
    this.updates = false,
    this.canInstall = false,
    this.storage = false,
    this.recordAudio = false,
    this.usbHost = true,
  });

  final bool android;
  final int sdkInt;
  final bool fireTv;
  final bool homeService;
  final bool defaultHome;
  final bool secureSettings;
  final bool hasCamera;
  final bool camera;

  /// The app updates itself (an update server is built in).
  final bool updates;
  final bool canInstall;
  final bool storage;
  final bool recordAudio;
  final bool usbHost;

  static const notAndroid = PermissionFacts(android: false);
}

/// The parts the permissions are for (as SystemParts, without the import).
typedef PermissionParts = ({bool radio, bool dashboard, bool music});

/// Every permission with its state on this device for the parts that are on.
/// Order: what matters most first.
List<PermissionEntry> permissionEntries(PermissionFacts f, PermissionParts parts) {
  if (!f.android) {
    return [
      for (final kind in PermissionKind.values)
        PermissionEntry(kind, PermissionStatus.notNeeded, notNeeded: PermissionNotNeeded.device),
    ];
  }
  PermissionStatus st(bool ok) => ok ? PermissionStatus.granted : PermissionStatus.missing;
  PermissionEntry off(PermissionKind kind, String part) =>
      PermissionEntry(kind, PermissionStatus.notNeeded, notNeeded: PermissionNotNeeded.partOff, part: part);
  PermissionEntry notHere(PermissionKind kind) =>
      PermissionEntry(kind, PermissionStatus.notNeeded, notNeeded: PermissionNotNeeded.device);

  // The Haussteuerung switches the display off through the service - there
  // being the default launcher isn't enough.
  final homeKeyOk = f.homeService || (!f.fireTv && f.defaultHome && !parts.dashboard);
  return [
    PermissionEntry(PermissionKind.homeKey, st(homeKeyOk)),
    if (!parts.dashboard)
      off(PermissionKind.camera, 'dashboard')
    else if (!f.hasCamera)
      const PermissionEntry(PermissionKind.camera, PermissionStatus.notNeeded, notNeeded: PermissionNotNeeded.noCamera)
    else
      PermissionEntry(PermissionKind.camera, st(f.camera)),
    if (f.updates && f.sdkInt >= 26)
      PermissionEntry(PermissionKind.installApps, st(f.canInstall))
    else
      notHere(PermissionKind.installApps),
    PermissionEntry(PermissionKind.storage, st(f.storage), optional: f.sdkInt >= 30),
    if (!parts.music) off(PermissionKind.recordAudio, 'music') else PermissionEntry(PermissionKind.recordAudio, st(f.recordAudio)),
    if (!parts.radio)
      off(PermissionKind.usb, 'radio')
    else if (!f.usbHost)
      notHere(PermissionKind.usb)
    else
      const PermissionEntry(PermissionKind.usb, PermissionStatus.info),
    const PermissionEntry(PermissionKind.notifications, PermissionStatus.info),
    PermissionEntry(PermissionKind.secureSettings, st(f.secureSettings)),
  ];
}

/// Granted / all of what can be allowed (the adb-only one doesn't count).
({int granted, int total}) permissionsCount(List<PermissionEntry> entries) {
  // Not counted: adb-only and optional ones.
  final counted = entries.where((e) => e.actionable && e.kind != PermissionKind.secureSettings && !e.optional);
  return (granted: counted.where((e) => e.status == PermissionStatus.granted).length, total: counted.length);
}

/// How asking went.
enum PermissionRequestResult {
  granted,
  denied,

  /// Android doesn't show its dialog any more ("don't ask again") - the
  /// app's info page was opened instead.
  blocked,

  /// A system settings page was opened - the state is read again when the
  /// app comes back.
  openedSettings,
}

/// Reads and asks for the permissions - through the feature plugins where
/// they have it (DisplayPlugin, MusicVisualizerPlugin, UpdatePlugin,
/// BackupPlugin, LauncherPlugin) and PermissionsPlugin.kt for the rest.
class PermissionsService {
  PermissionsService({
    required this.launcher,
    required this.display,
    required this.update,
    required this.backup,
    required this.spectrum,
  });

  final LauncherService launcher;
  final DisplayService display;
  final UpdateService update;
  final BackupService backup;
  final MusicSpectrum spectrum;

  static const _channel = MethodChannel('home_system/permissions');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static const _camera = 'android.permission.CAMERA';
  static const _recordAudio = 'android.permission.RECORD_AUDIO';
  static const _readStorage = 'android.permission.READ_EXTERNAL_STORAGE';
  static const _writeStorage = 'android.permission.WRITE_EXTERNAL_STORAGE';

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('permissions: $method failed: $e');
      return null;
    }
  }

  Future<int> _sdkInt() async => await _invoke<int>('sdkInt') ?? 0;

  /// The legacy storage permission for backups (null from Android 11 on).
  static String? _storagePermission(int sdk) => sdk >= 30 ? null : (sdk >= 29 ? _readStorage : _writeStorage);

  Future<PermissionFacts> facts() async {
    if (!supported) return PermissionFacts.notAndroid;
    final sdk = await _sdkInt();
    final status = await launcher.homeButtonStatus();
    final storagePermission = _storagePermission(sdk);
    final storage = storagePermission == null
        ? !await backup.canRequestAllFilesAccess()
        : await _invoke<bool>('check', {'permission': storagePermission}) ?? false;
    return PermissionFacts(
      sdkInt: sdk,
      fireTv: await launcher.isFireTv(),
      homeService: status.serviceEnabled,
      defaultHome: await launcher.isDefaultHome(),
      secureSettings: status.canEnable,
      hasCamera: await display.hasCamera(),
      camera: await display.hasCameraPermission(),
      updates: UpdateService.supported,
      canInstall: await update.canInstall(),
      storage: storage,
      recordAudio: await spectrum.hasPermission(),
      usbHost: await _invoke<bool>('hasUsbHost') ?? true,
    );
  }

  /// Opens the app's own page in the system settings.
  Future<bool> openAppSettings() async => await _invoke<bool>('openAppSettings') ?? false;

  /// Asks for [kind] - the system dialog, or the system settings page where
  /// it's allowed. The Home key has its own screen (HomeButtonSettingsScreen);
  /// [PermissionKind.usb], notifications and adb have nothing to ask.
  Future<PermissionRequestResult> request(PermissionKind kind) async {
    switch (kind) {
      case PermissionKind.camera:
        return _runtime(_camera, display.requestCameraPermission);
      case PermissionKind.recordAudio:
        return _runtime(_recordAudio, spectrum.requestPermission);
      case PermissionKind.installApps:
        await update.openInstallPermission();
        return PermissionRequestResult.openedSettings;
      case PermissionKind.storage:
        final permission = _storagePermission(await _sdkInt());
        if (permission != null) {
          return _runtime(permission, () async => await _invoke<bool>('request', {'permission': permission}) ?? false);
        }
        if (!await backup.requestAllFilesAccess()) await openAppSettings();
        return PermissionRequestResult.openedSettings;
      case PermissionKind.homeKey:
      case PermissionKind.usb:
      case PermissionKind.notifications:
      case PermissionKind.secureSettings:
        return PermissionRequestResult.denied;
    }
  }

  /// A runtime permission through [ask]. When Android didn't show its dialog
  /// (denied before with "don't ask again": no rationale before or after,
  /// and the answer came at once), the app's info page opens.
  Future<PermissionRequestResult> _runtime(String permission, Future<bool> Function() ask) async {
    Future<bool> rationale() async => await _invoke<bool>('shouldShowRationale', {'permission': permission}) ?? true;
    final before = await rationale();
    final asked = Stopwatch()..start();
    if (await ask()) return PermissionRequestResult.granted;
    final instant = asked.elapsedMilliseconds < 600;
    if (!before && instant && !await rationale()) {
      await openAppSettings();
      return PermissionRequestResult.blocked;
    }
    return PermissionRequestResult.denied;
  }
}
