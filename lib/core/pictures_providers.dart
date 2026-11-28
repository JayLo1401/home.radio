import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/settings_repository.dart';
import '../data/services/nas_service.dart' show normalizeNasPath;
import '../data/services/picture_library.dart';
import 'providers.dart';

/// Bilder: how slideshows run (Einstellungen → Bilder, the slideshow's
/// options, the admin page).
class SlideshowSettingsNotifier extends Notifier<SlideshowSettings> {
  @override
  SlideshowSettings build() {
    ref.watch(settingsRepositoryProvider).getSlideshowSettings().then((v) => state = v);
    return const SlideshowSettings();
  }

  Future<void> set(SlideshowSettings value) async {
    state = value;
    await ref.read(settingsRepositoryProvider).setSlideshowSettings(value);
  }

  /// The interval [direction] steps longer (1) or shorter (-1) - no wrap.
  Future<void> stepInterval(int direction) {
    const steps = SettingsRepository.slideshowIntervals;
    final i = steps.indexOf(state.intervalSeconds);
    final next = steps[((i < 0 ? steps.indexOf(SettingsRepository.defaultSlideshowInterval) : i) + direction)
        .clamp(0, steps.length - 1)];
    return set(state.copyWith(intervalSeconds: next));
  }
}

final slideshowSettingsProvider =
    NotifierProvider<SlideshowSettingsNotifier, SlideshowSettings>(SlideshowSettingsNotifier.new);

/// Bilder: videos in the pictures folders are shown too (the switch in its
/// top bar, Einstellungen → Bilder, the admin page) - off until switched on.
class PicturesShowVideosNotifier extends Notifier<bool> {
  @override
  bool build() {
    try {
      ref
          .watch(settingsRepositoryProvider)
          .getPicturesShowVideos()
          .then<void>((v) => state = v, onError: (Object e) => debugPrint('pictures show videos: $e'));
    } catch (e) {
      debugPrint('pictures show videos: $e');
    }
    return false;
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      await ref.read(settingsRepositoryProvider).setPicturesShowVideos(value);
    } catch (e) {
      debugPrint('pictures show videos: $e');
    }
  }
}

final picturesShowVideosProvider = NotifierProvider<PicturesShowVideosNotifier, bool>(PicturesShowVideosNotifier.new);

/// Where each folder's slideshow was last (the 30 most recent folders), so
/// the next start can go on from there. In the settings table - small, and
/// part of backups.
class SlideshowResumeStore {
  SlideshowResumeStore(this._read, this._write);

  static const _key = 'slideshow_resume';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  Map<String, SlideshowResumePoint>? _points;

  /// The key of [folder] on the NAS with [identity] (another NAS can have
  /// the same paths).
  static String keyOf(String identity, String folder) => '$identity|${normalizeNasPath(folder)}';

  Future<Map<String, SlideshowResumePoint>> _load() async => _points ??= decodeResumePoints(await _read(_key));

  Future<SlideshowResumePoint?> get(String key) async => (await _load())[key];

  Future<void> save(String key, SlideshowResumePoint point) async {
    final points = await _load();
    final raw = encodeResumePoints(points, key, point);
    _points = decodeResumePoints(raw);
    await _write(_key, raw);
  }
}

final slideshowResumeProvider = Provider<SlideshowResumeStore>((ref) {
  final db = ref.watch(databaseProvider);
  return SlideshowResumeStore(db.getSetting, db.setSetting);
});
