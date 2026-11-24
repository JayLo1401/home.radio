import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/permissions_service.dart';
import 'package:home_system/features/setup/permissions_screen.dart';

void main() {
  const allOff = (radio: false, dashboard: false, music: false);
  const allOn = (radio: true, dashboard: true, music: true);

  PermissionEntry entry(List<PermissionEntry> list, PermissionKind kind) => list.firstWhere((e) => e.kind == kind);

  test('not Android: nothing is needed', () {
    final list = permissionEntries(PermissionFacts.notAndroid, allOn);
    expect(list.every((e) => e.status == PermissionStatus.notNeeded), isTrue);
    expect(permissionsCount(list), (granted: 0, total: 0));
  });

  test('parts that are off need nothing', () {
    final list = permissionEntries(const PermissionFacts(sdkInt: 34, hasCamera: true), allOff);
    expect(entry(list, PermissionKind.camera).notNeeded, PermissionNotNeeded.partOff);
    expect(entry(list, PermissionKind.camera).part, 'dashboard');
    expect(entry(list, PermissionKind.recordAudio).part, 'music');
    expect(entry(list, PermissionKind.usb).part, 'radio');
    expect(entry(list, PermissionKind.homeKey).status, PermissionStatus.missing);
  });

  test('camera: only with a camera', () {
    final list = permissionEntries(const PermissionFacts(sdkInt: 30), allOn);
    expect(entry(list, PermissionKind.camera).notNeeded, PermissionNotNeeded.noCamera);
    final withCamera = permissionEntries(const PermissionFacts(sdkInt: 30, hasCamera: true, camera: true), allOn);
    expect(entry(withCamera, PermissionKind.camera).status, PermissionStatus.granted);
  });

  test('Home key: default launcher is enough - except for the Haussteuerung and on Fire TV', () {
    const facts = PermissionFacts(sdkInt: 30, defaultHome: true);
    expect(entry(permissionEntries(facts, allOff), PermissionKind.homeKey).status, PermissionStatus.granted);
    expect(entry(permissionEntries(facts, allOn), PermissionKind.homeKey).status, PermissionStatus.missing);
    const fire = PermissionFacts(sdkInt: 30, defaultHome: true, fireTv: true);
    expect(entry(permissionEntries(fire, allOff), PermissionKind.homeKey).status, PermissionStatus.missing);
    const service = PermissionFacts(sdkInt: 30, homeService: true, fireTv: true);
    expect(entry(permissionEntries(service, allOn), PermissionKind.homeKey).status, PermissionStatus.granted);
  });

  test('count leaves out adb and what is not needed', () {
    const facts = PermissionFacts(sdkInt: 34, updates: true, canInstall: true, storage: false, secureSettings: true);
    final list = permissionEntries(facts, allOff);
    // Home key (missing), install (granted); storage on Android 11+ (all
    // files access) is optional and not counted.
    expect(permissionsCount(list), (granted: 1, total: 2));
    const old = PermissionFacts(sdkInt: 29, updates: true, canInstall: true, storage: false);
    // Android 10: the storage permission counts.
    expect(permissionsCount(permissionEntries(old, allOff)).total, 3);
  });

  test('wizard: missing ones and the USB note, not audio, all-files or adb', () {
    const facts = PermissionFacts(sdkInt: 34, updates: true, hasCamera: true);
    final list = permissionEntries(facts, allOn);
    final kinds = wizardPermissions((facts: facts, parts: allOn, entries: list)).map((e) => e.kind).toList();
    expect(kinds, [PermissionKind.homeKey, PermissionKind.camera, PermissionKind.installApps, PermissionKind.usb]);
    const old = PermissionFacts(sdkInt: 28);
    final oldList = permissionEntries(old, allOff);
    expect(
      wizardPermissions((facts: old, parts: allOff, entries: oldList)).map((e) => e.kind),
      [PermissionKind.homeKey, PermissionKind.storage],
    );
  });
}
