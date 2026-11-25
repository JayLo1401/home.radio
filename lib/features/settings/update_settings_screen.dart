import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../core/nas_providers.dart';
import '../../core/providers.dart';
import '../../data/services/nas_service.dart';
import '../../data/services/update_service.dart';
import '../../l10n/l10n.dart';

/// Downloads and installs [update] behind a progress dialog. On Windows/
/// Linux the app quits when the installer takes over; on Android the
/// system's "Update?" confirmation follows. Errors end up in a SnackBar.
///
/// Right before installing, a backup goes to the NAS backup folder if one
/// is set (Settings → NAS) - at most [_nasBackupTimeout]; if that fails, a
/// short message and the update goes on.
Future<void> installUpdate(BuildContext context, WidgetRef ref, AvailableUpdate update) async {
  final progress = ValueNotifier<double?>(null);
  final backingUp = ValueNotifier(false);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final l = context.l10n;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: Text(l.miscUpdateDialogTitle(update.version)),
      content: ListenableBuilder(
        listenable: Listenable.merge([progress, backingUp]),
        builder: (_, _) {
          final value = backingUp.value ? null : progress.value;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                backingUp.value
                    ? l.nasBackupRunning
                    : value == null
                        ? l.miscUpdateDownloading
                        : l.miscUpdateDownloadingPercent((value * 100).round()),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: value),
            ],
          );
        },
      ),
    ),
  );
  try {
    await ref.read(updateServiceProvider).install(
      update,
      onProgress: (v) => progress.value = v,
      beforeInstall: () async {
        backingUp.value = true;
        final error = await backupToNasBeforeUpdate(ref);
        backingUp.value = false;
        if (error != null) messenger.showSnackBar(SnackBar(content: Text(l.nasBackupFailed(error))));
      },
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(l.miscUpdateFailed('$e'))));
  } finally {
    navigator.pop();
    progress.dispose();
    backingUp.dispose();
  }
}

const _nasBackupTimeout = Duration(seconds: 30);

/// Puts a backup into the NAS backup folder (if one is set) and prunes this
/// device's old ones - for the update path. Never throws and gives up after
/// [_nasBackupTimeout], so a dead NAS can't block an update. Returns a short
/// error message, or null (done, or no backup folder).
Future<String?> backupToNasBeforeUpdate(WidgetRef ref) async {
  try {
    final name = await ref.read(nasBackupServiceProvider).backupNow().timeout(_nasBackupTimeout);
    if (name != null) debugPrint('NAS backup before update: $name');
    return null;
  } on TimeoutException {
    return l10n.nasErrorTimeout;
  } on NasException catch (e) {
    return e.message;
  } catch (e) {
    debugPrint('NAS backup before update: $e');
    return '$e';
  }
}

/// Settings → Weiteres → Updates: installed version, automatic updates on
/// start, check by hand.
class UpdateSettingsScreen extends ConsumerStatefulWidget {
  const UpdateSettingsScreen({super.key});

  @override
  ConsumerState<UpdateSettingsScreen> createState() => _UpdateSettingsScreenState();
}

class _UpdateSettingsScreenState extends ConsumerState<UpdateSettingsScreen> {
  String? _version;
  bool _auto = true;
  bool _checking = false;
  bool _checked = false;
  AvailableUpdate? _update;
  DeviceAppInfo? _device;

  @override
  void initState() {
    super.initState();
    () async {
      final device = await ref.read(updateServiceProvider).deviceInfo();
      if (mounted) setState(() => _device = device);
      final version = await ref.read(updateServiceProvider).currentVersion();
      final auto = await ref.read(settingsRepositoryProvider).getAutoUpdate();
      if (mounted) {
        setState(() {
          _version = version;
          _auto = auto;
        });
      }
      await _check();
    }();
  }

  Future<void> _check() async {
    if (!UpdateService.supported) return;
    setState(() => _checking = true);
    final update = await ref.read(updateServiceProvider).check();
    if (!mounted) return;
    setState(() {
      _update = update;
      _checking = false;
      _checked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    const hint = TextStyle(color: Colors.white54);
    final update = _update;
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.miscUpdatesTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.miscUpdateInstalledVersion(_version ?? '…'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          if (!UpdateService.supported)
            Text(l.miscUpdateLocalBuild, style: hint)
          else ...[
            SwitchListTile(
              autofocus: true,
              title: Text(l.miscUpdateAuto),
              subtitle: Text(l.miscUpdateAutoHint, style: hint),
              value: _auto,
              onChanged: (v) {
                setState(() => _auto = v);
                ref.read(settingsRepositoryProvider).setAutoUpdate(v);
              },
            ),
            const SizedBox(height: 16),
            if (_checking)
              Row(
                children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text(l.miscUpdateChecking),
                ],
              )
            else if (update != null)
              Row(
                children: [
                  Expanded(child: Text(l.miscUpdateAvailable(update.version))),
                  FilledButton.icon(
                    onPressed: () => installUpdate(context, ref, update),
                    icon: const Icon(Icons.system_update),
                    label: Text(l.miscUpdateNow),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(child: Text(_checked ? l.miscUpdateUpToDate : '')),
                  OutlinedButton.icon(
                    onPressed: _check,
                    icon: const Icon(Icons.refresh),
                    label: Text(l.miscUpdateCheckAgain),
                  ),
                ],
              ),
          ],
          if (_device case final device?) ...[
            const SizedBox(height: 32),
            // Focusable: ▼ from the buttons above scrolls it into view.
            Focus(
              child: Builder(
                builder: (context) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Focus.of(context).hasFocus ? Theme.of(context).colorScheme.primary : Colors.white12,
                      width: 2,
                    ),
                  ),
                  child: DeviceInfoSection(device: device, version: _version),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Settings → Updates on Android: what the device is and which APK fits it
/// (the same choice the updater makes), with the list of all variants - to
/// decide on the device itself what to install on others like it.
class DeviceInfoSection extends StatelessWidget {
  const DeviceInfoSection({super.key, required this.device, this.version});

  final DeviceAppInfo device;
  final String? version;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    const hint = TextStyle(color: Colors.white54);
    final abi = device.abis.isEmpty ? '?' : device.abis.first;
    final ram = device.ramBytes;
    final installed = device.installed;
    final file = 'home_system-${version ?? '<version>'}-${device.recommended}.apk';
    Widget line(String text, {TextStyle? style}) =>
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(text, style: style));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.miscDeviceTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (device.name.isNotEmpty) line(device.name),
        line(l.miscDeviceAndroid(device.release, device.sdk)),
        line(device.system64 ? l.miscDeviceSystem64(abi) : l.miscDeviceSystem32(abi)),
        if (!device.system64 && device.cpu64) line(l.miscDeviceCpu64On32, style: hint),
        if (device.chip != null) line(l.miscDeviceChip(device.chip!)),
        if (ram != null && ram > 0)
          line(l.miscDeviceRam(NumberFormat('0.0', Localizations.localeOf(context).toString()).format(ram / (1 << 30)))),
        if (installed != null) line(l.miscDeviceInstalled(installed)),
        line(l.miscDeviceRecommended(file), style: const TextStyle(fontWeight: FontWeight.w600)),
        if (installed != null)
          line(
            device.installedFits
                ? l.miscDeviceFits
                : installed == 'universal'
                    ? l.miscDeviceUniversal
                    : l.miscDeviceOther,
            style: hint,
          ),
        const SizedBox(height: 16),
        Text(l.miscDeviceVariantsTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final text in [
          l.miscDeviceVariantArmv7,
          l.miscDeviceVariantArm64,
          l.miscDeviceVariantX86,
          l.miscDeviceVariantUniversal,
          l.miscDeviceMinAndroid(apkMinAndroid),
        ])
          line(text, style: hint),
      ],
    );
  }
}
