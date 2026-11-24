import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Where a film was left off - per film (its NAS path), on this device
/// only (a file next to the app's data, not in the backups).
class MovieResumeStore {
  MovieResumeStore({Future<File> Function()? file}) : _file = file ?? _defaultFile;

  final Future<File> Function() _file;
  Map<String, ({int position, int duration, int at})>? _entries;
  Future<void> _writing = Future.value();

  /// Films remembered at most (the oldest go).
  static const maxEntries = 300;

  /// Less than this from the start or the end isn't worth resuming.
  static const _margin = Duration(minutes: 1);

  static Future<File> _defaultFile() async => File('${(await getApplicationSupportDirectory()).path}/movie_resume.json');

  Future<Map<String, ({int position, int duration, int at})>> _load() async {
    final loaded = _entries;
    if (loaded != null) return loaded;
    final entries = <String, ({int position, int duration, int at})>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map) {
          for (final MapEntry(:key, :value) in json.entries) {
            if (key is String && value is Map) {
              final p = value['p'], d = value['d'], t = value['t'];
              if (p is int && d is int && t is int) entries[key] = (position: p, duration: d, at: t);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('MovieResumeStore: $e');
    }
    return _entries = entries;
  }

  /// Where to go on with [key], or null (never watched, watched to the
  /// end, or only the first minute).
  Future<Duration?> position(String key) async {
    final entry = (await _load())[key];
    if (entry == null) return null;
    final position = Duration(milliseconds: entry.position);
    return position < _margin ? null : position;
  }

  /// How far each remembered film was watched (0..1), by key.
  Future<Map<String, double>> progress() async => {
        for (final MapEntry(:key, :value) in (await _load()).entries)
          if (value.duration > 0) key: (value.position / value.duration).clamp(0.0, 1.0),
      };

  /// Remembers [position] of [key] (a film [duration] long); near the end
  /// it's forgotten - the film was watched.
  Future<void> save(String key, Duration position, Duration duration) async {
    final entries = await _load();
    final watched = duration > Duration.zero && duration - position < _margin * 3;
    if (position < _margin || watched) {
      if (entries.remove(key) == null) return;
    } else {
      entries[key] = (
        position: position.inMilliseconds,
        duration: duration.inMilliseconds,
        at: DateTime.now().millisecondsSinceEpoch,
      );
      if (entries.length > maxEntries) {
        final oldest = entries.entries.reduce((a, b) => a.value.at <= b.value.at ? a : b).key;
        entries.remove(oldest);
      }
    }
    await _write(entries);
  }

  Future<void> forget(String key) async {
    final entries = await _load();
    if (entries.remove(key) != null) await _write(entries);
  }

  Future<void> _write(Map<String, ({int position, int duration, int at})> entries) {
    final json = jsonEncode({
      for (final MapEntry(:key, :value) in entries.entries) key: {'p': value.position, 'd': value.duration, 't': value.at},
    });
    return _writing = _writing.then((_) async {
      try {
        final file = await _file();
        await file.parent.create(recursive: true);
        await file.writeAsString(json, flush: true);
      } catch (e) {
        debugPrint('MovieResumeStore: $e');
      }
    });
  }
}
