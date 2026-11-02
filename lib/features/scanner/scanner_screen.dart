import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/band_plan.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;
import '../shared/logo_picker_dialog.dart' show connectDecoder;
import 'waterfall_view.dart';

/// Just listening in on a band (CB radio, airband) - full screen and
/// separate from everyday radio: no stations, no favorites. Shows every
/// channel within the receiver's window, green while something is on air,
/// with modulation (auto-detected or fixed), squelch, a scan that stops on
/// activity, and a selectable bandwidth (the sample rate - over rtl_tcp it
/// decides how much the network has to carry).
class ScannerScreen extends ConsumerStatefulWidget {
  final BandPlan plan;

  /// Several bands on one screen (amateur radio: 10 m, 2 m, ...) - switched
  /// with chips, the last one is remembered. [plan] is the first.
  final List<BandPlan>? variants;

  const ScannerScreen({super.key, required this.plan, this.variants});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  // Kept from the start: ref can't be used safely in dispose().
  late final DabRtlSdrService _rx;
  late final SettingsRepository _settings;
  StreamSubscription<Map<String, dynamic>>? _sub;

  // CB: 1-40 or 1-80 channels (settings), else the band as given.
  late BandPlan _plan = widget.plan;
  bool _cbAll80 = false;
  bool _variantLoaded = false;

  int _sampleRate = SettingsRepository.defaultNbSampleRate;
  late int _index = _plan.channels.length ~/ 2;
  late String _mode = _plan.modes.first;
  double _squelchDb = 10;
  bool _started = false;
  bool _failed = false;
  bool _scanning = false;

  // The window: its centre and the channels inside it.
  int _centerHz = 0;
  List<BandChannel> _window = const [];

  // Live from the receiver.
  final Map<int, double?> _levels = {};
  double _noiseDb = -100;
  double? _levelDb;
  double? _snrDb;
  bool _squelchOpen = false;
  String? _detectedMode;
  List<double> _spectrum = const [];
  int _spectrumCenterHz = 0;
  int _spectrumSpanHz = 0;

  // When each channel last had a signal - shown as a green that fades
  // over [_fadeTime]: voice traffic comes and goes, this shows where.
  final Map<int, DateTime> _lastActive = {};
  static const _fadeTime = Duration(seconds: 90);

  // Signal filters (see _FilterPanel), per band.
  int _bandwidthHz = 0;
  bool _noiseBlanker = true;
  bool _voiceFilter = true;
  String _agc = 'auto';

  DateTime _lastOpenAt = DateTime.now();
  DateTime _lastTuneAt = DateTime.now();

  BandChannel get _channel => _plan.channels[_index];

  @override
  void initState() {
    super.initState();
    _rx = ref.read(dabRtlSdrServiceProvider);
    _settings = ref.read(settingsRepositoryProvider);
    _stepOverride = ref.read(remoteStepOverrideProvider.notifier);
    _sub = _rx.events.listen(_onEvent);
    // Not during build: providers can't change while the tree builds.
    Future.microtask(() => _stepOverride.set(_stepActive));
    _start();
  }

  late final RemoteStepOverride _stepOverride;

  @override
  void dispose() {
    Future.microtask(() => _stepOverride.set(null));
    _rx.nbStop();
    _sub?.cancel();
    super.dispose();
  }

  /// Next/previous (remote's track or channel keys): jumps only between
  /// channels that are green - on air now or recently (see [_heat]); with
  /// none, nothing happens. Stepping through every channel is left/right on
  /// the waterfall.
  void _stepActive(int direction) {
    final n = _plan.channels.length;
    for (var step = 1; step < n; step++) {
      final i = ((_index + direction * step) % n + n) % n;
      final c = _plan.channels[i];
      if (_inWindow(c.freqHz) && _heat(c) > 0) {
        _select(i);
        return;
      }
    }
  }

  /// The remote's channel and next/previous keys - also when they arrive as
  /// plain keys rather than through the media session (see [_stepActive]).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _stepActive(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _stepActive(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Usable part of the window: the edges of the stick's band are filtered.
  int get _usableHz => (_sampleRate * 0.8).round();

  /// Puts the window around the whole band if it fits, else around [freqHz].
  void _placeWindow(int freqHz) {
    final span = _plan.highHz - _plan.lowHz;
    if (span + 20000 <= _usableHz) {
      _centerHz = (_plan.lowHz + _plan.highHz) ~/ 2;
    } else {
      final half = _usableHz ~/ 2;
      _centerHz = freqHz.clamp(_plan.lowHz + half, _plan.highHz - half);
    }
    final half = _usableHz ~/ 2;
    _window = [
      for (final c in _plan.channels)
        if ((c.freqHz - _centerHz).abs() <= half) c,
    ];
  }

  bool _inWindow(int freqHz) => (freqHz - _centerHz).abs() <= _usableHz ~/ 2;

  Future<void> _start() async {
    _sampleRate = await _settings.getNbSampleRate();
    final variants = widget.variants;
    if (variants != null && !_variantLoaded) {
      _variantLoaded = true;
      final id = await _settings.getNbVariant(widget.plan.id);
      _plan = variants.firstWhere((p) => p.id == id, orElse: () => variants.first);
      _index = _plan.channels.length ~/ 2;
      _mode = _plan.modes.first;
    }
    if (widget.plan.id == 'cb') {
      _cbAll80 = await _settings.getCbAll80();
      _plan = cbBandPlan(all80: _cbAll80);
      _index = _plan.channels.length ~/ 2;
    }
    final filters = await _settings.getNbFilters(_plan.id);
    _bandwidthHz = filters.bandwidthHz;
    _noiseBlanker = filters.noiseBlanker;
    _voiceFilter = filters.voiceFilter;
    _agc = filters.agc;
    final last = await _settings.getNbLast(_plan.id);
    if (last != null) {
      final i = _plan.channels.indexWhere((c) => c.freqHz == last.freqHz);
      if (i >= 0) _index = i;
      if (_plan.modes.contains(last.mode)) _mode = last.mode;
      _squelchDb = last.squelchDb;
    }
    _placeWindow(_channel.freqHz);
    // The home screen tunes its station in again once back.
    ref.read(receiverInterruptedProvider.notifier).set(true);
    if (!await connectDecoder(ref)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final ok = await _rx.nbStart(
      sampleRate: _sampleRate,
      centerHz: _centerHz,
      channelsHz: [for (final c in _window) c.freqHz],
      freqHz: _channel.freqHz,
      mode: _mode,
      squelchDb: _squelchDb,
    );
    if (mounted) {
      setState(() {
        _started = ok;
        _failed = !ok;
      });
    }
    if (ok) await _applyFilters();
  }

  bool get _isSsb => (_mode == 'usb' || _mode == 'lsb');

  /// Filter widths offered for the current modulation (0 = automatic).
  List<int> get _bandwidthChoices => _isSsb ? const [0, 1800, 2400, 2700, 3000] : const [0, 6000, 8330, 10000, 12500];

  Future<void> _applyFilters() =>
      _rx.nbSetFilters(bandwidthHz: _bandwidthHz, noiseBlanker: _noiseBlanker, voiceFilter: _voiceFilter, agc: _agc);

  Future<void> _setFilters({int? bandwidthHz, bool? noiseBlanker, bool? voiceFilter, String? agc}) async {
    setState(() {
      _bandwidthHz = bandwidthHz ?? _bandwidthHz;
      _noiseBlanker = noiseBlanker ?? _noiseBlanker;
      _voiceFilter = voiceFilter ?? _voiceFilter;
      _agc = agc ?? _agc;
    });
    await _settings.setNbFilters(
      _plan.id,
      bandwidthHz: _bandwidthHz,
      noiseBlanker: _noiseBlanker,
      voiceFilter: _voiceFilter,
      agc: _agc,
    );
    await _applyFilters();
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'nbStatus':
        final open = event['squelchOpen'] as bool? ?? false;
        setState(() {
          _levelDb = (event['levelDb'] as num?)?.toDouble();
          _snrDb = (event['snrDb'] as num?)?.toDouble();
          _squelchOpen = open;
          final mode = event['mode'] as String?;
          _detectedMode = mode == null || mode == 'auto' ? null : mode;
        });
        if (open) _lastOpenAt = DateTime.now();
        if (_scanning) _scanStep();
      case 'nbActivity':
        final channels = (event['channelsHz'] as List).cast<int>();
        final levels = (event['levelsDb'] as List).map((v) => (v as num?)?.toDouble()).toList();
        setState(() {
          _noiseDb = (event['noiseDb'] as num?)?.toDouble() ?? _noiseDb;
          for (var i = 0; i < channels.length && i < levels.length; i++) {
            _levels[channels[i]] = levels[i];
          }
          final now = DateTime.now();
          for (final c in _window) {
            if (_isActive(c)) _lastActive[c.freqHz] = now;
          }
        });
      case 'nbSpectrum':
        setState(() {
          _spectrum = (event['binsDb'] as List).map((v) => (v as num).toDouble()).toList();
          _spectrumCenterHz = event['centerHz'] as int;
          _spectrumSpanHz = event['spanHz'] as int;
        });
    }
  }

  /// "Something on air" - clearly above the noise, at least as far as the
  /// squelch asks for.
  bool _isActive(BandChannel c) {
    final level = _levels[c.freqHz];
    return level != null && level - _noiseDb >= (_squelchDb < 6 ? 6 : _squelchDb);
  }

  /// 1 while the channel is active, fading to 0 over [_fadeTime] after its
  /// last signal.
  double _heat(BandChannel c) {
    if (_isActive(c)) return 1;
    final last = _lastActive[c.freqHz];
    if (last == null) return 0;
    final age = DateTime.now().difference(last).inMilliseconds / _fadeTime.inMilliseconds;
    return age >= 1 ? 0 : 0.85 * (1 - age);
  }

  /// Another band of [ScannerScreen.variants]: a fresh start there.
  Future<void> _switchVariant(BandPlan plan) async {
    if (plan.id == _plan.id) return;
    await _settings.setNbVariant(widget.plan.id, plan.id);
    setState(() {
      _plan = plan;
      _index = plan.channels.length ~/ 2;
      _mode = plan.modes.first;
      _started = false;
      _levels.clear();
      _lastActive.clear();
      _spectrum = const [];
    });
    await _rx.nbStop();
    await _start();
  }

  Future<void> _setCbAll80(bool all80) async {
    final freq = _channel.freqHz;
    await _settings.setCbAll80(all80);
    setState(() {
      _cbAll80 = all80;
      _plan = cbBandPlan(all80: all80);
      final i = _plan.channels.indexWhere((c) => c.freqHz == freq);
      _index = i >= 0 ? i : _plan.channels.length ~/ 2;
      _placeWindow(_channel.freqHz);
    });
    await _rx.nbSetChannels(centerHz: _centerHz, channelsHz: [for (final c in _window) c.freqHz]);
    await _rx.nbTune(freqHz: _channel.freqHz, mode: _mode);
    _remember();
  }

  Future<void> _select(int index) async {
    setState(() {
      _index = index.clamp(0, _plan.channels.length - 1);
      _detectedMode = null;
    });
    _lastTuneAt = DateTime.now();
    final freq = _channel.freqHz;
    if (!_inWindow(freq)) {
      setState(() => _placeWindow(freq));
      await _rx.nbSetChannels(centerHz: _centerHz, channelsHz: [for (final c in _window) c.freqHz]);
    }
    await _rx.nbTune(freqHz: freq, mode: _mode);
    _remember();
  }

  void _remember() => _settings.setNbLast(_plan.id, freqHz: _channel.freqHz, mode: _mode, squelchDb: _squelchDb);

  /// Scan: stays while the squelch is open (and a moment after), then moves
  /// on to the next active channel - within the current window only; it
  /// doesn't wander off through the band (the fading marks show where
  /// there was traffic, the range buttons change the window).
  void _scanStep() {
    final now = DateTime.now();
    if (_squelchOpen ||
        now.difference(_lastOpenAt) < const Duration(milliseconds: 1500) ||
        now.difference(_lastTuneAt) < const Duration(milliseconds: 1000)) {
      return;
    }
    final n = _plan.channels.length;
    for (var step = 1; step < n; step++) {
      final i = (_index + step) % n;
      final c = _plan.channels[i];
      if (_inWindow(c.freqHz) && _isActive(c)) {
        _select(i);
        return;
      }
    }
  }

  Future<void> _setMode(String mode) async {
    final wasSsb = _isSsb;
    setState(() {
      _mode = mode;
      _detectedMode = null;
    });
    await _rx.nbTune(freqHz: _channel.freqHz, mode: mode);
    // SSB and AM/FM widths differ by an order of magnitude - back to auto.
    if (wasSsb != _isSsb && _bandwidthHz != 0) {
      await _setFilters(bandwidthHz: 0);
    } else {
      await _applyFilters();
    }
    _remember();
  }

  Future<void> _setSquelch(double db) async {
    setState(() => _squelchDb = db.clamp(0, 40));
    await _rx.nbSetSquelch(_squelchDb);
    _remember();
  }

  Future<void> _setSampleRate(int rate) async {
    await _settings.setNbSampleRate(rate);
    setState(() {
      _sampleRate = rate;
      _started = false;
      _levels.clear();
      _placeWindow(_channel.freqHz);
    });
    await _rx.nbStop();
    await _start();
  }

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    final signal = ((_snrDb ?? 0) / 40).clamp(0.0, 1.0);
    final signalColor = _snrDb == null
        ? Colors.white24
        : (_snrDb! >= 20 ? Colors.greenAccent : (_snrDb! >= 10 ? Colors.amberAccent : Colors.redAccent));
    final pagesWindow = _window.length < _plan.channels.length;
    return Focus(
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: AppBar(title: Text(_plan.title)),
        body: _failed
            ? const Center(child: Text('Empfänger konnte nicht gestartet werden.'))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (widget.variants case final variants?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (final v in variants)
                            ChoiceChip(
                              label: Text(hamBandShort(v)),
                              selected: v.id == _plan.id,
                              onSelected: (_) => _switchVariant(v),
                            ),
                        ],
                      ),
                    ),
                  // What's tuned.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        _squelchOpen ? Icons.volume_up : Icons.volume_off,
                        color: _squelchOpen ? Colors.greenAccent : Colors.white38,
                        size: 36,
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_plan.longLabel(channel), style: Theme.of(context).textTheme.headlineMedium),
                          Text(
                            '${formatMhz(channel.freqHz)} MHz · ${modeLabel(_mode)}'
                            '${_mode == 'auto' && _detectedMode != null ? ' → ${modeLabel(_detectedMode!)}' : ''}',
                            style: const TextStyle(color: Colors.white70, fontSize: 18),
                          ),
                        ],
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LinearProgressIndicator(value: _snrDb == null ? 0 : signal, color: signalColor),
                            const SizedBox(height: 4),
                            Text(
                              _snrDb == null
                                  ? (_started ? '' : 'Starte Empfänger…')
                                  : 'Signal ${_snrDb!.round()} dB über Rauschen'
                                        '${_levelDb == null ? '' : ' (${_levelDb!.round()} dB)'}',
                              style: const TextStyle(color: Colors.white54),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Controls - left/right with the remote moves between them.
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => _select(_index - 1),
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('Kanal'),
                      ),
                      FilledButton.tonalIcon(
                        autofocus: true,
                        onPressed: () => _select(_index + 1),
                        icon: const Icon(Icons.chevron_right),
                        label: const Text('Kanal'),
                      ),
                      if (widget.plan.id == 'cb')
                        for (final all80 in const [false, true])
                          ChoiceChip(
                            label: Text(all80 ? '80 Kanäle' : '40 Kanäle'),
                            selected: _cbAll80 == all80,
                            onSelected: (_) => _setCbAll80(all80),
                          ),
                      FilterChip(
                        label: const Text('Suchlauf'),
                        selected: _scanning,
                        onSelected: (v) => setState(() {
                          _scanning = v;
                          _lastTuneAt = DateTime.now();
                        }),
                      ),
                      const SizedBox(width: 8),
                      const Text('Rauschsperre', style: TextStyle(color: Colors.white70)),
                      IconButton(onPressed: () => _setSquelch(_squelchDb - 2), icon: const Icon(Icons.remove)),
                      Text('${_squelchDb.round()} dB'),
                      IconButton(onPressed: () => _setSquelch(_squelchDb + 2), icon: const Icon(Icons.add)),
                      if (_plan.modes.length > 1)
                        for (final m in _plan.modes)
                          ChoiceChip(label: Text(modeLabel(m)), selected: _mode == m, onSelected: (_) => _setMode(m)),
                      DropdownButton<int>(
                        value: _sampleRate,
                        items: [
                          for (final r in SettingsRepository.nbSampleRates)
                            DropdownMenuItem(
                              value: r,
                              // 2 bytes per sample over rtl_tcp.
                              child: Text(
                                'Bandbreite ${formatMhz(r, decimals: 2)} MHz (~${(r * 16 / 1e6).round()} Mbit/s)',
                              ),
                            ),
                        ],
                        onChanged: (r) => r == null || r == _sampleRate ? null : _setSampleRate(r),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => _FilterDialog(
                            bandwidthHz: _bandwidthHz,
                            bandwidthChoices: _bandwidthChoices,
                            noiseBlanker: _noiseBlanker,
                            voiceFilter: _voiceFilter,
                            agc: _agc,
                            onChanged: _setFilters,
                          ),
                        ),
                        icon: const Icon(Icons.tune),
                        label: const Text('Signalfilter'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Spectrum + waterfall of the window; a tap
                  // tunes the nearest channel.
                  _StepFocus(
                    onStep: (direction) => _select(_index + direction),
                    child: WaterfallView(
                      bins: _spectrum,
                      centerHz: _spectrumCenterHz,
                      spanHz: _spectrumSpanHz,
                      markHz: channel.freqHz,
                      // A band that fits into the window (CB) is shown on
                      // its own, with a little margin.
                      view: _window.length == _plan.channels.length
                          ? (lowHz: _plan.lowHz - 15000, highHz: _plan.highHz + 15000)
                          : null,
                      onTapFreq: (hz) {
                        if (_window.isEmpty) return;
                        final nearest = _window.reduce(
                          (a, b) => (a.freqHz - hz).abs() <= (b.freqHz - hz).abs() ? a : b,
                        );
                        _select(_plan.channels.indexOf(nearest));
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (pagesWindow)
                    Row(
                      children: [
                        TextButton.icon(
                          // Greyed out at the band edges.
                          onPressed: _plan.lowHz < _centerHz - _usableHz ~/ 2
                              ? () =>
                                    _select(_plan.channels.lastIndexWhere((c) => c.freqHz < _centerHz - _usableHz ~/ 2))
                              : null,
                          icon: const Icon(Icons.keyboard_double_arrow_left),
                          label: const Text('Bereich'),
                        ),
                        Expanded(
                          child: Text(
                            'Zeigt ${formatMhz(_window.first.freqHz)}–${formatMhz(_window.last.freqHz)} MHz',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _plan.highHz > _centerHz + _usableHz ~/ 2
                              ? () => _select(_plan.channels.indexWhere((c) => c.freqHz > _centerHz + _usableHz ~/ 2))
                              : null,
                          icon: const Icon(Icons.keyboard_double_arrow_right),
                          label: const Text('Bereich'),
                        ),
                      ],
                    ),
                  // Every channel in the window - green while active.
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in _window)
                        _ChannelButton(
                          label: c.label,
                          selected: c.freqHz == channel.freqHz,
                          heat: _heat(c),
                          onPressed: () => _select(_plan.channels.indexOf(c)),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// Makes [child] (the waterfall) reachable with the remote: focused it gets
/// a frame, and left/right step through the channels.
class _StepFocus extends StatefulWidget {
  final Widget child;
  final void Function(int direction) onStep;

  const _StepFocus({required this.child, required this.onStep});

  @override
  State<_StepFocus> createState() => _StepFocusState();
}

class _StepFocusState extends State<_StepFocus> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onStep(-1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onStep(1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: _focused ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 2),
        ),
        child: widget.child,
      ),
    );
  }
}

class _ChannelButton extends StatelessWidget {
  final String label;
  final bool selected;

  /// 1 = signal now, fading towards 0 after it (see _heat).
  final double heat;
  final VoidCallback onPressed;

  const _ChannelButton({required this.label, required this.selected, required this.heat, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 40,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(52, 40),
          backgroundColor: heat > 0 ? Colors.green.withValues(alpha: 0.08 + 0.5 * heat) : null,
          side: BorderSide(color: selected ? primary : Colors.white24, width: selected ? 3 : 1),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(color: Colors.white, fontWeight: selected ? FontWeight.bold : null),
        ),
      ),
    );
  }
}

/// "Signalfilter": what each does in one line, so they can be judged by
/// ear. Defaults (automatic width, blanker and voice filter on, automatic
/// AGC) suit voice radio; nothing here is needed to hear something. A dialog,
/// so the waterfall keeps its place on screen.
class _FilterDialog extends StatefulWidget {
  final int bandwidthHz;
  final List<int> bandwidthChoices;
  final bool noiseBlanker;
  final bool voiceFilter;
  final String agc;
  final Future<void> Function({int? bandwidthHz, bool? noiseBlanker, bool? voiceFilter, String? agc}) onChanged;

  const _FilterDialog({
    required this.bandwidthHz,
    required this.bandwidthChoices,
    required this.noiseBlanker,
    required this.voiceFilter,
    required this.agc,
    required this.onChanged,
  });

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  late int bandwidthHz = widget.bandwidthHz;
  late bool noiseBlanker = widget.noiseBlanker;
  late bool voiceFilter = widget.voiceFilter;
  late String agc = widget.agc;

  void onChanged({int? bandwidthHz, bool? noiseBlanker, bool? voiceFilter, String? agc}) {
    setState(() {
      this.bandwidthHz = bandwidthHz ?? this.bandwidthHz;
      this.noiseBlanker = noiseBlanker ?? this.noiseBlanker;
      this.voiceFilter = voiceFilter ?? this.voiceFilter;
      this.agc = agc ?? this.agc;
    });
    widget.onChanged(bandwidthHz: bandwidthHz, noiseBlanker: noiseBlanker, voiceFilter: voiceFilter, agc: agc);
  }

  @override
  Widget build(BuildContext context) {
    const hint = TextStyle(color: Colors.white54, fontSize: 12);
    Widget row(String title, String help, List<Widget> controls) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 260,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(help, style: hint),
              ],
            ),
          ),
          Expanded(child: Wrap(spacing: 8, runSpacing: 6, children: controls)),
        ],
      ),
    );
    String khz(int hz) =>
        hz == 0 ? 'Auto' : '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 2).replaceAll('.', ',')} kHz';
    return AlertDialog(
      title: const Text('Signalfilter'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row(
                'Filterbreite',
                'Schmaler: weniger Rauschen und Nachbarkanäle. Breiter: verständlicher, wenn ein Sender '
                    'etwas daneben liegt. Auto passt zur Modulation.',
                [
                  for (final bw in widget.bandwidthChoices)
                    ChoiceChip(
                      label: Text(khz(bw)),
                      selected: bandwidthHz == bw,
                      onSelected: (_) => onChanged(bandwidthHz: bw),
                    ),
                ],
              ),
              row('Störaustaster', 'Entfernt kurze Knackser von Zündfunken, Weidezäunen und Netzteilen.', [
                Switch(
                  value: noiseBlanker,
                  onChanged: (v) => onChanged(noiseBlanker: v),
                ),
              ]),
              row('Sprachfilter', 'Nur der Sprachbereich 300–3000 Hz: weniger Brummen, Rauschen und Pilottöne.', [
                Switch(
                  value: voiceFilter,
                  onChanged: (v) => onChanged(voiceFilter: v),
                ),
              ]),
              row(
                'Lautstärkeregelung',
                'Schnell für AM/FM, langsam für SSB - verhindert Pumpen zwischen den Silben. '
                    'Auto wählt passend zur Modulation.',
                [
                  for (final (value, label) in const [('auto', 'Auto'), ('fast', 'Schnell'), ('slow', 'Langsam')])
                    ChoiceChip(
                      label: Text(label),
                      selected: agc == value,
                      onSelected: (_) => onChanged(agc: value),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Schließen')),
      ],
    );
  }
}
