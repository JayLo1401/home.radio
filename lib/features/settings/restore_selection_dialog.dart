import 'package:flutter/material.dart';

import '../../core/popup_text_field.dart';
import '../../core/theme.dart';
import '../../data/services/backup_service.dart';
import '../../l10n/l10n.dart';

/// Before a backup is restored on the device: the device name (prefilled
/// with the backup's, editable) and one tick per area the backup contains,
/// all ticked - like the selection on the admin page. Returns null if the
/// user cancelled. Works with the remote: D-Pad through the rows, OK ticks,
/// "Übernehmen" has the focus at first.
Future<BackupRestoreSelection?> showRestoreSelectionDialog(
  BuildContext context, {
  required String source,
  required BackupPreview preview,
  required String currentName,
}) =>
    showDialog<BackupRestoreSelection>(
      context: context,
      builder: (context) => _RestoreSelectionDialog(source: source, preview: preview, currentName: currentName),
    );

class _RestoreSelectionDialog extends StatefulWidget {
  const _RestoreSelectionDialog({required this.source, required this.preview, required this.currentName});

  final String source;
  final BackupPreview preview;
  final String currentName;

  @override
  State<_RestoreSelectionDialog> createState() => _RestoreSelectionDialogState();
}

class _RestoreSelectionDialogState extends State<_RestoreSelectionDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.preview.deviceName);
  late final Set<BackupArea> _chosen = widget.preview.areas.toSet();
  bool _nothing = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _apply() {
    final name = _name.text.trim();
    if (_chosen.isEmpty && (name.isEmpty || name == widget.currentName.trim())) {
      setState(() => _nothing = true);
      return;
    }
    Navigator.of(context).pop(BackupRestoreSelection(areas: {..._chosen}, deviceName: name));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    const hint = TextStyle(color: Colors.white60, fontSize: 13);
    final areas = widget.preview.areas;
    return AlertDialog(
      title: Text(l.backupSelectTitle),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.source, style: hint),
              const SizedBox(height: 4),
              Text(l.backupSelectHint, style: hint),
              const SizedBox(height: 16),
              PopupTextField(
                controller: _name,
                label: l.adminDeviceName,
                hint: widget.currentName.isEmpty ? null : widget.currentName,
                icon: Icons.badge_outlined,
                onSubmitted: (_) => setState(() => _nothing = false),
              ),
              const SizedBox(height: 4),
              Text(
                widget.currentName.isEmpty ? l.backupDeviceNameHelpNone : l.backupDeviceNameHelp(widget.currentName),
                style: hint,
              ),
              const SizedBox(height: 16),
              Text(l.backupSelectAreas, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              if (areas.isEmpty) Text(l.backupNothingInside, style: hint),
              for (final area in areas)
                _AreaTile(
                  title: backupAreaTitle(l, area),
                  summary: backupAreaSummary(l, area, widget.preview),
                  value: _chosen.contains(area),
                  onChanged: (v) => setState(() {
                    v ? _chosen.add(area) : _chosen.remove(area);
                    _nothing = false;
                  }),
                ),
              if (_nothing)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(l.backupNothingSelected, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.commonCancel)),
        FilledButton(autofocus: true, onPressed: _apply, child: Text(l.backupApply)),
      ],
    );
  }
}

/// One area: a focusable row with a tick - OK toggles it.
class _AreaTile extends StatefulWidget {
  const _AreaTile({required this.title, required this.summary, required this.value, required this.onChanged});

  final String title;
  final String summary;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_AreaTile> createState() => _AreaTileState();
}

class _AreaTileState extends State<_AreaTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          focusColor: Colors.transparent,
          hoverColor: Colors.white.withValues(alpha: 0.04),
          onFocusChange: (v) => setState(() => _focused = v),
          onTap: () => widget.onChanged(!widget.value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                ExcludeFocus(
                  child: Checkbox(value: widget.value, onChanged: (v) => widget.onChanged(v ?? false)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, style: const TextStyle(fontSize: 16, color: Colors.white)),
                      Text(widget.summary, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
