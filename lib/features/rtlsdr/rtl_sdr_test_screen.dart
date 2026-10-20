import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/rtl_sdr_service.dart';
import '../../data/services/rtl_sdr_usb_service.dart';

/// How the DAB+ decoder (and this screen's own test connection) reaches the
/// RTL-SDR dongle:
/// - [usb]: this app drives the dongle directly over USB (cpp/hrdab's own
///   RTL2832U/R820T driver) - no rtl_tcp server/client involved at all.
/// - [tcp]: a plain rtl_tcp client connection to host:port - either an
///   external driver app on this same device (localhost) or an rtl_tcp
///   service elsewhere on the network (e.g. a Raspberry Pi with the dongle
///   attached), both reached the exact same way.
enum RtlSdrConnectionMode { usb, tcp }

/// DAB+'s RTL-SDR setup/diagnostic screen - picks how the dongle is reached
/// and lets that chain be verified independently of DAB+ decoding itself.
class RtlSdrTestScreen extends ConsumerStatefulWidget {
  const RtlSdrTestScreen({super.key});

  @override
  ConsumerState<RtlSdrTestScreen> createState() => _RtlSdrTestScreenState();
}

class _RtlSdrTestScreenState extends ConsumerState<RtlSdrTestScreen> {
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _portController = TextEditingController(text: '1234');
  final _freqController = TextEditingController(text: '100000000');

  bool _connecting = false;
  RtlConnectResult? _lastResult;
  RtlSdrStats? _lastStats;
  bool _autoGain = true;

  RtlSdrConnectionMode _mode = RtlSdrConnectionMode.tcp;
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
    final ownUsb = await settings.getRtlSdrAutoStartOwnService();
    if (!mounted) return;
    setState(() {
      _hostController.text = host;
      _portController.text = '$port';
      _mode = ownUsb ? RtlSdrConnectionMode.usb : RtlSdrConnectionMode.tcp;
    });
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

  Future<void> _selectMode(RtlSdrConnectionMode mode) async {
    setState(() => _mode = mode);
    await ref.read(settingsRepositoryProvider).setRtlSdrMode(ownUsbService: mode == RtlSdrConnectionMode.usb);
    if (mode == RtlSdrConnectionMode.usb) _refreshUsbDevices();
  }

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
      appBar: AppBar(title: const Text('DAB+ RTL-SDR Einrichtung')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Wie soll DAB+ den RTL-SDR-Stick ansprechen?',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            DropdownButton<RtlSdrConnectionMode>(
              value: _mode,
              items: const [
                DropdownMenuItem(value: RtlSdrConnectionMode.usb, child: Text('RTL-SDR-USB')),
                DropdownMenuItem(value: RtlSdrConnectionMode.tcp, child: Text('RTL-SDR TCP')),
              ],
              onChanged: connected ? null : (m) => m == null ? null : _selectMode(m),
            ),
            const SizedBox(height: 16),
            if (_mode == RtlSdrConnectionMode.usb) ...[
              const Text(
                'DAB+ öffnet den Stick direkt über USB, ohne rtl_tcp-Umweg. '
                'Kein separater "Dienst starten"-Schritt nötig - sobald ein Sender '
                'gestartet wird, öffnet der Decoder den Stick selbst.',
                style: TextStyle(color: Colors.white70),
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
                    child: TextField(
                      controller: _hostController,
                      enabled: !connected,
                      decoration: const InputDecoration(labelText: 'Host (IP)'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _portController,
                      enabled: !connected,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Port'),
                    ),
                  ),
                ],
              ),
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
                    child: TextField(
                      controller: _freqController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Frequenz (Hz)'),
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
