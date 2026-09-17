import 'package:flutter/material.dart';

/// Text-entry dialog for manually overriding a station/favorite's display
/// name - DAB+ FIG labels sometimes carry genuinely-real but garbled-looking
/// special characters (confirmed real-world AT ensembles, not a decode bug),
/// so this lets the user replace them with something readable. Returns the
/// trimmed new name, an empty string to clear an override back to the
/// decoded default, or null if cancelled.
class RenameDialog extends StatefulWidget {
  final String title;
  final String initialValue;

  const RenameDialog({super.key, required this.title, required this.initialValue});

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Anzeigename'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
