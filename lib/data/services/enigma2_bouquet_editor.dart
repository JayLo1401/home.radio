import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../l10n/l10n.dart';
import 'enigma2_service.dart';

/// One step for the receiver: [ref] (exactly as the bouquet lists it) to
/// index [position] of the bouquet - counted over every entry, markers,
/// radio channels and hidden ones included (that's how Enigma2 counts).
typedef BouquetMove = ({String ref, int position});

/// The receiver's OpenWebif has no bouquet editor (the controller is missing
/// or its BouquetEditor plugin isn't installed) - the order stays in the app.
class BouquetEditorUnavailable implements Exception {
  @override
  String toString() => 'BouquetEditor not available';
}

/// The receiver answered every move, but its bouquet doesn't show the new
/// order afterwards. [channels]: the bouquet as it is now (its TV channels).
class BouquetOrderMismatch implements Exception {
  BouquetOrderMismatch(this.channels);

  final List<E2Channel> channels;

  @override
  String toString() => l10n.tvOrderMismatch;
}

/// Writes a new channel order into a bouquet of the receiver, through
/// OpenWebif's bouquet editor (the "bouqueteditor" controller):
///
///   GET /bouqueteditor/api/moveservice?sBouquetRef=…&sRef=…&mode=0&position=…
///
/// answers {"Result": [true, "Service … moved."]}. OpenWebif calls
/// Enigma2's eBouquet::moveService(ref, position) - position is the entry's
/// new 0-based index among all entries of the bouquet - then flushChanges()
/// (the bouquet file is written) and refreshes the receiver's own channel
/// list; no bouquet reload is needed. It answers true even when Enigma2
/// refused the move, so the bouquet is read again afterwards to check.
/// The same in E2OpenPlugins' OpenWebif and oe-alliance's fork (OpenATV);
/// only the former answers [false, "BouquetEditor plugin not found"] when
/// its BouquetEditor module is missing.
class Enigma2BouquetEditor {
  Enigma2BouquetEditor(this.config, {http.Client? client}) : _client = client ?? http.Client();

  final Enigma2Config config;
  final http.Client _client;
  static const _timeout = Duration(seconds: 15);

  Future<http.Response> _send(String path, Map<String, String> query) async {
    if (!config.configured) throw Enigma2Exception(l10n.tvErrorNoReceiver);
    try {
      return await _client.get(config.webUri(path, query), headers: config.authHeaders).timeout(_timeout);
    } catch (e) {
      throw Enigma2Exception(l10n.tvErrorUnreachable(config.host, '$e'));
    }
  }

  Map<String, dynamic> _json(http.Response response) {
    if (response.statusCode == 401) throw Enigma2Exception(l10n.tvErrorLoginRejected);
    if (response.statusCode != 200) throw Enigma2Exception(l10n.tvErrorHttpStatus('${response.statusCode}'));
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    throw Enigma2Exception(l10n.tvErrorUnexpectedResponse);
  }

  /// Every entry of the bouquet - markers and hidden ones too ("hidden=1"),
  /// in the receiver's order - with picons, so the TV channels can be taken
  /// from the same answer.
  Future<Map<String, dynamic>> bouquet(String bouquetRef) async =>
      _json(await _send('/api/getservices', {'sRef': bouquetRef, 'picon': '1', 'hidden': '1'}));

  /// Moves [ref] to index [position] of the bouquet.
  Future<void> moveService(String bouquetRef, String ref, int position) async {
    final response = await _send('/bouqueteditor/api/moveservice', {
      'sBouquetRef': bouquetRef,
      'sRef': ref,
      // OpenWebif passes it on but moveService doesn't use it (0 = TV).
      'mode': '0',
      'position': '$position',
    });
    // No bouquet editor in this OpenWebif.
    if (response.statusCode == 404) throw BouquetEditorUnavailable();
    final result = _json(response)['Result'];
    if (result is! List || result.isEmpty) throw Enigma2Exception(l10n.tvErrorUnexpectedResponse);
    if (result.first == true) return;
    final message = result.length > 1 ? '${result[1]}' : '';
    // The controller is there, its BouquetEditor module isn't.
    if (message.contains('plugin not found')) throw BouquetEditorUnavailable();
    throw Enigma2Exception(message.isEmpty ? l10n.tvErrorUnexpectedResponse : message);
  }

  /// Puts the bouquet's TV channels into the order [desired] (service
  /// references; [moved] is the one the user moved - it goes next to the
  /// channel it was moved past, markers stay where they are). Returns the
  /// bouquet's TV channels as they are afterwards.
  Future<List<E2Channel>> applyOrder(String bouquetRef, List<String> desired, {String? moved}) async {
    final before = await bouquet(bouquetRef);
    final moves = planBouquetMoves(bouquetEntries(before), desired, moved: moved);
    for (final m in moves) {
      await moveService(bouquetRef, m.ref, m.position);
    }
    final after = moves.isEmpty ? before : await bouquet(bouquetRef);
    final channels = parseChannels(after).where((c) => !c.isRadio).toList();
    final wanted = desired.map(_key).toList();
    final present = channels.map((c) => _key(c.ref)).toSet();
    final wantedSet = wanted.toSet();
    final got = [for (final c in channels) if (wantedSet.contains(_key(c.ref))) _key(c.ref)];
    if (!_sameOrder(_unique(got), _unique(wanted.where(present.contains)))) throw BouquetOrderMismatch(channels);
    return channels;
  }
}

/// The service references of every entry of a bouquet, in its order.
List<String> bouquetEntries(Map<String, dynamic> json) => [
      for (final s in (json['services'] as List? ?? const []).whereType<Map>())
        if (s['servicereference'] is String) s['servicereference'] as String,
    ];

String _key(String ref) => ref.replaceAll(RegExp(r':+$'), '').toUpperCase();

List<String> _unique(Iterable<String> keys) {
  final seen = <String>{};
  return [for (final k in keys) if (seen.add(k)) k];
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The moves that turn the bouquet [raw] (every entry, in order) into one
/// whose channels from [desired] come in that order. Entries not in
/// [desired] (markers, radio channels, hidden ones) stay in place; as few
/// channels as possible are moved (the longest run already in order stays).
/// [moved] - the channel the user moved - is placed last, right before the
/// channel it was moved above or right after the one it was moved below, so
/// it lands on the side of a marker the user expects.
/// Positions count as Enigma2's eBouquet::moveService does: the entry's new
/// index, the moves applied one after another.
List<BouquetMove> planBouquetMoves(List<String> raw, List<String> desired, {String? moved}) {
  final sim = List<String>.of(raw);
  final keys = [for (final r in sim) _key(r)];
  final present = keys.toSet();
  final order = _unique(desired.map(_key).where(present.contains));
  final wanted = order.toSet();
  final movedKey = moved == null ? null : _key(moved);
  final moves = <BouquetMove>[];

  int indexOf(String key) => keys.indexOf(key);
  void move(int from, int to) {
    if (from == to) return;
    final ref = sim.removeAt(from);
    final key = keys.removeAt(from);
    sim.insert(to, ref);
    keys.insert(to, key);
    moves.add((ref: ref, position: to));
  }

  // Whether a channel of the order (other than [skip]) lies between two
  // indexes (exclusive).
  bool channelBetween(int a, int b, String skip) {
    for (var i = a + 1; i < b; i++) {
      final k = keys[i];
      if (k != skip && k != movedKey && wanted.contains(k) && indexOf(k) == i) return true;
    }
    return false;
  }

  // 1. Every channel but the moved one.
  final rest = [for (final k in order) if (k != movedKey) k];
  final rank = {for (var i = 0; i < rest.length; i++) rest[i]: i};
  final current = [for (var i = 0; i < keys.length; i++) if (rank.containsKey(keys[i]) && indexOf(keys[i]) == i) keys[i]];
  final fixed = _longestInOrder(current, rank);
  for (var k = 0; k < rest.length; k++) {
    final x = rest[k];
    if (fixed.contains(x)) continue;
    final s = indexOf(x);
    if (k == 0) {
      // First of all: before the first other channel.
      for (var i = 0; i < s; i++) {
        final key = keys[i];
        if (key != movedKey && rank.containsKey(key) && indexOf(key) == i) {
          move(s, i);
          break;
        }
      }
      continue;
    }
    final r = indexOf(rest[k - 1]);
    if (s < r) {
      move(s, r);
    } else if (channelBetween(r, s, x)) {
      move(s, r + 1);
    }
  }

  // 2. The moved channel, next to its new neighbours.
  if (movedKey != null && wanted.contains(movedKey)) {
    final j = order.indexOf(movedKey);
    final s = indexOf(movedKey);
    final pred = j > 0 ? indexOf(order[j - 1]) : -1;
    final succ = j < order.length - 1 ? indexOf(order[j + 1]) : -1;
    if (succ >= 0 && s > succ) {
      move(s, succ);
    } else if (pred >= 0 && s < pred) {
      move(s, pred);
    }
  }
  return moves;
}

/// The longest run of [items] already in the order of [rank] (not
/// necessarily next to each other) - those needn't move.
Set<String> _longestInOrder(List<String> items, Map<String, int> rank) {
  if (items.isEmpty) return {};
  // Patience sorting: tails[l] = index into items of the smallest rank
  // ending a run of length l + 1.
  final tails = <int>[];
  final previous = List<int>.filled(items.length, -1);
  for (var i = 0; i < items.length; i++) {
    final v = rank[items[i]]!;
    var lo = 0, hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (rank[items[tails[mid]]]! < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) previous[i] = tails[lo - 1];
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  final result = <String>{};
  for (var i = tails.last; i >= 0; i = previous[i]) {
    result.add(items[i]);
  }
  return result;
}
