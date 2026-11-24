import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dashboard_providers.dart';
import '../../core/music_providers.dart';
import '../../core/providers.dart';
import '../../core/system_providers.dart';
import '../../core/theme.dart';
import '../../data/services/permissions_service.dart';
import '../../l10n/l10n.dart';
import '../launcher/launcher_providers.dart';
import '../settings/launcher_settings_screens.dart' show HomeButtonSettingsScreen;

final permissionsServiceProvider = Provider<PermissionsService>(
  (ref) => PermissionsService(
    launcher: ref.read(launcherServiceProvider),
    display: ref.read(displayServiceProvider),
    update: ref.read(updateServiceProvider),
    backup: ref.read(backupServiceProvider),
    spectrum: ref.read(musicSpectrumProvider),
  ),
);

/// What the device says and the permissions with their state for the parts
/// that are on - read again by invalidating it (back from the system's
/// settings, see [PermissionsAutoRefresh]).
typedef PermissionsState = ({PermissionFacts facts, PermissionParts parts, List<PermissionEntry> entries});

final permissionEntriesProvider = FutureProvider.autoDispose<PermissionsState>((ref) async {
  final p = ref.watch(systemPartsProvider);
  final PermissionParts parts = (radio: p.radio, dashboard: p.dashboard, music: p.music);
  final facts = await ref.read(permissionsServiceProvider).facts();
  return (facts: facts, parts: parts, entries: permissionEntries(facts, parts));
});

/// The ones the setup wizard goes through one by one: what's still missing,
/// and the USB stick (Android asks for it later). Not there: "Audio
/// aufnehmen" (an opt-in for a visual effect), all-files access (only for an
/// earlier installation's backups - the restore screen offers it), adb.
List<PermissionEntry> wizardPermissions(PermissionsState s) => [
      for (final e in s.entries)
        if ((e.status == PermissionStatus.missing &&
                e.kind != PermissionKind.recordAudio &&
                e.kind != PermissionKind.secureSettings &&
                !(e.kind == PermissionKind.storage && s.facts.sdkInt >= 30)) ||
            (e.kind == PermissionKind.usb && e.status == PermissionStatus.info))
          e,
    ];

/// The button for [e] - null when there's nothing to do.
String? permissionActionLabel(AppLocalizations l, PermissionEntry e) => switch ((e.kind, e.status)) {
      (PermissionKind.homeKey, PermissionStatus.granted) => l.permissionsChange,
      (PermissionKind.homeKey, PermissionStatus.missing) => l.permissionsSetUp,
      (PermissionKind.secureSettings, _) => null,
      (_, PermissionStatus.missing) => l.permissionsAllow,
      _ => null,
    };

/// Asks for [e] (the Home key: its own screen), then reads the states again.
Future<void> askPermission(BuildContext context, WidgetRef ref, PermissionEntry e) async {
  final l = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  if (e.kind == PermissionKind.homeKey) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HomeButtonSettingsScreen()));
  } else {
    final result = await ref.read(permissionsServiceProvider).request(e.kind);
    switch (result) {
      case PermissionRequestResult.granted:
        // Allowed for "Folgt der Musik" - so that's switched on, too.
        if (e.kind == PermissionKind.recordAudio) {
          await ref.read(musicSettingsProvider.notifier).set((s) => s.copyWith(audioReactive: true));
          messenger.showSnackBar(SnackBar(content: Text(l.permissionsMusicOn)));
        }
      case PermissionRequestResult.denied:
        messenger.showSnackBar(SnackBar(content: Text(l.permissionsDenied)));
      case PermissionRequestResult.blocked:
        messenger.showSnackBar(SnackBar(content: Text(l.permissionsBlocked), duration: const Duration(seconds: 8)));
      case PermissionRequestResult.openedSettings:
        break;
    }
  }
  ref.invalidate(permissionEntriesProvider);
}

/// Reads the states again whenever the app comes back to the front (from
/// the system's settings or its permission dialog).
class PermissionsAutoRefresh extends ConsumerStatefulWidget {
  const PermissionsAutoRefresh({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PermissionsAutoRefresh> createState() => _PermissionsAutoRefreshState();
}

class _PermissionsAutoRefreshState extends ConsumerState<PermissionsAutoRefresh> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(permissionEntriesProvider);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

IconData _icon(PermissionKind kind) => switch (kind) {
      PermissionKind.homeKey => Icons.home_outlined,
      PermissionKind.camera => Icons.videocam_outlined,
      PermissionKind.installApps => Icons.system_update_alt,
      PermissionKind.storage => Icons.folder_outlined,
      PermissionKind.notifications => Icons.notifications_none,
      PermissionKind.recordAudio => Icons.graphic_eq,
      PermissionKind.usb => Icons.usb,
      PermissionKind.secureSettings => Icons.terminal,
    };

String _title(AppLocalizations l, PermissionKind kind, PermissionFacts f) => switch (kind) {
      PermissionKind.homeKey => l.permissionsHomeKeyTitle,
      PermissionKind.camera => l.permissionsCameraTitle,
      PermissionKind.installApps => l.permissionsInstallTitle,
      PermissionKind.storage => f.sdkInt >= 30 ? l.permissionsAllFilesTitle : l.permissionsStorageTitle,
      PermissionKind.notifications => l.permissionsNotificationsTitle,
      PermissionKind.recordAudio => l.permissionsRecordAudioTitle,
      PermissionKind.usb => l.permissionsUsbTitle,
      PermissionKind.secureSettings => l.permissionsSecureSettingsTitle,
    };

String _why(AppLocalizations l, PermissionKind kind, PermissionFacts f, PermissionParts parts) => switch (kind) {
      PermissionKind.homeKey =>
        parts.dashboard ? '${l.permissionsHomeKeyWhy} ${l.permissionsHomeKeyWhyDashboard}' : l.permissionsHomeKeyWhy,
      PermissionKind.camera => l.permissionsCameraWhy,
      PermissionKind.installApps => l.permissionsInstallWhy,
      PermissionKind.storage => f.sdkInt >= 30 ? l.permissionsAllFilesWhy : l.permissionsStorageWhy,
      PermissionKind.notifications => l.permissionsNotificationsWhy,
      PermissionKind.recordAudio => l.permissionsRecordAudioWhy,
      PermissionKind.usb => l.permissionsUsbWhy,
      PermissionKind.secureSettings => l.permissionsSecureSettingsWhy,
    };

String? _notNeededReason(AppLocalizations l, PermissionEntry e) => switch (e.notNeeded) {
      PermissionNotNeeded.device => l.permissionsNotNeededDevice,
      PermissionNotNeeded.noCamera => l.permissionsNotNeededNoCamera,
      PermissionNotNeeded.partOff => l.permissionsNotNeededPart(switch (e.part) {
          'dashboard' => l.dashboardTitle,
          'music' => l.musicTitle,
          _ => 'Radio',
        }),
      null => null,
    };

/// One permission: icon, title, its state, why it's needed (and what it
/// doesn't do). With [onTap] the whole card is a button (OK on the remote);
/// without it, it's still focusable so the remote can scroll to it.
class PermissionCard extends StatefulWidget {
  const PermissionCard({
    super.key,
    required this.entry,
    required this.state,
    this.onTap,
    this.actionLabel,
    this.autofocus = false,
    this.large = false,
  });

  final PermissionEntry entry;
  final PermissionsState state;
  final VoidCallback? onTap;

  /// Shown at the end of the card ("Erlauben ›").
  final String? actionLabel;
  final bool autofocus;

  /// The setup wizard's one-at-a-time page: bigger, not focusable (the
  /// wizard has its own buttons).
  final bool large;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final e = widget.entry;
    final primary = Theme.of(context).colorScheme.primary;
    final dim = e.status == PermissionStatus.notNeeded;
    final (statusIcon, statusColor, statusText) = switch (e.status) {
      PermissionStatus.granted => (Icons.check_circle, primary, l.permissionsStatusGranted),
      PermissionStatus.missing when e.kind == PermissionKind.secureSettings =>
        (Icons.terminal, Colors.white60, l.permissionsStatusAdb),
      PermissionStatus.missing => (Icons.error_outline, Colors.amber, l.permissionsStatusMissing),
      PermissionStatus.notNeeded => (Icons.remove_circle_outline, Colors.white38, l.permissionsStatusNotNeeded),
      PermissionStatus.info => (
          Icons.info_outline,
          Colors.white60,
          e.kind == PermissionKind.usb ? l.permissionsStatusUsb : l.permissionsStatusNotifications,
        ),
    };
    final reason = _notNeededReason(l, e);
    final big = widget.large;
    final content = Padding(
      padding: EdgeInsets.all(big ? 20 : 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon(e.kind), size: big ? 40 : 30, color: dim ? Colors.white38 : primary),
          SizedBox(width: big ? 20 : 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      _title(l, e.kind, widget.state.facts),
                      style: TextStyle(
                        fontSize: big ? 22 : 17,
                        fontWeight: FontWeight.w600,
                        color: dim ? Colors.white54 : Colors.white,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(statusIcon, size: 18, color: statusColor),
                        const SizedBox(width: 6),
                        Text(statusText, style: TextStyle(fontSize: 14, color: statusColor)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _why(l, e.kind, widget.state.facts, widget.state.parts),
                  style: TextStyle(fontSize: big ? 17 : 14, height: 1.35, color: dim ? Colors.white38 : Colors.white70),
                ),
                if (reason != null) ...[
                  const SizedBox(height: 6),
                  Text(reason, style: const TextStyle(fontSize: 14, color: Colors.white54)),
                ],
              ],
            ),
          ),
          if (widget.actionLabel != null) ...[
            const SizedBox(width: 14),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.actionLabel!, style: TextStyle(fontSize: 16, color: primary, fontWeight: FontWeight.w600)),
                  Icon(Icons.chevron_right, color: primary),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    final box = BoxDecoration(
      color: Colors.white.withValues(alpha: dim ? 0.02 : 0.05),
      borderRadius: BorderRadius.circular(12),
    );
    if (big) return DecoratedBox(decoration: box, child: content);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TvFocusHighlight(
        focused: _focused,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            autofocus: widget.autofocus,
            borderRadius: BorderRadius.circular(12),
            focusColor: Colors.transparent,
            hoverColor: Colors.white.withValues(alpha: 0.04),
            splashFactory: widget.onTap == null ? NoSplash.splashFactory : null,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onTap ?? () {},
            child: Ink(decoration: box, child: content),
          ),
        ),
      ),
    );
  }
}

/// Einstellungen → System → Berechtigungen: every permission Home System
/// uses, why, and its state - what's not needed on this device or for the
/// parts that are on at the end; WRITE_SECURE_SETTINGS (adb) folded away.
class PermissionsScreen extends ConsumerWidget {
  const PermissionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(permissionEntriesProvider);
    final state = async.value;
    return PermissionsAutoRefresh(
      child: Scaffold(
        appBar: AppBar(title: Text(l.permissionsTitle)),
        body: state == null
            ? Center(
                child: async.hasError ? Text('${async.error}') : const CircularProgressIndicator(),
              )
            : FocusTraversalGroup(child: _list(context, ref, state)),
      ),
    );
  }

  Widget _list(BuildContext context, WidgetRef ref, PermissionsState state) {
    final l = context.l10n;
    final entries = state.entries.where((e) => e.kind != PermissionKind.secureSettings);
    final needed = entries.where((e) => e.status != PermissionStatus.notNeeded).toList();
    final notNeeded = entries.where((e) => e.status == PermissionStatus.notNeeded).toList();
    final adb = state.entries.where((e) => e.kind == PermissionKind.secureSettings && e.actionable).firstOrNull;
    var first = true;
    Widget card(PermissionEntry e) {
      final label = permissionActionLabel(l, e);
      final autofocus = first;
      first = false;
      return PermissionCard(
        entry: e,
        state: state,
        autofocus: autofocus,
        actionLabel: label,
        onTap: label == null ? null : () => askPermission(context, ref, e),
      );
    }

    const help = TextStyle(color: Colors.white60, fontSize: 14);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      children: [
        Text(needed.isEmpty ? l.permissionsNoneNeeded : l.permissionsIntro, style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 12),
        for (final e in needed) card(e),
        if (notNeeded.isNotEmpty && needed.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(l.permissionsNotNeededHeading, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          for (final e in notNeeded) card(e),
        ],
        if (adb != null) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            leading: const Icon(Icons.terminal),
            title: Text(l.permissionsAdvanced),
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              card(adb),
              const SizedBox(height: 8),
              const _Command('adb shell pm grant at.jaycloud.home.system android.permission.WRITE_SECURE_SETTINGS'),
              if (state.facts.sdkInt >= 33) ...[
                const SizedBox(height: 12),
                Text(l.permissionsRestrictedWhy, style: help),
                const SizedBox(height: 6),
                const _Command('adb shell appops set at.jaycloud.home.system ACCESS_RESTRICTED_SETTINGS allow'),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// An adb command to type in on the computer - selectable for the touch
/// screen, the copy button for the remote.
class _Command extends StatelessWidget {
  const _Command(this.text);

  final String text;

  static const _mono = TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'monospace');

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: SelectableText(text, style: _mono)),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: MaterialLocalizations.of(context).copyButtonLabel,
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          ),
        ],
      );
}
