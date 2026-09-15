import 'package:flutter/material.dart';

/// Assigns a favorite's preset "program number" via a plain +/- stepper
/// instead of a text field - entering digits with a direction-keys-only
/// remote is painful, stepping through numbers isn't. Shared by the
/// internet-radio and DAB+ favoriting flows.
class ProgramNumberDialog extends StatefulWidget {
  final int initial;
  const ProgramNumberDialog({super.key, required this.initial});

  @override
  State<ProgramNumberDialog> createState() => _ProgramNumberDialogState();
}

class _ProgramNumberDialogState extends State<ProgramNumberDialog> {
  late int _value = widget.initial;

  void _change(int delta) {
    setState(() => _value = (_value + delta).clamp(1, 999));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Programmnummer vergeben'),
      content: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton.filledTonal(
            onPressed: () => _change(-1),
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 80,
            child: Text(
              '$_value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton.filledTonal(
            onPressed: () => _change(1),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_value),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
