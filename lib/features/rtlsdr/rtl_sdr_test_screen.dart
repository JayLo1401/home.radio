import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/rtl_sdr_service.dart';
import '../../data/services/rtl_sdr_usb_service.dart';

/// How the app reaches the RTL-SDR dongle - the three options from the
/// project's DAB+/RTL-SDR settings: our own direct-USB service (this app
/// drives the dongle itself and serves rtl_tcp on localhost), an external
/// rtl_tcp driver app running on this same device, or an external rtl_tcp
/// service somewhere on the network (e.g. a Raspberry Pi with the dongle
/// attached).
enum RtlSdrConnectionMode { ownUsb, externalApp, network }

/// Standalone test screen for the RTL-SDR / rtl_tcp connection layer
/// (2026-09-17) - lets the whole chain (dongle -> Android driver app or
/// remote rtl_tcp server -> this app) be verified the moment the dongle
/// arrives, independent of the DAB+/FM/AM demodulation work that comes
/// after. Meant to stay useful as a low-level diagnostic tool even once
/// that's built, not just a throwaway.
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

  RtlSdrConnectionMode _mode = RtlSdrConnectionMode.ownUsb;
  List<RtlSdrUsbDevice> _usbDevices = [];
  bool _usbBusy = false;
  bool _usbServerRunning = false;
  String? _usbError;

  @override
  void initState() {
    super.initState();
    _refreshUsbDevices();
    _loadPersistedServer();
  }

  /// The DAB+ decoder (DabRtlSdrPlugin) reads the same host/port from
  /// SettingsRepository to know where to connect, so this screen persists
  /// whatever the user configures here rather than keeping it purely local.
  Future<void> _loadPersistedServer() async {
    final settings = ref.read(settingsRepositoryProvider);
    final host = await settings.getRtlSdrHost();
    final port = await settings.getRtlSdrPort();
    if (!mounted) return;
    setState(() {
      _hostController.text = host;
      _portController.text = '$port';
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
    final running = await _usbService.isServerRunning();
    if (!mounted) return;
    setState(() {
      _usbDevices = devices;
      _usbServerRunning = running;
    });
  }

  Future<void> _requestUsbPermission(RtlSdrUsbDevice device) async {
    setState(() => _usbBusy = true);
    await _usbService.requestPermission(device.deviceName);
    await _refreshUsbDevices();
    if (mounted) setState(() => _usbBusy = false);
  }

  Future<void> _toggleUsbServer() async {
    setState(() {
      _usbBusy = true;
      _usbError = null;
    });
    try {
      if (_usbServerRunning) {
        await _usbService.stopServer();
      } else {
        final port = int.tryParse(_portController.text) ?? 1234;
        final freq = int.tryParse(_freqController.text) ?? 100000000;
        await _usbService.startServer(port: port, frequencyHz: freq);
        _hostController.text = '127.0.0.1';
        _portController.text = '$port';
        await ref.read(settingsRepositoryProvider).setRtlSdrServer('127.0.0.1', port);
        await ref.read(settingsRepositoryProvider).setRtlSdrMode(ownUsbService: true);
      }
    } catch (e) {
      _usbError = '$e';
    }
    await _refreshUsbDevices();
    if (mounted) setState(() => _usbBusy = false);
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text) ?? 1234;
    if (_mode != RtlSdrConnectionMode.ownUsb) {
      await ref.read(settingsRepositoryProvider).setRtlSdrServer(host, port);
      await ref.read(settingsRepositoryProvider).setRtlSdrMode(ownUsbService: false);
    }
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
      appBar: AppBar(title: const Text('RTL-SDR Test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Wie soll der RTL-SDR-Stick angesprochen werden? Entweder direkt über '
              'unseren eigenen USB-Dienst, über eine externe rtl_tcp-App auf diesem '
              'Gerät (z.B. "SDR driver" / marto.rtl_tcp_andro), oder über einen '
              'externen Netzwerk-Dienst (z.B. Raspberry Pi mit angeschlossenem Stick).',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Eigener USB-Dienst'),
                  selected: _mode == RtlSdrConnectionMode.ownUsb,
                  onSelected: connected ? null : (_) => setState(() => _mode = RtlSdrConnectionMode.ownUsb),
                ),
                ChoiceChip(
                  label: const Text('Externe App'),
                  selected: _mode == RtlSdrConnectionMode.externalApp,
                  onSelected: connected ? null : (_) => setState(() => _mode = RtlSdrConnectionMode.externalApp),
                ),
                ChoiceChip(
                  label: const Text('Netzwerk-Dienst'),
                  selected: _mode == RtlSdrConnectionMode.network,
                  onSelected: connected ? null : (_) => setState(() => _mode = RtlSdrConnectionMode.network),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_mode == RtlSdrConnectionMode.ownUsb) ...[
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
              Row(
                children: [
                  ElevatedButton(
                    onPressed: (_usbBusy || _usbDevices.every((d) => !d.hasPermission)) ? null : _toggleUsbServer,
                    child: Text(
                      _usbBusy
                          ? 'Bitte warten…'
                          : (_usbServerRunning ? 'USB-Dienst stoppen' : 'USB-Dienst starten'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(onPressed: _refreshUsbDevices, icon: const Icon(Icons.refresh)),
                ],
              ),
              if (_usbError != null)
                Text('Fehler: $_usbError', style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _hostController,
                    enabled: !connected && _mode != RtlSdrConnectionMode.ownUsb,
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
                  onPressed: _connecting || (!connected && _mode == RtlSdrConnectionMode.ownUsb && !_usbServerRunning)
                      ? null
                      : (connected ? _disconnect : _connect),
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
        ),
      ),
    );
  }
}
