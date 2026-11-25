import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/update_service.dart';

void main() {
  test('the fitting APK: the preferred ABI the CI builds, else universal', () {
    expect(recommendedApkVariant(['armeabi-v7a', 'armeabi']), 'armeabi-v7a');
    expect(recommendedApkVariant(['arm64-v8a', 'armeabi-v7a', 'armeabi']), 'arm64-v8a');
    expect(recommendedApkVariant(['x86_64', 'x86', 'arm64-v8a']), 'x86_64');
    expect(recommendedApkVariant(['x86']), 'universal');
    expect(recommendedApkVariant([]), 'universal');
  });

  test('the installed variant from the APK\'s library folders', () {
    expect(installedApkVariant([]), isNull);
    expect(installedApkVariant(['armeabi-v7a']), 'armeabi-v7a');
    expect(installedApkVariant(['arm64-v8a', 'armeabi-v7a', 'x86_64']), 'universal');
  });

  test('device info from the platform channel', () {
    final info = DeviceAppInfo.fromMap({
      'sdk': 34,
      'release': '14',
      'manufacturer': 'Xiaomi',
      'model': 'MiTV-AFMU0',
      'chip': '',
      'ram': 2147483648,
      'abis': ['armeabi-v7a', 'armeabi'],
      'abis64': <String>[],
      'apkAbis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
      'cpu64': true,
    });
    expect(info.name, 'Xiaomi MiTV-AFMU0');
    expect(info.chip, isNull);
    expect(info.system64, isFalse);
    expect(info.cpu64, isTrue);
    expect(info.recommended, 'armeabi-v7a');
    expect(info.installed, 'universal');
    expect(info.installedFits, isFalse);
    expect(DeviceAppInfo.fromMap({'manufacturer': 'Amazon', 'model': 'Amazon KFTUWI'}).name, 'Amazon KFTUWI');
  });
}
