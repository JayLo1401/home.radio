import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/launcher_tile.dart';
import '../data/services/nas_service.dart' show NasFolder;
import '../features/launcher/launcher_providers.dart'
    show RadioCommand, launcherSettingsProvider, launcherTilesProvider, radioCommandProvider;
import 'music_providers.dart';
import 'nas_providers.dart';
import '../features/browser/browser_channel.dart';
import 'providers.dart';

/// Which of Home System's parts are switched on (Settings → System). A part
/// that is off has no tile under Home, no start option and its settings
/// are greyed out. The Haussteuerung is off until switched on; Bilder is
/// on once a NAS pictures folder is chosen (until switched off).
typedef SystemParts = ({bool radio, bool tv, bool dashboard, bool pictures, bool movies, bool music, bool browser});

class SystemPartsNotifier extends Notifier<SystemParts> {
  @override
  SystemParts build() {
    _load();
    return (radio: true, tv: true, dashboard: false, pictures: false, movies: false, music: false, browser: false);
  }

  Future<void> _load() async {
    final repo = ref.read(settingsRepositoryProvider);
    final pictures = await repo.getPicturesEnabled();
    final movies = await repo.getMoviesEnabled();
    final music = await repo.getMusicEnabled();
    state = (
      radio: await repo.getRadioEnabled(),
      tv: await repo.getTvEnabled(),
      dashboard: await repo.getDashboardEnabled(),
      pictures: pictures ?? false,
      movies: movies ?? false,
      music: music ?? false,
      browser: BrowserChannel.supported && await repo.getBrowserEnabled(),
    );
    // Its tile in Home's row the first time (on by default on Android).
    if (state.browser) await ref.read(launcherTilesProvider.notifier).add(const LauncherTile.browser());
    // Never decided: on when there is a pictures / films folder already.
    if (pictures == null) await picturesFolderChosen();
    if (movies == null) await moviesFolderChosen();
    if (music == null) await musicFolderChosen();
  }

  SystemParts _with({bool? radio, bool? tv, bool? dashboard, bool? pictures, bool? movies, bool? music, bool? browser}) => (
        radio: radio ?? state.radio,
        tv: tv ?? state.tv,
        dashboard: dashboard ?? state.dashboard,
        pictures: pictures ?? state.pictures,
        movies: movies ?? state.movies,
        music: music ?? state.music,
        browser: browser ?? state.browser,
      );

  /// Off: the radio stops, and a start into Radio becomes a start into Home.
  Future<void> setRadio(bool value) async {
    state = _with(radio: value);
    await ref.read(settingsRepositoryProvider).setRadioEnabled(value);
    if (!value) {
      ref.read(radioCommandProvider.notifier).send(RadioCommand.stop);
      await _startIntoHomeInsteadOf(StartScreen.radio);
    }
  }

  Future<void> setTv(bool value) async {
    state = _with(tv: value);
    await ref.read(settingsRepositoryProvider).setTvEnabled(value);
    if (!value) await _startIntoHomeInsteadOf(StartScreen.tv);
  }

  /// Switching the Haussteuerung on also puts its tile into Home's row.
  Future<void> setDashboard(bool value) async {
    state = _with(dashboard: value);
    await ref.read(settingsRepositoryProvider).setDashboardEnabled(value);
    if (value) {
      await ref.read(launcherTilesProvider.notifier).add(const LauncherTile.dashboard());
    } else {
      await _startIntoHomeInsteadOf(StartScreen.dashboard);
    }
  }

  /// Switching Bilder on also puts its tile into Home's row. There's no
  /// start option for it.
  Future<void> setPictures(bool value) async {
    state = _with(pictures: value);
    await ref.read(settingsRepositoryProvider).setPicturesEnabled(value);
    if (value) await ref.read(launcherTilesProvider.notifier).add(const LauncherTile.pictures());
  }

  /// A NAS pictures folder was chosen (or is there at the start): Bilder
  /// goes on - unless it was ever switched on or off by hand.
  Future<void> picturesFolderChosen() async {
    if (await ref.read(settingsRepositoryProvider).getPicturesEnabled() != null) return;
    final nas = await ref.read(nasSettingsRepositoryProvider).load();
    if (nas.folder(NasFolder.pictures) != null) await setPictures(true);
  }

  /// Switching Filme on also puts its tile into Home's row.
  Future<void> setMovies(bool value) async {
    state = _with(movies: value);
    await ref.read(settingsRepositoryProvider).setMoviesEnabled(value);
    if (value) await ref.read(launcherTilesProvider.notifier).add(const LauncherTile.movies());
  }

  /// A NAS films or videos folder was chosen (or is there at the start):
  /// Filme goes on - unless it was ever switched on or off by hand.
  Future<void> moviesFolderChosen() async {
    if (await ref.read(settingsRepositoryProvider).getMoviesEnabled() != null) return;
    final nas = await ref.read(nasSettingsRepositoryProvider).load();
    if (nas.folder(NasFolder.movies) != null || nas.folder(NasFolder.videos) != null) await setMovies(true);
  }

  /// Switching Musik on also puts its tile into Home's row; off stops
  /// what's playing.
  Future<void> setMusic(bool value) async {
    state = _with(music: value);
    await ref.read(settingsRepositoryProvider).setMusicEnabled(value);
    if (value) {
      await ref.read(launcherTilesProvider.notifier).add(const LauncherTile.music());
    } else {
      await ref.read(musicPlayerProvider).stop();
    }
  }

  /// A NAS music folder was chosen (or is there at the start): Musik goes
  /// on - unless it was ever switched on or off by hand.
  Future<void> musicFolderChosen() async {
    if (await ref.read(settingsRepositoryProvider).getMusicEnabled() != null) return;
    final nas = await ref.read(nasSettingsRepositoryProvider).load();
    if (nas.folder(NasFolder.music) != null) await setMusic(true);
  }

  /// The Browser on/off (Android); on puts its tile into Home's row.
  Future<void> setBrowser(bool value) async {
    state = _with(browser: value);
    await ref.read(settingsRepositoryProvider).setBrowserEnabled(value);
    if (value) await ref.read(launcherTilesProvider.notifier).add(const LauncherTile.browser());
  }

  Future<void> _startIntoHomeInsteadOf(StartScreen part) async {
    if (ref.read(launcherSettingsProvider).startScreen != part) return;
    await ref.read(launcherSettingsProvider.notifier).setStartScreen(StartScreen.launcher);
  }

  /// A part of [type] (LauncherTile's) is on - Radio, TV, Haussteuerung, Bilder;
  /// everything else (apps) always.
  bool showsTile(LauncherTile tile) => switch (tile.type) {
        LauncherTile.radioType => state.radio,
        LauncherTile.tvType => state.tv,
        LauncherTile.dashboardType => state.dashboard,
        LauncherTile.picturesType => state.pictures,
        LauncherTile.moviesType => state.movies,
        LauncherTile.musicType => state.music,
        LauncherTile.browserType => state.browser,
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
