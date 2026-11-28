import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nas_providers.dart';
import '../../core/theme.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';
import '../tv/tv_recording_providers.dart';
import '../tv/tv_timeshift.dart';
import '../tv/tv_widgets.dart' show TvRow;
import 'nas_settings_screen.dart';

/// "Aufnahmen & Timeshift" (Einstellungen → TV): where the live picture is
/// kept for pausing and rewinding, and - to read only - where the receiver
/// records, with the hint to let it record onto the NAS share.
class TvRecordingSettingsScreen extends ConsumerStatefulWidget {
  const TvRecordingSettingsScreen({super.key});

  @override
  ConsumerState<TvRecordingSettingsScreen> createState() => _TvRecordingSettingsScreenState();
}

class _TvRecordingSettingsScreenState extends ConsumerState<TvRecordingSettingsScreen> {
  String? _location;
  String? _locationError;
  bool _locationLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_loadLocation()));
  }

  Future<void> _loadLocation() async {
    if (!mounted) return;
    final api = ref.read(enigma2RecordingsProvider);
    if (api == null) {
      setState(() {
        _locationLoading = false;
        _locationError = context.l10n.tvErrorNoReceiver;
      });
      return;
    }
    try {
      final l = await api.locations();
      if (!mounted) return;
      setState(() {
        _location = l.current ?? l.locations.firstOrNull;
        _locationLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _locationError = '$e';
          _locationLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = ref.watch(tvTimeshiftProvider);
    final memory = ref.watch(tvTimeshiftMemoryProvider).value;
    final nas = ref.watch(nasSettingsProvider).value;
    final timeshiftFolder = nas?.folder(NasFolder.timeshift);
    final recordingsFolder = nas?.folder(NasFolder.recordings);
    const help = TextStyle(color: Colors.white60, fontSize: 15);
    final title = Theme.of(context).textTheme.titleLarge;

    Widget choice(TvTimeshiftMode mode, String label, String? subtitle, {bool autofocus = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: TvRow(
            autofocus: autofocus,
            selected: settings.mode == mode,
            onTap: () => ref.read(tvTimeshiftProvider.notifier).set((mode: mode, minutes: settings.minutes)),
            child: ListTile(
              leading: Icon(settings.mode == mode ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: settings.mode == mode ? brandGreen : Colors.white54),
              title: Text(label),
              subtitle: subtitle == null ? null : Text(subtitle, style: const TextStyle(color: Colors.white54)),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(l.tvRecSettingsTitle)),
      body: FocusTraversalGroup(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l.tvShiftTitle, style: title),
            const SizedBox(height: 4),
            Text(l.tvShiftSettingsHelp, style: help),
            const SizedBox(height: 10),
            choice(TvTimeshiftMode.off, l.tvShiftModeOff, null, autofocus: true),
            choice(
              TvTimeshiftMode.memory,
              l.tvShiftModeMemory,
              memory == null
                  ? null
                  : l.tvShiftModeMemoryInfo(memory >> 20, memory ~/ (1200 * 1024 * 60), memory ~/ (500 * 1024 * 60)),
            ),
            choice(TvTimeshiftMode.local, l.tvShiftModeLocal, l.tvShiftModeLocalInfo),
            choice(
              TvTimeshiftMode.nas,
              l.tvShiftModeNas,
              timeshiftFolder ?? l.tvShiftNasFolderMissing,
            ),
            if (settings.mode == TvTimeshiftMode.local || settings.mode == TvTimeshiftMode.nas) ...[
              const SizedBox(height: 10),
              Text(l.tvShiftMaxMinutes, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in tvTimeshiftMinuteChoices)
                    SizedBox(
                      width: 140,
                      child: TvRow(
                        selected: settings.minutes == m,
                        onTap: () => ref.read(tvTimeshiftProvider.notifier).set((mode: settings.mode, minutes: m)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              Icon(settings.minutes == m ? Icons.radio_button_checked : Icons.radio_button_off,
                                  color: settings.minutes == m ? brandGreen : Colors.white54, size: 20),
                              const SizedBox(width: 8),
                              Text(l.tvMinutes(m)),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(l.tvShiftMaxMinutesHelp, style: help),
            ],
            const SizedBox(height: 8),
            Text(l.tvShiftKeysHelp, style: help),
            const Divider(height: 40),
            Text(l.tvRecRecordingsTitle, style: title),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(l.tvRecReceiverLocation),
              subtitle: Text(
                _locationLoading ? l.commonLoading : (_location ?? _locationError ?? '–'),
                style: TextStyle(color: _location != null ? brandGreen : Colors.white54),
              ),
            ),
            Text(l.tvRecLocationHint, style: help),
            const SizedBox(height: 12),
            TvRow(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NasSettingsScreen())),
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(l.tvRecNasFolder),
                subtitle: Text(recordingsFolder ?? l.tvRecNasFolderMissing),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
