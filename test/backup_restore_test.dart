import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/db/database.dart';
import 'package:home_system/data/services/backup_areas.dart';
import 'package:home_system/data/services/backup_service.dart';
import 'package:home_system/data/services/secret_store.dart';
import 'package:home_system/core/popup_text_field.dart';
import 'package:home_system/features/settings/restore_selection_dialog.dart';
import 'package:home_system/l10n/app_localizations.dart';

void main() {
  // Secure storage has no plugin in tests - SecretStore falls back to the
  // settings table ('secret_fallback.<key>'), which is what a restore must
  // handle on a Linux box without a keyring too.
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late BackupService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = BackupService(db);
  });
  tearDown(() => db.close());

  Future<Map<String, String>> settings() async => {for (final s in await db.select(db.settings).get()) s.key: s.value};
  Future<List<String>> favorites() async => [for (final f in await db.select(db.favorites).get()) f.displayName];

  Future<void> addFavorite(int number, String name) => db.into(db.favorites).insert(FavoritesCompanion.insert(
        programNumber: Value(number),
        sourceType: 'internet',
        displayName: name,
        sourceRef: 'http://example.com/$number',
      ));

  /// Device A: something in every area.
  Future<void> fillDeviceA() async {
    await addFavorite(1, 'Ö1');
    await addFavorite(2, 'FM4');
    await db.into(db.dabStations).insert(DabStationsCompanion.insert(
          freqKhz: 222064,
          serviceId: 0xD220,
          channelLabel: '11D',
          stationLabel: 'Radio A',
        ));
    for (final MapEntry(:key, :value) in {
      'device_name': 'Wohnzimmer',
      'language': 'de',
      'start_app': 'tv',
      'launcher_tiles': '[1,2]',
      'launcher_bg_url': 'https://a/bg.jpg',
      'enigma2': '{"host":"gb-a"}',
      'tv_reminders': '[a]',
      'iptv_enabled': 'true',
      'autostart_mode': 'last',
      'music_shuffle': 'true',
      'slideshow_interval': '10',
      'nas_host': 'nas-a',
      'nas_folder_music': '/Musik',
      'dashboard_url': 'http://ha-a:8123',
      'ha_host': 'ha-a',
      'rtl_tcp_servers': '[a]',
      'weather_lat': '48.2',
      'browser.settings': '{"a":1}',
      'some_future_setting': 'a',
    }.entries) {
      await db.setSetting(key, value);
    }
    final secrets = SecretStore(db);
    await secrets.write('nas_password', 'nas-secret-a');
    await secrets.write(SecretStore.enigma2PasswordKey, 'rx-secret-a');
    await secrets.write(SecretStore.haMqttPasswordKey, 'ha-secret-a');
  }

  /// Device B: other values everywhere, keys A doesn't have.
  Future<void> turnIntoDeviceB() async {
    await db.delete(db.favorites).go();
    await db.delete(db.dabStations).go();
    await db.delete(db.settings).go();
    await addFavorite(7, 'Radio B');
    for (final MapEntry(:key, :value) in {
      'device_name': 'Küche',
      'language': 'en',
      'start_app': 'radio',
      'launcher_bg_url': 'https://b/bg.jpg',
      'enigma2': '{"host":"gb-b"}',
      'tv_only_on_b': 'x',
      'nas_host': 'nas-b',
      'nas_folder_recordings': '/Aufnahmen',
      'ha_host': 'ha-b',
      'weather_lat': '47.0',
      'some_future_setting': 'b',
    }.entries) {
      await db.setSetting(key, value);
    }
    final secrets = SecretStore(db);
    await secrets.write('nas_password', 'nas-secret-b');
    await secrets.write(SecretStore.enigma2PasswordKey, 'rx-secret-b');
    await secrets.write(SecretStore.haMqttPasswordKey, 'ha-secret-b');
  }

  group('areas', () {
    test('every key lands in one area - exact keys, longest prefix, else Sonstiges', () {
      expect(backupAreaOf('language'), BackupArea.system);
      expect(backupAreaOf('part_tv_enabled'), BackupArea.system);
      expect(backupAreaOf('part_dashboard_enabled'), BackupArea.system);
      expect(backupAreaOf('launcher_tiles'), BackupArea.system);
      expect(backupAreaOf('launcher_bg_url'), BackupArea.weather);
      expect(backupAreaOf('enigma2'), BackupArea.tv);
      expect(backupAreaOf(SecretStore.enigma2PasswordKey), BackupArea.tv);
      expect(backupAreaOf('tv_reminders'), BackupArea.tv);
      expect(backupAreaOf('iptv_favorites'), BackupArea.tv);
      expect(backupAreaOf('last_played_kind'), BackupArea.radio);
      expect(backupAreaOf('dab_sort_mode'), BackupArea.radio);
      expect(backupAreaOf('music_repeat'), BackupArea.music);
      expect(backupAreaOf('slideshow_order'), BackupArea.media);
      expect(backupAreaOf('nas_folder_movies'), BackupArea.nas);
      expect(backupAreaOf('nas_password'), BackupArea.nas);
      expect(backupAreaOf('secret_fallback.nas_password'), BackupArea.nas);
      expect(backupAreaOf('motion_enabled'), BackupArea.dashboard);
      expect(backupAreaOf('screen_off_timer'), BackupArea.dashboard);
      expect(backupAreaOf(SecretStore.haMqttPasswordKey), BackupArea.ha);
      expect(backupAreaOf('rtl_sdr_host'), BackupArea.sdr);
      expect(backupAreaOf('nb_gain_cb'), BackupArea.sdr);
      expect(backupAreaOf('radar_url'), BackupArea.weather);
      expect(backupAreaOf('browser.settings'), BackupArea.browser);
      expect(backupAreaOf('ftp_host'), BackupArea.other);
      expect(backupAreaOf('something_new'), BackupArea.other);
    });

    test('settings added later land by their prefix without changes here', () {
      expect(backupAreaOf('nas_folder_timeshift'), BackupArea.nas);
      expect(backupAreaOf('nas_movie_folders'), BackupArea.nas);
      expect(backupAreaOf('tv_timeshift_minutes'), BackupArea.tv);
      expect(backupAreaOf('tv_channel_order'), BackupArea.tv);
      expect(backupAreaOf('pictures_show_videos'), BackupArea.media);
      expect(backupAreaOf('dashboard_mini_player'), BackupArea.dashboard);
    });
  });

  test('inspect: device name, areas present with counts, radio numbers', () async {
    await fillDeviceA();
    final (:name, :content) = await service.export();
    expect(name, startsWith('home_system_backup_Wohnzimmer_'));
    final preview = service.inspect(content);
    expect(preview.deviceName, 'Wohnzimmer');
    expect(preview.createdAt, isNotNull);
    expect(preview.areas, BackupArea.values);
    expect(preview.counts[BackupArea.radio], 2 + 1 + 1); // favorites, DAB station, autostart_mode
    expect(preview.counts[BackupArea.nas], 2 + 1 + 1); // host, folder, secret + its fallback copy
    expect((preview.favorites, preview.dabStations, preview.fmStations), (2, 1, 0));
    expect(backupAreaSummary(lookupAppLocalizations(const Locale('de')), BackupArea.radio, preview),
        contains('2 Favoriten, 1 DAB+-Sender, 0 UKW-Sender'));
  });

  test('restore only some areas: those replaced completely, everything else untouched', () async {
    await fillDeviceA();
    final (name: _, :content) = await service.export();
    await turnIntoDeviceB();
    final before = await settings();

    await service.restoreJson(
      content,
      selection: const BackupRestoreSelection(areas: {BackupArea.tv, BackupArea.nas}, deviceName: '  Esszimmer '),
    );

    final after = await settings();
    // TV and NAS: exactly as in the backup - also keys only B had are gone.
    expect(after['enigma2'], '{"host":"gb-a"}');
    expect(after['tv_reminders'], '[a]');
    expect(after['iptv_enabled'], 'true');
    expect(after.containsKey('tv_only_on_b'), isFalse);
    expect(after['nas_host'], 'nas-a');
    expect(after['nas_folder_music'], '/Musik');
    expect(after.containsKey('nas_folder_recordings'), isFalse);
    final secrets = SecretStore(db);
    expect(await secrets.read('nas_password'), 'nas-secret-a');
    expect(await secrets.read(SecretStore.enigma2PasswordKey), 'rx-secret-a');
    // Everything else as B had it.
    expect(await secrets.read(SecretStore.haMqttPasswordKey), 'ha-secret-b');
    for (final key in ['language', 'start_app', 'launcher_bg_url', 'ha_host', 'weather_lat', 'some_future_setting']) {
      expect(after[key], before[key], reason: key);
    }
    for (final key in ['launcher_tiles', 'music_shuffle', 'slideshow_interval', 'dashboard_url', 'autostart_mode']) {
      expect(after.containsKey(key), isFalse, reason: key);
    }
    expect(await favorites(), ['Radio B']);
    expect(await db.select(db.dabStations).get(), isEmpty);
    // The name from the field, set up.
    expect(after['device_name'], 'Esszimmer');
    expect(after['setup_done'], 'true');
  });

  test('restore radio only: favorites and stations, settings of other areas stay', () async {
    await fillDeviceA();
    final (name: _, :content) = await service.export();
    await turnIntoDeviceB();

    await service.restoreJson(content, selection: const BackupRestoreSelection(areas: {BackupArea.radio}));

    expect(await favorites(), ['Ö1', 'FM4']);
    expect((await db.select(db.dabStations).get()).single.stationLabel, 'Radio A');
    final after = await settings();
    expect(after['autostart_mode'], 'last');
    expect(after['nas_host'], 'nas-b');
    // No name given: the current one stays.
    expect(after['device_name'], 'Küche');
  });

  test('restore without selection replaces everything (as before)', () async {
    await fillDeviceA();
    final (name: _, :content) = await service.export();
    final original = await settings();
    await turnIntoDeviceB();

    await service.restoreJson(content);

    expect(await settings(), {...original, 'setup_done': 'true'});
    expect(await favorites(), ['Ö1', 'FM4']);
    expect(await SecretStore(db).read(SecretStore.haMqttPasswordKey), 'ha-secret-a');
  });

  test('all areas selected = full restore, apart from the name field', () async {
    await fillDeviceA();
    final (name: _, :content) = await service.export();
    final original = await settings();
    await turnIntoDeviceB();

    await service.restoreJson(content, selection: BackupRestoreSelection(areas: BackupArea.values.toSet()));

    expect(await settings(), {...original, 'device_name': 'Küche', 'setup_done': 'true'});
  });

  test('old backups (no FM stations, no passwords, no date) still work', () async {
    final old = jsonEncode({
      'app': 'home_radio',
      'format': 1,
      'schemaVersion': 4,
      'favorites': [
        {
          'programNumber': 3,
          'sourceType': 'dab',
          'displayName': 'Alt',
          'logoUrl': null,
          'logoLocalPath': '/gone/logo.png',
          'sourceRef': 'dab:1',
          'createdAt': DateTime(2024).millisecondsSinceEpoch,
        },
      ],
      'dabStations': <Object>[],
      'settings': [
        {'key': 'device_name', 'value': 'Altes Gerät'},
        {'key': 'autostart_mode', 'value': 'fixed'},
        {'key': 'rtl_sdr_host', 'value': '192.168.1.5'},
      ],
    });
    await turnIntoDeviceB();
    final preview = service.inspect(old);
    expect(preview.deviceName, 'Altes Gerät');
    expect(preview.createdAt, isNull);
    expect(preview.areas, [BackupArea.radio, BackupArea.sdr]);

    await service.restoreJson(old, selection: const BackupRestoreSelection(areas: {BackupArea.radio}, deviceName: ''));

    final f = (await db.select(db.favorites).get()).single;
    expect((f.displayName, f.logoLocalPath), ('Alt', null));
    final after = await settings();
    expect(after['autostart_mode'], 'fixed');
    expect(after.containsKey('rtl_sdr_host'), isFalse);
    expect(after['device_name'], 'Küche');
    // No passwords in the file - the device's stay.
    expect(await SecretStore(db).read('nas_password'), 'nas-secret-b');
  });

  test('broken or foreign files are refused before anything changes', () async {
    await turnIntoDeviceB();
    final before = await settings();
    for (final content in [
      'kein json',
      jsonEncode({'app': 'something_else'}),
      jsonEncode({'app': 'home_radio', 'format': 99}),
      jsonEncode({
        'app': 'home_radio',
        'format': 1,
        'settings': [
          {'key': 'x'},
        ],
      }),
    ]) {
      expect(() => service.inspect(content), throwsA(isA<BackupFormatException>()));
      await expectLater(
        service.restoreJson(content, selection: const BackupRestoreSelection(areas: {BackupArea.tv})),
        throwsA(isA<BackupFormatException>()),
      );
    }
    expect(await settings(), before);
    expect(await favorites(), ['Radio B']);
  });

  group('selection dialog on the device', () {
    const preview = BackupPreview(
      deviceName: 'Wohnzimmer',
      createdAt: null,
      counts: {BackupArea.system: 3, BackupArea.radio: 5, BackupArea.nas: 2},
      favorites: 4,
    );

    Future<BackupRestoreSelection?> open(WidgetTester tester, Future<void> Function() act) async {
      // A TV screen - the whole list fits.
      tester.view.physicalSize = const Size(1920, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      BackupRestoreSelection? result;
      var closed = false;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: const [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showRestoreSelectionDialog(context, source: 'a.json', preview: preview, currentName: 'Küche');
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await act();
      await tester.pumpAndSettle();
      expect(closed, isTrue, reason: 'dialog closed');
      return result;
    }

    testWidgets('only the areas in the backup, all ticked; the name from the backup', (tester) async {
      final result = await open(tester, () async {
        expect(find.text('Systemeinstellungen'), findsOneWidget);
        expect(find.text('Radio-Einstellungen'), findsOneWidget);
        expect(find.text('NAS'), findsOneWidget);
        expect(find.text('TV-Einstellungen'), findsNothing);
        expect(find.textContaining('4 Favoriten'), findsOneWidget);
        expect(find.textContaining('„Küche“'), findsOneWidget);
        // "Übernehmen" has the focus - OK on the remote takes everything.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      });
      expect(result!.areas, {BackupArea.system, BackupArea.radio, BackupArea.nas});
      expect(result.deviceName, 'Wohnzimmer');
    });

    testWidgets('an area unticked stays out; Abbrechen returns nothing', (tester) async {
      final result = await open(tester, () async {
        await tester.tap(find.text('Radio-Einstellungen'));
        await tester.pump();
        await tester.tap(find.text('Übernehmen'));
      });
      expect(result!.areas, {BackupArea.system, BackupArea.nas});
      expect(await open(tester, () => tester.tap(find.text('Abbrechen'))), isNull);
    });

    testWidgets('nothing ticked and no new name: says so instead of closing', (tester) async {
      Future<void> enterName(String name) async {
        await tester.tap(find.byType(PopupTextField));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, name);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }

      final result = await open(tester, () async {
        for (final t in ['Systemeinstellungen', 'Radio-Einstellungen', 'NAS']) {
          await tester.tap(find.text(t));
          await tester.pump();
        }
        // The backup's name is a new one - empty keeps the current name.
        await enterName('');
        await tester.tap(find.text('Übernehmen'));
        await tester.pump();
        expect(find.textContaining('Nichts ausgewählt'), findsOneWidget);
        // A new name alone is something to take over.
        await enterName('Esszimmer');
        await tester.tap(find.text('Übernehmen'));
      });
      expect(result!.areas, isEmpty);
      expect(result.deviceName, 'Esszimmer');
    });
  });
}
