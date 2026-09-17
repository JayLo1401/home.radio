import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// TEMP (2026-09-16): live DAB+ playback tuning panel, so the right values
/// can be found by ear while playback runs, instead of a rebuild/install
/// cycle per attempt. Meant to be removed again once good values are found
/// (see DabTuning.kt on the native side for what each knob actually does).
class DabTuningPanel extends ConsumerStatefulWidget {
  const DabTuningPanel({super.key});

  @override
  ConsumerState<DabTuningPanel> createState() => _DabTuningPanelState();
}

class _DabTuningPanelState extends ConsumerState<DabTuningPanel> {
  bool _expanded = false;
  bool _loaded = false;

  double _audioBufferMs = 800;
  double _degenerateFillThreshold = 64;
  double _overrunCheckInterval = 100;
  double _watchdogTimeoutMs = 1500;

  Future<void> _loadCurrent() async {
    final values = await ref.read(dabUsbServiceProvider).dabGetTuning();
    if (!mounted) return;
    setState(() {
      _audioBufferMs = (values['audioBufferMs'] ?? _audioBufferMs.toInt()).toDouble();
      _degenerateFillThreshold = (values['degenerateFillThreshold'] ?? _degenerateFillThreshold.toInt()).toDouble();
      _overrunCheckInterval = (values['overrunCheckInterval'] ?? _overrunCheckInterval.toInt()).toDouble();
      _watchdogTimeoutMs = (values['watchdogTimeoutMs'] ?? _watchdogTimeoutMs.toInt()).toDouble();
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      color: Colors.black87,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            title: const Text('DAB+ Feinabstimmung (live)', style: TextStyle(color: Colors.white)),
            trailing: IconButton(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: Colors.white),
              onPressed: () {
                setState(() => _expanded = !_expanded);
                if (_expanded && !_loaded) _loadCurrent();
              },
            ),
            onTap: () {
              setState(() => _expanded = !_expanded);
              if (_expanded && !_loaded) _loadCurrent();
            },
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _tuningSlider(
                    label: 'Audio-Puffer',
                    value: _audioBufferMs,
                    min: 100,
                    max: 3000,
                    divisions: 58,
                    unit: 'ms',
                    onChanged: (v) {
                      setState(() => _audioBufferMs = v);
                      ref.read(dabUsbServiceProvider).dabSetTuning(audioBufferMs: v.round());
                    },
                  ),
                  _tuningSlider(
                    label: 'Füllmuster-Schwelle',
                    value: _degenerateFillThreshold,
                    min: 16,
                    max: 256,
                    divisions: 30,
                    unit: 'Byte',
                    onChanged: (v) {
                      setState(() => _degenerateFillThreshold = v);
                      ref.read(dabUsbServiceProvider).dabSetTuning(degenerateFillThreshold: v.round());
                    },
                  ),
                  _tuningSlider(
                    label: 'Überlauf-Prüfintervall',
                    value: _overrunCheckInterval,
                    min: 10,
                    max: 500,
                    divisions: 49,
                    unit: 'Reads',
                    onChanged: (v) {
                      setState(() => _overrunCheckInterval = v);
                      ref.read(dabUsbServiceProvider).dabSetTuning(overrunCheckInterval: v.round());
                    },
                  ),
                  _tuningSlider(
                    label: 'Watchdog-Timeout',
                    value: _watchdogTimeoutMs,
                    min: 300,
                    max: 5000,
                    divisions: 47,
                    unit: 'ms',
                    onChanged: (v) {
                      setState(() => _watchdogTimeoutMs = v);
                      ref.read(dabUsbServiceProvider).dabSetTuning(watchdogTimeoutMs: v.round());
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _tuningSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String unit,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.round()} $unit', style: const TextStyle(color: Colors.white70, fontSize: 13)),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: '${value.round()} $unit',
          onChanged: onChanged,
        ),
      ],
    );
  }
}
