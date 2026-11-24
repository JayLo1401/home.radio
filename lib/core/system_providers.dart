import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Which of Home System's parts are switched on (Settings → System). A part
/// that is off has no tile under Home, no start option and its settings
/// are greyed out.
typedef SystemParts = ({bool radio, bool tv});

class SystemPartsNotifier extends Notifier<SystemParts> {
  @override
  SystemParts build() {
    _load();
    return (radio: true, tv: true);
  }

  Future<void> _load() async {
    final repo = ref.read(settingsRepositoryProvider);
    state = (radio: await repo.getRadioEnabled(), tv: await repo.getTvEnabled());
  }

  Future<void> setRadio(bool value) async {
    state = (radio: value, tv: state.tv);
    await ref.read(settingsRepositoryProvider).setRadioEnabled(value);
  }

  Future<void> setTv(bool value) async {
    state = (radio: state.radio, tv: value);
    await ref.read(settingsRepositoryProvider).setTvEnabled(value);
  }
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
