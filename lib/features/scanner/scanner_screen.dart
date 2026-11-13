import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/aprs.dart';
import '../../data/models/band_plan.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;
import '../../core/popup_text_field.dart' show showTextInputDialog;
import '../shared/logo_picker_dialog.dart' show connectDecoder;
import 'waterfall_view.dart';

/// Just listening in on a band (CB radio, airband, amateur radio, a free
/// range) - full screen and separate from everyday radio: no stations, no
/// favorites. Shows every channel within the receiver's window, green while
/// something is on air, with modulation (auto-detected or fixed), squelch,
/// tuner gain, a scan that stops on activity, and a selectable bandwidth
/// (the sample rate - over rtl_tcp it decides how much the network has to
/// carry).
///
/// "Bandplan": tuning into another part of the band (e.g. from the SSB part
/// of 2 m into the FM repeaters) switches modulation and filter width to
/// what's used there, as listed in [BandPlan.segments].
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
  String? _sourceWarning; // 'connectionMessage' of the receiver's source
  bool _scanning = false;

  /// Follow the band plan (see [ScannerScreen]).
  bool _bandPlanAuto = true;

  /// Fine tuning off the channel (SSB/CW), in Hz.
  int _fineHz = 0;

  /// Tuner gain step, -1 = automatic; [_gainDb] is the gain in effect.
  int _gainIndex = -1;
  double? _gainDb;

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
  BandSegment? get _segment => _plan.segmentAt(_channel.freqHz);
  int get _tunedHz => _channel.freqHz + _fineHz;

  /// CW is USB with a narrow filter for the receiver.
  static String _nativeMode(String mode) => mode == 'cw' ? 'usb' : mode;
  bool get _fineTunable => _mode == 'usb' || _mode == 'lsb' || _mode == 'cw';

  @override
  void initState() {
    super.initState();
    _rx = ref.read(dabRtlSdrServiceProvider);
    _settings = ref.read(settingsRepositoryProvider);
    _stepOverride = ref.read(remoteStepOverrideProvider.notifier);
    _sub = _rx.events.listen(_onEvent);
    FocusManager.instance.addListener(_recoverFocus);
    // Not during build: providers can't change while the tree builds.
    Future.microtask(() => _stepOverride.set(_stepActive));
    _start();
  }

  late final RemoteStepOverride _stepOverride;

  @override
  void dispose() {
    FocusManager.instance.removeListener(_recoverFocus);
    _screenFocus.dispose();
    _waterfallFocus.dispose();
    Future.microtask(() => _stepOverride.set(null));
    if (_decoderSent ?? false) _rx.nbSetPacketDecoder(DabRtlSdrService.packetOff);
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
  final _screenFocus = FocusNode(debugLabel: 'scanner');
  final _waterfallFocus = FocusNode(debugLabel: 'waterfall');

  /// The focused control can vanish under the remote - a range button greys
  /// out at the band edge, a channel button leaves when the window moves.
  /// Focus then falls back to the page itself and the arrow keys find
  /// nothing; put it on the waterfall instead.
  void _recoverFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary == _screenFocus || primary == _screenFocus.enclosingScope) {
        if (ModalRoute.of(context)?.isCurrent ?? false) _waterfallFocus.requestFocus();
      }
    });
  }

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

  /// Auto modulation was picked (CB): the band plan keeps it wherever AM or
  /// FM is used - the receiver tells those apart itself - and only sets SSB
  /// parts to their sideband, back to Auto outside them.
  bool _preferAuto = false;

  /// The band plan's modulation and filter width for [segment] - only when
  /// [_bandPlanAuto] is on and the band offers that modulation.
  void _takeSegmentSettings(BandSegment? segment) {
    if (!_bandPlanAuto || segment == null || !_plan.modes.contains(segment.mode)) return;
    final autoFits = _preferAuto && _plan.modes.contains('auto') && (segment.mode == 'am' || segment.mode == 'fm');
    _mode = autoFits ? 'auto' : segment.mode;
    // Auto picks the width per detected modulation.
    _bandwidthHz = autoFits ? 0 : segment.bandwidthHz;
    _detectedMode = null;
  }

  Future<void> _start() async {
    _sampleRate = await _settings.getNbSampleRate();
    _bandPlanAuto = await _settings.getNbBandPlanAuto();
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
    // A band's usual start (e.g. 2 m on the FM calling channel).
    if (_plan.defaultFreqHz case final hz?) {
      final i = _plan.channels.indexWhere((c) => c.freqHz == hz);
      if (i >= 0) _index = i;
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
    _preferAuto = _mode == 'auto';
    // Without a plan entry the remembered or first modulation stays.
    _takeSegmentSettings(_segment);
    if (!_plan.modes.contains(_mode)) _mode = _plan.modes.first;
    _fineHz = 0;
    _gainIndex = await _settings.getNbGain(_plan.id);
    _homeLat = await _settings.getWeatherLat();
    _homeLon = await _settings.getWeatherLon();
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
      freqHz: _tunedHz,
      mode: _nativeMode(_mode),
      squelchDb: _squelchDb,
    );
    if (mounted) {
      setState(() {
        _started = ok;
        _failed = !ok;
      });
    }
    if (ok) {
      await _applyFilters();
      final db = await _rx.nbSetGain(_gainIndex);
      if (mounted && _gainIndex >= 0) setState(() => _gainDb = db);
      _decoderSent = null; // a new start: send the decoder state again
      await _syncDecoder();
    }
  }

  // --- APRS packet decoder ---

  /// The user's choice for the packet decoder; null = automatic (on at
  /// the APRS frequencies, see aprsFrequenciesHz).
  bool? _aprsChoice;
  bool? _decoderSent;
  final List<AprsPacket> _packets = [];
  double _homeLat = SettingsRepository.defaultLat, _homeLon = SettingsRepository.defaultLon;

  bool get _fmLike => _mode == 'fm' || _mode == 'auto';
  bool get _decoderOn => _fmLike && (_aprsChoice ?? aprsFrequenciesHz.contains(_tunedHz));

  /// Tells the receiver whether to decode packets - after every tune or
  /// modulation change.
  Future<void> _syncDecoder() async {
    final on = _decoderOn;
    if (on == _decoderSent) return;
    _decoderSent = on;
    await _rx.nbSetPacketDecoder(on ? DabRtlSdrService.packetAprs : DabRtlSdrService.packetOff);
  }

  void _onPacket(Map<String, dynamic> event) {
    if ((event['kind'] as int? ?? DabRtlSdrService.packetAprs) != DabRtlSdrService.packetAprs) return;
    final bytes = aprsFrameFromEvent(event);
    if (bytes == null) return;
    final packet = parseAx25(bytes);
    if (packet == null) return;
    setState(() {
      _packets.insert(0, packet);
      if (_packets.length > 200) _packets.removeLast();
    });
  }

  /// Modulations whose filter widths are of the same order: CW, SSB,
  /// wideband FM, the rest.
  String get _widthFamily => switch (_mode) {
    'cw' => 'cw',
    'usb' || 'lsb' => 'ssb',
    'wfm' => 'wfm',
    _ => 'narrow',
  };

  /// Filter widths offered for the current modulation (0 = automatic).
  List<int> get _bandwidthChoices => switch (_widthFamily) {
    'cw' => const [0, 1000, 1500, 1800],
    'ssb' => const [0, 1800, 2400, 2700, 3000],
    'wfm' => const [0, 50000, 100000, 150000, 200000],
    _ => const [0, 6000, 8000, 8330, 10000, 12500],
  };

  /// The filter width in effect (for the waterfall's shading).
  int get _effectiveBandwidthHz {
    if (_bandwidthHz > 0) return _bandwidthHz;
    return switch (_mode == 'auto' ? (_detectedMode ?? 'fm') : _mode) {
      'cw' => 1000,
      'usb' || 'lsb' => 2700,
      'am' => 9500,
      'wfm' => 100000,
      _ => 10500,
    };
  }

  // CW: the narrowest the receiver has (passband 300-1300 Hz above the
  // tuned frequency).
  Future<void> _applyFilters() => _rx.nbSetFilters(
    bandwidthHz: _mode == 'cw' && _bandwidthHz == 0 ? 1000 : _bandwidthHz,
    noiseBlanker: _noiseBlanker,
    voiceFilter: _voiceFilter,
    agc: _agc,
  );

  Future<void> _setFilters({int? bandwidthHz, bool? noiseBlanker, bool? voiceFilter, String? agc}) async {
    setState(() {
      _bandwidthHz = bandwidthHz ?? _bandwidthHz;
      _noiseBlanker = noiseBlanker ?? _noiseBlanker;
      _voiceFilter = voiceFilter ?? _voiceFilter;
      _agc = agc ?? _agc;
    });
    await _saveFilters();
    await _applyFilters();
  }

  Future<void> _saveFilters() => _settings.setNbFilters(
    _plan.id,
    bandwidthHz: _bandwidthHz,
    noiseBlanker: _noiseBlanker,
    voiceFilter: _voiceFilter,
    agc: _agc,
  );

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
          _spectrum = [for (final v in event['binsDb'] as List) (v as num).toDouble()];
          _spectrumCenterHz = event['centerHz'] as int;
          _spectrumSpanHz = event['spanHz'] as int;
          _gainDb = (event['gainDb'] as num?)?.toDouble() ?? _gainDb;
        });
      case 'nbPacket':
        _onPacket(event);
      case 'connectionMessage':
        final isError = event['isError'] as bool? ?? false;
        final message = (event['message'] as String?)?.trim() ?? '';
        setState(() => _sourceWarning = isError && message.isNotEmpty ? message : null);
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
    await _rx.nbTune(freqHz: _tunedHz, mode: _nativeMode(_mode));
    await _syncDecoder();
    _remember();
  }

  /// Tunes channel [index], [fineHz] off it. Entering another part of the
  /// band takes over its settings (see [_takeSegmentSettings]).
  Future<void> _select(int index, {int fineHz = 0}) async {
    final oldSegment = _segment;
    final oldMode = _mode, oldWidth = _bandwidthHz;
    setState(() {
      _index = index.clamp(0, _plan.channels.length - 1);
      _fineHz = fineHz;
      _detectedMode = null;
      if (_segment != oldSegment) _takeSegmentSettings(_segment);
    });
    _lastTuneAt = DateTime.now();
    final freq = _channel.freqHz;
    if (!_inWindow(freq)) {
      setState(() => _placeWindow(freq));
      await _rx.nbSetChannels(centerHz: _centerHz, channelsHz: [for (final c in _window) c.freqHz]);
    }
    await _rx.nbTune(freqHz: _tunedHz, mode: _nativeMode(_mode));
    await _syncDecoder();
    if (_mode != oldMode || _bandwidthHz != oldWidth) {
      await _saveFilters();
      await _applyFilters();
    }
    _remember();
  }

  /// Free band scan: tunes [hz] - the nearest channel, the rest as fine
  /// offset (so e.g. 174,928 MHz is exact on a 100 kHz raster).
  Future<void> _jumpTo(int hz) async {
    final ch = _plan.channels;
    var lo = 0, hi = ch.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (ch[mid].freqHz < hz) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var i = lo;
    if (i > 0 && (ch[i - 1].freqHz - hz).abs() < (ch[i].freqHz - hz).abs()) i--;
    final fine = (hz - ch[i].freqHz).clamp(-25000, 25000);
    await _select(i, fineHz: fine);
  }

  /// "Springen zu…": the plan's jump targets, pickable with the remote.
  Future<void> _pickJump() async {
    final hz = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Springen zu…'),
        children: [
          for (final (i, (name, hz)) in _plan.jumpTargets.indexed)
            ListTile(
              autofocus: i == 0,
              onTap: () => Navigator.of(context).pop(hz),
              title: Text(name),
              trailing: Text('${formatMhzAuto(hz)} MHz', style: const TextStyle(color: Colors.white54)),
            ),
        ],
      ),
    );
    if (hz != null) await _jumpTo(hz);
  }

  /// "Frequenz…": any frequency in MHz within the stick's range.
  Future<void> _enterFrequency() async {
    final text = await showTextInputDialog(
      context,
      title: 'Frequenz (MHz)',
      initialValue: formatMhzAuto(_tunedHz),
      hint: 'z. B. 145,500',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    final mhz = double.tryParse(text?.trim().replaceAll(',', '.') ?? '');
    if (mhz == null) return;
    final hz = (mhz * 1e6).round();
    if (hz < _plan.lowHz || hz > _plan.highHz) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Der Stick empfängt ${formatMhz(_plan.lowHz, decimals: 0)}–${formatMhz(_plan.highHz, decimals: 0)} MHz.')),
        );
      }
      return;
    }
    await _jumpTo(hz);
  }

  /// SSB/CW: in 100 Hz steps around the channel.
  Future<void> _fineTune(int deltaHz) async {
    setState(() => _fineHz = (_fineHz + deltaHz).clamp(-25000, 25000));
    await _rx.nbTune(freqHz: _tunedHz, mode: _nativeMode(_mode));
    await _syncDecoder();
  }

  // The Auto preference is kept even while an SSB part uses its sideband.
  void _remember() => _settings.setNbLast(
    _plan.id,
    freqHz: _channel.freqHz,
    mode: _preferAuto ? 'auto' : _mode,
    squelchDb: _squelchDb,
  );

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
    final family = _widthFamily;
    setState(() {
      _mode = mode;
      _preferAuto = mode == 'auto';
      _detectedMode = null;
      if (!_fineTunable) _fineHz = 0;
    });
    await _rx.nbTune(freqHz: _tunedHz, mode: _nativeMode(mode));
    await _syncDecoder();
    // CW, SSB, AM/FM and wideband FM widths differ by orders of magnitude -
    // back to auto.
    if (family != _widthFamily && _bandwidthHz != 0) {
      await _setFilters(bandwidthHz: 0);
    } else {
      await _applyFilters();
    }
    _remember();
  }

  Future<void> _setBandPlanAuto(bool on) async {
    setState(() => _bandPlanAuto = on);
    await _settings.setNbBandPlanAuto(on);
    if (!on) return;
    final oldMode = _mode;
    setState(() => _takeSegmentSettings(_segment));
    if (_mode != oldMode) await _rx.nbTune(freqHz: _tunedHz, mode: _nativeMode(_mode));
    await _syncDecoder();
    await _saveFilters();
    await _applyFilters();
    _remember();
  }

  Future<void> _setSquelch(double db) async {
    setState(() => _squelchDb = db.clamp(0, 40));
    await _rx.nbSetSquelch(_squelchDb);
    _remember();
  }

  /// One gain step up/down; below the lowest step is "Auto".
  Future<void> _stepGain(int delta) async {
    final next = (_gainIndex + delta).clamp(-1, DabRtlSdrService.nbGainSteps - 1);
    if (next == _gainIndex) return;
    setState(() => _gainIndex = next);
    await _settings.setNbGain(_plan.id, next);
    final db = await _rx.nbSetGain(next);
    if (mounted) setState(() => _gainDb = db);
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

  static Color _modeColour(String mode) => switch (mode) {
    'cw' => const Color(0xFF9B59B6),
    'usb' || 'lsb' => const Color(0xFF2E86DE),
    'am' => const Color(0xFFE67E22),
    'wfm' => const Color(0xFF16A085),
    _ => const Color(0xFF27AE60),
  };

  // The band plan for the waterfall, built once per plan.
  BandPlan? _segmentsFor;
  List<WaterfallSegment> _waterfallSegments = const [];

  List<WaterfallSegment> get _segmentsOfPlan {
    if (!identical(_segmentsFor, _plan)) {
      _segmentsFor = _plan;
      // Unnamed parts (the free scan's gaps between bands) aren't drawn.
      _waterfallSegments = _plan.segments.length < 2
          ? const []
          : [
              for (final s in _plan.segments)
                if (s.name.isNotEmpty) (lowHz: s.lowHz, highHz: s.highHz, name: s.name, color: _modeColour(s.mode)),
            ];
    }
    return _waterfallSegments;
  }

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    final segment = _segment;
    final signal = ((_snrDb ?? 0) / 40).clamp(0.0, 1.0);
    final signalColor = _snrDb == null
        ? Colors.white24
        : (_snrDb! >= 20 ? Colors.greenAccent : (_snrDb! >= 10 ? Colors.amberAccent : Colors.redAccent));
    // Empty until _start() placed the window.
    final pagesWindow = _window.isNotEmpty && _window.length < _plan.channels.length;
    const muted = TextStyle(color: Colors.white70);
    return Focus(
      focusNode: _screenFocus,
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
                  // The receiver's source has a problem (rtl_tcp gone, with
                  // rtl_tcp Jay extended e.g. the server's stick not ready,
                  // server busy).
                  if (_sourceWarning case final warning?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber, color: Colors.orangeAccent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(warning, style: const TextStyle(color: Colors.orangeAccent, fontSize: 16)),
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
                            '${_fineHz == 0 ? formatMhzAuto(_tunedHz) : formatMhz(_tunedHz, decimals: 4)} MHz · '
                            '${modeLabel(_mode)}'
                            '${_mode == 'auto' && _detectedMode != null ? ' → ${modeLabel(_detectedMode!)}' : ''}'
                            '${segment != null && segment.name.isNotEmpty && _plan.segments.length > 1 ? ' · ${segment.name}' : ''}',
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
                      if (_plan.isFree) ...[
                        OutlinedButton.icon(
                          onPressed: _pickJump,
                          icon: const Icon(Icons.bookmarks_outlined),
                          label: const Text('Springen zu…'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _enterFrequency,
                          icon: const Icon(Icons.dialpad),
                          label: const Text('Frequenz…'),
                        ),
                      ],
                      if (_fineTunable) ...[
                        const Text('Fein', style: muted),
                        IconButton(
                          tooltip: '−100 Hz',
                          onPressed: () => _fineTune(-100),
                          icon: const Icon(Icons.remove),
                        ),
                        Text('${_fineHz >= 0 ? '+' : ''}$_fineHz Hz'),
                        IconButton(tooltip: '+100 Hz', onPressed: () => _fineTune(100), icon: const Icon(Icons.add)),
                      ],
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
                      if (_fmLike)
                        Tooltip(
                          message: 'APRS-Pakete (1200 Baud) dekodieren - auf 144,800 und 145,825 automatisch',
                          child: FilterChip(
                            label: const Text('APRS'),
                            selected: _decoderOn,
                            onSelected: (v) async {
                              setState(() => _aprsChoice = v);
                              await _syncDecoder();
                            },
                          ),
                        ),
                      if (_plan.segments.length > 1)
                        Tooltip(
                          message: 'Modulation und Filter passend zum Bereich des Bandplans',
                          child: FilterChip(
                            label: const Text('Bandplan'),
                            selected: _bandPlanAuto,
                            onSelected: _setBandPlanAuto,
                          ),
                        ),
                      const SizedBox(width: 8),
                      const Text('Rauschsperre', style: muted),
                      IconButton(onPressed: () => _setSquelch(_squelchDb - 2), icon: const Icon(Icons.remove)),
                      Text('${_squelchDb.round()} dB'),
                      IconButton(onPressed: () => _setSquelch(_squelchDb + 2), icon: const Icon(Icons.add)),
                      const SizedBox(width: 8),
                      const Text('Verstärkung', style: muted),
                      IconButton(onPressed: () => _stepGain(-1), icon: const Icon(Icons.remove)),
                      Text(
                        _gainIndex < 0
                            ? 'Auto${_gainDb == null ? '' : ' (${_gainDb!.toStringAsFixed(1).replaceAll('.', ',')} dB)'}'
                            : '${(_gainDb ?? 0).toStringAsFixed(1).replaceAll('.', ',')} dB',
                      ),
                      IconButton(onPressed: () => _stepGain(1), icon: const Icon(Icons.add)),
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
                  // Spectrum + waterfall of the window; a tap tunes the
                  // nearest channel (SSB/CW: right where tapped).
                  _StepFocus(
                    focusNode: _waterfallFocus,
                    onStep: (direction) => _select(_index + direction),
                    child: WaterfallView(
                      bins: _spectrum,
                      centerHz: _spectrumCenterHz,
                      spanHz: _spectrumSpanHz,
                      markHz: _tunedHz,
                      segments: _segmentsOfPlan,
                      bandwidthHz: _effectiveBandwidthHz,
                      upperSideband: _mode == 'usb' || _mode == 'cw',
                      lowerSideband: _mode == 'lsb',
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
                        final index = _plan.channels.indexOf(nearest);
                        if (!_fineTunable) {
                          _select(index);
                          return;
                        }
                        // The segment's settings first, then right where tapped.
                        final fine = ((hz - nearest.freqHz) / 100).round() * 100;
                        _select(index, fineHz: fine.clamp(-25000, 25000));
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  // APRS: what the packet decoder received, newest first.
                  if (_decoderOn || _packets.isNotEmpty) ...[
                    _AprsHeader(
                      count: _packets.length,
                      decoding: _decoderOn,
                      onClear: _packets.isEmpty ? null : () => setState(_packets.clear),
                    ),
                    for (final p in _packets.take(50))
                      _AprsTile(packet: p, homeLat: _homeLat, homeLon: _homeLon),
                    const SizedBox(height: 12),
                  ],
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
                          label: _plan.id == 'cb' || c.name == null ? c.label : c.name!,
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
  final FocusNode focusNode;

  const _StepFocus({required this.child, required this.onStep, required this.focusNode});

  @override
  State<_StepFocus> createState() => _StepFocusState();
}

class _StepFocusState extends State<_StepFocus> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
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

/// "APRS · 12 Pakete" above the packet list, with a button to clear it.
class _AprsHeader extends StatelessWidget {
  final int count;
  final bool decoding;
  final VoidCallback? onClear;

  const _AprsHeader({required this.count, required this.decoding, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.location_on, color: decoding ? Colors.greenAccent : Colors.white38),
          const SizedBox(width: 8),
          Text(
            'APRS · $count ${count == 1 ? 'Paket' : 'Pakete'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              decoding
                  ? (count == 0 ? 'Dekoder läuft - warte auf Pakete…' : 'Dekoder läuft')
                  : 'Dekoder aus',
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          if (onClear != null)
            TextButton.icon(onPressed: onClear, icon: const Icon(Icons.delete_outline), label: const Text('Leeren')),
        ],
      ),
    );
  }
}

/// One received APRS packet: sender, what it is, where (distance and
/// direction from the home location), and its text. OK shows the details.
class _AprsTile extends StatelessWidget {
  final AprsPacket packet;
  final double homeLat;
  final double homeLon;

  const _AprsTile({required this.packet, required this.homeLat, required this.homeLon});

  String get _time {
    final t = packet.receivedAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String? get _where {
    final km = packet.distanceKm(homeLat, homeLon);
    if (km == null) return null;
    final d = km < 10 ? km.toStringAsFixed(1).replaceAll('.', ',') : km.round().toString();
    return '$d km ${packet.bearingFrom(homeLat, homeLon)}';
  }

  String get _text {
    final p = packet;
    return [
      if (p.name != null) p.kind == 'Nachricht' ? 'an ${p.name}' : p.name!,
      if (p.weather != null) p.weather!.describe(),
      if (p.speedKmh != null) '${p.speedKmh!.round()} km/h${p.course != null ? ' · ${p.course}°' : ''}',
      if (p.comment != null) p.comment!,
    ].join(' · ');
  }

  void _details(BuildContext context) {
    final p = packet;
    String coord(double v, String pos, String neg) =>
        '${v.abs().toStringAsFixed(5).replaceAll('.', ',')}° ${v >= 0 ? pos : neg}';
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${p.source} · ${p.kind}'),
        content: SizedBox(
          width: 640,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Empfangen $_time'),
              if (p.symbolName != null) Text('Symbol: ${p.symbolName}'),
              if (p.hasPosition) Text('Position: ${coord(p.lat!, 'N', 'S')}, ${coord(p.lon!, 'O', 'W')}'),
              if (_where != null) Text('Entfernung: $_where'),
              if (_text.isNotEmpty) Text(_text),
              Text('Weg: ${p.path.isEmpty ? 'direkt' : p.path.join(', ')}'),
              const SizedBox(height: 12),
              const Text('Rohdaten', style: TextStyle(color: Colors.white54)),
              SelectableText(p.tnc2, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
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
    final where = _where;
    final text = _text;
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => _details(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 70, child: Text(_time, style: const TextStyle(color: Colors.white54))),
              SizedBox(
                width: 130,
                child: Text(packet.source, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              SizedBox(
                width: 150,
                child: Text(
                  packet.symbolName != null && packet.hasPosition ? packet.symbolName! : packet.kind,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              SizedBox(width: 110, child: Text(where ?? '', style: const TextStyle(color: Colors.greenAccent))),
              Expanded(
                child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
