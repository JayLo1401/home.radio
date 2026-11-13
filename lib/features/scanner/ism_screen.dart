import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/popup_text_field.dart' show showTextInputDialog;
import '../../core/providers.dart';
import '../../core/theme.dart' show TvFocusHighlight;
import '../../data/models/ism.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;
import '../shared/logo_picker_dialog.dart' show connectDecoder;
import 'reception_status.dart';

/// Wireless sensors in the neighbourhood (433,92 / 868,3 MHz): thermometers
/// and weather stations as cards with their values and a 24 h curve,
/// remotes/doorbells as an event list, everything undecoded under
/// "Unbekannt". Own names and hidden devices are remembered.
class IsmScreen extends ConsumerStatefulWidget {
  const IsmScreen({super.key});

  @override
  ConsumerState<IsmScreen> createState() => _IsmScreenState();
}

class _IsmScreenState extends ConsumerState<IsmScreen> {
  late final DabRtlSdrService _rx;
  late final SettingsRepository _settings;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _tick;

  final _tracker = IsmTracker();
  Map<String, String> _names = {};
  int _freqHz = 433920000;
  bool _started = false;
  bool _failed = false;
  String? _sourceWarning;
  int _gainIndex = -1;
  double? _gainDb;
  bool _showUnknown = false;
  bool _showHidden = false;

  // Reception indicator (see ReceptionStatus).
  RxStatus? _status;
  DateTime? _lastBurst;

  static const _gainKey = 'ism';
  static const _freqs = [(433920000, '433,92 MHz'), (868300000, '868,3 MHz')];

  @override
  void initState() {
    super.initState();
    _rx = ref.read(dabRtlSdrServiceProvider);
    _settings = ref.read(settingsRepositoryProvider);
    _sub = _rx.events.listen(_onEvent);
    _init();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    _rx.ismStop();
    super.dispose();
  }

  Future<void> _init() async {
    _names = await _settings.getIsmNames();
    _freqHz = await _settings.getIsmFrequency();
    _gainIndex = await _settings.getNbGain(_gainKey);
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    await _start();
    // Ages ("vor 20 s") and curves update without a new burst too.
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _start() async {
    final ok = await _rx.ismStart(_freqHz);
    if (ok) _gainDb = await _rx.nbSetGain(_gainIndex);
    if (mounted) {
      setState(() {
        _started = ok;
        _failed = !ok;
      });
    }
  }

  Future<void> _setFrequency(int hz) async {
    if (hz == _freqHz) return;
    setState(() {
      _freqHz = hz;
      _started = false;
    });
    await _settings.setIsmFrequency(hz);
    await _start();
  }

  Future<void> _stepGain(int delta) async {
    final next = (_gainIndex + delta).clamp(-1, DabRtlSdrService.nbGainSteps - 1);
    if (next == _gainIndex) return;
    setState(() => _gainIndex = next);
    await _settings.setNbGain(_gainKey, next);
    final db = await _rx.nbSetGain(next);
    if (mounted) setState(() => _gainDb = db);
  }

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'rxStatus':
        if (!mounted) return;
        setState(() {
          _status = RxStatus.fromEvent(event);
          if (_gainIndex < 0) _gainDb = _status!.gainDb;
        });
      case 'ismBurst':
        _tracker.add(IsmBurst.fromEvent(event, freqHz: _freqHz));
        _lastBurst = DateTime.now();
        if (mounted) setState(() {});
      case 'connectionMessage':
        final isError = event['isError'] as bool? ?? false;
        final message = (event['message'] as String?)?.trim() ?? '';
        if (mounted) setState(() => _sourceWarning = isError && message.isNotEmpty ? message : null);
    }
  }

  bool _hidden(IsmDevice d) => _names[d.key] == SettingsRepository.ismHidden;
  String? _nameOf(IsmDevice d) => _hidden(d) ? null : _names[d.key];

  Future<void> _rename(IsmDevice d) async {
    final name = await showTextInputDialog(
      context,
      title: 'Name für ${d.last.model}',
      initialValue: _nameOf(d) ?? '',
      hint: 'z. B. Balkon, Keller, Nachbar Garten',
    );
    if (name == null) return;
    setState(() {
      if (name.isEmpty) {
        _names.remove(d.key);
      } else {
        _names[d.key] = name;
      }
    });
    await _settings.setIsmNames(_names);
  }

  Future<void> _setHidden(IsmDevice d, bool hidden) async {
    setState(() {
      if (hidden) {
        _names[d.key] = SettingsRepository.ismHidden;
      } else {
        _names.remove(d.key);
      }
    });
    await _settings.setIsmNames(_names);
  }

  /// Named first, then by last heard.
  List<IsmDevice> _sorted(IsmCategory category) {
    final list = _tracker.devices.values
        .where((d) => d.last.category == category && (_showHidden || !_hidden(d)))
        .toList();
    list.sort((a, b) {
      final na = _nameOf(a) != null, nb = _nameOf(b) != null;
      if (na != nb) return na ? -1 : 1;
      return b.lastSeen.compareTo(a.lastSeen);
    });
    return list;
  }

  void _details(IsmDevice d) {
    showDialog<void>(
      context: context,
      builder: (context) => _DeviceDialog(
        device: d,
        name: _nameOf(d),
        hidden: _hidden(d),
        onRename: () async {
          Navigator.of(context).pop();
          await _rename(d);
        },
        onHide: (v) async {
          Navigator.of(context).pop();
          await _setHidden(d, v);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final weather = _sorted(IsmCategory.weather);
    final switches = _sorted(IsmCategory.switches);
    final hiddenCount = _tracker.devices.values.where(_hidden).length;
    const muted = TextStyle(color: Colors.white70);
    String db(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
    return Scaffold(
      appBar: AppBar(title: const Text('Funksensoren')),
      body: _failed
          ? const Center(child: Text('Empfänger konnte nicht gestartet werden.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_sourceWarning case final warning?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(warning, style: const TextStyle(color: Colors.orangeAccent, fontSize: 16)),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final (i, (hz, label)) in _freqs.indexed)
                      ChoiceChip(
                        autofocus: i == 0,
                        label: Text(label),
                        selected: _freqHz == hz,
                        onSelected: (_) => _setFrequency(hz),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      _started
                          ? '${_tracker.devices.length} Geräte · ${_tracker.bursts} Signale'
                          : 'Starte Empfänger…',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(width: 8),
                    const Text('Verstärkung', style: muted),
                    IconButton(onPressed: () => _stepGain(-1), icon: const Icon(Icons.remove)),
                    Text(
                      _gainIndex < 0
                          ? 'Auto${_gainDb == null ? '' : ' (${db(_gainDb!)} dB)'}'
                          : '${db(_gainDb ?? 0)} dB',
                    ),
                    IconButton(onPressed: () => _stepGain(1), icon: const Icon(Icons.add)),
                    if (hiddenCount > 0)
                      FilterChip(
                        label: Text('Ausgeblendete zeigen ($hiddenCount)'),
                        selected: _showHidden,
                        onSelected: (v) => setState(() => _showHidden = v),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                ReceptionStatus(status: _status, expectedRate: 1024000, lastSignal: _lastBurst),
                const SizedBox(height: 16),
                if (_started && _tracker.devices.isEmpty && _tracker.unknown.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Warte auf Funksensoren… Die meisten senden alle 30–60 Sekunden.\n'
                      'Antenne für 433 MHz: senkrecht, ~17 cm (868 MHz: ~8,6 cm).',
                      style: TextStyle(color: Colors.white54, fontSize: 16),
                    ),
                  ),
                if (weather.isNotEmpty) ...[
                  const _Section(icon: Icons.thermostat, title: 'Thermometer & Wetter'),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final d in weather)
                        _WeatherCard(device: d, name: _nameOf(d), hidden: _hidden(d), onTap: () => _details(d)),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
                if (switches.isNotEmpty) ...[
                  const _Section(icon: Icons.notifications_active_outlined, title: 'Schalter, Klingeln, Fernbedienungen'),
                  for (final d in switches)
                    _EventRow(device: d, name: _nameOf(d), onTap: () => _details(d)),
                  const SizedBox(height: 20),
                ],
                if (_tracker.keyPresses > 0) ...[
                  const _Section(icon: Icons.key_outlined, title: 'Funkschlüssel (anonym)'),
                  Padding(
                    padding: const EdgeInsets.only(left: 28, bottom: 20),
                    child: Text(
                      '${_tracker.keyPresses} Tastendrücke in der Umgebung, seit diese Seite offen ist · '
                      'zuletzt ${_age(_tracker.lastKeyPress!)}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
                if (_tracker.unknown.isNotEmpty) ...[
                  Row(
                    children: [
                      const _Section(icon: Icons.help_outline, title: 'Unbekannt'),
                      const SizedBox(width: 12),
                      Text('${_tracker.unknown.length} Sender', style: muted),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: () => setState(() => _showUnknown = !_showUnknown),
                        child: Text(_showUnknown ? 'Rohdaten ausblenden' : 'Rohdaten ansehen'),
                      ),
                    ],
                  ),
                  if (_showUnknown)
                    for (final u in _tracker.unknown.take(30)) _UnknownRow(group: u),
                ],
              ],
            ),
    );
  }
}

String _age(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 60) return 'vor $s s';
  if (s < 3600) return 'vor ${s ~/ 60} min';
  return 'vor ${s ~/ 3600} h';
}

String _num(double v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;

  const _Section({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: Colors.white70),
          const SizedBox(width: 8),
          Text(title.toUpperCase(), style: const TextStyle(color: Colors.white70, letterSpacing: 1, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// A focusable card (frame while focused, OK = onTap).
class _FocusCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double? width;

  const _FocusCard({required this.child, required this.onTap, this.width});

  @override
  State<_FocusCard> createState() => _FocusCardState();
}

class _FocusCardState extends State<_FocusCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(10),
        child: Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            focusColor: Colors.transparent,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onTap,
            child: Padding(padding: const EdgeInsets.all(12), child: widget.child),
          ),
        ),
      ),
    );
  }
}

class _WeatherCard extends StatelessWidget {
  final IsmDevice device;
  final String? name;
  final bool hidden;
  final VoidCallback onTap;

  const _WeatherCard({required this.device, required this.name, required this.hidden, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final r = device.last;
    final title = name ?? '${r.model}${r.channel != null ? ' · Kanal ${r.channel}' : ''}';
    return Opacity(
      opacity: hidden ? 0.5 : 1,
      child: _FocusCard(
        width: 300,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$title${name != null ? ' ★' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (r.temperatureC != null)
                  Text('${_num(r.temperatureC!, 1)} °C', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
                const SizedBox(width: 14),
                if (r.humidity != null)
                  Text('${r.humidity} %', style: const TextStyle(fontSize: 22, color: Colors.lightBlueAccent)),
              ],
            ),
            if (r.windMs != null || r.rainMm != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [
                    if (r.windMs != null)
                      'Wind ${_num(r.windMs! * 3.6, 0)} km/h'
                          '${r.windDirection != null ? ' aus ${r.windDirection!.round()}°' : ''}',
                    if (r.gustMs != null) 'Böen ${_num(r.gustMs! * 3.6, 0)}',
                    if (r.rainMm != null) 'Regen ${_num(r.rainMm!, 1)} mm',
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(height: 36, child: CustomPaint(size: Size.infinite, painter: _Sparkline(device.history))),
            const SizedBox(height: 6),
            Row(
              children: [
                if (r.batteryOk != null) ...[
                  Icon(
                    r.batteryOk! ? Icons.battery_full : Icons.battery_alert,
                    size: 16,
                    color: r.batteryOk! ? Colors.white54 : Colors.orangeAccent,
                  ),
                  Text(r.batteryOk! ? ' ok' : ' schwach',
                      style: TextStyle(color: r.batteryOk! ? Colors.white54 : Colors.orangeAccent, fontSize: 12)),
                  const SizedBox(width: 10),
                ],
                Text(_age(device.lastSeen), style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Temperature over the last 24 h (humidity faint behind it).
class _Sparkline extends CustomPainter {
  final List<({DateTime at, double? temp, int? hum})> history;

  _Sparkline(this.history);

  @override
  void paint(Canvas canvas, Size size) {
    void line(List<(DateTime, double)> pts, Color color) {
      if (pts.length < 2) return;
      final t0 = pts.first.$1, t1 = pts.last.$1;
      final span = math.max(1, t1.difference(t0).inSeconds);
      final lo = pts.map((p) => p.$2).reduce(math.min), hi = pts.map((p) => p.$2).reduce(math.max);
      final range = math.max(1.0, hi - lo);
      final path = Path();
      for (final (i, (t, v)) in pts.indexed) {
        final x = t.difference(t0).inSeconds / span * size.width;
        final y = size.height - (v - lo) / range * size.height;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    line([for (final h in history) if (h.hum != null) (h.at, h.hum!.toDouble())], Colors.lightBlueAccent.withValues(alpha: 0.35));
    line([for (final h in history) if (h.temp != null) (h.at, h.temp!)], Colors.greenAccent);
  }

  @override
  bool shouldRepaint(covariant _Sparkline old) => true;
}

class _EventRow extends StatelessWidget {
  final IsmDevice device;
  final String? name;
  final VoidCallback onTap;

  const _EventRow({required this.device, required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final e = device.events.isEmpty ? null : device.events.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _FocusCard(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(width: 60, child: Text(e == null ? '' : hhmm(e.at), style: const TextStyle(color: Colors.white54))),
            Expanded(
              child: Text(
                name ?? '${device.last.model} · ID ${device.last.id}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(e?.event ?? '', style: const TextStyle(color: Colors.white70)),
            const SizedBox(width: 16),
            Text('${device.events.length}× · ${_age(device.lastSeen)}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _UnknownRow extends StatelessWidget {
  final IsmUnknownGroup group;

  const _UnknownRow({required this.group});

  @override
  Widget build(BuildContext context) {
    final u = group.sample;
    final b = u.burst;
    final p = b.pulses.toList()..sort();
    final g = b.gaps.toList()..sort();
    String range(List<int> v) => v.isEmpty ? '–' : '${v[v.length ~/ 10]}–${v[v.length * 9 ~/ 10]} µs';
    final band = b.freqHz == 0 ? '' : '${(b.freqHz / 1e6).round()} MHz · ';
    if (u.continuous) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          '${_age(group.lastSeen)} · ${group.count}× · ${band}Dauersender (FSK, ~${u.bitUs} µs/Bit) · '
          '${_num(b.offsetHz / 1000, 0)} kHz · SNR ${b.snrDb.round()} dB - fortlaufendes Muster, nicht dekodierbar',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white38),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '${_age(group.lastSeen)} · ${group.count}× · $band${b.modulation.toUpperCase()} ${u.coding}'
        '${u.bitUs != null ? ' ~${u.bitUs} µs/Bit' : ''} · ${p.length} Pulse '
        '(${range(p)}, Pausen ${range(g)}) · ${_num(b.offsetHz / 1000, 0)} kHz · SNR ${b.snrDb.round()} dB'
        '${u.afterSync != null ? '\n   Nach Sync 2DD4: ${u.afterSync}' : [for (final r in u.rows) '\n   $r'].join()}'
        '${u.manchesterHex != null ? '\n   Manchester: ${u.manchesterHex}' : ''}',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white60),
      ),
    );
  }
}

class _DeviceDialog extends StatelessWidget {
  final IsmDevice device;
  final String? name;
  final bool hidden;
  final VoidCallback onRename;
  final ValueChanged<bool> onHide;

  const _DeviceDialog({required this.device, required this.name, required this.hidden, required this.onRename, required this.onHide});

  @override
  Widget build(BuildContext context) {
    final r = device.last;
    String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final temps = [for (final h in device.history) if (h.temp != null) h.temp!];
    return AlertDialog(
      title: Text(name ?? r.model),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Gerät: ${r.model} · ID ${r.id}${r.channel != null ? ' · Kanal ${r.channel}' : ''}'),
            if (r.temperatureC != null)
              Text('Temperatur: ${_num(r.temperatureC!, 1)} °C'
                  '${temps.length > 1 ? ' (24 h: ${_num(temps.reduce(math.min), 1)} bis ${_num(temps.reduce(math.max), 1)} °C)' : ''}'),
            if (r.humidity != null) Text('Luftfeuchte: ${r.humidity} %'),
            if (r.batteryOk != null) Text('Batterie: ${r.batteryOk! ? 'ok' : 'schwach'}'),
            Text('Empfangen: ${device.count}× · zuletzt ${_age(device.lastSeen)} · Pegel ${device.levelDb.round()} dB'),
            if (device.history.length > 1) ...[
              const SizedBox(height: 12),
              SizedBox(height: 120, child: CustomPaint(size: Size.infinite, painter: _Sparkline(device.history))),
              Text('${hhmm(device.history.first.at)} – ${hhmm(device.history.last.at)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
            if (device.events.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final e in device.events.take(8)) Text('${hhmm(e.at)}  ${e.event}', style: const TextStyle(color: Colors.white70)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: onRename, child: Text(name == null ? 'Name vergeben' : 'Umbenennen')),
        TextButton(onPressed: () => onHide(!hidden), child: Text(hidden ? 'Wieder anzeigen' : 'Ausblenden')),
        TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Schließen')),
      ],
    );
  }
}
