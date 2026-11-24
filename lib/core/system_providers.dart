import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/launcher_tile.dart';
import '../features/launcher/launcher_providers.dart'
    show RadioCommand, launcherSettingsProvider, launcherTilesProvider, radioCommandProvider;
import 'providers.dart';

/// Which of Home System's parts are switched on (Settings → System). A part
/// that is off has no tile under Home, no start option and its settings
/// are greyed out. The Haussteuerung is off until switched on.
typedef SystemParts = ({bool radio, bool tv, bool dashboard});

class SystemPartsNotifier extends Notifier<SystemParts> {
  @override
  SystemParts build() {
    _load();
    return (radio: true, tv: true, dashboard: false);
  }

  Future<void> _load() async {
    final repo = ref.read(settingsRepositoryProvider);
    state = (
      radio: await repo.getRadioEnabled(),
      tv: await repo.getTvEnabled(),
      dashboard: await repo.getDashboardEnabled(),
    );
  }

  /// Off: the radio stops, and a start into Radio becomes a start into Home.
  Future<void> setRadio(bool value) async {
    state = (radio: value, tv: state.tv, dashboard: state.dashboard);
    await ref.read(settingsRepositoryProvider).setRadioEnabled(value);
    if (!value) {
      ref.read(radioCommandProvider.notifier).send(RadioCommand.stop);
      await _startIntoHomeInsteadOf(StartScreen.radio);
    }
  }

  Future<void> setTv(bool value) async {
    state = (radio: state.radio, tv: value, dashboard: state.dashboard);
    await ref.read(settingsRepositoryProvider).setTvEnabled(value);
    if (!value) await _startIntoHomeInsteadOf(StartScreen.tv);
  }

  /// Switching the Haussteuerung on also puts its tile into Home's row.
  Future<void> setDashboard(bool value) async {
    state = (radio: state.radio, tv: state.tv, dashboard: value);
    await ref.read(settingsRepositoryProvider).setDashboardEnabled(value);
    if (value) {
      await ref.read(launcherTilesProvider.notifier).add(const LauncherTile.dashboard());
    } else {
      await _startIntoHomeInsteadOf(StartScreen.dashboard);
    }
  }

  Future<void> _startIntoHomeInsteadOf(StartScreen part) async {
    if (ref.read(launcherSettingsProvider).startScreen != part) return;
    await ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.launcher);
  }

  /// A part of [type] (LauncherTile's) is on - Radio, TV, Haussteuerung;
  /// everything else (apps) always.
  bool showsTile(LauncherTile tile) => switch (tile.type) {
        LauncherTile.radioType => state.radio,
        LauncherTile.tvType => state.tv,
        LauncherTile.dashboardType => state.dashboard,
        _ => true,
      };
}

final systemPartsProvider = NotifierProvider<SystemPartsNotifier, SystemParts>(SystemPartsNotifier.new);

/// The device's name (Settings → System → Gerätename), '' until set.
class DeviceNameNotifier extends Notifier<String> {
  @override
  String build() {
    ref.read(settingsRepositoryProvider).getDeviceName().then((v) => state = v);
    return '';
  }

  Future<void> set(String name) async {
    state = name.trim();
    await ref.read(settingsRepositoryProvider).setDeviceName(name);
  }
}

final deviceNameProvider = NotifierProvider<DeviceNameNotifier, String>(DeviceNameNotifier.new);
