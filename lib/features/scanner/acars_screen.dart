import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart' show TvFocusHighlight;
import '../../data/models/acars.dart';
import '../../data/models/band_plan.dart' show formatMhz;
import '../../data/repositories/settings_repository.dart';
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;
import '../shared/logo_picker_dialog.dart' show connectDecoder;
import 'reception_status.dart';

/// ACARS: short text messages between aircraft and their airlines on the
/// VHF airband. Two ways they travel: classic ACARS (AM, 2400 bit/s, around
/// 131 MHz) and VDL Mode 2 (D8PSK, 31,5 kbit/s, around 136,9 MHz) - in Europe
/// most airliners use VDL2 by now. Either way the receiver decodes all
/// channels at once - they fit into one window of the stick.
class AcarsScreen extends ConsumerStatefulWidget {
  const AcarsScreen({super.key});

  @override
  ConsumerState<AcarsScreen> createState() => _AcarsScreenState();
}

class _AcarsScreenState extends ConsumerState<AcarsScreen> {
  late final DabRtlSdrService _rx;
  late final SettingsRepository _settings;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _tick;

  /// European ACARS channels (131,725 the main one) and VDL2 channels
  /// (136,975 the common one); each window's centre lies between them (no
  /// channel on the tuner's DC spike).
  static const _acarsChannels = [131525000, 131725000, 131825000, 131850000];
  static const _acarsCenterHz = 131687500;
  static const _vdl2Channels = [136725000, 136775000, 136825000, 136875000, 136975000];
  static const _vdl2CenterHz = 136850000;

  bool _vdl2 = false;
  List<int> get _channels => _vdl2 ? _vdl2Channels : _acarsChannels;

  bool _started = false;
  bool _failed = false;
  String? _sourceWarning;
  final List<AcarsMessage> _messages = [];
  final Map<int, int> _count = {};
  final Map<int, DateTime> _lastAt = {};
  int _gainIndex = -1;
  double? _gainDb;

  // Reception indicator (see ReceptionStatus); channel levels in
  // [_channels] order.
  RxStatus? _status;

  static const _gainKey = 'acars';

  /// The channel's level, and whether a carrier stands out (8 dB above
  /// the quietest channel - someone is sending there).
  (double?, bool) _level(int hz) {
    final levels = _status?.channelLevelsDb ?? const [];
    final i = _channels.indexOf(hz);
    if (i < 0 || i >= levels.length) return (null, false);
    final quietest = levels.reduce((a, b) => a < b ? a : b);
    return (levels[i], levels[i] > quietest + 8);
  }

  @override
  void initState() {
    super.initState();
    _rx = ref.read(dabRtlSdrServiceProvider);
    _settings = ref.read(settingsRepositoryProvider);
    _sub = _rx.events.listen(_onEvent);
    _start();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    _rx.acarsStop();
    super.dispose();
  }

  Future<void> _start() async {
    _gainIndex = await _settings.getNbGain(_gainKey);
    _vdl2 = await _settings.getNbVariant(_gainKey) == 'vdl2';
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    await _tune();
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _tune() async {
    final ok = await _rx.acarsStart(centerHz: _vdl2 ? _vdl2CenterHz : _acarsCenterHz, channelsHz: _channels);
    if (ok) _gainDb = await _rx.nbSetGain(_gainIndex);
    if (!mounted) return;
    setState(() {
      _started = ok;
      _failed = !ok;
    });
  }

  /// Classic ACARS or VDL2: the other window; the messages so far stay.
  Future<void> _setVdl2(bool on) async {
    if (on == _vdl2) return;
    setState(() {
      _vdl2 = on;
      _started = false;
      _status = null;
    });
    await _settings.setNbVariant(_gainKey, on ? 'vdl2' : 'acars');
    await _tune();
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
    if (!mounted) return;
    switch (event['type']) {
      case 'rxStatus':
        setState(() {
          _status = RxStatus.fromEvent(event);
          if (_gainIndex < 0) _gainDb = _status!.gainDb;
        });
      case 'acarsFrame':
        final freq = event['freqHz'] as int? ?? 0;
        final bytes = acarsFrameFromEvent(event);
        final m = bytes == null ? null : parseAcars(bytes, freqHz: freq);
        if (m == null) return;
        setState(() {
          _messages.insert(0, m);
          if (_messages.length > 300) _messages.removeLast();
          _count.update(freq, (v) => v + 1, ifAbsent: () => 1);
          _lastAt[freq] = m.receivedAt;
        });
      case 'connectionMessage':
        final isError = event['isError'] as bool? ?? false;
        final message = (event['message'] as String?)?.trim() ?? '';
        setState(() => _sourceWarning = isError && message.isNotEmpty ? message : null);
    }
  }

  bool _recent(int hz) {
    final t = _lastAt[hz];
    return t != null && DateTime.now().difference(t) < const Duration(seconds: 10);
  }

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: Colors.white70);
    String db(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
    return Scaffold(
      appBar: AppBar(title: const Text('ACARS (Textmeldungen von Flugzeugen)')),
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
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('VDL2 · 136,9 MHz'),
                      selected: _vdl2,
                      onSelected: (_) => _setVdl2(true),
                    ),
                    ChoiceChip(
                      label: const Text('ACARS klassisch · 131 MHz'),
                      selected: !_vdl2,
                      onSelected: (_) => _setVdl2(false),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(_started ? '${_messages.length} Meldungen' : 'Starte Empfänger…',
                        style: Theme.of(context).textTheme.titleMedium),
                    // All channels at once: per channel how much came in.
                    for (final hz in _channels)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 10, color: _recent(hz) ? Colors.greenAccent : Colors.white24),
                          const SizedBox(width: 6),
                          Text('${formatMhz(hz)} · ${_count[hz] ?? 0}', style: muted),
                          const SizedBox(width: 6),
                          ChannelLevel(levelDb: _level(hz).$1, active: _level(hz).$2),
                        ],
                      ),
                    const SizedBox(width: 8),
                    const Text('Verstärkung', style: muted),
                    IconButton(
                      autofocus: true,
                      onPressed: () => _stepGain(-1),
                      icon: const Icon(Icons.remove),
                    ),
                    Text(_gainIndex < 0 ? 'Auto${_gainDb == null ? '' : ' (${db(_gainDb!)} dB)'}' : '${db(_gainDb ?? 0)} dB'),
                    IconButton(onPressed: () => _stepGain(1), icon: const Icon(Icons.add)),
                  ],
                ),
                const SizedBox(height: 8),
                ReceptionStatus(
                  status: _status,
                  expectedRate: _vdl2 ? 1050000 : 1152000,
                  lastSignal: _messages.isEmpty ? null : _messages.first.receivedAt,
                ),
                const SizedBox(height: 6),
                Text(
                  'Alle ${_channels.length} Kanäle werden gleichzeitig dekodiert. Punkt grün = Meldung in den '
                  'letzten 10 s, Balken grün = auf dem Kanal wird gerade gesendet.'
                  '${_vdl2 ? ' VDL2 ist digital: Bodenstationen und Flugzeuge senden kurze Datenpakete, '
                            'Textmeldungen (ACARS) sind ein Teil davon.' : ''}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 16),
                if (_started && _messages.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Warte auf Meldungen… Bei Flugverkehr in der Nähe kommen meist mehrere pro Minute.\n'
                      'Antenne für ${_vdl2 ? '137 MHz: senkrecht, ~55 cm' : '131 MHz: senkrecht, ~57 cm'} '
                      '(Viertelwelle) - möglichst frei, am Fenster.'
                      '${_vdl2 ? '' : '\nIn Europa senden die meisten Flugzeuge inzwischen über VDL2 - kommt hier '
                                'nichts, oben auf VDL2 umschalten.'}',
                      style: const TextStyle(color: Colors.white54, fontSize: 16),
                    ),
                  ),
                if (_messages.isNotEmpty) const _Header(),
                for (final m in _messages) _MessageTile(message: m),
              ],
            ),
    );
  }
}

const _wTime = 80.0, _wFlight = 100.0, _wReg = 100.0, _wLabel = 210.0;

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    const s = TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600);
    return const Padding(
      padding: EdgeInsets.fromLTRB(15, 0, 15, 6),
      child: Row(
        children: [
          SizedBox(width: _wTime, child: Text('Zeit', style: s)),
          SizedBox(width: _wFlight, child: Text('Flug', style: s)),
          SizedBox(width: _wReg, child: Text('Kennzeichen', style: s)),
          SizedBox(width: _wLabel, child: Text('Art', style: s)),
          Expanded(child: Text('Text', style: s)),
        ],
      ),
    );
  }
}

class _MessageTile extends StatefulWidget {
  final AcarsMessage message;

  const _MessageTile({required this.message});

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> {
  bool _focused = false;

  String get _time {
    final t = widget.message.receivedAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  void _details() {
    final m = widget.message;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${m.flight ?? m.registration} · ${m.labelName}'),
        content: SizedBox(
          width: 680,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Empfangen $_time auf ${formatMhz(m.freqHz)} MHz'),
              Text('Richtung: ${m.downlink ? 'vom Flugzeug' : 'zum Flugzeug'}'),
              Text('Kennzeichen: ${m.registration}${m.flight != null ? ' · Flug ${m.flight}' : ''}'),
              Text('Label: ${m.label.replaceAll('\x7f', '␡')} · Block ${m.blockId}'
                  '${m.messageNo != null ? ' · Nr. ${m.messageNo}' : ''}${m.more ? ' · Fortsetzung folgt' : ''}'),
              const SizedBox(height: 12),
              SelectableText(
                m.text.isEmpty ? '(kein Text)' : m.text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Schließen')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    const dim = TextStyle(color: Colors.white70);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TvFocusHighlight(
        focused: _focused,
        borderRadius: BorderRadius.circular(8),
        child: Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            focusColor: Colors.transparent,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: _details,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: _wTime, child: Text(_time, style: const TextStyle(color: Colors.white54))),
                  SizedBox(
                    width: _wFlight,
                    child: Text(m.flight ?? '—', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  SizedBox(width: _wReg, child: Text(m.registration, style: dim)),
                  SizedBox(
                    width: _wLabel,
                    child: Text('${m.downlink ? '↑' : '↓'} ${m.labelName}', style: dim),
                  ),
                  Expanded(
                    child: Text(
                      m.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
