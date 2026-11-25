import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../l10n/l10n.dart';
import 'desktop/hrdab_desktop.dart';

/// A newer version on the update server, ready to download for this device.
class AvailableUpdate {
  final String version;
  final String url;
  final String? sha256;

  const AvailableUpdate({required this.version, required this.url, this.sha256});
}

/// The Android APKs the CI builds, one per ABI (see release.yml) - plus
/// "universal" with all three.
const apkAbiVariants = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

/// The lowest Android the APKs install on (Flutter's minSdk 24).
const apkMinAndroid = '7.0';

/// The APK variant for a device with these ABIs (Build.SUPPORTED_ABIS, the
/// preferred first) - the same choice the updater makes.
String recommendedApkVariant(List<String> abis) =>
    abis.firstWhere(apkAbiVariants.contains, orElse: () => 'universal');

/// The variant an APK is from its native library folders: one ABI, or
/// "universal" with several; null if unknown.
String? installedApkVariant(List<String> apkAbis) => switch (apkAbis.length) {
      0 => null,
      1 => apkAbis.single,
      _ => 'universal',
    };

/// What this Android device is - to tell which APK fits it.
class DeviceAppInfo {
  const DeviceAppInfo({
    required this.sdk,
    required this.release,
    required this.manufacturer,
    required this.model,
    this.chip,
    this.ramBytes,
    this.abis = const [],
    this.abis64 = const [],
    this.apkAbis = const [],
    this.cpu64 = false,
  });

  factory DeviceAppInfo.fromMap(Map<Object?, Object?> m) {
    List<String> list(Object? v) => [for (final x in (v as List?) ?? const []) '$x'];
    String text(Object? v) => (v as String?)?.trim() ?? '';
    return DeviceAppInfo(
      sdk: (m['sdk'] as num?)?.toInt() ?? 0,
      release: text(m['release']),
      manufacturer: text(m['manufacturer']),
      model: text(m['model']),
      chip: text(m['chip']).isEmpty ? null : text(m['chip']),
      ramBytes: (m['ram'] as num?)?.toInt(),
      abis: list(m['abis']),
      abis64: list(m['abis64']),
      apkAbis: list(m['apkAbis']),
      cpu64: m['cpu64'] == true,
    );
  }

  /// Android API level and version ("14").
  final int sdk;
  final String release;
  final String manufacturer;
  final String model;
  final String? chip;
  final int? ramBytes;

  /// The system's ABIs, preferred first.
  final List<String> abis;
  final List<String> abis64;

  /// The ABIs inside the installed APK.
  final List<String> apkAbis;

  /// The processor could run 64-bit (also when the system is 32-bit).
  final bool cpu64;

  bool get system64 => abis64.isNotEmpty;

  /// "Xiaomi MiTV-AFMU0" (without the maker twice).
  String get name {
    if (manufacturer.isEmpty) return model;
    return model.toLowerCase().startsWith(manufacturer.toLowerCase()) ? model : '$manufacturer $model';
  }

  String get recommended => recommendedApkVariant(abis);

  String? get installed => installedApkVariant(apkAbis);

  /// The installed APK is the one made for this device (or universal - it
  /// runs, only bigger; the next update brings the fitting one).
  bool get installedFits => installed == recommended;

  Map<String, Object?> toJson() => {
        'name': name,
        'android': release,
        'sdk': sdk,
        'chip': chip,
        'ramBytes': ramBytes,
        'abis': abis,
        'system64': system64,
        'cpu64': cpu64,
        'installed': installed,
        'recommended': recommended,
      };
}

/// Updates from the Nexus raw repository the CI publishes to (see
/// .github/workflows/release.yml). Each platform has a manifest at
/// `<base>/<platform>/release/latest/version.json`:
///
///   Windows/Linux: {"version": "1.3.0", "url": ".../setup.exe", "sha256": "..."}
///   Android:       {"version": "1.3.0", "apks": {"arm64-v8a": {"url": ..., "sha256": ...}, ...}}
///
/// The base URL is compiled in by the CI (`--dart-define=UPDATE_BASE_URL=...`);
/// local builds have none and never update themselves.
///
/// Installing: Windows runs the Inno Setup installer silently and quits (it
/// restarts the app), Linux installs the .deb through pkexec and the
/// polkit-allowed apply-update.sh, then restarts; Android hands the APK to
/// the system installer, which asks the user to confirm.
class UpdateService {
  static const baseUrl = String.fromEnvironment('UPDATE_BASE_URL');
  static const _channel = MethodChannel('home_system/update');

  static bool get supported => baseUrl != '' && (Platform.isAndroid || Platform.isWindows || Platform.isLinux);

  String? _currentVersion;

  Future<String> currentVersion() async => _currentVersion ??= (await PackageInfo.fromPlatform()).version;

  String get _platform => Platform.isAndroid ? 'android' : (Platform.isWindows ? 'windows' : 'linux');

  /// The newer version for this device, or null (none, offline, no server).
  Future<AvailableUpdate?> check() async {
    if (!supported) return null;
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/$_platform/release/latest/version.json'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final version = json['version'] as String;
      if (compareVersions(version, await currentVersion()) <= 0) return null;
      if (!Platform.isAndroid) {
        return AvailableUpdate(version: version, url: json['url'] as String, sha256: json['sha256'] as String?);
      }
      // The APK built for this device's ABI - split APKs have higher
      // version codes than the universal one, so this always upgrades.
      final apks = (json['apks'] as Map).cast<String, dynamic>();
      final abis = (await _channel.invokeListMethod<String>('supportedAbis')) ?? const [];
      for (final abi in [...abis, 'universal']) {
        final apk = apks[abi] as Map<String, dynamic>?;
        if (apk != null) {
          return AvailableUpdate(version: version, url: apk['url'] as String, sha256: apk['sha256'] as String?);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Android: what the device is (Android version, 32/64-bit, the
  /// installed APK variant) - null elsewhere or if it can't be read.
  Future<DeviceAppInfo?> deviceInfo() async {
    if (!Platform.isAndroid) return null;
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('deviceInfo');
      return map == null ? null : DeviceAppInfo.fromMap(map);
    } catch (_) {
      return null;
    }
  }

  /// Android: the app may "install unknown apps" (always true below
  /// Android 8 and elsewhere).
  Future<bool> canInstall() async =>
      !Platform.isAndroid || (await _channel.invokeMethod<bool>('canInstall') ?? false);

  /// Android: opens the system page where "install unknown apps" is allowed
  /// for this app.
  Future<void> openInstallPermission() async {
    if (Platform.isAndroid) await _channel.invokeMethod('openInstallPermission');
  }

  /// Downloads and installs [update]. On Windows/Linux the app quits when
  /// the installer has taken over (doesn't return then). Throws on failure.
  ///
  /// [beforeInstall] runs once the update is downloaded and can be
  /// installed, right before installing (e.g. the backup to the NAS) - it
  /// should not throw; the update goes on when it's done.
  Future<void> install(
    AvailableUpdate update, {
    void Function(double progress)? onProgress,
    Future<void> Function()? beforeInstall,
  }) async {
    final file = await _download(update, onProgress);
    if (Platform.isAndroid) {
      if (!(await _channel.invokeMethod<bool>('canInstall') ?? false)) {
        // "Install unknown apps" for this app - once; the user comes back
        // and starts the update again.
        await _channel.invokeMethod('openInstallPermission');
        throw UpdateException(l10n.miscUpdateAllowUnknownApps);
      }
      await beforeInstall?.call();
      await _channel.invokeMethod('install', {'path': file.path});
      return;
    }
    await beforeInstall?.call();
    if (Platform.isWindows) {
      HrdabDesktop.shutdownIfStarted();
      await Process.start(file.path, const [
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
      ], mode: ProcessStartMode.detached);
      exit(0);
    }
    // Linux: apply-update.sh installs exactly this file (fixed path), see
    // linux/packaging.
    final result = await Process.run('pkexec', [_linuxApplyScript]);
    if (result.exitCode != 0) {
      throw UpdateException(l10n.miscUpdateInstallCancelled(result.exitCode));
    }
    // rtl_tcp takes one client - free it before the new instance connects.
    HrdabDesktop.shutdownIfStarted();
    await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
    exit(0);
  }

  static const _linuxDeb = '/tmp/home-system-update.deb';
  static const _linuxApplyScript = '/opt/home-system/apply-update.sh';

  Future<File> _download(AvailableUpdate update, void Function(double progress)? onProgress) async {
    final String path;
    if (Platform.isLinux) {
      path = _linuxDeb;
    } else {
      final dir = await getTemporaryDirectory();
      path = p.join(dir.path, Platform.isWindows ? 'HomeSystemSetup.exe' : 'home_system_update.apk');
    }
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(update.url)));
      if (res.statusCode != 200) throw UpdateException(l10n.miscUpdateDownloadFailed(res.statusCode));
      final total = res.contentLength ?? 0;
      final file = File(path);
      final sink = file.openWrite();
      final hashSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(hashSink);
      var received = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
      hasher.close();
      final expected = update.sha256?.toLowerCase();
      if (expected != null && hashSink.value.toString() != expected) {
        await file.delete();
        throw UpdateException(l10n.miscUpdateCorrupt);
      }
      return file;
    } finally {
      client.close();
    }
  }
}

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);

  @override
  String toString() => message;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Compares dotted versions numerically ("1.10.0" > "1.9.2").
int compareVersions(String a, String b) {
  List<int> parts(String v) => v.split('+').first.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
