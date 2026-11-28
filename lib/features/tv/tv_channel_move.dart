import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/services/enigma2_service.dart';
import '../../l10n/l10n.dart';
import 'hbbtv_overlay.dart';
import 'tv_channel_order.dart';
import 'tv_providers.dart';
import 'tv_widgets.dart';

/// Moving a receiver channel in the channel list, like a Radio or
/// Internet-TV favorite: "Verschieben" in its options (OK held, or the
/// options key), then ↑/↓ move it, OK keeps the new place - written into
/// the receiver's bouquet (tv_channel_order.dart) - and Back puts it back.
mixin TvChannelMoveMixin<W extends ConsumerStatefulWidget> on ConsumerState<W> {
  /// The list while a channel is being moved (renumbered with every step),
  /// null otherwise.
  List<E2Channel>? moveList;

  /// The channel being moved (its service reference).
  String? movingRef;

  /// Where it was when moving started.
  int _moveFrom = 0;

  /// The row that holds the list's start focus node while a channel is
  /// moved and afterwards - by position, so the node doesn't jump rows
  /// with the tuned channel (the focus would get lost).
  int? moveStartRow;

  bool get movingChannel => movingRef != null;

  /// The row index of [moveStartRow] has to take the focus (after Back).
  void focusMoveStartRow();

  /// A note for the user (over the picture).
  void moveNote(String text);

  List<E2Channel> shownChannels(List<E2Channel> list) => moveList ?? list;

  void startChannelMove(E2Channel channel, {required int startRow}) {
    final list = ref.read(tvChannelsProvider).value;
    final from = list?.indexWhere((c) => c.ref == channel.ref) ?? -1;
    if (list == null || from < 0 || list.length < 2) return;
    setState(() {
      moveList = list;
      movingRef = channel.ref;
      _moveFrom = from;
      moveStartRow = startRow;
    });
  }

  /// One place up or down, the focus with it.
  void moveChannelBy(int delta) {
    final list = moveList;
    if (list == null) return;
    final from = list.indexWhere((c) => c.ref == movingRef);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= list.length) return;
    final next = [...list];
    next.insert(to, next.removeAt(from));
    setState(() => moveList = renumberChannels(next));
    FocusManager.instance.primaryFocus?.focusInDirection(delta < 0 ? TraversalDirection.up : TraversalDirection.down);
  }

  /// Back: the channel where it was, the focus on it.
  void cancelChannelMove() {
    if (!movingChannel) return;
    setState(() {
      moveList = null;
      movingRef = null;
      moveStartRow = _moveFrom;
    });
    focusMoveStartRow();
  }

  /// Dropped without a word (another bouquet chosen).
  void dropChannelMove() {
    moveList = null;
    movingRef = null;
    moveStartRow = null;
  }

  /// OK: the new place - shown at once, written to the receiver (or kept in
  /// the app); if writing fails, the old order is back with a note.
  Future<E2Channel?> commitChannelMove() async {
    final list = moveList;
    final moved = list?.where((c) => c.ref == movingRef).firstOrNull;
    final changed = list != null && moved != null && list.indexOf(moved) != _moveFrom;
    final bouquet = ref.read(tvCurrentBouquetProvider).value;
    final notifier = ref.read(tvChannelOrderProvider.notifier);
    final t = context.l10n;
    final note = moveNote;
    // In the same frame as the pending order (commit sets it before it
    // waits for anything): the list doesn't flash the old order.
    setState(() {
      moveList = null;
      movingRef = null;
    });
    if (!changed || bouquet == null) return moved;
    final result = await notifier.commit(bouquet.ref, list, moved: moved);
    switch (result.outcome) {
      case TvOrderOutcome.receiver:
        note(t.tvOrderSaved);
      case TvOrderOutcome.localOnly:
        if (result.firstTime) note(t.tvOrderLocalOnly);
      case TvOrderOutcome.failed:
        note(t.tvOrderFailed(result.error ?? ''));
      case TvOrderOutcome.unchanged:
    }
    return moved;
  }

  /// The keys while a channel is moved; null when none is.
  KeyEventResult? channelMoveKey(KeyEvent event) {
    if (!movingChannel) return null;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      moveChannelBy(key == LogicalKeyboardKey.arrowUp ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.browserBack) {
      cancelChannelMove();
      return KeyEventResult.handled;
    }
    // ←/→ mustn't leave the list or open the guide meanwhile.
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  /// A receiver channel's options (OK held or the options key): play /
  /// programme info, programme guide, move, the receiver's order again.
  Future<void> receiverChannelOptions(
    E2Channel channel, {
    required bool isCurrent,
    required int startRow,
    required VoidCallback onPlay,
    required VoidCallback onGuide,
    VoidCallback? onHbbtv,
  }) async {
    final t = context.l10n;
    final bouquet = ref.read(tvCurrentBouquetProvider).value;
    final count = ref.read(tvChannelsProvider).value?.length ?? 0;
    final hasLocal = bouquet != null && ref.read(tvChannelOrderProvider).hasLocalOrder(bouquet.ref);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(channel.name),
        children: [
          TvRow(
            autofocus: true,
            onTap: () => Navigator.of(context).pop('play'),
            child: ListTile(
              leading: Icon(isCurrent ? Icons.info_outline : Icons.play_arrow),
              title: Text(isCurrent ? t.tvChannelInfo : t.tvChannelPlay),
            ),
          ),
          TvRow(
            onTap: () => Navigator.of(context).pop('guide'),
            child: ListTile(leading: const Icon(Icons.view_list), title: Text(t.tvGuide)),
          ),
          // HbbTV of the channel on screen (remotes without a red key).
          if (isCurrent && onHbbtv != null) hbbtvOptionsRow(context, () => Navigator.of(context).pop('hbbtv')),
          if (count > 1)
            TvRow(
              onTap: () => Navigator.of(context).pop('move'),
              child: ListTile(
                leading: const Icon(Icons.swap_vert, color: brandGreen),
                title: Text(t.tvChannelMove),
                subtitle: Text(t.tvChannelMoveSubtitle),
              ),
            ),
          if (hasLocal)
            TvRow(
              onTap: () => Navigator.of(context).pop('reset'),
              child: ListTile(
                leading: const Icon(Icons.restore),
                title: Text(t.tvChannelOrderReset),
                subtitle: Text(t.tvChannelOrderResetSubtitle),
              ),
            ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'play':
        onPlay();
      case 'guide':
        onGuide();
      case 'hbbtv':
        onHbbtv?.call();
      case 'move':
        startChannelMove(channel, startRow: startRow);
      case 'reset':
        if (bouquet != null) await ref.read(tvChannelOrderProvider.notifier).resetLocal(bouquet.ref);
    }
  }
}
