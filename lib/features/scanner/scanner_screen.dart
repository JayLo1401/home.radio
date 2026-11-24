import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/aprs.dart';
import '../../data/models/band_plan.dart';
import '../../data/models/dmr.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/dab_rtlsdr_service.dart' show DabRtlSdrService;
import '../../core/popup_text_field.dart' show showTextInputDialog;
import '../../l10n/l10n.dart';
import '../shared/logo_picker_dialog.dart' show connectDecoder;
import 'waterfall_view.dart';
import '../../core/native_messages.dart';

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
  final _spectrumTick = ValueNotifier<int>(0);
  int _spectrumCenterHz = 0;
  int _spectrumSpanHz = 0;

  // DMR (mode dmr, or auto having found it): slots and calls heard.
  DmrStatus? _dmr;
  String _dmrShownAs = '';
  final List<_DmrCall> _dmrCalls = [];
  bool get _dmrShown => _mode == 'dmr' || _detectedMode == 'dmr';

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

  /// Shortwave below the tuner's own range (24 MHz - CB and 10 m it tunes
  /// itself): since when nothing has come in (no signal on the channel, no
  /// activity in the window) - after [_hfHintAfter] a hint what HF needs.
  DateTime? _hfQuietSince;
  static const _hfHintBelowHz = 24000000, _hfHintAfter = Duration(seconds: 15);
  bool get _hfHint =>
      _tunedHz < _hfHintBelowHz &&
      _hfQuietSince != null &&
      DateTime.now().difference(_hfQuietSince!) >= _hfHintAfter;

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
    _spectrumTick.dispose();
    Future.microtask(() => _stepOverride.set(null));
    if (_decoderSent ?? false) _rx.nbSetPacketDecoder(DabRtlSdrService.packetOff);
    _rx.nbStop();
    _sub?.cancel();
    super.dispose();
  }

  /// Next/previous (remote's track or channel keys): jumps only between
  /// channels lit in the activity strip - on air now or recently (see
  /// [_heat]); with
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
  /// out at the band edge.
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
      _plan = variants.firstWhere((p) => p.id == id, orElse: () => widget.plan);
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
    // Shortwave through an external upconverter (applies from the next tune).
    await _rx.setUpconverter(await _settings.getHfUpconverterHz());
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

  /// A DMR status: the new picture, and each call into the list of calls
  /// heard (newest first; a call already at the top only gets its time).
  void _onDmr(Map<String, dynamic> event) {
    final status = DmrStatus.fromEvent(event);
    if (status == null) return;
    final now = DateTime.now();
    for (final s in status.slots) {
      if (!s.active || s.src == 0) continue;
      final i = _dmrCalls.indexWhere((c) => c.slot.slot == s.slot);
      if (i >= 0 && _dmrCalls[i].slot.src == s.src && _dmrCalls[i].slot.dst == s.dst) {
        _dmrCalls[i] = _DmrCall(s, now);
      } else {
        _dmrCalls.insert(0, _DmrCall(s, now));
        if (_dmrCalls.length > 20) _dmrCalls.removeLast();
      }
    }
    // Five reports a second: the page is only rebuilt when what it shows
    // changed ("vor 12 s" at most once a second).
    final shown = [
      status.sync,
      status.source,
      status.colorCode,
      status.audioSlot,
      for (final s in status.slots) ...[
        s.active,
        s.src,
        s.dst,
        s.alias,
        s.encrypted,
        s.emergency,
        s.errorRate < 0.5 ? 0 : (s.errorRate < 2 ? 1 : 2),
        s.secondsAgo.floor(),
      ],
    ].join('|');
    if (shown == _dmrShownAs && _dmr != null) return;
    _dmrShownAs = shown;
    setState(() => _dmr = status);
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
        _trackHfQuiet();
        if (_scanning) _scanStep();
      // Activity and spectrum don't rebuild the whole page (20 times a
      // second is too much for a TV box): the waterfall listens to
      // [_spectrumTick] and takes the activity strip along.
      case 'nbActivity':
        final channels = (event['channelsHz'] as List).cast<int>();
        final levels = (event['levelsDb'] as List).map((v) => (v as num?)?.toDouble()).toList();
        _noiseDb = (event['noiseDb'] as num?)?.toDouble() ?? _noiseDb;
        for (var i = 0; i < channels.length && i < levels.length; i++) {
          _levels[channels[i]] = levels[i];
        }
        final now = DateTime.now();
        for (final c in _window) {
          if (_isActive(c)) _lastActive[c.freqHz] = now;
        }
        _updateActivity();
      case 'nbSpectrum':
        _spectrum = [for (final v in event['binsDb'] as List) (v as num).toDouble()];
        _spectrumCenterHz = event['centerHz'] as int;
        _spectrumSpanHz = event['spanHz'] as int;
        _spectrumTick.value++;
        final gain = (event['gainDb'] as num?)?.toDouble();
        if (gain != null && gain != _gainDb) setState(() => _gainDb = gain);
      case 'nbPacket':
        _onPacket(event);
      case 'nbDmr':
        _onDmr(event);
      case 'connectionMessage':
        final isError = event['isError'] as bool? ?? false;
        final message = (event['message'] as String?)?.trim() ?? '';
        setState(() => _sourceWarning = isError && message.isNotEmpty ? nativeMessageText(message) : null);
    }
  }

  /// See [_hfQuietSince]: reset by a signal on the channel or anywhere in
  /// the window, and when leaving shortwave.
  void _trackHfQuiet() {
    final heard = (_snrDb ?? 0) >= 6 || _window.any(_isActive);
    if (_tunedHz >= _hfHintBelowHz || heard) {
      _hfQuietSince = null;
    } else {
      _hfQuietSince ??= DateTime.now();
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

  /// The channels with a signal now or lately, for the activity strip under
  /// the waterfall - a new list per nbActivity event; the waterfall picks it
  /// up with its next spectrum line.
  List<WaterfallActivity> _activity = const [];

  void _updateActivity() {
    _activity = [
      for (final c in _window)
        if (_heat(c) case final heat when heat > 0) (hz: c.freqHz, heat: heat),
    ];
  }

  // The window's channel frequencies for the strip's raster ticks.
  List<BandChannel>? _channelsHzFor;
  List<int> _channelsHz = const [];

  List<int> get _windowChannelsHz {
    if (!identical(_channelsHzFor, _window)) {
      _channelsHzFor = _window;
      _channelsHz = [for (final c in _window) c.freqHz];
    }
    return _channelsHz;
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
      _activity = const [];
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
      _dmr = null;
      _dmrCalls.clear();
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
        title: Text(context.l10n.scannerJumpTo),
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
      title: context.l10n.scannerFrequencyTitle,
      initialValue: formatMhzAuto(_tunedHz),
      hint: context.l10n.scannerFrequencyHint,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    final mhz = double.tryParse(text?.trim().replaceAll(',', '.') ?? '');
    if (mhz == null) return;
    final hz = (mhz * 1e6).round();
    if (hz < _plan.lowHz || hz > _plan.highHz) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.scannerOutOfRange(
                formatMhz(_plan.lowHz, decimals: _plan.lowHz < 1000000 ? 1 : 0),
                formatMhz(_plan.highHz, decimals: 0),
              ),
            ),
          ),
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
  void _remember() =>
      _settings.setNbLast(_plan.id, freqHz: _channel.freqHz, mode: _preferAuto ? 'auto' : _mode, squelchDb: _squelchDb);

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
      _dmr = null;
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
      _activity = const [];
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
    'dmr' => const Color(0xFFE84393),
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
    final l = context.l10n;
    String decimal(double v, int d) => l.localeName == 'de' ? v.toStringAsFixed(d).replaceAll('.', ',') : v.toStringAsFixed(d);
    return Focus(
      focusNode: _screenFocus,
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: AppBar(title: Text(_plan.title)),
        body: _failed
            ? Center(child: Text(l.scannerReceiverStartFailed))
            // The controls on top, the waterfall fills the rest of the screen
            // (scrolls only when there's too little room for it).
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    sliver: SliverList.list(
                      children: [
                        if (widget.variants case final variants?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Wrap(
                              spacing: 8,
                              children: [
                                for (final v in variants)
                                  ChoiceChip(
                                    label: Text(bandShortTitle(v)),
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
                                  child: Text(
                                    warning,
                                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 16),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // Shortwave and nothing comes in: what it takes.
                        if (_hfHint)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline, color: Colors.white54),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(l.scannerHfHint, style: const TextStyle(color: Colors.white54, fontSize: 15)),
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
                                        ? (_started ? '' : l.scannerReceiverStarting)
                                        : '${l.scannerSignalAboveNoise(_snrDb!.round())}'
                                              '${_levelDb == null ? '' : ' (${_levelDb!.round()} dB)'}',
                                    style: const TextStyle(color: Colors.white54),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // DMR: who is talking on which slot (display only, no focus).
                        if (_dmrShown) ...[
                          const SizedBox(height: 12),
                          _DmrPanel(status: _dmr, calls: _dmrCalls),
                        ],
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
                              label: Text(l.scannerChannelButton),
                            ),
                            FilledButton.tonalIcon(
                              autofocus: true,
                              onPressed: () => _select(_index + 1),
                              icon: const Icon(Icons.chevron_right),
                              label: Text(l.scannerChannelButton),
                            ),
                            if (_plan.isFree) ...[
                              OutlinedButton.icon(
                                onPressed: _pickJump,
                                icon: const Icon(Icons.bookmarks_outlined),
                                label: Text(l.scannerJumpTo),
                              ),
                              OutlinedButton.icon(
                                onPressed: _enterFrequency,
                                icon: const Icon(Icons.dialpad),
                                label: Text(l.scannerFrequencyButton),
                              ),
                            ],
                            if (_fineTunable) ...[
                              Text(l.scannerFine, style: muted),
                              IconButton(
                                tooltip: '−100 Hz',
                                onPressed: () => _fineTune(-100),
                                icon: const Icon(Icons.remove),
                              ),
                              Text('${_fineHz >= 0 ? '+' : ''}$_fineHz Hz'),
                              IconButton(
                                tooltip: '+100 Hz',
                                onPressed: () => _fineTune(100),
                                icon: const Icon(Icons.add),
                              ),
                            ],
                            if (widget.plan.id == 'cb')
                              for (final all80 in const [false, true])
                                ChoiceChip(
                                  label: Text(l.scannerCbChannels(all80 ? 80 : 40)),
                                  selected: _cbAll80 == all80,
                                  onSelected: (_) => _setCbAll80(all80),
                                ),
                            FilterChip(
                              label: Text(l.scannerScan),
                              selected: _scanning,
                              onSelected: (v) => setState(() {
                                _scanning = v;
                                _lastTuneAt = DateTime.now();
                              }),
                            ),
                            if (_fmLike)
                              Tooltip(
                                message: l.scannerAprsTooltip,
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
                                message: l.scannerBandPlanTooltip,
                                child: FilterChip(
                                  label: Text(l.scannerBandPlan),
                                  selected: _bandPlanAuto,
                                  onSelected: _setBandPlanAuto,
                                ),
                              ),
                            const SizedBox(width: 8),
                            Text(l.scannerSquelch, style: muted),
                            IconButton(onPressed: () => _setSquelch(_squelchDb - 2), icon: const Icon(Icons.remove)),
                            Text('${_squelchDb.round()} dB'),
                            IconButton(onPressed: () => _setSquelch(_squelchDb + 2), icon: const Icon(Icons.add)),
                            const SizedBox(width: 8),
                            Text(l.scannerGain, style: muted),
                            IconButton(onPressed: () => _stepGain(-1), icon: const Icon(Icons.remove)),
                            Text(
                              _gainIndex < 0
                                  ? 'Auto${_gainDb == null ? '' : ' (${decimal(_gainDb!, 1)} dB)'}'
                                  : '${decimal(_gainDb ?? 0, 1)} dB',
                            ),
                            IconButton(onPressed: () => _stepGain(1), icon: const Icon(Icons.add)),
                            if (_plan.modes.length > 1)
                              for (final m in _plan.modes)
                                ChoiceChip(
                                  label: Text(modeLabel(m)),
                                  selected: _mode == m,
                                  onSelected: (_) => _setMode(m),
                                ),
                            DropdownButton<int>(
                              value: _sampleRate,
                              items: [
                                for (final r in SettingsRepository.nbSampleRates)
                                  DropdownMenuItem(
                                    value: r,
                                    // 2 bytes per sample over rtl_tcp.
                                    child: Text(l.scannerSampleRate(formatMhz(r, decimals: 2), (r * 16 / 1e6).round())),
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
                              label: Text(l.scannerSignalFilters),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // A band wider than the window: move it along.
                        if (pagesWindow)
                          Row(
                            children: [
                              TextButton.icon(
                                // Greyed out at the band edges.
                                onPressed: _plan.lowHz < _centerHz - _usableHz ~/ 2
                                    ? () => _select(
                                        _plan.channels.lastIndexWhere((c) => c.freqHz < _centerHz - _usableHz ~/ 2),
                                      )
                                    : null,
                                icon: const Icon(Icons.keyboard_double_arrow_left),
                                label: Text(l.scannerRange),
                              ),
                              Expanded(
                                child: Text(
                                  l.scannerShowing(formatMhz(_window.first.freqHz), formatMhz(_window.last.freqHz)),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white54),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _plan.highHz > _centerHz + _usableHz ~/ 2
                                    ? () => _select(
                                        _plan.channels.indexWhere((c) => c.freqHz > _centerHz + _usableHz ~/ 2),
                                      )
                                    : null,
                                icon: const Icon(Icons.keyboard_double_arrow_right),
                                label: Text(l.scannerRange),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: _MinHeight(
                        minHeight: _decoderOn || _packets.isNotEmpty ? 560 : 360,
                        child: Column(
                          children: [
                            // Spectrum + waterfall of the window, under it the activity
                            // strip (where there is or was traffic); a tap tunes the
                            // nearest channel (SSB/CW: right where tapped), left/right
                            // on the remote step through the channels.
                            Expanded(
                              flex: 3,
                              child: _StepFocus(
                                focusNode: _waterfallFocus,
                                onStep: (direction) => _select(_index + direction),
                                child: ValueListenableBuilder<int>(
                                  valueListenable: _spectrumTick,
                                  builder: (context, _, _) => WaterfallView(
                                    bins: _spectrum,
                                    centerHz: _spectrumCenterHz,
                                    spanHz: _spectrumSpanHz,
                                    markHz: _tunedHz,
                                    segments: _segmentsOfPlan,
                                    activity: _activity,
                                    channelsHz: _windowChannelsHz,
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
                              ),
                            ),
                            // APRS: what the packet decoder received, newest first.
                            if (_decoderOn || _packets.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              _AprsHeader(
                                count: _packets.length,
                                decoding: _decoderOn,
                                onClear: _packets.isEmpty ? null : () => setState(_packets.clear),
                              ),
                              Expanded(
                                flex: 2,
                                child: ListView(
                                  children: [
                                    for (final p in _packets.take(50))
                                      _AprsTile(packet: p, homeLat: _homeLat, homeLon: _homeLon),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Reports [minHeight] as its intrinsic height: SliverFillRemaining then
/// gives the waterfall at least that much and the page scrolls if the screen
/// is shorter (the waterfall itself has no natural height).
class _MinHeight extends SingleChildRenderObjectWidget {
  final double minHeight;

  const _MinHeight({required this.minHeight, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMinHeight(minHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderMinHeight renderObject) => renderObject.minHeight = minHeight;
}

class _RenderMinHeight extends RenderProxyBox {
  _RenderMinHeight(this._minHeight);

  double _minHeight;
  set minHeight(double value) {
    if (value == _minHeight) return;
    _minHeight = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicHeight(double width) => _minHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => _minHeight;
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
    final l = context.l10n;
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
    String khz(int hz) {
      if (hz == 0) return 'Auto';
      final text = (hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 2);
      return '${l.localeName == 'de' ? text.replaceAll('.', ',') : text} kHz';
    }

    return AlertDialog(
      title: Text(l.scannerSignalFilters),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row(
                l.scannerFilterWidth,
                l.scannerFilterWidthHelp,
                [
                  for (final bw in widget.bandwidthChoices)
                    ChoiceChip(
                      label: Text(khz(bw)),
                      selected: bandwidthHz == bw,
                      onSelected: (_) => onChanged(bandwidthHz: bw),
                    ),
                ],
              ),
              row(l.scannerNoiseBlanker, l.scannerNoiseBlankerHelp, [
                Switch(
                  value: noiseBlanker,
                  onChanged: (v) => onChanged(noiseBlanker: v),
                ),
              ]),
              row(l.scannerVoiceFilter, l.scannerVoiceFilterHelp, [
                Switch(
                  value: voiceFilter,
                  onChanged: (v) => onChanged(voiceFilter: v),
                ),
              ]),
              row(
                l.scannerAgc,
                l.scannerAgcHelp,
                [
                  for (final (value, label) in [('auto', 'Auto'), ('fast', l.scannerAgcFast), ('slow', l.scannerAgcSlow)])
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
        TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(l.commonClose)),
      ],
    );
  }
}

/// A DMR call as heard: the slot's state then, and when.
class _DmrCall {
  final DmrSlot slot;
  final DateTime at;

  const _DmrCall(this.slot, this.at);
}

/// DMR: source (repeater/radio) and colour code, each time slot's call -
/// talk group or called radio, speaker (radio ID, talker alias),
/// encrypted, emergency, reception - and the calls heard lately.
class _DmrPanel extends StatelessWidget {
  final DmrStatus? status;
  final List<_DmrCall> calls;

  const _DmrPanel({required this.status, required this.calls});

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  static String _ago(AppLocalizations l, double s) =>
      s < 60 ? l.scannerAgoSeconds(s.round()) : l.scannerAgoMinutes((s / 60).round());

  static String _call(DmrSlot s) => [if (s.target.isNotEmpty) s.target, if (s.speaker.isNotEmpty) s.speaker].join(' · ');

  Widget _slotLine(AppLocalizations l, DmrSlot s, bool playing) {
    const muted = TextStyle(color: Colors.white54);
    final String text;
    final Color colour;
    final IconData icon;
    if (s.talking) {
      final call = _call(s);
      text = call.isEmpty ? l.scannerDmrCallPending : call;
      colour = s.emergency ? Colors.redAccent : Colors.greenAccent;
      icon = s.encrypted ? Icons.lock : (playing ? Icons.volume_up : Icons.record_voice_over);
    } else {
      final last = s.heard && s.secondsAgo < 600 && _call(s).isNotEmpty
          ? ' – ${l.scannerDmrLast(_call(s), _ago(l, s.secondsAgo))}'
          : '';
      text = '${l.scannerDmrIdle}$last';
      colour = Colors.white38;
      icon = Icons.radio_button_unchecked;
    }
    final quality = !s.talking || s.encrypted
        ? ''
        : s.errorRate < 0.5
        ? l.scannerDmrReceptionGood
        : s.errorRate < 2
        ? l.scannerDmrReceptionFair
        : l.scannerDmrReceptionPoor;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(icon, color: colour, size: 22),
          const SizedBox(width: 8),
          Text('${l.scannerDmrSlot(s.slot)}: ', style: muted),
          Expanded(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 18, color: s.talking ? Colors.white : Colors.white54),
            ),
          ),
          if (s.talking && s.emergency) Text('${l.scannerDmrEmergency}  ', style: const TextStyle(color: Colors.redAccent)),
          if (s.talking && s.encrypted) Text(l.scannerDmrEncryptedNoAudio, style: muted),
          if (quality.isNotEmpty) Text(quality, style: muted),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: Colors.white54);
    final l = context.l10n;
    final st = status;
    final head = st == null || !st.sync
        ? 'DMR · ${l.scannerDmrNoSignal}'
        : [
            'DMR',
            if (st.sourceLabel.isNotEmpty) st.sourceLabel,
            if (st.colorCode >= 0) l.scannerDmrColorCode(st.colorCode),
          ].join(' · ');
    // A single radio uses one slot: the other is only shown once heard.
    final slots = st == null
        ? const <DmrSlot>[]
        : [
            for (final s in st.slots)
              if (st.source == 'repeater' || s.active || s.heard || s.slot == 1) s,
          ];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, color: st?.sync ?? false ? const Color(0xFFE84393) : Colors.white38),
              const SizedBox(width: 8),
              Text(head, style: Theme.of(context).textTheme.titleMedium),
              if (st != null && !st.voiceDecoder) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(l.scannerDmrNoVoiceDecoder, style: muted, overflow: TextOverflow.ellipsis),
                ),
              ],
            ],
          ),
          for (final s in slots) _slotLine(l, s, st!.audioSlot == s.slot),
          if (calls.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(l.scannerDmrRecentlyHeard, style: muted),
            for (final c in calls.take(5))
              Text(
                '${_time(c.at)} · ${l.scannerDmrSlot(c.slot.slot)} · ${_call(c.slot)}'
                '${c.slot.encrypted ? ' · ${l.scannerDmrEncrypted}' : ''}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70),
              ),
          ],
        ],
      ),
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
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.location_on, color: decoding ? Colors.greenAccent : Colors.white38),
          const SizedBox(width: 8),
          Text('APRS · ${l.scannerAprsPackets(count)}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              decoding ? (count == 0 ? l.scannerAprsDecoderWaiting : l.scannerAprsDecoderRunning) : l.scannerAprsDecoderOff,
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          if (onClear != null)
            TextButton.icon(onPressed: onClear, icon: const Icon(Icons.delete_outline), label: Text(l.scannerAprsClear)),
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

  String? _where(AppLocalizations l) {
    final km = packet.distanceKm(homeLat, homeLon);
    if (km == null) return null;
    final d = km >= 10
        ? km.round().toString()
        : (l.localeName == 'de' ? km.toStringAsFixed(1).replaceAll('.', ',') : km.toStringAsFixed(1));
    return '$d km ${packet.bearingFrom(homeLat, homeLon)}';
  }

  String _text(AppLocalizations l) {
    final p = packet;
    return [
      if (p.name != null) p.type == AprsKind.message ? l.scannerAprsTo(p.name!) : p.name!,
      if (p.weather != null) p.weather!.describe(),
      if (p.speedKmh != null) '${p.speedKmh!.round()} km/h${p.course != null ? ' · ${p.course}°' : ''}',
      if (p.comment != null) p.comment!,
    ].join(' · ');
  }

  void _details(BuildContext context) {
    final p = packet;
    final l = context.l10n;
    final where = _where(l), text = _text(l);
    String coord(double v, String pos, String neg) {
      final n = v.abs().toStringAsFixed(5);
      return '${l.localeName == 'de' ? n.replaceAll('.', ',') : n}° ${v >= 0 ? pos : neg}';
    }

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
              Text(l.scannerAprsReceived(_time)),
              if (p.symbolName != null) Text('Symbol: ${p.symbolName}'),
              if (p.hasPosition) Text('Position: ${coord(p.lat!, 'N', 'S')}, ${coord(p.lon!, l.scannerEastShort, 'W')}'),
              if (where != null) Text(l.scannerAprsDistance(where)),
              if (text.isNotEmpty) Text(text),
              Text(l.scannerAprsPath(p.path.isEmpty ? l.scannerAprsDirect : p.path.join(', '))),
              const SizedBox(height: 12),
              Text(l.scannerRawData, style: const TextStyle(color: Colors.white54)),
              SelectableText(p.tnc2, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ],
          ),
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(l.commonClose)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final where = _where(l);
    final text = _text(l);
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => _details(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 70,
                child: Text(_time, style: const TextStyle(color: Colors.white54)),
              ),
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
              SizedBox(
                width: 110,
                child: Text(where ?? '', style: const TextStyle(color: Colors.greenAccent)),
              ),
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
