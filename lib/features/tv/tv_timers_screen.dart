import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/services/enigma2_recordings.dart';
import '../../l10n/l10n.dart';
import 'tv_programme_actions.dart';
import 'tv_recording_providers.dart';
import 'tv_widgets.dart';

/// "Aufnahmen geplant": the receiver's recording timers - running ones with
/// the red dot. OK on one deletes it (after asking). Back closes.
class TvTimersScreen extends ConsumerWidget {
  const TvTimersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final timers = ref.watch(tvTimersProvider);
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TvRecordingTopBar(title: l.tvRecTimersTitle, icon: Icons.schedule),
            Expanded(
              child: timers.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => TvRecordingMessage(
                  icon: Icons.error_outline,
                  text: '$e',
                  action: l.commonRetry,
                  onAction: () => ref.invalidate(tvTimersProvider),
                ),
                data: (all) {
                  final list = all.where((t) => t.isRecording && !t.ended).toList();
                  if (list.isEmpty) return TvRecordingMessage(icon: Icons.event_available, text: l.tvRecTimersEmpty);
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(40, 16, 40, 24),
                    children: [
                      for (final (i, t) in list.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: TvRow(
                            autofocus: i == 0,
                            onTap: () => unawaited(deleteTvTimer(context, ref, t, ask: true)),
                            child: _TimerRow(timer: t),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(l.tvRecTimersHint, style: const TextStyle(color: Colors.white54, fontSize: 15)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimerRow extends StatelessWidget {
  const _TimerRow({required this.timer});

  final E2Timer timer;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = timer;
    final dim = t.disabled;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: t.running ? const TvRecordDot(size: 16) : const Icon(Icons.schedule, color: Colors.white38, size: 20),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 260,
            child: Text(tvProgrammeWhen(context, t.begin, t.end),
                style: TextStyle(color: dim ? Colors.white38 : brandGreen, fontSize: 17)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.name.isEmpty ? '–' : t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: dim ? Colors.white38 : Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  [
                    t.serviceName,
                    if (t.running) l.tvRecRunningNow,
                    if (t.disabled) l.tvRecTimerDisabled,
                  ].where((s) => s.isNotEmpty).join('  ·  '),
                  style: const TextStyle(color: Colors.white60, fontSize: 15),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The top bar of the recording pages - like the programme guide's.
class TvRecordingTopBar extends StatelessWidget {
  const TvRecordingTopBar({super.key, required this.title, required this.icon, this.trailing});

  final String title;
  final IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black.withValues(alpha: 0.7),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/icon/tv_logo.png', width: 36, height: 36),
              ),
              const SizedBox(width: 10),
              Icon(icon, color: brandGreen),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              ?trailing,
              const SizedBox(width: 20),
              const TvClock(),
            ],
          ),
        ),
      );
}

/// A note in the middle of a recording page (empty, an error) - with a
/// button if there's something to do.
class TvRecordingMessage extends StatelessWidget {
  const TvRecordingMessage({super.key, required this.icon, required this.text, this.action, this.onAction});

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white38, size: 56),
              const SizedBox(height: 16),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 18)),
              if (action != null && onAction != null) ...[
                const SizedBox(height: 20),
                FilledButton(autofocus: true, onPressed: onAction, child: Text(action!)),
              ],
            ],
          ),
        ),
      );
}
