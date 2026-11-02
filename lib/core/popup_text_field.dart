import 'package:flutter/material.dart';

import 'dpad_text_field.dart';
import 'theme.dart';

/// A text setting for remote-control use: looks like a text field, but is
/// only a focusable button showing the current value - OK/tap opens
/// [showTextInputDialog] with the real text field. An inline TextField
/// grabbed focus as soon as the D-Pad reached it, popped up the on-screen
/// keyboard, and after Return left the arrow keys stuck in the field (fine
/// with touch, unusable with a TV remote).
///
/// Edits [controller] like a TextField would; [onSubmitted] runs after a
/// value was accepted in the dialog.
class PopupTextField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final ValueChanged<String>? onSubmitted;
  final bool obscureText;
  final TextInputType? keyboardType;
  final bool enabled;
  final bool autofocus;

  const PopupTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.icon,
    this.onSubmitted,
    this.obscureText = false,
    this.keyboardType,
    this.enabled = true,
    this.autofocus = false,
  });

  @override
  State<PopupTextField> createState() => _PopupTextFieldState();
}

class _PopupTextFieldState extends State<PopupTextField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(covariant PopupTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() => setState(() {});

  Future<void> _edit() async {
    final value = await showTextInputDialog(
      context,
      title: widget.label,
      initialValue: widget.controller.text,
      hint: widget.hint,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
    );
    if (value == null) return;
    widget.controller.text = value;
    widget.onSubmitted?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final display = widget.obscureText && text.isNotEmpty ? '•' * 8 : text;
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        focusColor: Colors.transparent,
        canRequestFocus: widget.enabled,
        autofocus: widget.autofocus,
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.enabled ? _edit : null,
        child: InputDecorator(
          isEmpty: text.isEmpty,
          decoration: InputDecoration(
            labelText: widget.label,
            enabled: widget.enabled,
            border: const OutlineInputBorder(),
            prefixIcon: widget.icon == null ? null : Icon(widget.icon),
            suffixIcon: const Icon(Icons.edit_outlined, size: 20),
          ),
          child: Text(display, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

/// A small dialog with one text field for remote-control use: the field is
/// focused right away (keyboard up), Return or "Übernehmen" returns the
/// text, Back or "Abbrechen" returns null - and D-Pad down leaves the field
/// for the buttons (see [DpadTextField]).
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String? hint,
  bool obscureText = false,
  TextInputType? keyboardType,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      initialValue: initialValue,
      hint: hint,
      obscureText: obscureText,
      keyboardType: keyboardType,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  final String title;
  final String initialValue;
  final String? hint;
  final bool obscureText;
  final TextInputType? keyboardType;

  const _TextInputDialog({
    required this.title,
    required this.initialValue,
    this.hint,
    this.obscureText = false,
    this.keyboardType,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _controller = TextEditingController(text: widget.initialValue)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initialValue.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _accept() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: DpadTextField(
          controller: _controller,
          autofocus: true,
          obscureText: widget.obscureText,
          keyboardType: widget.keyboardType,
          decoration: InputDecoration(hintText: widget.hint),
          onSubmitted: (_) => _accept(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
        FilledButton(onPressed: _accept, child: const Text('Übernehmen')),
      ],
    );
  }
}
