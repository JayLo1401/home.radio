import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'desktop/hrdab_desktop.dart';

/// A newer version on the update server, ready to download for this device.
class AvailableUpdate {
  final String version;
  final String url;
  final String? sha256;

  const AvailableUpdate({required this.version, required this.url, this.sha256});
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
  static const _channel = MethodChannel('home_radio/update');

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

  /// Downloads and installs [update]. On Windows/Linux the app quits when
  /// the installer has taken over (doesn't return then). Throws on failure.
  Future<void> install(AvailableUpdate update, {void Function(double progress)? onProgress}) async {
    final file = await _download(update, onProgress);
    if (Platform.isAndroid) {
      if (!(await _channel.invokeMethod<bool>('canInstall') ?? false)) {
        // "Install unknown apps" for this app - once; the user comes back
        // and starts the update again.
        await _channel.invokeMethod('openInstallPermission');
        throw const UpdateException(
          'Bitte „Unbekannte Apps installieren“ für Home Radio erlauben und das Update erneut starten.',
        );
      }
      await _channel.invokeMethod('install', {'path': file.path});
      return;
    }
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
      throw UpdateException('Installation abgebrochen (${result.exitCode}).');
    }
    // rtl_tcp takes one client - free it before the new instance connects.
    HrdabDesktop.shutdownIfStarted();
    await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
    exit(0);
  }

  static const _linuxDeb = '/tmp/home-radio-update.deb';
  static const _linuxApplyScript = '/opt/home-radio/apply-update.sh';

  Future<File> _download(AvailableUpdate update, void Function(double progress)? onProgress) async {
    final String path;
    if (Platform.isLinux) {
      path = _linuxDeb;
    } else {
      final dir = await getTemporaryDirectory();
      path = p.join(dir.path, Platform.isWindows ? 'HomeRadioSetup.exe' : 'home_radio_update.apk');
    }
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(update.url)));
      if (res.statusCode != 200) throw UpdateException('Download fehlgeschlagen (HTTP ${res.statusCode}).');
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
        throw const UpdateException('Die heruntergeladene Datei ist beschädigt.');
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
