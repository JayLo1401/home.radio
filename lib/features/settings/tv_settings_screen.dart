import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../data/services/enigma2_service.dart';
import '../../l10n/l10n.dart';
import '../tv/iptv_providers.dart';
import '../tv/tv_providers.dart';
import 'iptv_settings_screen.dart';
import 'receiver_search_dialog.dart';

/// TV's receiver: an Enigma2 box with OpenWebif (GigaBlue, VU+,
/// Dreambox, ...) in the home network - address, ports, login, and which
/// channel list (bouquet) TV shows.
class TvSettingsScreen extends ConsumerStatefulWidget {
  const TvSettingsScreen({super.key});

  @override
  ConsumerState<TvSettingsScreen> createState() => _TvSettingsScreenState();
}

class _TvSettingsScreenState extends ConsumerState<TvSettingsScreen> {
  late final Enigma2Config _initial = ref.read(enigma2ConfigProvider) ?? const Enigma2Config();
  late final _host = TextEditingController(text: _initial.host);
  late final _webPort = TextEditingController(text: '${_initial.webPort}');
  late final _streamPort = TextEditingController(text: '${_initial.streamPort}');
  late final _user = TextEditingController(text: _initial.user);
  late final _password = TextEditingController(text: _initial.password);
  late bool _https = _initial.useHttps;

  bool _testing = false;
  String? _result;
  bool _ok = false;
  List<E2Bouquet> _bouquets = const [];
  String? _bouquet;

  @override
  void initState() {
    super.initState();
    _bouquet = ref.read(tvBouquetProvider);
  }

  @override
  void dispose() {
    for (final c in [_host, _webPort, _streamPort, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Enigma2Config get _config => Enigma2Config(
        host: _host.text.trim(),
        webPort: int.tryParse(_webPort.text.trim()) ?? 80,
        streamPort: int.tryParse(_streamPort.text.trim()) ?? 8001,
        useHttps: _https,
        user: _user.text.trim(),
        password: _password.text,
      );

  Future<void> _test() async {
    if (_host.text.trim().isEmpty) {
      setState(() => _result = context.l10n.tvSettingsEnterAddress);
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    final service = Enigma2Service(_config);
    try {
      final about = await service.about();
      final bouquets = await service.bouquets();
      if (!mounted) return;
      setState(() {
        _ok = true;
        _bouquets = bouquets;
        _bouquet ??= bouquets.firstOrNull?.ref;
        final model = about.model.isEmpty ? context.l10n.tvEnigma2Receiver : about.model;
        _result = context.l10n
            .tvSettingsConnected('$model${about.image.isEmpty ? '' : ' (${about.image})'}', bouquets.length);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _ok = false;
          _result = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Finds the receiver in the network, takes its address and tests it.
  Future<void> _search() async {
    final found = await showReceiverSearch(context);
    if (found == null || !mounted) return;
    _host.text = found.host;
    _webPort.text = '${found.port}';
    setState(() => _https = false);
    await _test();
  }

  Future<void> _save() async {
    await ref.read(enigma2ConfigProvider.notifier).set(_config);
    final bouquet = _bouquet;
    if (bouquet != null) await ref.read(tvBouquetProvider.notifier).set(bouquet);
    ref.invalidate(tvBouquetsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.tvSettingsTitle)),
      body: FocusTraversalGroup(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(context.l10n.tvSettingsIntro, style: help),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: PopupTextField(
                    controller: _host,
                    label: context.l10n.tvSettingsAddress,
                    hint: '192.168.1.50',
                    keyboardType: TextInputType.url,
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  autofocus: _initial.host.isEmpty,
                  onPressed: _search,
                  icon: const Icon(Icons.search),
                  label: Text(context.l10n.tvSearchReceiver),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: PopupTextField(
                    controller: _webPort,
                    label: context.l10n.tvSettingsWebPort,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PopupTextField(
                    controller: _streamPort,
                    label: context.l10n.tvSettingsStreamPort,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(context.l10n.tvSettingsPortsHelp, style: help),
            const SizedBox(height: 12),
            SwitchListTile(
              title: Text(context.l10n.tvSettingsHttps),
              value: _https,
              onChanged: (v) => setState(() => _https = v),
            ),
            Row(
              children: [
                Expanded(child: PopupTextField(controller: _user, label: context.l10n.tvSettingsUser)),
                const SizedBox(width: 12),
                Expanded(
                  child: PopupTextField(controller: _password, label: context.l10n.tvSettingsPassword, obscureText: true),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.network_check),
                  label: Text(context.l10n.tvSettingsTestConnection),
                ),
                const SizedBox(width: 12),
                if (_testing) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                if (_result != null)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(_ok ? Icons.check_circle : Icons.error_outline,
                            color: _ok ? Theme.of(context).colorScheme.primary : Colors.amber),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_result!)),
                      ],
                    ),
                  ),
              ],
            ),
            if (_bouquets.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(context.l10n.tvSettingsChannelList, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final b in _bouquets)
                    ChoiceChip(
                      label: Text(b.name),
                      selected: _bouquet == b.ref,
                      onSelected: (_) => setState(() => _bouquet = b.ref),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(context.l10n.tvSettingsChannelListHelp, style: help),
            ],
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check),
                label: Text(context.l10n.commonSave),
              ),
            ),
            // Internet-TV: TV's other source, without a receiver.
            const Divider(height: 40),
            ListTile(
              leading: const Icon(Icons.public),
              title: Text(context.l10n.iptvSettingsTitle),
              subtitle: Text((ref.watch(iptvProvider)?.enabled ?? true) ? context.l10n.commonOn : context.l10n.commonOff),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IptvSettingsScreen())),
            ),
          ],
        ),
      ),
    );
  }
}
