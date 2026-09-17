import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/rtl_sdr_service.dart';

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

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _freqController.dispose();
    super.dispose();
  }

  RtlSdrService get _service => ref.read(rtlSdrServiceProvider);

  Future<void> _connect() async {
    setState(() => _connecting = true);
    final port = int.tryParse(_portController.text) ?? 1234;
    final result = await _service.connect(host: _hostController.text.trim(), port: port);
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
              'Verbindet sich mit einem rtl_tcp-Server - z.B. der App "SDR driver" '
              '(marto.rtl_tcp_andro) lokal auf diesem Gerät, oder einem entfernten '
              'Server (z.B. Raspberry Pi mit angeschlossenem Stick).',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
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
        ),
      ),
    );
  }
}
