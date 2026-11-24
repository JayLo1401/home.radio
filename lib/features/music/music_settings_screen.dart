import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/music_providers.dart';
import '../../data/repositories/music_settings_repository.dart';
import '../../data/services/music_library.dart' show MusicRepeat;
import '../../data/services/music_spectrum.dart';
import '../../l10n/l10n.dart';
import '../settings/nas_settings_screen.dart';
import 'music_widgets.dart';

/// Einstellungen → Musik: playing, the visualisation, the index.
class MusicSettingsScreen extends ConsumerWidget {
  const MusicSettingsScreen({super.key});

  Future<void> _set(WidgetRef ref, MusicSettings Function(MusicSettings s) change) =>
      ref.read(musicSettingsProvider.notifier).set(change);

  Future<void> _setAudioReactive(BuildContext context, WidgetRef ref, bool on) async {
    if (on) {
      final spectrum = ref.read(musicSpectrumProvider);
      if (!await spectrum.hasPermission()) {
        if (!context.mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.musicSettingsReactive),
            content: SizedBox(width: 560, child: Text(context.l10n.musicSettingsReactivePermission)),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.l10n.commonCancel)),
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(context.l10n.musicSettingsReactiveAllow),
              ),
            ],
          ),
        );
        if (ok != true) return;
        if (!await spectrum.requestPermission()) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(context.l10n.musicSettingsReactiveDenied)));
          }
          return;
        }
      }
    }
    await _set(ref, (s) => s.copyWith(audioReactive: on));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final s = ref.watch(musicSettingsProvider);
    final folder = ref.watch(musicFolderProvider);
    final index = ref.watch(musicIndexProvider);
    final progress = ref.watch(musicIndexProgressProvider);
    final section = Theme.of(context).textTheme.titleMedium?.copyWith(color: musicLime);
    const help = TextStyle(color: Colors.white54, fontSize: 14);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.musicSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        children: [
          // The music folder lives in the NAS settings.
          ListTile(
            leading: const Icon(Icons.folder_rounded),
            title: Text(l10n.musicSettingsFolder),
            subtitle: Text(folder ?? l10n.musicSettingsNoFolder),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NasSettingsScreen())),
          ),
          const Divider(height: 32),
          Text(l10n.musicSettingsPlayback, style: section),
          const SizedBox(height: 8),
          MusicChoiceTile(
            label: l10n.musicSettingsShuffle,
            subtitle: l10n.musicSettingsShuffleHelp,
            asToggle: true,
            selected: s.shuffle,
            onTap: () => ref.read(musicPlayerProvider).setShuffle(!s.shuffle),
          ),
          const SizedBox(height: 8),
          Text(l10n.musicSettingsRepeat, style: help),
          Wrap(
            spacing: 8,
            children: [
              for (final r in MusicRepeat.values)
                MusicChoiceTile(
                  label: switch (r) {
                    MusicRepeat.off => l10n.musicRepeatOff,
                    MusicRepeat.all => l10n.musicRepeatAll,
                    MusicRepeat.one => l10n.musicRepeatOne,
                  },
                  selected: s.repeat == r,
                  onTap: () => ref.read(musicPlayerProvider).setRepeat(r),
                ),
            ].map((w) => SizedBox(width: 260, child: w)).toList(),
          ),
          const SizedBox(height: 8),
          MusicChoiceTile(
            label: l10n.musicWithSubfolders,
            subtitle: l10n.musicWithSubfoldersHelp,
            asToggle: true,
            selected: s.subfolders,
            onTap: () => _set(ref, (x) => x.copyWith(subfolders: !x.subfolders)),
          ),
          MusicChoiceTile(
            label: l10n.musicSettingsPreferTags,
            subtitle: l10n.musicSettingsPreferTagsHelp,
            asToggle: true,
            selected: s.preferTags,
            onTap: () => _set(ref, (x) => x.copyWith(preferTags: !x.preferTags)),
          ),
          const Divider(height: 32),
          Text(l10n.musicSettingsVisualizer, style: section),
          const SizedBox(height: 8),
          for (final m in MusicVisualizerMode.values)
            MusicChoiceTile(
              label: switch (m) {
                MusicVisualizerMode.off => l10n.musicVisualizerOff,
                MusicVisualizerMode.manual => l10n.musicVisualizerManual,
                MusicVisualizerMode.auto => l10n.musicVisualizerAuto,
              },
              selected: s.visualizer == m,
              onTap: () => _set(ref, (x) => x.copyWith(visualizer: m)),
            ),
          const SizedBox(height: 8),
          Text(l10n.musicSettingsQuality, style: help),
          Wrap(
            spacing: 8,
            children: [
              for (final q in MusicVisualizerQuality.values)
                SizedBox(
                  width: 260,
                  child: MusicChoiceTile(
                    label: switch (q) {
                      MusicVisualizerQuality.auto => l10n.musicQualityAuto,
                      MusicVisualizerQuality.low => l10n.musicQualityLow,
                      MusicVisualizerQuality.high => l10n.musicQualityHigh,
                    },
                    enabled: s.visualizer != MusicVisualizerMode.off,
                    selected: s.quality == q,
                    onTap: () => _set(ref, (x) => x.copyWith(quality: q)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(l10n.musicSettingsInterval, style: help),
          Wrap(
            spacing: 8,
            children: [
              for (final seconds in MusicSettings.visualizerIntervals)
                SizedBox(
                  width: 200,
                  child: MusicChoiceTile(
                    label: seconds == 0 ? l10n.musicIntervalManual : l10n.musicIntervalSeconds(seconds),
                    enabled: s.visualizer != MusicVisualizerMode.off,
                    selected: s.visualizerInterval == seconds,
                    onTap: () => _set(ref, (x) => x.copyWith(visualizerInterval: seconds)),
                  ),
                ),
            ],
          ),
          if (MusicSpectrum.supported) ...[
            const SizedBox(height: 8),
            MusicChoiceTile(
              label: l10n.musicSettingsReactive,
              subtitle: l10n.musicSettingsReactiveHelp,
              asToggle: true,
              enabled: s.visualizer != MusicVisualizerMode.off,
              selected: s.audioReactive,
              onTap: () => _setAudioReactive(context, ref, !s.audioReactive),
            ),
          ],
          const Divider(height: 32),
          Text(l10n.musicSettingsIndex, style: section),
          const SizedBox(height: 6),
          Text(l10n.musicSettingsIndexHelp, style: help),
          const SizedBox(height: 12),
          if (progress.running)
            Row(
              children: [
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: musicLime)),
                const SizedBox(width: 12),
                Expanded(child: Text(l10n.musicIndexRunning(progress.folders, progress.tracks))),
              ],
            )
          else if (index != null)
            Text(
              l10n.musicIndexState(
                index.trackCount,
                index.folders.length,
                MaterialLocalizations.of(context).formatMediumDate(index.updated),
              ),
            )
          else
            Text(progress.interrupted ? l10n.musicIndexInterrupted(progress.tracks) : l10n.musicIndexNone),
          if (progress.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(progress.error!, style: const TextStyle(color: Colors.amberAccent)),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (progress.running)
                OutlinedButton.icon(
                  onPressed: () => ref.read(musicIndexStoreProvider).cancel(),
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(l10n.musicIndexStop),
                )
              else ...[
                FilledButton.icon(
                  onPressed: folder == null ? null : () => unawaited(buildMusicIndexFrom(ref, fresh: !progress.interrupted)),
                  icon: const Icon(Icons.manage_search_rounded),
                  label: Text(progress.interrupted
                      ? l10n.musicIndexContinue
                      : (index == null ? l10n.musicIndexBuild : l10n.musicIndexRefresh)),
                ),
                if (index != null || progress.interrupted)
                  OutlinedButton.icon(
                    onPressed: () => ref.read(musicIndexStoreProvider).delete(),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(l10n.musicIndexDelete),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
