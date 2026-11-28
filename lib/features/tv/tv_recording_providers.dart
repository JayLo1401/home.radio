import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/enigma2_recordings.dart';
import '../../data/services/enigma2_service.dart';
import 'tv_providers.dart';

/// The receiver's timers and recordings over OpenWebif (null: no receiver).
final enigma2RecordingsProvider = Provider<Enigma2Recordings?>((ref) {
  final config = ref.watch(enigma2ConfigProvider);
  return config == null || !config.configured ? null : Enigma2Recordings(config);
});

/// The receiver's timers - the guide marks the programmes it records.
/// Fetched while something shows them, every two minutes again.
final tvTimersProvider = FutureProvider.autoDispose<List<E2Timer>>((ref) async {
  final api = ref.watch(enigma2RecordingsProvider);
  if (api == null) return const [];
  final timer = Timer(const Duration(minutes: 2), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return api.timers();
});

/// Whether [event] on [serviceRef] will be (or is being) recorded, by
/// [timers] as loaded (none while loading or on an error).
bool isRecorded(List<E2Timer>? timers, String serviceRef, E2Event event) =>
    timers != null && timerForEvent(timers, serviceRef, event) != null;
