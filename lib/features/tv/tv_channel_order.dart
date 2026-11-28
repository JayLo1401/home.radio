import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/enigma2_bouquet_editor.dart';
import '../../data/services/enigma2_service.dart';
import 'tv_providers.dart';

/// The order of the receiver's channels, changed in the channel list
/// ("Verschieben"): written into the receiver's bouquet through OpenWebif's
/// bouquet editor, so the receiver shows the same order. Without a bouquet
/// editor on the receiver the order is kept in the app only (per receiver
/// and bouquet) and laid over the bouquet's order - the channel numbers
/// follow it either way.

/// The channels of the bouquet shown, as the receiver lists them (TV
/// channels only) - [tvChannelsProvider] lays the app's order over them.
typedef TvBouquetChannels = ({String? bouquetRef, List<E2Channel> channels});

class TvBouquetChannelsNotifier extends AsyncNotifier<TvBouquetChannels> {
  @override
  Future<TvBouquetChannels> build() async {
    final service = ref.watch(enigma2ServiceProvider);
    final bouquet = await ref.watch(tvCurrentBouquetProvider.future);
    if (service == null || bouquet == null) return (bouquetRef: null, channels: const <E2Channel>[]);
    final channels = (await service.channels(bouquet.ref)).where((c) => !c.isRadio).toList();
    return (bouquetRef: bouquet.ref, channels: channels);
  }

  /// The bouquet as just read back from the receiver (after writing it) -
  /// no second query, no loading state in the list.
  void replace(String bouquetRef, List<E2Channel> channels) {
    if (state.value?.bouquetRef != bouquetRef) return;
    state = AsyncData((bouquetRef: bouquetRef, channels: renumberChannels(channels)));
  }
}

final tvBouquetChannelsProvider =
    AsyncNotifierProvider<TvBouquetChannelsNotifier, TvBouquetChannels>(TvBouquetChannelsNotifier.new);

/// [tvChannelsProvider]'s list: the bouquet's channels in the app's order
/// (if it has one for it), numbered 1, 2, 3, ... in that order. Straight
/// away when both are there - a changed order mustn't make the list load.
FutureOr<List<E2Channel>> orderedTvChannels(Ref ref) {
  final orders = ref.watch(tvChannelOrderProvider);
  final box = ref.watch(tvBouquetChannelsProvider);
  if (!orders.loaded) return Completer<List<E2Channel>>().future; // in a moment
  List<E2Channel> ordered(TvBouquetChannels b) =>
      b.bouquetRef == null ? b.channels : applyChannelOrder(b.channels, orders.orderFor(b.bouquetRef!));
  if (!box.isLoading && box.hasValue) return ordered(box.requireValue);
  if (!box.isLoading && box.hasError) Error.throwWithStackTrace(box.error!, box.stackTrace ?? StackTrace.current);
  return ref.watch(tvBouquetChannelsProvider.future).then(ordered);
}

/// The same channels numbered 1, 2, 3, ... in this order.
List<E2Channel> renumberChannels(List<E2Channel> channels) => [
      for (var i = 0; i < channels.length; i++)
        channels[i].number == i + 1
            ? channels[i]
            : E2Channel(
                ref: channels[i].ref,
                name: channels[i].name,
                number: i + 1,
                piconPath: channels[i].piconPath,
                hasPicon: channels[i].hasPicon,
              ),
    ];

/// [channels] in [order] (service keys, see [serviceKey]), renumbered.
/// Channels the order doesn't know (new in the bouquet) stay behind the
/// channel they follow in the bouquet; ones gone from it are skipped.
List<E2Channel> applyChannelOrder(List<E2Channel> channels, List<String>? order) {
  if (order == null || order.isEmpty) return channels;
  final rank = <String, int>{};
  for (var i = 0; i < order.length; i++) {
    rank.putIfAbsent(order[i], () => i);
  }
  final known = [for (final c in channels) if (rank.containsKey(serviceKey(c.ref))) c];
  // A stable sort: two entries of the same channel keep their order.
  final indexed = [for (var i = 0; i < known.length; i++) (i, known[i])]
    ..sort((a, b) {
      final r = rank[serviceKey(a.$2.ref)]!.compareTo(rank[serviceKey(b.$2.ref)]!);
      return r != 0 ? r : a.$1.compareTo(b.$1);
    });
  final result = [for (final e in indexed) e.$2];
  for (var i = 0; i < channels.length; i++) {
    final c = channels[i];
    if (rank.containsKey(serviceKey(c.ref))) continue;
    var at = 0;
    for (var p = i - 1; p >= 0; p--) {
      final found = result.indexOf(channels[p]);
      if (found >= 0) {
        at = found + 1;
        break;
      }
    }
    result.insert(at, c);
  }
  return renumberChannels(result);
}

/// The app's channel orders: [local] ones (no bouquet editor on the
/// receiver, kept in the settings) and [pending] ones (being written to
/// the receiver right now - shown meanwhile). Keyed by [orderKey].
class TvChannelOrders {
  const TvChannelOrders({this.loaded = false, this.host = '', this.local = const {}, this.pending = const {}});

  final bool loaded;

  /// The receiver the orders are for (the host in Einstellungen → TV).
  final String host;
  final Map<String, List<String>> local;
  final Map<String, List<String>> pending;

  static String orderKey(String host, String bouquetRef) => '${host.trim().toLowerCase()}|$bouquetRef';

  List<String>? orderFor(String bouquetRef) {
    final key = orderKey(host, bouquetRef);
    return pending[key] ?? local[key];
  }

  bool hasLocalOrder(String bouquetRef) => local.containsKey(orderKey(host, bouquetRef));

  TvChannelOrders copyWith({bool? loaded, String? host, Map<String, List<String>>? local, Map<String, List<String>>? pending}) =>
      TvChannelOrders(
        loaded: loaded ?? this.loaded,
        host: host ?? this.host,
        local: local ?? this.local,
        pending: pending ?? this.pending,
      );
}

/// Where the app-only orders are kept (the settings table) - replaceable
/// in tests.
class TvChannelOrderStore {
  TvChannelOrderStore(this.read, this.write);

  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String value) write;

  static const _ordersKey = 'tv_channel_orders';
  static const _toldKey = 'tv_channel_order_local_told';

  Future<Map<String, List<String>>> orders() async {
    try {
      final json = jsonDecode(await read(_ordersKey) ?? '{}');
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (e.value is List) '${e.key}': [for (final k in e.value as List) '$k'],
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> setOrders(Map<String, List<String>> orders) => write(_ordersKey, jsonEncode(orders));

  /// The receivers (hosts) the user was told about the missing bouquet
  /// editor - once each.
  Future<Set<String>> told() async {
    try {
      final json = jsonDecode(await read(_toldKey) ?? '[]');
      return {for (final h in json as List) '$h'};
    } catch (_) {
      return {};
    }
  }

  Future<void> setTold(Set<String> hosts) => write(_toldKey, jsonEncode(hosts.toList()));
}

final tvChannelOrderStoreProvider = Provider<TvChannelOrderStore>((ref) {
  final db = ref.watch(databaseProvider);
  return TvChannelOrderStore(db.getSetting, db.setSetting);
});

/// The receiver's bouquet editor (null without a receiver).
final enigma2BouquetEditorProvider = Provider<Enigma2BouquetEditor?>((ref) {
  final config = ref.watch(enigma2ConfigProvider);
  return config == null || !config.configured ? null : Enigma2BouquetEditor(config);
});

enum TvOrderOutcome {
  /// Nothing changed.
  unchanged,

  /// Written into the receiver's bouquet.
  receiver,

  /// Kept in the app - the receiver has no bouquet editor; [firstTime]: the
  /// user hasn't been told yet.
  localOnly,

  /// Writing failed - the old order is back.
  failed,
}

typedef TvOrderResult = ({TvOrderOutcome outcome, bool firstTime, String? error});

class TvChannelOrderNotifier extends Notifier<TvChannelOrders> {
  /// The writes one after another (a second move waits for the first).
  Future<void> _queue = Future.value();
  int _generation = 0;

  /// This session found no bouquet editor on this receiver - the next
  /// moves aren't tried there again.
  String? _noEditorHost;

  @override
  TvChannelOrders build() {
    final host = ref.watch(enigma2ConfigProvider.select((c) => c?.host.trim().toLowerCase() ?? ''));
    _load(host);
    return TvChannelOrders(host: host);
  }

  TvChannelOrderStore get _store => ref.read(tvChannelOrderStoreProvider);

  Future<void> _load(String host) async {
    var local = <String, List<String>>{};
    try {
      local = await _store.orders();
    } catch (_) {}
    if (!ref.mounted || state.host != host) return;
    state = state.copyWith(loaded: true, local: {...local, ...state.local});
  }

  Future<void> _setLocal(String key, List<String>? order) async {
    final local = {...state.local};
    order == null ? local.remove(key) : local[key] = order;
    state = state.copyWith(local: local);
    try {
      await _store.setOrders(local);
    } catch (_) {}
  }

  void _setPending(String key, List<String>? order) {
    final pending = {...state.pending};
    order == null ? pending.remove(key) : pending[key] = order;
    state = state.copyWith(pending: pending);
  }

  /// [order]: the bouquet's TV channels in their new order, [moved] the
  /// channel the user moved. Shown in that order at once; written to the
  /// receiver; if that fails, the old order is back.
  Future<TvOrderResult> commit(String bouquetRef, List<E2Channel> order, {E2Channel? moved}) {
    final host = state.host;
    final key = TvChannelOrders.orderKey(host, bouquetRef);
    final keys = [for (final c in order) serviceKey(c.ref)];
    final editor = ref.read(enigma2BouquetEditorProvider);
    final generation = ++_generation;
    // Right away (before anything is awaited): the list never shows the
    // old order in between.
    _setPending(key, keys);
    final done = Completer<TvOrderResult>();
    _queue = _queue.then((_) async {
      TvOrderResult result;
      try {
        result = await _write(host, key, bouquetRef, order, keys, moved, editor);
      } catch (e) {
        result = (outcome: TvOrderOutcome.failed, firstTime: false, error: '$e');
      }
      if (generation == _generation) _setPending(key, null);
      done.complete(result);
    });
    return done.future;
  }

  Future<TvOrderResult> _write(
    String host,
    String key,
    String bouquetRef,
    List<E2Channel> order,
    List<String> keys,
    E2Channel? moved,
    Enigma2BouquetEditor? editor,
  ) async {
    Future<TvOrderResult> keepLocal() async {
      _noEditorHost = host;
      await _setLocal(key, keys);
      var firstTime = false;
      try {
        final told = await _store.told();
        if (told.add(host)) {
          firstTime = true;
          await _store.setTold(told);
        }
      } catch (_) {}
      return (outcome: TvOrderOutcome.localOnly, firstTime: firstTime, error: null);
    }

    if (editor == null || _noEditorHost == host) return keepLocal();
    try {
      final channels = await editor.applyOrder(bouquetRef, [for (final c in order) c.ref], moved: moved?.ref);
      // The receiver has the order now - an app-only one isn't needed.
      ref.read(tvBouquetChannelsProvider.notifier).replace(bouquetRef, channels);
      if (state.local.containsKey(key)) await _setLocal(key, null);
      return (outcome: TvOrderOutcome.receiver, firstTime: false, error: null);
    } on BouquetEditorUnavailable {
      return keepLocal();
    } on BouquetOrderMismatch catch (e) {
      // What the receiver really has now.
      ref.read(tvBouquetChannelsProvider.notifier).replace(bouquetRef, e.channels);
      if (state.local.containsKey(key)) await _setLocal(key, null);
      return (outcome: TvOrderOutcome.failed, firstTime: false, error: '$e');
    }
  }

  /// Back to the receiver's own order (drops the app's order of the bouquet).
  Future<void> resetLocal(String bouquetRef) => _setLocal(TvChannelOrders.orderKey(state.host, bouquetRef), null);
}

final tvChannelOrderProvider =
    NotifierProvider<TvChannelOrderNotifier, TvChannelOrders>(TvChannelOrderNotifier.new);
