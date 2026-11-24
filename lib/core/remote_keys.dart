import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'providers.dart';

/// What a key of the remote (or the PC's keyboard) can do - assignable in
/// Einstellungen → Tasten der Fernbedienung, e.g. when ☰ does something else
/// on the remote.
enum RemoteAction {
  /// TV: the channel list.
  channelList,

  /// TV: the programme guide of the channel (also in the channel list).
  guide,

  /// The options: of a launcher tile or app, TV's menu (programme
  /// guide, sound track).
  options,

  /// TV: choosing the sound track.
  audio;

  /// The action's name in the app's language.
  String get label => switch (this) {
        RemoteAction.channelList => l10n.miscActionChannelList,
        RemoteAction.guide => l10n.miscActionGuide,
        RemoteAction.options => l10n.miscActionOptions,
        RemoteAction.audio => l10n.miscActionAudio,
      };

  /// The standard keys: the remote's, plus a letter on the PC's keyboard.
  List<LogicalKeyboardKey> get standard => switch (this) {
        RemoteAction.channelList => const [
            LogicalKeyboardKey.select,
            LogicalKeyboardKey.enter,
            LogicalKeyboardKey.numpadEnter,
            LogicalKeyboardKey.gameButtonA,
          ],
        RemoteAction.guide => const [LogicalKeyboardKey.info, LogicalKeyboardKey.guide, LogicalKeyboardKey.keyE],
        RemoteAction.options => const [LogicalKeyboardKey.contextMenu, LogicalKeyboardKey.keyO],
        RemoteAction.audio => const [LogicalKeyboardKey.mediaAudioTrack, LogicalKeyboardKey.keyA],
      };
}

/// Keys that can't be assigned: they move, go back or leave.
final unassignableKeys = {
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.goBack,
  LogicalKeyboardKey.browserBack,
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.browserHome,
};

/// The keys of every action; an action the user set has exactly the keys
/// set, else its standard ones.
class RemoteKeys {
  const RemoteKeys([this._custom = const {}]);

  final Map<RemoteAction, List<LogicalKeyboardKey>> _custom;

  List<LogicalKeyboardKey> keysOf(RemoteAction action) => _custom[action] ?? action.standard;

  bool isCustom(RemoteAction action) => _custom.containsKey(action);

  /// Whether [key] does [action].
  bool matches(RemoteAction action, LogicalKeyboardKey key) => keysOf(action).contains(key);

  /// The action [key] does, if any.
  RemoteAction? actionOf(LogicalKeyboardKey key) =>
      RemoteAction.values.where((a) => matches(a, key)).firstOrNull;
}

class RemoteKeysNotifier extends Notifier<RemoteKeys> {
  @override
  RemoteKeys build() {
    _load();
    return const RemoteKeys();
  }

  Future<void> _load() async {
    final saved = await ref.read(settingsRepositoryProvider).getRemoteKeys();
    final custom = <RemoteAction, List<LogicalKeyboardKey>>{};
    for (final action in RemoteAction.values) {
      final ids = saved[action.name];
      if (ids == null) continue;
      custom[action] = [for (final id in ids) LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id)];
    }
    state = RemoteKeys(custom);
  }

  Map<RemoteAction, List<LogicalKeyboardKey>> get _current => {
        for (final a in RemoteAction.values)
          if (state.isCustom(a)) a: state.keysOf(a),
      };

  Future<void> _save(Map<RemoteAction, List<LogicalKeyboardKey>> custom) async {
    state = RemoteKeys(custom);
    await ref.read(settingsRepositoryProvider).setRemoteKeys({
      for (final e in custom.entries) e.key.name: [for (final k in e.value) k.keyId],
    });
  }

  /// [action] gets [key] alone (its standard keys no longer count); another
  /// action that had [key] loses it.
  Future<void> assign(RemoteAction action, LogicalKeyboardKey key) async {
    final custom = _current;
    for (final other in RemoteAction.values) {
      if (other == action || !state.matches(other, key)) continue;
      custom[other] = [for (final k in state.keysOf(other)) if (k != key) k];
    }
    custom[action] = [key];
    await _save(custom);
  }

  Future<void> reset(RemoteAction action) async {
    await _save(_current..remove(action));
  }
}

final remoteKeysProvider = NotifierProvider<RemoteKeysNotifier, RemoteKeys>(RemoteKeysNotifier.new);

/// The key to name for [action] in hints on screen: on the PC a key of the
/// keyboard (Enter, a letter, ☰), on the TV box the remote's.
String remoteKeyHint(RemoteKeys keys, RemoteAction action) {
  final list = keys.keysOf(action);
  if (list.isEmpty) return '–';
  final pc = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  bool keyboard(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.contextMenu || k.keyLabel.trim().length == 1;
  final key = pc ? list.where(keyboard).firstOrNull ?? list.first : list.where((k) => !keyboard(k)).firstOrNull ?? list.first;
  return _keyLabel(key, short: true);
}

/// A key's name as it's printed on a remote or a keyboard.
String remoteKeyLabel(LogicalKeyboardKey key) => _keyLabel(key, short: false);

/// [short]: for hints - "☰" without the word "Menu", a letter without "Key".
String _keyLabel(LogicalKeyboardKey key, {required bool short}) {
  if (key == LogicalKeyboardKey.select) return 'OK';
  if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) return 'Enter';
  if (key == LogicalKeyboardKey.contextMenu) return short ? '☰' : l10n.miscKeyMenu;
  if (key == LogicalKeyboardKey.info) return 'Info';
  if (key == LogicalKeyboardKey.guide) return 'Guide/EPG';
  if (key == LogicalKeyboardKey.mediaAudioTrack) return 'Audio';
  if (key == LogicalKeyboardKey.browserSearch) return l10n.miscKeySearch;
  if (key == LogicalKeyboardKey.gameButtonA) return 'A (Gamepad)';
  if (key == LogicalKeyboardKey.colorF0Red) return l10n.miscKeyRed;
  if (key == LogicalKeyboardKey.colorF1Green) return l10n.miscKeyGreen;
  if (key == LogicalKeyboardKey.colorF2Yellow) return l10n.miscKeyYellow;
  if (key == LogicalKeyboardKey.colorF3Blue) return l10n.miscKeyBlue;
  final label = key.keyLabel.trim();
  if (label.isNotEmpty) return label.length == 1 && !short ? l10n.miscKeyNamed(label) : label;
  return key.debugName ?? (short ? '${key.keyId}' : l10n.miscKeyNamed('${key.keyId}'));
}
