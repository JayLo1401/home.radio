import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/core/providers.dart';
import 'package:home_system/data/db/database.dart';
import 'package:home_system/core/remote_keys.dart';
import 'package:home_system/l10n/l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The tests check the German texts; `flutter test` runs in English.
  setUpAll(() => applyAppLocale(const Locale('de')));

  test('standard keys: OK opens the channel list, ☰ the options, Info the guide', () {
    const keys = RemoteKeys();
    expect(keys.actionOf(LogicalKeyboardKey.select), RemoteAction.channelList);
    expect(keys.actionOf(LogicalKeyboardKey.contextMenu), RemoteAction.options);
    expect(keys.actionOf(LogicalKeyboardKey.info), RemoteAction.guide);
    expect(keys.actionOf(LogicalKeyboardKey.keyE), RemoteAction.guide);
    expect(keys.actionOf(LogicalKeyboardKey.arrowUp), isNull);
  });

  test('an assigned key replaces the standard ones - ☰ is free then', () {
    final keys = RemoteKeys({
      RemoteAction.options: [LogicalKeyboardKey.colorF2Yellow],
    });
    expect(keys.actionOf(LogicalKeyboardKey.contextMenu), isNull);
    expect(keys.actionOf(LogicalKeyboardKey.colorF2Yellow), RemoteAction.options);
    expect(keys.isCustom(RemoteAction.options), isTrue);
    expect(keys.isCustom(RemoteAction.guide), isFalse);
  });

  test('HbbTV: red on the remote, R on the keyboard - assignable like the others', () {
    const keys = RemoteKeys();
    expect(keys.actionOf(LogicalKeyboardKey.colorF0Red), RemoteAction.hbbtv);
    expect(keys.actionOf(LogicalKeyboardKey.keyR), RemoteAction.hbbtv);
    expect(RemoteAction.values, contains(RemoteAction.hbbtv));
    expect(RemoteAction.hbbtv.label, contains('HbbTV'));
    // A remote without a red key: green does it instead, red is free.
    final custom = RemoteKeys({
      RemoteAction.hbbtv: [LogicalKeyboardKey.colorF1Green],
    });
    expect(custom.actionOf(LogicalKeyboardKey.colorF1Green), RemoteAction.hbbtv);
    expect(custom.actionOf(LogicalKeyboardKey.colorF0Red), isNull);
    // No standard key does two things.
    final seen = <LogicalKeyboardKey, RemoteAction>{};
    for (final a in RemoteAction.values) {
      for (final k in a.standard) {
        expect(seen[k], isNull, reason: '$k: ${seen[k]} and $a');
        seen[k] = a;
      }
    }
  });

  test('key names as on the remote', () {
    expect(remoteKeyLabel(LogicalKeyboardKey.select), 'OK');
    expect(remoteKeyLabel(LogicalKeyboardKey.contextMenu), '☰ Menü');
    expect(remoteKeyLabel(LogicalKeyboardKey.colorF0Red), 'Rot');
    expect(remoteKeyLabel(LogicalKeyboardKey.keyE), 'Taste E');
  });

  test('assigning the HbbTV key takes it from the action that had it', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(remoteKeysProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    // ☰ for HbbTV: the options lose it (and keep their letter O).
    await notifier.assign(RemoteAction.hbbtv, LogicalKeyboardKey.contextMenu);
    var keys = container.read(remoteKeysProvider);
    expect(keys.actionOf(LogicalKeyboardKey.contextMenu), RemoteAction.hbbtv);
    expect(keys.keysOf(RemoteAction.options), [LogicalKeyboardKey.keyO]);
    expect(keys.actionOf(LogicalKeyboardKey.colorF0Red), isNull);
    await notifier.reset(RemoteAction.hbbtv);
    keys = container.read(remoteKeysProvider);
    expect(keys.actionOf(LogicalKeyboardKey.colorF0Red), RemoteAction.hbbtv);
  });
}
