import '../db/database.dart';
import '../services/music_library.dart' show MusicRepeat;

/// When the visualisation comes up.
/// - [off]: never (no button either);
/// - [manual]: by ↑ / the button on the now-playing screen;
/// - [auto]: also by itself after a minute without a key on the
///   now-playing screen (like a screen saver).
enum MusicVisualizerMode { off, manual, auto }

/// How much the visualisation draws: [auto] picks by the device (a weak
/// box like the Fire TV Stick gets [low]).
enum MusicVisualizerQuality { auto, low, high }

/// Musik's settings (Einstellungen → Musik and the admin page).
class MusicSettings {
  const MusicSettings({
    this.shuffle = false,
    this.repeat = MusicRepeat.off,
    this.preferTags = true,
    this.visualizer = MusicVisualizerMode.auto,
    this.audioReactive = false,
    this.quality = MusicVisualizerQuality.auto,
    this.loaded = false,
    this.subfolders = false,
    this.visualizerInterval = defaultVisualizerInterval,
  });

  /// The choices for [visualizerInterval] (seconds; 0 = only with ↑).
  static const visualizerIntervals = [20, 45, 90, 0];
  static const defaultVisualizerInterval = 45;

  /// Shuffle is on (kept from the last time).
  final bool shuffle;
  final MusicRepeat repeat;

  /// Artist/title from the files' tags where there are some - else always
  /// the file name.
  final bool preferTags;
  final MusicVisualizerMode visualizer;

  /// The visualisation follows the music (Android: needs the microphone
  /// permission, see MusicSpectrum).
  final bool audioReactive;
  final MusicVisualizerQuality quality;
  final bool loaded;

  /// Playing a folder ("Abspielen" / "Zufällig abspielen") takes its
  /// subfolders along - off by default: just the folder chosen.
  final bool subfolders;

  /// Seconds until the visualisation changes to another scene by itself;
  /// 0: only with ↑.
  final int visualizerInterval;

  MusicSettings copyWith({
    bool? shuffle,
    MusicRepeat? repeat,
    bool? preferTags,
    MusicVisualizerMode? visualizer,
    bool? audioReactive,
    MusicVisualizerQuality? quality,
    bool? subfolders,
    int? visualizerInterval,
  }) =>
      MusicSettings(
        shuffle: shuffle ?? this.shuffle,
        repeat: repeat ?? this.repeat,
        preferTags: preferTags ?? this.preferTags,
        visualizer: visualizer ?? this.visualizer,
        audioReactive: audioReactive ?? this.audioReactive,
        quality: quality ?? this.quality,
        subfolders: subfolders ?? this.subfolders,
        visualizerInterval: visualizerInterval ?? this.visualizerInterval,
        loaded: true,
      );
}

/// Stores [MusicSettings] in the settings table (so backups carry them),
/// keys "music_*".
class MusicSettingsRepository {
  MusicSettingsRepository(this._db);

  final AppDatabase _db;

  static const shuffleKey = 'music_shuffle';
  static const repeatKey = 'music_repeat';
  static const preferTagsKey = 'music_prefer_tags';
  static const visualizerKey = 'music_visualizer';
  static const audioReactiveKey = 'music_audio_reactive';
  static const qualityKey = 'music_visualizer_quality';
  static const subfoldersKey = 'music_with_subfolders';
  static const intervalKey = 'music_visualizer_interval';

  static T _parse<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  Future<MusicSettings> load() async {
    const d = MusicSettings();
    return MusicSettings(
      shuffle: (await _db.getSetting(shuffleKey)) == 'true',
      repeat: _parse(MusicRepeat.values, await _db.getSetting(repeatKey), d.repeat),
      preferTags: (await _db.getSetting(preferTagsKey)) != 'false',
      visualizer: _parse(MusicVisualizerMode.values, await _db.getSetting(visualizerKey), d.visualizer),
      audioReactive: (await _db.getSetting(audioReactiveKey)) == 'true',
      quality: _parse(MusicVisualizerQuality.values, await _db.getSetting(qualityKey), d.quality),
      subfolders: (await _db.getSetting(subfoldersKey)) == 'true',
      visualizerInterval: _interval(await _db.getSetting(intervalKey)),
      loaded: true,
    );
  }

  static int _interval(String? value) {
    final v = int.tryParse(value ?? '');
    return v != null && MusicSettings.visualizerIntervals.contains(v) ? v : MusicSettings.defaultVisualizerInterval;
  }

  Future<void> save(MusicSettings s) async {
    await _db.setSetting(shuffleKey, '${s.shuffle}');
    await _db.setSetting(repeatKey, s.repeat.name);
    await _db.setSetting(preferTagsKey, '${s.preferTags}');
    await _db.setSetting(visualizerKey, s.visualizer.name);
    await _db.setSetting(audioReactiveKey, '${s.audioReactive}');
    await _db.setSetting(qualityKey, s.quality.name);
    await _db.setSetting(subfoldersKey, '${s.subfolders}');
    await _db.setSetting(intervalKey, '${s.visualizerInterval}');
  }
}
