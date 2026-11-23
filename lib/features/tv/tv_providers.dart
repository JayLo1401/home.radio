import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/enigma2_service.dart';

/// The Enigma2 receiver Home TV uses (Einstellungen → Home TV).
class Enigma2ConfigNotifier extends Notifier<Enigma2Config?> {
  @override
  Enigma2Config? build() {
    _load();
    return null; // not loaded yet
  }

  Future<void> _load() async {
    state = await ref.read(settingsRepositoryProvider).getEnigma2Config();
  }

  Future<void> set(Enigma2Config config) async {
    state = config;
    await ref.read(settingsRepositoryProvider).setEnigma2Config(config);
  }
}

final enigma2ConfigProvider = NotifierProvider<Enigma2ConfigNotifier, Enigma2Config?>(Enigma2ConfigNotifier.new);

typedef TvNextUp = ({bool enabled, int leadMinutes, int showSeconds});

/// The "Als Nächstes" note (Einstellungen → Home TV).
class TvNextUpNotifier extends Notifier<TvNextUp> {
  @override
  TvNextUp build() {
    ref.read(settingsRepositoryProvider).getTvNextUp().then((v) => state = v);
    return (enabled: true, leadMinutes: 5, showSeconds: 30);
  }

  Future<void> set(TvNextUp value) async {
    state = value;
    await ref
        .read(settingsRepositoryProvider)
        .setTvNextUp(enabled: value.enabled, leadMinutes: value.leadMinutes, showSeconds: value.showSeconds);
  }
}

final tvNextUpProvider = NotifierProvider<TvNextUpNotifier, TvNextUp>(TvNextUpNotifier.new);

/// "Verschlüsselte Sender: Receiver umschalten" (Einstellungen → Home TV).
class TvZapEncryptedNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.read(settingsRepositoryProvider).getTvZapEncrypted().then((v) => state = v);
    return true;
  }

  Future<void> set(bool value) async {
    state = value;
    await ref.read(settingsRepositoryProvider).setTvZapEncrypted(value);
  }
}

final tvZapEncryptedProvider = NotifierProvider<TvZapEncryptedNotifier, bool>(TvZapEncryptedNotifier.new);

/// The channels (service references) whose stream came scrambled - the
/// receiver is switched to them right away next time, without waiting for
/// the stream to show it. Kept in the settings.
class TvStreamKnowledge {
  TvStreamKnowledge(this._repo) {
    _repo.getTvEncryptedChannels().then(_encrypted.addAll);
  }

  final SettingsRepository _repo;
  final _encrypted = <String>{};

  bool isEncrypted(String serviceRef) => _encrypted.contains(serviceRef);

  void markEncrypted(String serviceRef) {
    if (_encrypted.add(serviceRef)) _repo.setTvEncryptedChannels(_encrypted);
  }
}

final tvStreamKnowledgeProvider = Provider<TvStreamKnowledge>(
  (ref) => TvStreamKnowledge(ref.read(settingsRepositoryProvider)),
);

final enigma2ServiceProvider = Provider<Enigma2Service?>((ref) {
  final config = ref.watch(enigma2ConfigProvider);
  return config == null || !config.configured ? null : Enigma2Service(config);
});

final tvBouquetsProvider = FutureProvider<List<E2Bouquet>>((ref) async {
  final service = ref.watch(enigma2ServiceProvider);
  if (service == null) return const [];
  return service.bouquets();
});

/// The bouquet Home TV shows (its reference), stored; null = the first one.
class TvBouquetNotifier extends Notifier<String?> {
  @override
  String? build() {
    ref.read(settingsRepositoryProvider).getTvBouquet().then((v) {
      if (v != null) state = v;
    });
    return null;
  }

  Future<void> set(String ref_) async {
    state = ref_;
    await ref.read(settingsRepositoryProvider).setTvBouquet(ref_);
  }
}

final tvBouquetProvider = NotifierProvider<TvBouquetNotifier, String?>(TvBouquetNotifier.new);

/// The bouquet actually shown: the chosen one if the box still has it,
/// else the first.
final tvCurrentBouquetProvider = FutureProvider<E2Bouquet?>((ref) async {
  final bouquets = await ref.watch(tvBouquetsProvider.future);
  if (bouquets.isEmpty) return null;
  final chosen = ref.watch(tvBouquetProvider);
  return bouquets.where((b) => b.ref == chosen).firstOrNull ?? bouquets.first;
});

final tvChannelsProvider = FutureProvider<List<E2Channel>>((ref) async {
  final service = ref.watch(enigma2ServiceProvider);
  final bouquet = await ref.watch(tvCurrentBouquetProvider.future);
  if (service == null || bouquet == null) return const [];
  return (await service.channels(bouquet.ref)).where((c) => !c.isRadio).toList();
});

/// Now and next per channel (service reference -> events, by start),
/// refreshed every minute and whenever a programme ends.
final tvNowNextProvider = FutureProvider<Map<String, List<E2Event>>>((ref) async {
  final service = ref.watch(enigma2ServiceProvider);
  final bouquet = await ref.watch(tvCurrentBouquetProvider.future);
  if (service == null || bouquet == null) return const {};
  final timer = Timer(const Duration(minutes: 1), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final events = await service.nowNext(bouquet.ref);
  final map = <String, List<E2Event>>{};
  for (final e in events) {
    (map[serviceKey(e.serviceRef)] ??= []).add(e);
  }
  for (final list in map.values) {
    list.sort((a, b) => a.begin.compareTo(b.begin));
  }
  return map;
});

/// The full EPG of one channel.
final tvChannelEpgProvider = FutureProvider.family<List<E2Event>, String>((ref, serviceRef) async {
  final service = ref.watch(enigma2ServiceProvider);
  if (service == null) return const [];
  return service.channelEpg(serviceRef);
});

/// Service references compared without the trailing ':' and case.
String serviceKey(String serviceRef) => serviceRef.replaceAll(RegExp(r':+$'), '').toUpperCase();

/// Now and next for [channel] from [tvNowNextProvider]'s map.
({E2Event? now, E2Event? next}) nowNextFor(Map<String, List<E2Event>> map, E2Channel channel, DateTime t) {
  final events = map[serviceKey(channel.ref)] ?? const [];
  final now = events.where((e) => e.runsAt(t)).firstOrNull;
  final next = events.where((e) => e.begin.isAfter(t) || (now != null && !e.begin.isBefore(now.end))).firstOrNull;
  return (now: now, next: next);
}
