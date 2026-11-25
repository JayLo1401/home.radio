import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dashboard_providers.dart';
import '../../core/ha_providers.dart';
import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../core/system_providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/ha_mqtt_link.dart';
import '../../l10n/l10n.dart';

/// The link's state as a line of text (also for the admin page).
String haLinkStatusText(AppLocalizations l, HaLinkState state, String? error, {required String deviceName, required bool hasHost}) {
  if (!hasHost && state == HaLinkState.off) return l.haStatusNoHost;
  return switch (state) {
    HaLinkState.off => l.haStatusOff,
    HaLinkState.connecting => l.haStatusConnecting,
    HaLinkState.connected => l.haStatusConnected(deviceName.isEmpty ? 'Home System' : deviceName),
    HaLinkState.failed => switch (error) {
        'login' => l.haErrorLogin,
        'unreachable' => l.haErrorUnreachable,
        _ => l.haErrorOther(error ?? '?'),
      },
  };
}

/// Settings → System → Home Assistant: this device as a device in Home
/// Assistant over MQTT (see HaMqttLink) - on/off, broker and login. Every
/// change is saved and applied right away.
class HaSettingsScreen extends ConsumerStatefulWidget {
  const HaSettingsScreen({super.key});

  @override
  ConsumerState<HaSettingsScreen> createState() => _HaSettingsScreenState();
}

class _HaSettingsScreenState extends ConsumerState<HaSettingsScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    () async {
      final s = await ref.read(settingsRepositoryProvider).getHaLink();
      if (!mounted) return;
      setState(() {
        _host.text = s.host;
        _port.text = s.port == HaLinkSettings.defaultPort ? '' : '${s.port}';
        _user.text = s.user;
        _password.text = s.password;
        _loaded = true;
      });
    }();
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool? enabled}) async {
    final current = ref.read(haLinkSettingsProvider);
    await ref.read(haLinkSettingsProvider.notifier).set(current.copyWith(
          enabled: enabled,
          host: _host.text.trim(),
          port: int.tryParse(_port.text.trim()) ?? HaLinkSettings.defaultPort,
          user: _user.text.trim(),
          password: _password.text,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    final settings = ref.watch(haLinkSettingsProvider);
    final dashboardUrl = ref.watch(dashboardUrlProvider);
    final deviceName = ref.watch(deviceNameProvider);
    final link = ref.read(haMqttLinkProvider);
    final defaultHost = Uri.tryParse(dashboardUrl)?.host ?? '';
    return Scaffold(
      appBar: AppBar(title: Text(l.haTitle)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : FocusTraversalGroup(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(l.haIntro, style: help),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    autofocus: true,
                    title: Text(l.haEnabled),
                    value: settings.enabled,
                    onChanged: (v) => _save(enabled: v),
                  ),
                  ListenableBuilder(
                    listenable: Listenable.merge([link.state, link.error]),
                    builder: (context, _) => Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        haLinkStatusText(
                          l,
                          link.state.value,
                          link.error.value,
                          deviceName: deviceName,
                          hasHost: haBrokerFor(settings.copyWith(enabled: true), dashboardUrl) != null,
                        ),
                        style: TextStyle(
                          color: link.state.value == HaLinkState.connected
                              ? Theme.of(context).colorScheme.primary
                              : link.state.value == HaLinkState.failed
                                  ? Colors.orangeAccent
                                  : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                  PopupTextField(
                    controller: _host,
                    label: l.haHost,
                    hint: defaultHost.isEmpty ? l.nasHostHint : defaultHost,
                    icon: Icons.dns_outlined,
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 12),
                  PopupTextField(
                    controller: _port,
                    label: l.haPort(HaLinkSettings.defaultPort),
                    icon: Icons.numbers,
                    keyboardType: TextInputType.number,
                    onSubmitted: (v) {
                      if (int.tryParse(v.trim()) == null) _port.text = '';
                      _save();
                    },
                  ),
                  const SizedBox(height: 12),
                  PopupTextField(
                    controller: _user,
                    label: l.haUser,
                    icon: Icons.person_outline,
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 12),
                  PopupTextField(
                    controller: _password,
                    label: l.nasPassword,
                    icon: Icons.key_outlined,
                    obscureText: true,
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 12),
                  Text(l.haLoginHint, style: help),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: Text(l.haShareCamera),
                    subtitle: Text(l.haShareCameraHelp, style: help),
                    value: settings.shareCamera,
                    onChanged: (v) async {
                      // Sharing means the camera - its permission is asked here.
                      if (v && !await ref.read(displayServiceProvider).requestCameraPermission()) return;
                      await ref.read(haLinkSettingsProvider.notifier).set(ref.read(haLinkSettingsProvider).copyWith(shareCamera: v));
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(l.haEntitiesHint, style: help),
                ],
              ),
            ),
    );
  }
}
