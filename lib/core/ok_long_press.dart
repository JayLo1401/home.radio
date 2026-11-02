import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Long press for the remote: holding OK on [child] (a focusable row/button
/// like an InkWell, whose own onTap/onLongPress still serve touch) for at
/// least 0.6 s calls [onLongPress] on release; a short press calls [onTap].
/// Needed because a remote's OK normally "activates" immediately on
/// key-down, so there'd be no hold.
/// Only does anything while [onLongPress] is set.
class OkLongPress extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const OkLongPress({super.key, required this.child, this.onTap, this.onLongPress});

  @override
  State<OkLongPress> createState() => _OkLongPressState();
}

class _OkLongPressState extends State<OkLongPress> {
  static const _holdTime = Duration(milliseconds: 600);
  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  DateTime? _downAt;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final onLongPress = widget.onLongPress;
    if (onLongPress == null || !_okKeys.contains(event.logicalKey)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _downAt = DateTime.now();
    } else if (event is KeyUpEvent) {
      final downAt = _downAt;
      _downAt = null;
      // Decided on release, not while the key is still held: a long press
      // that opened its dialog right away had the held key's repeats land
      // in that dialog, toggling its first field on and off.
      if (downAt != null) {
        DateTime.now().difference(downAt) >= _holdTime ? onLongPress() : widget.onTap?.call();
      }
    }
    // Down, repeats and up are all ours - otherwise OK would also trigger
    // the normal "activate" on key-down.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // An ancestor of the child's own focus node: key events bubble up here
    // before reaching the app-wide "activate" shortcuts.
    return Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: widget.child);
  }
}
