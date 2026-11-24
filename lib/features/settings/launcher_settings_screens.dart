import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/nas_providers.dart';
import '../../data/models/launcher_tile.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/launcher_background_service.dart';
import '../../data/services/launcher_service.dart';
import '../../data/services/nas_picture_cache.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';
import '../launcher/launcher_background.dart';
import '../launcher/launcher_providers.dart';

/// A radio-style choice row (ListTile, like RadarSourceSettingsScreen).
Widget _choice(BuildContext context, {required String title, String? subtitle, required bool selected, required VoidCallback onTap, bool autofocus = false}) {
  return ListTile(
    autofocus: autofocus,
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_off,
      color: selected ? Theme.of(context).colorScheme.primary : Colors.white54,
    ),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    focusColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
    onTap: onTap,
  );
}

/// The launcher's background: built-in gradients, random photos, or the own
/// server - and how often it changes.
class LauncherBackgroundSettingsScreen extends ConsumerStatefulWidget {
  const LauncherBackgroundSettingsScreen({super.key});

  @override
  ConsumerState<LauncherBackgroundSettingsScreen> createState() => _LauncherBackgroundSettingsScreenState();
}

class _LauncherBackgroundSettingsScreenState extends ConsumerState<LauncherBackgroundSettingsScreen> {
  late final _settings = ref.read(launcherSettingsProvider);
  late LauncherBackgroundSource _source = _settings.backgroundSource;

  late int _interval = _settings.backgroundInterval;

  @override
  void initState() {
    super.initState();
    // What's cached from the NAS pictures folder (no sync).
    ref.read(nasPictureCacheProvider).init();
  }

  String? get _nasPicturesFolder => ref.watch(nasSettingsProvider).value?.folder(NasFolder.backgrounds);

  Future<void> _save() async {
    final server = _source == LauncherBackgroundSource.server;
    if (server && ref.read(nasSettingsProvider).value?.folder(NasFolder.backgrounds) == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.nasBgNoFolder)));
      return;
    }
    final url = server ? LauncherBackgroundService.nasAddress : '';
    await ref.read(launcherSettingsProvider.notifier).setBackground(source: _source, url: url, interval: _interval);
    if (mounted) Navigator.of(context).pop();
  }

  /// "Pictures folder on the NAS": what's cached, and "Sync now".
  List<Widget> _nasPart(BuildContext context, TextStyle help) {
    final l = context.l10n;
    final cache = ref.read(nasPictureCacheProvider);
    String date(DateTime t) {
      if (l.localeName != 'de') return DateFormat.yMd(l.localeName).add_Hm().format(t);
      String two(int v) => v.toString().padLeft(2, '0');
      return '${two(t.day)}.${two(t.month)}.${t.year}, ${two(t.hour)}:${two(t.minute)}';
    }

    return [
      const SizedBox(height: 8),
      ValueListenableBuilder<NasPictureStatus>(
        valueListenable: cache.status,
        builder: (context, status, _) {
          final lastSync = status.lastSync;
          final error = status.error;
          return Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.syncing
                      ? (status.total == null
                          ? l.nasBgSyncListing
                          : status.total == 0
                              ? l.nasBgSyncNothingNew
                              : l.nasBgSyncProgress(status.loaded, status.total!))
                      : lastSync == null
                          ? l.nasBgStatus(status.count)
                          : l.nasBgLastSync(status.count, date(lastSync)),
                  style: help,
                ),
                // Moves while it works - the folder being read, then each picture.
                if (status.syncing)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 24),
                    child: LinearProgressIndicator(
                      value: (status.total ?? 0) > 0 ? status.loaded / status.total! : null,
                      minHeight: 4,
                    ),
                  ),
                if (error != null && !status.syncing) Text(l.nasBgSyncError(error), style: help),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: status.syncing ? null : cache.sync,
                  icon: status.syncing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync),
                  label: Text(l.nasBgSyncNow),
                ),
              ],
            ),
          );
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsBgTitle)),
      body: FocusTraversalGroup(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _choice(
              context,
              title: l.settingsBackgroundGradients,
              subtitle: l.settingsBgGradientsHint,
              selected: _source == LauncherBackgroundSource.builtin,
              autofocus: true,
              onTap: () => setState(() => _source = LauncherBackgroundSource.builtin),
            ),
            _choice(
              context,
              title: l.settingsBgPhotos,
              subtitle: l.settingsBgPhotosHint,
              selected: _source == LauncherBackgroundSource.photos,
              onTap: () => setState(() => _source = LauncherBackgroundSource.photos),
            ),
            _choice(
              context,
              title: context.l10n.nasBgFromNas,
              subtitle: _nasPicturesFolder == null
                  ? context.l10n.nasBgNoFolder
                  : context.l10n.nasBgFromNasHint(_nasPicturesFolder!),
              selected: _source == LauncherBackgroundSource.server,
              onTap: () => setState(() => _source = LauncherBackgroundSource.server),
            ),
            if (_source == LauncherBackgroundSource.server && _nasPicturesFolder != null) ..._nasPart(context, help),
            const SizedBox(height: 20),
            Text(l.settingsBgBand, style: Theme.of(context).textTheme.titleMedium),
            Text(l.settingsBgBandHint, style: help),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final opacity in SettingsRepository.launcherBandOpacities)
                  ChoiceChip(
                    label: Text(opacity == 0 ? l.settingsBgBandNone : l.settingsPercent((opacity * 100).round())),
                    selected: (ref.watch(launcherSettingsProvider).bandOpacity - opacity).abs() < 0.01,
                    onSelected: (_) => ref.read(launcherSettingsProvider.notifier).setBandOpacity(opacity),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(l.settingsBgInterval, style: Theme.of(context).textTheme.titleMedium),
            Wrap(
              spacing: 8,
              children: [
                for (final minutes in SettingsRepository.launcherBackgroundIntervals)
                  ChoiceChip(
                    label: Text(minutes == 60 ? l.settingsBgOneHour : l.settingsMinutesShort(minutes)),
                    selected: _interval == minutes,
                    onSelected: (_) => setState(() => _interval = minutes),
                  ),
              ],
            ),
            if (_source == LauncherBackgroundSource.builtin) ...[
              const SizedBox(height: 20),
              SizedBox(
                height: 90,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final b in builtinBackdrops)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(width: 112, height: 63, child: BuiltinBackdrop(backdrop: b)),
                            ),
                            const SizedBox(height: 4),
                            Text(b.name, style: help),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: Text(l.commonSave)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks the icon pack for app tiles (or none).
Future<void> chooseIconPack(BuildContext context, WidgetRef ref) async {
  ref.invalidate(iconPacksProvider);
  final packs = await ref.read(iconPacksProvider.future);
  if (!context.mounted) return;
  final current = ref.read(launcherSettingsProvider).iconPack;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(context.l10n.settingsIconPackTitle),
      children: [
        _choice(
          context,
          title: context.l10n.settingsIconPackNoneOriginal,
          selected: current == null,
          autofocus: current == null,
          onTap: () => Navigator.of(context).pop(''),
        ),
        for (final p in packs)
          _choice(
            context,
            title: p.label,
            subtitle: p.package,
            selected: current == p.package,
            autofocus: current == p.package,
            onTap: () => Navigator.of(context).pop(p.package),
          ),
        if (packs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text(
              context.l10n.settingsIconPackNoneInstalled,
              style: const TextStyle(color: Colors.white60),
            ),
          ),
      ],
    ),
  );
  if (choice == null) return;
  await ref.read(launcherSettingsProvider.notifier).setIconPack(choice.isEmpty ? null : choice);
}

/// The Home key: as the device's launcher (Android TV boxes) or via the
/// accessibility service (Fire TV, see HomeButtonService.kt).
class HomeButtonSettingsScreen extends ConsumerStatefulWidget {
  const HomeButtonSettingsScreen({super.key});

  @override
  ConsumerState<HomeButtonSettingsScreen> createState() => _HomeButtonSettingsScreenState();
}

class _HomeButtonSettingsScreenState extends ConsumerState<HomeButtonSettingsScreen> with WidgetsBindingObserver {
  bool _loaded = false;
  bool _fireTv = false;
  bool _defaultHome = false;
  HomeButtonStatus _status = const HomeButtonStatus(serviceEnabled: false, canEnable: false, redirect: true);

  LauncherService get _service => ref.read(launcherServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from the system's settings: show what changed there.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final fireTv = await _service.isFireTv();
    final defaultHome = await _service.isDefaultHome();
    final status = await _service.homeButtonStatus();
    if (!mounted) return;
    setState(() {
      _fireTv = fireTv;
      _defaultHome = defaultHome;
      _status = status;
      _loaded = true;
    });
  }

  /// Switched on, but Android dropped it again (restricted settings).
  bool _blocked = false;

  Future<void> _enable() async {
    final ok = await _service.enableHomeButtonService();
    if (!ok) {
      await _service.openAccessibilitySettings();
      await _refresh();
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await _refresh();
    if (mounted) setState(() => _blocked = !_status.serviceEnabled);
  }

  @override
  Widget build(BuildContext context) {
    const help = TextStyle(color: Colors.white60, fontSize: 14);
    const mono = TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'monospace');
    Widget state(bool ok, String yes, String no) => Row(
          children: [
            Icon(ok ? Icons.check_circle : Icons.error_outline, color: ok ? Theme.of(context).colorScheme.primary : Colors.amber),
            const SizedBox(width: 10),
            Expanded(child: Text(ok ? yes : no, style: const TextStyle(fontSize: 16))),
          ],
        );
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsHomeKey)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : FocusTraversalGroup(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    l.settingsHomeKeyIntro,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  if (!_fireTv) ...[
                    state(_defaultHome, l.settingsHomeKeyIsDefault, l.settingsHomeKeyNotDefault),
                    const SizedBox(height: 8),
                    Text(l.settingsHomeKeyDefaultHelp, style: help),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        autofocus: true,
                        onPressed: () async {
                          await _service.openHomeSettings();
                        },
                        icon: const Icon(Icons.home_outlined),
                        label: Text(l.settingsHomeKeyChooseDefault),
                      ),
                    ),
                    const Divider(height: 32),
                    Text(l.settingsHomeKeyServiceFallback, style: help),
                    const SizedBox(height: 12),
                  ],
                  state(
                    _status.serviceEnabled,
                    l.settingsHomeKeyServiceOn,
                    l.settingsHomeKeyServiceOff,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _fireTv ? l.settingsHomeKeyServiceFireTv : l.settingsHomeKeyServiceOther,
                    style: help,
                  ),
                  const SizedBox(height: 12),
                  if (!_status.serviceEnabled)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        autofocus: _fireTv,
                        onPressed: _enable,
                        icon: const Icon(Icons.power_settings_new),
                        label: Text(_status.canEnable ? l.settingsHomeKeyEnable : l.settingsHomeKeyOpenA11y),
                      ),
                    ),
                  if (!_status.serviceEnabled && (!_status.canEnable || _blocked)) ...[
                    const SizedBox(height: 12),
                    Text(
                      _blocked ? l.settingsHomeKeyBlocked : l.settingsHomeKeyEnableThere,
                      style: help,
                    ),
                    const SizedBox(height: 6),
                    const SelectableText(
                      'adb shell pm grant at.jaycloud.home.system android.permission.WRITE_SECURE_SETTINGS\n'
                      'adb shell appops set at.jaycloud.home.system ACCESS_RESTRICTED_SETTINGS allow',
                      style: mono,
                    ),
                  ],
                  if (_status.serviceEnabled)
                    SwitchListTile(
                      autofocus: _fireTv,
                      title: Text(l.settingsHomeKeyRedirect),
                      subtitle: Text(l.settingsHomeKeyRedirectHint),
                      value: _status.redirect,
                      onChanged: (v) async {
                        await _service.setHomeRedirect(v);
                        await _refresh();
                      },
                    ),
                ],
              ),
            ),
    );
  }
}

/// Labels for the settings list.
String startScreenLabel(StartScreen s) => switch (s) {
      StartScreen.launcher => 'Home',
      StartScreen.radio => 'Radio',
      StartScreen.tv => 'TV',
      StartScreen.dashboard => l10n.dashboardTitle,
      StartScreen.app => l10n.adminStartScreenApp,
    };
