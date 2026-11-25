import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/services/tv_reminders.dart';
import '../../l10n/l10n.dart';
import 'tv_widgets.dart' show hhmm;

/// "Ihre Erinnerungen": the marked programmes that begin now. One: a bar
/// runs [countdown] long, then it switches by itself - "Jetzt umschalten"
/// at once, "Abbrechen" (or Back) not. Several at the same time: OK on one
/// switches to it. Returns the reminder to switch to, or null.
Future<TvReminder?> showTvReminderDialog(
  BuildContext context,
  List<TvReminder> reminders, {
  Duration countdown = const Duration(seconds: 30),
}) =>
    showDialog<TvReminder>(
      context: context,
      barrierDismissible: true,
      builder: (_) => TvReminderDialog(reminders: reminders, countdown: countdown),
    );

class TvReminderDialog extends StatefulWidget {
  const TvReminderDialog({super.key, required this.reminders, this.countdown = const Duration(seconds: 30)});

  final List<TvReminder> reminders;
  final Duration countdown;

  @override
  State<TvReminderDialog> createState() => _TvReminderDialogState();
}

class _TvReminderDialogState extends State<TvReminderDialog> with SingleTickerProviderStateMixin {
  late final AnimationController _bar;

  bool get _single => widget.reminders.length == 1;

  @override
  void initState() {
    super.initState();
    // Made here, not lazily: else a dialog with several (no bar) would make
    // it first in dispose.
    _bar = AnimationController(vsync: this, duration: widget.countdown);
    if (_single) {
      _bar.addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) Navigator.of(context).pop(widget.reminders.single);
      });
      _bar.forward();
    }
  }

  @override
  void dispose() {
    _bar.dispose();
    super.dispose();
  }

  String _when(TvReminder r) {
    final l = context.l10n;
    final minutes = r.begin.difference(DateTime.now()).inSeconds / 60;
    if (minutes <= 0.5) return '${hhmm(r.begin)} · ${l.tvReminderNow}';
    return '${hhmm(r.begin)} · ${l.tvReminderInMinutes(minutes.ceil())}';
  }

  Widget _programme(TvReminder r, {VoidCallback? onTap, bool autofocus = false}) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.notifications_active, color: brandGreen),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text('${r.channelName}  ·  ${_when(r)}', style: const TextStyle(color: Colors.white70, fontSize: 16)),
              ],
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return _FocusRow(autofocus: autofocus, onTap: onTap, child: content);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final reminders = widget.reminders;
    return AlertDialog(
      backgroundColor: const Color(0xFF111A16),
      title: Text(l.tvRemindersTitle),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_single) ...[
              _programme(reminders.single),
              const SizedBox(height: 16),
              AnimatedBuilder(
                animation: _bar,
                builder: (context, _) {
                  final left = (widget.countdown.inSeconds * (1 - _bar.value)).ceil();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(value: 1 - _bar.value, minHeight: 8, color: brandGreen),
                      ),
                      const SizedBox(height: 6),
                      Text(l.tvReminderSwitchIn(left), style: const TextStyle(color: Colors.white60, fontSize: 14)),
                    ],
                  );
                },
              ),
            ] else ...[
              Text(l.tvRemindersPick, style: const TextStyle(color: Colors.white60, fontSize: 14)),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final (i, r) in reminders.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _programme(r, autofocus: i == 0, onTap: () => Navigator.of(context).pop(r)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.commonCancel)),
        if (_single)
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(reminders.single),
            child: Text(l.tvReminderSwitchNow),
          ),
      ],
    );
  }
}

/// A row OK can choose, with the app's focus frame.
class _FocusRow extends StatefulWidget {
  const _FocusRow({required this.child, required this.onTap, this.autofocus = false});

  final Widget child;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_FocusRow> createState() => _FocusRowState();
}

class _FocusRowState extends State<_FocusRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(10),
        child: Material(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            autofocus: widget.autofocus,
            borderRadius: BorderRadius.circular(10),
            focusColor: Colors.transparent,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onTap,
            child: widget.child,
          ),
        ),
      );
}
