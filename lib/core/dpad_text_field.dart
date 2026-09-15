import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A [TextField] that stays fully usable with mouse/keyboard, but doesn't
/// trap a D-Pad: while focused (not necessarily mid-edit), Up/Down move
/// focus to the next/previous widget instead of being swallowed by the text
/// field's own (single-line, so otherwise unused) vertical-navigation
/// handling. Left/Right still move the text cursor as usual.
class DpadTextField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final ValueChanged<String>? onSubmitted;

  const DpadTextField({
    super.key,
    required this.controller,
    required this.decoration,
    this.onSubmitted,
  });

  @override
  State<DpadTextField> createState() => _DpadTextFieldState();
}

class _DpadTextFieldState extends State<DpadTextField> {
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _handleKey);

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final TraversalDirection direction;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      direction = TraversalDirection.down;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      direction = TraversalDirection.up;
    } else {
      return KeyEventResult.ignored;
    }
    final moved = FocusTraversalGroup.of(context).inDirection(node, direction);
    return moved ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      focusNode: _focusNode,
      controller: widget.controller,
      decoration: widget.decoration,
      onSubmitted: widget.onSubmitted,
    );
  }
}
