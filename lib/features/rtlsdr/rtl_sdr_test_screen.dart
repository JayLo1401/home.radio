import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart';
import '../../core/providers.dart';
import '../../data/repositories/settings_repository.dart' show ReceiverMode, RtlTcpAuth;
import '../../data/services/rtl_sdr_service.dart';
import '../../data/services/rtl_sdr_usb_service.dart';

/// "Radio-Empfänger": whether and how DAB+ and FM reach the RTL-SDR receiver (see
/// [ReceiverMode]) - "Kein Empfänger" for internet radio only - and a test
/// connection that verifies the rtl_tcp chain independently of DAB+
/// decoding itself.
class RtlSdrTestScreen extends ConsumerStatefulWidget {
  const RtlSdrTestScreen({super.key});

  @override
  ConsumerState<RtlSdrTestScreen> createState() => _RtlSdrTestScreenState();
}

class _RtlSdrTestScreenState extends ConsumerState<RtlSdrTestScreen> {
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _portController = TextEditingController(text: '1234');
  final _freqController = TextEditingController(text: '100000000');
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  RtlTcpAuth _auth = const RtlTcpAuth();

  bool _connecting = false;
  RtlConnectResult? _lastResult;
  RtlSdrStats? _lastStats;
  bool _autoGain = true;

  late ReceiverMode _mode = ref.read(receiverModeProvider);
  List<RtlSdrUsbDevice> _usbDevices = [];
  bool _usbBusy = false;

  @override
  void initState() {
    super.initState();
    _loadPersisted();
    _refreshUsbDevices();
  }

  Future<void> _loadPersisted() async {
    final settings = ref.read(settingsRepositoryProvider);
    final host = await settings.getRtlSdrHost();
    final port = await settings.getRtlSdrPort();
    final mode = await settings.getReceiverMode();
    final auth = await settings.getRtlTcpAuth();
    if (!mounted) return;
    setState(() {
      _hostController.text = host;
      _portController.text = '$port';
      _mode = mode;
      _auth = auth;
      _userController.text = auth.user;
      _passwordController.text = auth.password;
    });
  }

  /// Protocol/login are saved right away; the receiver picks them up the
  /// next time it connects (a changed setting starts a new session).
  Future<void> _saveAuth(RtlTcpAuth auth) async {
    setState(() => _auth = auth);
    await ref.read(settingsRepositoryProvider).setRtlTcpAuth(auth);
  }

  @override
  void dispose() {
    // rtl_tcp (both our own server and most external ones) only serves one
    // client at a time - leaving this screen connected would permanently
    // block the DAB+ decoder (or anything else) from ever getting a real
    // connection, with no obvious error (the TCP handshake still succeeds,
    // it just never receives any data).
    if (_lastResult?.connected == true) {
      _service.disconnect();
    }
    _hostController.dispose();
    _portController.dispose();
    _freqController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  RtlSdrService get _service => ref.read(rtlSdrServiceProvider);
  RtlSdrUsbService get _usbService => ref.read(rtlSdrUsbServiceProvider);

  Future<void> _refreshUsbDevices() async {
    final devices = await _usbService.listDevices();
    if (!mounted) return;
    setState(() => _usbDevices = devices);
  }

  Future<void> _requestUsbPermission(RtlSdrUsbDevice device) async {
    setState(() => _usbBusy = true);
    await _usbService.requestPermission(device.deviceName);
    await _refreshUsbDevices();
    if (mounted) setState(() => _usbBusy = false);
  }

  Future<void> _selectMode(ReceiverMode mode) async {
    setState(() => _mode = mode);
    await ref.read(receiverModeProvider.notifier).set(mode);
    if (mode == ReceiverMode.usb) _refreshUsbDevices();
  }

  /// Saved right away, not only on "Verbinden" - DAB+ uses this server too.
  Future<void> _saveServer() => ref
      .read(settingsRepositoryProvider)
      .setRtlSdrServer(_hostController.text.trim(), int.tryParse(_portController.text) ?? 1234);

  Future<void> _connect() async {
    setState(() => _connecting = true);
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text) ?? 1234;
    await ref.read(settingsRepositoryProvider).setRtlSdrServer(host, port);
    final result = await _service.connect(host: host, port: port);
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _lastResult = result;
    });
    if (result.connected) {
      ref.read(rtlSdrServiceProvider).stats.listen((stats) {
        if (mounted) setState(() => _lastStats = stats);
      });
      await _service.setSampleRateHz(2048000);
      await _service.setGainMode(auto: _autoGain);
      final hz = int.tryParse(_freqController.text);
      if (hz != null) await _service.setFrequencyHz(hz);
    }
  }

  Future<void> _disconnect() async {
    await _service.disconnect();
    if (!mounted) return;
    setState(() {
      _lastResult = null;
      _lastStats = null;
    });
  }

  Future<void> _tune() async {
    final hz = int.tryParse(_freqController.text);
    if (hz != null) await _service.setFrequencyHz(hz);
  }

  @override
  Widget build(BuildContext context) {
    final connected = _lastResult?.connected ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Radio-Empfänger (DAB+ & UKW)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Für DAB+ und UKW braucht es einen RTL-SDR-Stick - direkt am Gerät oder über das Netzwerk. '
              'Internetradio funktioniert auch ohne.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            DropdownButton<ReceiverMode>(
              value: _mode,
              items: const [
                DropdownMenuItem(value: ReceiverMode.none, child: Text('Kein Empfänger (nur Internetradio)')),
                DropdownMenuItem(value: ReceiverMode.usb, child: Text('RTL-SDR-Stick per USB')),
                DropdownMenuItem(value: ReceiverMode.tcp, child: Text('RTL-SDR über Netzwerk (rtl_tcp)')),
              ],
              onChanged: connected ? null : (m) => m == null ? null : _selectMode(m),
            ),
            const SizedBox(height: 16),
            if (_mode == ReceiverMode.none)
              const Text(
                'DAB+- und UKW-Sendersuche sowie die Reiter „DAB+“ und „FM“ sind ausgeblendet. '
                'Vorhandene DAB+- und UKW-Favoriten bleiben erhalten, spielen aber erst wieder mit einem Empfänger.',
                style: TextStyle(color: Colors.white70),
              )
            else if (_mode == ReceiverMode.usb) ...[
              const Text(
                'DAB+ öffnet den Stick direkt über USB, ohne rtl_tcp-Umweg. '
                'Kein separater "Dienst starten"-Schritt nötig - sobald ein Sender '
                'gestartet wird, öffnet der Decoder den Stick selbst.',
                style: TextStyle(color: Colors.white70),
              ),
              if (Platform.isWindows)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Windows: Der Stick braucht einmalig den WinUSB-Treiber - mit Zadig (zadig.akeo.ie) '
                    'für "Bulk-In, Interface (Interface 0)" installieren. Ohne ihn ist kein Zugriff möglich.',
                    style: TextStyle(color: Colors.white70),
                  ),
                )
              else if (Platform.isLinux)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Linux: Für den Zugriff braucht es eine udev-Regel für den Stick (z.B. aus dem Paket rtl-sdr); '
                    'der DVB-T-Treiber des Kernels wird automatisch abgekoppelt.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              const SizedBox(height: 12),
              if (_usbDevices.isEmpty)
                const Text('Kein RTL-SDR-Stick erkannt.', style: TextStyle(color: Colors.orangeAccent))
              else
                for (final device in _usbDevices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(child: Text(device.label)),
                        if (!device.hasPermission)
                          ElevatedButton(
                            onPressed: _usbBusy ? null : () => _requestUsbPermission(device),
                            child: const Text('Zugriff erlauben'),
                          )
                        else
                          const Text('Zugriff erteilt', style: TextStyle(color: Colors.greenAccent)),
                      ],
                    ),
                  ),
              IconButton(onPressed: _refreshUsbDevices, icon: const Icon(Icons.refresh)),
            ] else ...[
              const Text(
                'Verbindet sich als rtl_tcp-Client - egal ob eine externe Treiber-App '
                'auf diesem Gerät (Host 127.0.0.1), ein Netzwerkdienst (z.B. Raspberry '
                'Pi) oder später einmal ein eigener lokaler Dienst dahintersteckt.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: PopupTextField(
                      controller: _hostController,
                      enabled: !connected,
                      label: 'Host (IP)',
                      onSubmitted: (_) => _saveServer(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PopupTextField(
                      controller: _portController,
                      enabled: !connected,
                      keyboardType: TextInputType.number,
                      label: 'Port',
                      onSubmitted: (_) => _saveServer(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Chosen by hand, no auto-detection (rtltcp.server's
              // docs/client-integration.md).
              Row(
                children: [
                  const Text('Protokoll:'),
                  const SizedBox(width: 12),
                  DropdownButton<bool>(
                    value: _auth.v2,
                    items: const [
                      DropdownMenuItem(value: false, child: Text('rtl_tcp (v1)')),
                      DropdownMenuItem(value: true, child: Text('rtltcp_v2')),
                    ],
                    onChanged: (v) => v == null ? null : _saveAuth(_auth.copyWith(v2: v)),
                  ),
                ],
              ),
              if (_auth.v2) ...[
                const Text(
                  'rtltcp_v2 (z.B. rtltcp.server) meldet, wenn der Stick am Server fehlt oder der Server '
                  'belegt ist, und kann eine Anmeldung verlangen. Ein klassischer rtl_tcp-Server funktioniert '
                  'trotzdem weiter.',
                  style: TextStyle(color: Colors.white70),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Anmeldung'),
                  subtitle: const Text('Nur nötig, wenn der Server es verlangt'),
                  value: _auth.login,
                  onChanged: (v) => _saveAuth(_auth.copyWith(login: v)),
                ),
                if (_auth.login)
                  Row(
                    children: [
                      Expanded(
                        child: PopupTextField(
                          controller: _userController,
                          label: 'Benutzer',
                          onSubmitted: (v) => _saveAuth(_auth.copyWith(user: v.trim())),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PopupTextField(
                          controller: _passwordController,
                          label: 'Passwort',
                          obscureText: true,
                          onSubmitted: (v) => _saveAuth(_auth.copyWith(password: v)),
                        ),
                      ),
                    ],
                  ),
                const Text(
                  'Der Verbindungstest hier unten nutzt immer das klassische Protokoll (v1).',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: _connecting ? null : (connected ? _disconnect : _connect),
                    child: Text(_connecting ? 'Verbinde…' : (connected ? 'Trennen' : 'Verbinden')),
                  ),
                  const SizedBox(width: 16),
                  Switch(
                    value: _autoGain,
                    onChanged: connected
                        ? (v) {
                            setState(() => _autoGain = v);
                            _service.setGainMode(auto: v);
                          }
                        : null,
                  ),
                  const Text('Auto-Gain'),
                ],
              ),
              const Divider(height: 32),
              Row(
                children: [
                  Expanded(
                    child: PopupTextField(
                      controller: _freqController,
                      keyboardType: TextInputType.number,
                      label: 'Frequenz (Hz)',
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(onPressed: connected ? _tune : null, child: const Text('Antunen')),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                connected ? 'Status: Verbunden' : 'Status: Nicht verbunden',
                style: TextStyle(color: connected ? Colors.greenAccent : Colors.redAccent, fontSize: 16),
              ),
              if (_lastResult?.error != null)
                Text('Fehler: ${_lastResult!.error}', style: const TextStyle(color: Colors.redAccent)),
              if (connected) ...[
                Text('Tuner-Typ: ${_lastResult?.tunerType}'),
                Text('Gain-Stufen: ${_lastResult?.tunerGainCount}'),
                const SizedBox(height: 12),
                Text(
                  _lastStats == null
                      ? 'Warte auf Daten…'
                      : 'Empfangen: ${_lastStats!.bytesPerSec} Byte/s '
                          '(gesamt: ${(_lastStats!.totalBytes / 1024).toStringAsFixed(0)} KB)',
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 8),
                Text(
                  (_lastStats?.bytesPerSec ?? 0) > 0
                      ? '✓ Es kommen Daten an - die Kette Stick → Treiber-App → Netzwerk → diese App funktioniert.'
                      : 'Noch keine Daten - prüfe ob die Treiber-App läuft und den Stick erkannt hat.',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
