import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop/hrdab_desktop.dart';

/// Dart bridge to [DabRtlSdrPlugin] (Kotlin) - DAB+ reception with the
/// app's own receiver (cpp/hrdab) on an RTL-SDR stick, opened either
/// directly over USB ([useDirectUsb]) or through an rtl_tcp server
/// ([setServer]: an external driver app or a network service).
///
/// On Windows/Linux the same receiver runs as hrdab.dll / libhrdab.so
/// ([HrdabDesktop], the desktop port of DabRtlSdrPlugin) - same methods,
/// same events.
class DabRtlSdrService {
  static const _methodChannel = MethodChannel('home_radio/dab_rtlsdr');
  static const _eventChannel = EventChannel('home_radio/dab_rtlsdr/events');

  static final bool _desktop = Platform.isWindows || Platform.isLinux;

  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _eventSub;

  /// Raw scan/sync/playback events - see DabRtlSdrPlugin.kt for the exact
  /// shapes (`scanProgress`, `channelLocked`, `scanFinished`, `syncChange`,
  /// `serviceDetected`, `ensembleLabel`, `dynamicLabel`, `rsErrors`,
  /// `aacErrors`, `playbackStatus`).
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  DabRtlSdrService() {
    if (_desktop) {
      _eventSub = HrdabDesktop.instance.events.listen(_eventsController.add);
      return;
    }
    _eventSub = _eventChannel.receiveBroadcastStream().listen((event) {
      _eventsController.add((event as Map).cast<String, dynamic>());
    });
  }

  Future<T?> _invokeMethod<T>(String method, [Map<String, dynamic>? arguments]) => _desktop
      ? HrdabDesktop.instance.invoke<T>(method, arguments)
      : _methodChannel.invokeMethod<T>(method, arguments);

  /// Points the receiver at the rtl_tcp server [host]:[port]. Must be called
  /// (at least once) before [scanBand3]/[tuneFrequency]/[playService].
  /// Returns whether something actually listens there. The protocol (rtl_tcp
  /// or rtl_tcp Jay extended) is negotiated by the receiver on every connect.
  Future<bool> setServer({String host = '127.0.0.1', int port = 1234}) async {
    final result = await _invokeMethod<bool>('setServer', {'host': host, 'port': port});
    return result ?? false;
  }

  /// "RTL-SDR-USB" mode's alternative to [setServer]: opens the stick
  /// directly over USB (asking for the permission if needed).
  Future<bool> useDirectUsb() async {
    final result = await _invokeMethod<bool>('useDirectUsb');
    return result ?? false;
  }

  /// The whole of Band III, or with [onlyFreqKhz] just that one channel
  /// (searched more patiently - see DabRtlSdrPlugin.scanBand3).
  Future<void> scanBand3({int? onlyFreqKhz}) async {
    await _settled();
    await _invokeMethod('scanBand3', {'freqKhz': ?onlyFreqKhz});
  }

  // FM (UKW) - same receiver and stick; starting FM leaves DAB+ and vice
  // versa (one tuner). Events: fmStatus, fmRds, fmSeekResult,
  // fmScanProgress, fmStationFound, fmScanFinished.

  /// Switches to FM, tunes [freqKhz] and plays it.
  Future<bool> fmPlay(int freqKhz) async {
    await _settled();
    return await _invokeMethod<bool>('fmPlay', {'freqKhz': freqKhz}) ?? false;
  }

  /// Retunes while FM is playing (manual tuning) - audio continues.
  Future<bool> fmTune(int freqKhz) async =>
      await _invokeMethod<bool>('fmTune', {'freqKhz': freqKhz}) ?? false;

  /// Looks for the next station up or down from [fromKhz] and plays it;
  /// the result arrives as an `fmSeekResult` event.
  Future<void> fmSeek({required int fromKhz, required bool up}) async {
    await _settled();
    await _invokeMethod('fmSeek', {'fromKhz': fromKhz, 'up': up});
  }

  Future<void> fmStop() => _invokeMethod('fmStop');

  Future<void> fmScan() async {
    await _settled();
    await _invokeMethod('fmScan');
  }

  Future<void> stopFmScan() => _invokeMethod('stopFmScan');

  // Narrowband listening (CB radio, airband) - same receiver; leaves DAB+/FM.
  // Events: nbStatus, nbActivity, nbSpectrum. Modes: auto, am, fm, usb, lsb.

  Future<bool> nbStart({
    required int sampleRate,
    required int centerHz,
    required List<int> channelsHz,
    required int freqHz,
    required String mode,
    required double squelchDb,
  }) async {
    // A band switch (10 m -> 2 m) stops and starts again.
    await _settled();
    return await _invokeMethod<bool>('nbStart', {
          'sampleRate': sampleRate,
          'centerHz': centerHz,
          'channelsHz': channelsHz,
          'freqHz': freqHz,
          'mode': mode,
          'squelchDb': squelchDb,
        }) ??
        false;
  }

  Future<bool> nbTune({required int freqHz, required String mode}) async =>
      await _invokeMethod<bool>('nbTune', {'freqHz': freqHz, 'mode': mode}) ?? false;

  Future<void> nbSetSquelch(double squelchDb) => _invokeMethod('nbSetSquelch', {'squelchDb': squelchDb});

  Future<bool> nbSetChannels({required int centerHz, required List<int> channelsHz}) async =>
      await _invokeMethod<bool>('nbSetChannels', {'centerHz': centerHz, 'channelsHz': channelsHz}) ??
      false;

  /// Leaving a listening band: the scanner stops NB in dispose() without
  /// waiting, while the home screen already tunes DAB+/FM again - an nbStop
  /// arriving after that tune halted the stick ("Sender wird getunt" for
  /// good). Every receiver start waits for a pending stop first ([_settled]).
  Future<void> nbStop() {
    final stop = _invokeMethod<void>('nbStop').catchError((Object _) {});
    _stopping = stop;
    return stop;
  }

  Future<void> _stopping = Future.value();

  /// Waits for a pending [nbStop] - before anything that tunes.
  Future<void> _settled() => _stopping;

  /// Tuner gain while listening: step 0..[nbGainSteps]-1 held fixed, -1 =
  /// automatic. Returns the step's gain in dB (the current one for -1). The
  /// gain in effect also comes with every `nbSpectrum` event (`gainDb`).
  Future<double> nbSetGain(int gainIndex) async =>
      (await _invokeMethod<num>('nbSetGain', {'gainIndex': gainIndex}))?.toDouble() ?? 0;

  /// ADS-B on 1090 MHz (leaves DAB+/FM/NB): verified Mode S frames arrive
  /// as `adsbFrame` events (see adsbFrameFromEvent); [nbSetGain] sets the
  /// gain here too.
  Future<bool> adsbStart() async {
    await _settled();
    return await _invokeMethod<bool>('adsbStart') ?? false;
  }

  /// Like [nbStop]: a later receiver start waits for it.
  Future<void> adsbStop() {
    final stop = _invokeMethod<void>('adsbStop').catchError((Object _) {});
    _stopping = stop;
    return stop;
  }

  /// ACARS on all [channelsHz] at once around [centerHz] (no audio):
  /// messages arrive as `acarsFrame` events with their `freqHz`.
  Future<bool> acarsStart({required int centerHz, required List<int> channelsHz}) async {
    await _settled();
    return await _invokeMethod<bool>('acarsStart', {'centerHz': centerHz, 'channelsHz': channelsHz}) ?? false;
  }

  /// Like [nbStop]: a later receiver start waits for it.
  Future<void> acarsStop() {
    final stop = _invokeMethod<void>('acarsStop').catchError((Object _) {});
    _stopping = stop;
    return stop;
  }

  /// ISM sensors on [freqHz] (433,92 / 868,3 MHz): bursts arrive as
  /// `ismBurst` events (see IsmBurst.fromEvent); gain via [nbSetGain].
  Future<bool> ismStart(int freqHz) async {
    await _settled();
    return await _invokeMethod<bool>('ismStart', {'freqHz': freqHz}) ?? false;
  }

  /// Like [nbStop]: a later receiver start waits for it.
  Future<void> ismStop() {
    final stop = _invokeMethod<void>('ismStop').catchError((Object _) {});
    _stopping = stop;
    return stop;
  }

  /// Packet decoder on the listened channel's audio: [packetOff],
  /// [packetAprs] (AFSK 1200) or [packetAcars] (MSK 2400). Frames arrive as
  /// `nbPacket` events with that `kind` (see aprsFrameFromEvent).
  Future<void> nbSetPacketDecoder(int kind) => _invokeMethod('nbSetPacketDecoder', {'kind': kind});

  static const packetOff = 0, packetAprs = 1, packetAcars = 2;

  /// Gain steps of the R820T/R828D tuner (see R82xx::kGainSteps).
  static const nbGainSteps = 31;

  /// Signal filters for the listened channel: [bandwidthHz] (0 = mode
  /// default), impulse [noiseBlanker], [voiceFilter] (300-3000 Hz) and
  /// [agc] ("auto", "fast", "slow").
  Future<void> nbSetFilters({
    required int bandwidthHz,
    required bool noiseBlanker,
    required bool voiceFilter,
    required String agc,
  }) =>
      _invokeMethod('nbSetFilters', {
        'bandwidthHz': bandwidthHz,
        'noiseBlanker': noiseBlanker,
        'voiceFilter': voiceFilter,
        'agc': agc,
      });

  /// FM band limits (kHz) and the smallest tuning step.
  static const fmMinKhz = 87500, fmMaxKhz = 108000, fmStepKhz = 50;

  /// Band III channels (label, kHz) - same list as DabChannels.BAND3 on the
  /// Kotlin side, for picking one to search manually.
  static const band3Channels = [
    ('5A', 174928), ('5B', 176640), ('5C', 178352), ('5D', 180064),
    ('6A', 181936), ('6B', 183648), ('6C', 185360), ('6D', 187072),
    ('7A', 188928), ('7B', 190640), ('7C', 192352), ('7D', 194064),
    ('8A', 195936), ('8B', 197648), ('8C', 199360), ('8D', 201072),
    ('9A', 202928), ('9B', 204640), ('9C', 206352), ('9D', 208064),
    ('10A', 209936), ('10N', 210096), ('10B', 211648), ('10C', 213360),
    ('10D', 215072), ('11A', 216928), ('11N', 217088), ('11B', 218640),
    ('11C', 220352), ('11D', 222064), ('12A', 223936), ('12N', 224096),
    ('12B', 225648), ('12C', 227360), ('12D', 229072), ('13A', 230784),
    ('13B', 232496), ('13C', 234208), ('13D', 235776), ('13E', 237488),
    ('13F', 239200),
  ];

  Future<void> stopScan() => _invokeMethod('stopScan');

  Future<void> tuneFrequency(int freqKhz) async {
    await _settled();
    await _invokeMethod('tuneFrequency', {'freqKhz': freqKhz});
  }

  /// Tunes to [freqKhz], waits for sync, then decodes+plays [serviceId]'s
  /// audio component. Returns whether playback actually started.
  Future<bool> playService({required int freqKhz, required int serviceId}) async {
    await _settled();
    final result = await _invokeMethod<bool>(
      'playService',
      {'freqKhz': freqKhz, 'serviceId': serviceId},
    );
    return result ?? false;
  }

  Future<void> stopPlayback() => _invokeMethod('stopPlayback');

  /// Tears down the native DAB+ session (direct-USB mode's rtlsdr_dev_t /
  /// UsbDeviceConnection, or the rtl_tcp client) so a later play/scan
  /// attempt starts fresh - call this once RtlSdrUsbService reports the
  /// known RTL-SDR dongle was unplugged. Without it, a direct-USB session
  /// left pointing at now-gone hardware never recovers on its own; every
  /// later attempt just silently fails until the app is force-stopped.
  Future<void> resetSession() => _invokeMethod('resetSession');

  Future<String> getEnsembleLabel() async {
    final result = await _invokeMethod<String>('getEnsembleLabel');
    return result ?? '';
  }

  /// Tunes to each station in turn and waits for a real DAB+ MOT slideshow
  /// image (the actual broadcast logo/cover art) - a dedicated, separate,
  /// slower action from [scanBand3] (some stations take 10-30s to send a
  /// slide, some never do). Progress/results arrive via [events]
  /// (`logoScanProgress`, `logoFound`, `logoNotFound`, `logoScanFinished`).
  Future<void> fetchLogos(List<({int freqKhz, int serviceId})> stations) async {
    await _settled();
    return _invokeMethod('fetchLogos', {
      'stations': stations.map((s) => {'freqKhz': s.freqKhz, 'serviceId': s.serviceId}).toList(),
    });
  }

  Future<void> stopLogoFetch() => _invokeMethod('stopLogoFetch');

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _eventsController.close();
  }
}
