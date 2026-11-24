import '../../l10n/l10n.dart';

/// A listening band for the ScannerScreen: its channels and how they're
/// usually modulated. Nothing here is saved as a station or favorite - the
/// listening bands are deliberately separate from everyday radio.
class BandChannel {
  /// Short label shown on the channel button, e.g. "19" or "121,500".
  final String label;
  final int freqHz;

  /// A well-known frequency's name ("FT8", "Anruf", "ISS") - shown on the
  /// button instead of the frequency.
  final String? name;

  const BandChannel(this.label, this.freqHz, {this.name});
}

/// A part of a band with its own use (band plan, IARU Region 1): what's
/// heard there and how to receive it - the settings the scanner switches to
/// on its own when tuning into it (see ScannerScreen's "Bandplan").
class BandSegment {
  final int lowHz;

  /// Exclusive.
  final int highHz;
  final String name;

  /// Recommended modulation ("cw" is USB with a narrow filter).
  final String mode;

  /// Recommended filter width, 0 = the modulation's default.
  final int bandwidthHz;

  /// Channel raster (ham bands: the channels are built from it).
  final int stepHz;

  /// Well-known frequencies in here: (name, Hz).
  final List<(String, int)> marks;

  const BandSegment(
    this.lowHz,
    this.highHz,
    this.name, {
    required this.mode,
    this.bandwidthHz = 0,
    this.stepHz = 0,
    this.marks = const [],
  });

  bool contains(int hz) => hz >= lowHz && hz < highHz;
}

class BandPlan {
  /// Settings key part, e.g. "cb".
  final String id;
  final String title;
  final List<BandChannel> channels;

  /// Modulations offered (first = default); "auto" lets the receiver decide.
  final List<String> modes;

  /// How the channel label reads in a sentence, e.g. "Kanal 19".
  final String Function(BandChannel c) longLabel;

  /// The band plan: recommended settings per part of the band.
  final List<BandSegment> segments;

  /// Where to start without a remembered channel (null = mid-band).
  final int? defaultFreqHz;

  /// Free tuning over a wide range (see [worldBandPlan]): places to jump
  /// to, and frequency entry offered.
  final List<(String, int)> jumpTargets;

  /// Name on the chip when switching between bands (see [bandShortTitle]).
  final String? shortTitle;

  const BandPlan({
    required this.id,
    required this.title,
    required this.channels,
    required this.modes,
    required this.longLabel,
    this.segments = const [],
    this.defaultFreqHz,
    this.jumpTargets = const [],
    this.shortTitle,
  });

  bool get isFree => jumpTargets.isNotEmpty;

  int get lowHz => channels.first.freqHz;
  int get highHz => channels.last.freqHz;

  BandSegment? segmentAt(int hz) {
    for (final s in segments) {
      if (s.contains(hz)) return s;
    }
    return null;
  }
}

/// MHz with the decimal separator of the app's language ("121,500" in
/// German, "121.500" in English).
String formatMhz(int freqHz, {int decimals = 3}) {
  final text = (freqHz / 1e6).toStringAsFixed(decimals);
  return l10n.localeName == 'de' ? text.replaceAll('.', ',') : text;
}

/// MHz with as many decimals as [freqHz] needs (at least 3, at most 5).
String formatMhzAuto(int freqHz) {
  for (var d = 3; d < 5; d++) {
    if ((freqHz / 1e6 * _pow10(d)).roundToDouble() * 1e6 / _pow10(d) == freqHz) return formatMhz(freqHz, decimals: d);
  }
  return formatMhz(freqHz, decimals: 5);
}

int _pow10(int n) => [1, 10, 100, 1000, 10000, 100000][n];

String _mhzLabel(BandChannel c) => '${formatMhzAuto(c.freqHz)} MHz${c.name == null ? '' : ' · ${c.name}'}';

/// Channels from the segments' rasters plus their marks, by frequency.
List<BandChannel> _segmentChannels(List<BandSegment> segments) {
  final byHz = <int, BandChannel>{};
  for (final s in segments) {
    for (var n = 0;; n++) {
      // Doubles for 8,33 kHz (25/3 kHz) rasters.
      final hz = s.lowHz + (n * s.stepHz).round();
      if (hz >= s.highHz) break;
      byHz[hz] = BandChannel(formatMhzAuto(hz), hz);
    }
    for (final (name, hz) in s.marks) {
      byHz[hz] = BandChannel(formatMhzAuto(hz), hz, name: name);
    }
  }
  return byHz.values.toList()..sort((a, b) => a.freqHz.compareTo(b.freqHz));
}

int _mhz(double mhz) => (mhz * 1e6).round();

/// A frequency in a name, e.g. "29,600" ("29.600" in English).
String _f(double mhz) => formatMhz(_mhz(mhz));

/// The plans carry translated names and labels: built once per language.
final _builtPlans = <String, Object>{};

T _perLanguage<T extends Object>(String name, T Function() build) =>
    _builtPlans.putIfAbsent('${l10n.localeName}/$name', build) as T;

/// CB radio: channels 1-40 (26.965-27.405 MHz, the CEPT plan with its
/// historic gaps/swaps), with [all80] also 41-80 (26.565-26.955 MHz, 10 kHz
/// apart, allowed in Germany; Austria uses 1-40). Sorted by frequency.
BandPlan cbBandPlan({bool all80 = false}) => BandPlan(
  id: 'cb',
  title: l10n.scannerBandCb,
  channels: () {
    const ch1to40 = [
      26965, 26975, 26985, 27005, 27015, 27025, 27035, 27055, 27065, 27075, //
      27085, 27105, 27115, 27125, 27135, 27155, 27165, 27175, 27185, 27205,
      27215, 27225, 27255, 27235, 27245, 27265, 27275, 27285, 27295, 27305,
      27315, 27325, 27335, 27345, 27355, 27365, 27375, 27385, 27395, 27405,
    ];
    final names = {9: l10n.scannerMarkEmergency, 19: l10n.scannerCbTruckers};
    final list = [
      if (all80)
        for (var n = 41; n <= 80; n++) BandChannel('$n', (26565 + (n - 41) * 10) * 1000),
      for (var i = 0; i < 40; i++) BandChannel('${i + 1}', ch1to40[i] * 1000, name: names[i + 1]),
    ]..sort((a, b) => a.freqHz.compareTo(b.freqHz));
    return list;
  }(),
  modes: const ['auto', 'fm', 'am', 'usb', 'lsb'],
  longLabel: (c) => '${l10n.scannerChannel(c.label)}${c.name == null ? '' : ' · ${c.name}'}',
  segments: [
    BandSegment(_mhz(26.560), _mhz(27.360), l10n.scannerSegCbFm, mode: 'fm', bandwidthHz: 10000),
    BandSegment(_mhz(27.360), _mhz(27.410), l10n.scannerSegCbSsb, mode: 'lsb', bandwidthHz: 2700),
  ],
  defaultFreqHz: _mhz(27.185),
);

/// PMR446: licence-free walkie-talkies, channels 1-16 from 446,00625 MHz
/// in 12,5 kHz steps, FM.
final pmrBandPlan = BandPlan(
  id: 'pmr',
  title: 'PMR446',
  channels: [
    for (var n = 1; n <= 16; n++) BandChannel('$n', 446006250 + (n - 1) * 12500),
  ],
  modes: const ['fm', 'auto', 'am', 'dmr'],
  longLabel: (c) => l10n.scannerChannel(c.label),
  segments: [BandSegment(_mhz(446.0), _mhz(446.2), 'PMR446 (FM)', mode: 'fm', bandwidthHz: 12500)],
  defaultFreqHz: 446006250,
);

/// Civil airband voice, 118.000-136.975 MHz on the 25 kHz raster (8.33 kHz
/// channels fall inside those), AM only.
BandPlan get airBandPlan => _perLanguage(
  'air',
  () => BandPlan(
    id: 'air',
    title: l10n.scannerBandAir,
    channels: [for (var khz = 118000; khz <= 136975; khz += 25) BandChannel(formatMhz(khz * 1000), khz * 1000)],
    modes: const ['am'],
    longLabel: (c) => '${c.label} MHz',
    segments: [BandSegment(_mhz(118), _mhz(137), '${l10n.scannerBandAir} (AM)', mode: 'am', bandwidthHz: 8330)],
  ),
);

/// Military airband, 225.000-399.975 MHz on the 25 kHz raster, AM.
BandPlan get milBandPlan => _perLanguage(
  'mil',
  () => BandPlan(
    id: 'mil',
    title: l10n.scannerBandMil,
    channels: [for (var khz = 225000; khz <= 399975; khz += 25) BandChannel(formatMhz(khz * 1000), khz * 1000)],
    modes: const ['am'],
    longLabel: (c) => '${c.label} MHz',
    segments: [BandSegment(_mhz(225), _mhz(400), '${l10n.scannerSegMilAir} (AM)', mode: 'am', bandwidthHz: 8330)],
  ),
);

const _hamModes = ['usb', 'lsb', 'cw', 'fm', 'am', 'auto', 'dmr'];

/// An amateur band, e.g. [band] "40 m": "Amateurfunk 40 m", "40 m" on the
/// chip.
BandPlan _hamPlan(String id, String band, int defaultHz, List<BandSegment> segments) => BandPlan(
  id: id,
  title: l10n.scannerBandHam(band),
  shortTitle: band,
  channels: _segmentChannels(segments),
  modes: _hamModes,
  longLabel: _mhzLabel,
  segments: segments,
  defaultFreqHz: defaultHz,
);

// Typical settings: CW 1 kHz raster (narrowest filter, fine tuning in
// 100 Hz), SSB 2,5 kHz raster with 2,7 kHz, NFM in the band's channel
// spacing with 12,5 kHz.
BandSegment _cw(double lo, double hi, String name, {List<(String, int)> marks = const []}) =>
    BandSegment(_mhz(lo), _mhz(hi), name, mode: 'cw', bandwidthHz: 1000, stepHz: 1000, marks: marks);
BandSegment _ssb(double lo, double hi, String name, {int step = 2500, List<(String, int)> marks = const []}) =>
    BandSegment(_mhz(lo), _mhz(hi), name, mode: 'usb', bandwidthHz: 2700, stepHz: step, marks: marks);
BandSegment _nfm(double lo, double hi, String name, {int step = 12500, int bw = 12500, List<(String, int)> marks = const []}) =>
    BandSegment(_mhz(lo), _mhz(hi), name, mode: 'fm', bandwidthHz: bw, stepHz: step, marks: marks);
// Analog FM and DMR side by side: auto tells them apart (and decodes DMR).
BandSegment _fmOrDmr(double lo, double hi, String name) =>
    BandSegment(_mhz(lo), _mhz(hi), name, mode: 'auto', stepHz: 12500);

// Below 10 MHz SSB voice is on the lower sideband.
BandSegment _lsb(double lo, double hi, String name, {int step = 2500, List<(String, int)> marks = const []}) =>
    BandSegment(_mhz(lo), _mhz(hi), name, mode: 'lsb', bandwidthHz: 2700, stepHz: step, marks: marks);

/// Shortwave ends here: below, the receiver switches to direct sampling,
/// the RTL-SDR Blog V4's upconverter or an external one (see hf.h).
const hfTopHz = 30000000;

/// The shortwave amateur bands (IARU Region 1, 60 m as allowed in Austria
/// and Germany), 160 m to 12 m - 10 m is in [hamBandPlans]. Digital modes
/// (FT8 & co.) always on the upper sideband, voice below 10 MHz on the lower
/// one; the FT8 frequencies are marked.
List<BandPlan> get hfHamBandPlans => _perLanguage('hfHam', () {
  final t = l10n;
  return [
    _hamPlan('ham160', '160 m', _mhz(1.850), [
      _cw(1.810, 1.838, t.scannerSegCw),
      _ssb(1.838, 1.843, t.scannerSegDigital, step: 1000, marks: [('FT8', _mhz(1.840))]),
      _lsb(1.843, 2.000, t.scannerSegVoiceLsb),
    ]),
    _hamPlan('ham80', '80 m', _mhz(3.700), [
      _cw(3.500, 3.570, t.scannerSegCw),
      _ssb(3.570, 3.600, t.scannerSegDigital, step: 1000, marks: [('FT8', _mhz(3.573))]),
      _lsb(3.600, 3.800, t.scannerSegVoiceLsb),
    ]),
    _hamPlan('ham60', '60 m', _mhz(5.357), [
      _cw(5.3515, 5.354, t.scannerSegCw),
      _ssb(5.354, 5.3665, t.scannerSegDigitalVoiceUsb, step: 1000, marks: [('FT8', _mhz(5.357))]),
    ]),
    _hamPlan('ham40', '40 m', _mhz(7.100), [
      _cw(7.000, 7.040, t.scannerSegCw),
      _ssb(7.040, 7.060, t.scannerSegDigital, step: 1000),
      _lsb(7.060, 7.074, t.scannerSegVoiceLsb),
      // FT8 sits in the voice part, on the upper sideband.
      _ssb(7.074, 7.0775, 'FT8', step: 1000, marks: [('FT8', _mhz(7.074))]),
      _lsb(7.0775, 7.200, t.scannerSegVoiceLsb),
    ]),
    _hamPlan('ham30', '30 m', _mhz(10.136), [
      _cw(10.100, 10.130, t.scannerSegCw),
      _ssb(10.130, 10.150, t.scannerSegDigital, step: 1000, marks: [('FT8', _mhz(10.136))]),
    ]),
    _hamPlan('ham20', '20 m', _mhz(14.200), [
      _cw(14.000, 14.070, t.scannerSegCw),
      _ssb(14.070, 14.099, t.scannerSegDigital, step: 1000, marks: [('FT8', _mhz(14.074))]),
      _cw(14.099, 14.101, t.scannerSegBeacons, marks: [('NCDXF', _mhz(14.100))]),
      _ssb(14.101, 14.1125, t.scannerSegDigitalAllModes, step: 1000),
      _ssb(14.1125, 14.350, t.scannerSegVoiceUsb),
    ]),
    _hamPlan('ham17', '17 m', _mhz(18.130), [
      _cw(18.068, 18.095, t.scannerSegCw),
      _ssb(18.095, 18.109, t.scannerSegDigital, step: 1000, marks: [('FT8', _mhz(18.100))]),
      _cw(18.109, 18.1125, t.scannerSegBeacons, marks: [('NCDXF', _mhz(18.110))]),
      _ssb(18.1125, 18.168, t.scannerSegVoiceUsb),
    ]),
    _hamPlan('ham15', '15 m', _mhz(21.250), [
      _cw(21.000, 21.070, t.scannerSegCw),
      _ssb(21.070, 21.149, t.scannerSegDigital, step: 1000, marks: [('FT8', _mhz(21.074))]),
      _cw(21.149, 21.1525, t.scannerSegBeacons, marks: [('NCDXF', _mhz(21.150))]),
      _ssb(21.1525, 21.450, t.scannerSegVoiceUsb),
    ]),
    _hamPlan('ham12', '12 m', _mhz(24.950), [
      _cw(24.890, 24.915, t.scannerSegCw),
      _ssb(24.915, 24.929, t.scannerSegDigital, step: 1000, marks: [('FT8', _mhz(24.915))]),
      _cw(24.929, 24.9325, t.scannerSegBeacons, marks: [('NCDXF', _mhz(24.930))]),
      _ssb(24.9325, 24.990, t.scannerSegVoiceUsb),
    ]),
  ];
});

/// The amateur radio bands from 10 m up, which the tuner receives itself.
/// Built from the IARU Region 1 band plans: each part of a band with its
/// own raster and the settings the scanner switches to there.
List<BandPlan> get hamBandPlans => _perLanguage('ham', () {
  final t = l10n;
  final call = t.scannerMarkCall;
  return [
    _hamPlan('ham10', '10 m', _mhz(28.074), [
      _cw(28.000, 28.070, t.scannerSegCw),
      _ssb(28.070, 28.190, t.scannerSegDigital, step: 1000, marks: [('FT8', _mhz(28.074))]),
      _cw(28.190, 28.225, t.scannerSegBeacons, marks: [('NCDXF', _mhz(28.200))]),
      _ssb(28.225, 28.300, t.scannerSegBeaconsAllModes),
      _ssb(28.300, 29.000, t.scannerSegVoiceSsb),
      BandSegment(_mhz(29.000), _mhz(29.100), t.scannerSegAmVoice, mode: 'am', bandwidthHz: 6000, stepHz: 5000),
      _nfm(29.100, 29.200, t.scannerSegFmSimplex, step: 10000, bw: 10000),
      _nfm(29.200, 29.300, t.scannerSegPacket, step: 10000, bw: 10000),
      _ssb(29.300, 29.510, t.scannerSegSatellites),
      _nfm(29.510, 29.600, t.scannerSegRepeaterInputs, step: 10000, bw: 10000),
      _nfm(29.600, 29.620, t.scannerSegFmSimplexCall(_f(29.600)), step: 10000, bw: 10000, marks: [(call, _mhz(29.600))]),
      _nfm(29.620, 29.700, t.scannerSegRepeaterOutputs, step: 10000, bw: 10000),
    ]),
    _hamPlan('ham6', '6 m', _mhz(50.313), [
      _cw(50.000, 50.100, t.scannerSegCwBeacons),
      _ssb(50.100, 50.500, t.scannerSegSsbVoiceCall(_f(50.150)), marks: [(call, _mhz(50.150)), ('FT8', _mhz(50.313))]),
      _ssb(50.500, 51.100, t.scannerSegDigitalAllModes, step: 5000),
      _nfm(51.100, 51.410, t.scannerSegRepeaterInputs, step: 10000),
      _nfm(51.410, 51.600, t.scannerSegFmSimplexCall(_f(51.510)), step: 10000, marks: [(call, _mhz(51.510))]),
      _nfm(51.600, 51.810, t.scannerSegAllModes, step: 10000),
      _nfm(51.810, 52.000, t.scannerSegRepeaterOutputs, step: 10000),
    ]),
    _hamPlan('ham2', '2 m', _mhz(145.500), [
      _cw(144.000, 144.110, t.scannerSegCwEme),
      _ssb(144.110, 144.400, t.scannerSegSsbVoiceCall(_f(144.300)), marks: [('FT8', _mhz(144.174)), (call, _mhz(144.300))]),
      _cw(144.400, 144.500, t.scannerSegBeacons),
      _nfm(144.500, 144.800, t.scannerSegAllModesSstv),
      _nfm(144.800, 145.000, t.scannerSegDigitalAprs(_f(144.800)), marks: [('APRS', _mhz(144.800))]),
      _nfm(145.000, 145.200, t.scannerSegRepeaterInputs),
      _nfm(145.200, 145.600, t.scannerSegFmSimplexCall(_f(145.500)), marks: [(call, _mhz(145.500))]),
      _nfm(145.600, 145.800, t.scannerSegRepeaterOutputs),
      _nfm(
        145.800,
        146.000,
        t.scannerSegSatellitesIss(_f(145.800)),
        marks: [('ISS', _mhz(145.800)), (aprsIssName, _mhz(145.825))],
      ),
    ]),
    _hamPlan('ham70', '70 cm', _mhz(433.500), [
      _nfm(430.000, 432.000, t.scannerSegDigitalRepeaterInputs),
      _cw(432.000, 432.100, t.scannerSegCwEme),
      _ssb(432.100, 432.400, t.scannerSegSsbVoiceCall(_f(432.200)), marks: [('FT8', _mhz(432.174)), (call, _mhz(432.200))]),
      _cw(432.400, 432.500, t.scannerSegBeacons),
      _nfm(432.500, 433.000, t.scannerSegAllModes),
      _nfm(433.000, 433.400, t.scannerSegRepeaterInputsLpd),
      _nfm(433.400, 433.600, t.scannerSegFmSimplexCallLpd(_f(433.500)), marks: [(call, _mhz(433.500))]),
      _nfm(433.600, 435.000, t.scannerSegLpdIsm(_f(433.920)), marks: [(t.scannerMarkSensors, _mhz(433.920))]),
      _nfm(435.000, 438.000, t.scannerSegSatellites),
      _fmOrDmr(438.000, 438.650, 'Digital (DMR, C4FM)'),
      _fmOrDmr(438.650, 439.450, t.scannerSegRepeaterOutputsDigital),
      _fmOrDmr(439.450, 440.000, 'Digital'),
    ]),
    _hamPlan('ham23', '23 cm', _mhz(1297.500), [
      _nfm(1240.000, 1243.250, 'Digital', step: 25000),
      BandSegment(_mhz(1243.250), _mhz(1260), t.scannerSegAtv, mode: 'fm', stepHz: 250000),
      _nfm(1260.000, 1270.000, t.scannerSegSatellitesUplink, step: 25000),
      BandSegment(_mhz(1270), _mhz(1291), t.scannerSegAtvDigital, mode: 'fm', stepHz: 250000),
      _nfm(1291.000, 1291.500, t.scannerSegRepeaterInputs, step: 25000),
      _nfm(1291.500, 1296.000, t.scannerSegAllModes, step: 25000),
      _cw(1296.000, 1296.150, t.scannerSegCwEme),
      _ssb(1296.150, 1296.800, t.scannerSegSsbVoiceCall(_f(1296.200)), marks: [(call, _mhz(1296.200))]),
      _cw(1296.800, 1297.000, t.scannerSegBeacons),
      _nfm(1297.000, 1297.500, t.scannerSegRepeaterOutputs, step: 25000),
      _nfm(1297.500, 1298.000, t.scannerSegFmSimplexCall(_f(1297.500)), step: 25000, marks: [(call, _mhz(1297.500))]),
      _nfm(1298.000, 1300.000, 'Digital', step: 25000),
    ]),
  ];
});

const aprsIssName = 'ISS APRS';

/// APRS frequencies - the scanner turns its packet decoder on there
/// (Europe 144,800, the ISS digipeater 145,825).
const aprsFrequenciesHz = {144800000, 145825000};

/// All amateur bands, 160 m to 23 cm.
List<BandPlan> get allHamBandPlans => [...hfHamBandPlans, ...hamBandPlans];

/// Short names for switching between bands ([allHamBandPlans],
/// [broadcastBandPlans]).
String bandShortTitle(BandPlan p) => p.shortTitle ?? p.title;

// --- Kurzwelle: broadcasting and utility stations ---

BandPlan _broadcastPlan(String id, String title, String short, double lo, double hi, {int step = 5000}) {
  final segment = BandSegment(_mhz(lo), _mhz(hi), '$title (AM)', mode: 'am', bandwidthHz: 8000, stepHz: step);
  return BandPlan(
    id: id,
    title: title,
    shortTitle: short,
    channels: _segmentChannels([segment]),
    modes: const ['am', 'usb', 'lsb', 'auto'],
    longLabel: _mhzLabel,
    segments: [segment],
  );
}

/// Shortwave broadcasting in the [band], e.g. "49 m".
BandPlan _shortwavePlan(String id, String band, double lo, double hi) =>
    _broadcastPlan(id, l10n.scannerBandShortwave(band), band, lo, hi);

/// Long and medium wave (9 kHz raster, Europe) and the shortwave
/// broadcasting bands (5 kHz raster), all AM.
List<BandPlan> get broadcastBandPlans => _perLanguage(
  'broadcast',
  () => [
    _broadcastPlan('bclw', l10n.scannerBandLongWave, 'LW', 0.153, 0.2835, step: 9000),
    _broadcastPlan('bcmw', l10n.scannerBandMediumWave, 'MW', 0.531, 1.611, step: 9000),
    _shortwavePlan('bc75', '75 m', 3.900, 4.000),
    _shortwavePlan('bc49', '49 m', 5.900, 6.200),
    _shortwavePlan('bc41', '41 m', 7.200, 7.450),
    _shortwavePlan('bc31', '31 m', 9.400, 9.900),
    _shortwavePlan('bc25', '25 m', 11.600, 12.100),
    _shortwavePlan('bc22', '22 m', 13.570, 13.870),
    _shortwavePlan('bc19', '19 m', 15.100, 15.800),
    _shortwavePlan('bc16', '16 m', 17.480, 17.900),
    _shortwavePlan('bc15', '15 m', 18.900, 19.020),
    _shortwavePlan('bc13', '13 m', 21.450, 21.850),
    _shortwavePlan('bc11', '11 m', 25.670, 26.100),
  ],
);

/// Shortwave utility stations worth listening to: time signals (AM),
/// aeronautical weather (VOLMET) and the North Atlantic oceanic control
/// (Shanwick), DWD weather fax and RTTY (USB; their dial frequencies put the
/// tones at 1500-2300 Hz resp. 1275/1725 Hz - the decoders are stage 2).
BandPlan get hfUtilityBandPlan => _perLanguage('hfutil', () {
  final t = l10n;
  final chu = t.scannerUtilTimeSignal('CHU'), rwm = t.scannerUtilTimeSignal('RWM');
  final wwv = t.scannerUtilTimeSignal('WWV');
  final fax = t.scannerUtilWeatherFax('DWD'), rtty = t.scannerUtilWeatherRtty('DWD');
  final stations = [
    (chu, 3.330, 'am'),
    ('VOLMET Shannon', 3.413, 'usb'),
    (fax, 3.8531, 'usb'),
    (rtty, 4.5815, 'usb'),
    (rwm, 4.996, 'am'),
    (wwv, 5.000, 'am'),
    ('VOLMET RAF', 5.450, 'usb'),
    ('VOLMET Shannon', 5.505, 'usb'),
    ('Shanwick Oceanic', 5.598, 'usb'),
    ('Shanwick Oceanic', 5.616, 'usb'),
    (rtty, 7.6445, 'usb'),
    (chu, 7.850, 'am'),
    (fax, 7.8781, 'usb'),
    ('Shanwick Oceanic', 8.864, 'usb'),
    ('Shanwick Oceanic', 8.879, 'usb'),
    ('Shanwick Oceanic', 8.891, 'usb'),
    ('VOLMET Shannon', 8.957, 'usb'),
    (rwm, 9.996, 'am'),
    (wwv, 10.000, 'am'),
    (rtty, 11.0375, 'usb'),
    ('VOLMET RAF', 11.253, 'usb'),
    ('Shanwick Oceanic', 11.279, 'usb'),
    ('VOLMET Shannon', 13.264, 'usb'),
    ('Shanwick Oceanic', 13.306, 'usb'),
    (fax, 13.8806, 'usb'),
    (rtty, 14.4658, 'usb'),
    (chu, 14.670, 'am'),
    (rwm, 14.996, 'am'),
    (wwv, 15.000, 'am'),
  ];
  final segments = <BandSegment>[];
  for (final (name, mhz, mode) in stations) {
    final hz = _mhz(mhz);
    // AM both sides of the carrier, USB above the dial frequency; never
    // overlapping the previous station (RWM 9,996 / WWV 10,000).
    var low = mode == 'am' ? hz - 2000 : hz;
    if (segments.isNotEmpty && low < segments.last.highHz) low = segments.last.highHz;
    segments.add(
      BandSegment(
        low,
        mode == 'am' ? hz + 2000 : hz + 3000,
        '$name (${modeLabel(mode)})',
        mode: mode,
        bandwidthHz: mode == 'am' ? 6000 : 2700,
      ),
    );
  }
  return BandPlan(
    id: 'hfutil',
    title: t.scannerBandHfUtility,
    channels: [for (final (name, mhz, _) in stations) BandChannel(formatMhzAuto(_mhz(mhz)), _mhz(mhz), name: name)],
    modes: const ['usb', 'am', 'lsb', 'cw', 'auto'],
    longLabel: _mhzLabel,
    segments: segments,
    defaultFreqHz: _mhz(9.996),
  );
});

// --- Freier Band-Scan: the whole range of the stick, SDR style ---

/// The stick's range: the tuner's from 24 MHz up to 1766 MHz, below that
/// direct sampling, the RTL-SDR Blog V4's or an external upconverter (see
/// [hfTopHz]).
const worldLowHz = 150000, worldHighHz = 1766000000;

/// Raster in the gaps between known bands; shortwave gaps in AM 5 kHz.
const _gapStepHz = 25000, _hfGapStepHz = 5000;

/// What's where in Austria/Germany (CEPT), each with its usual modulation,
/// filter and raster - the amateur bands with their own band plans. Sorted,
/// not overlapping; [worldBandPlan] fills the gaps.
List<BandSegment> _worldSegments() {
  final t = l10n;
  BandSegment s(double lo, double hi, String name, String mode, {int bw = 0, int step = 12500, List<(String, int)> marks = const []}) =>
      BandSegment(_mhz(lo), _mhz(hi), name, mode: mode, bandwidthHz: bw, stepHz: step, marks: marks);
  final ham = {for (final p in hamBandPlans) p.id: p.segments};
  // Shortwave: broadcasting and amateur bands, by frequency (they don't
  // overlap).
  final hf = [
    for (final p in broadcastBandPlans) ...p.segments,
    for (final p in hfHamBandPlans) ...p.segments,
  ]..sort((a, b) => a.lowHz.compareTo(b.lowHz));
  return [
    ...hf,
    s(26.565, 27.360, t.scannerBandCb, 'fm', bw: 10000, step: 10000, marks: [('CB 9', _mhz(27.065)), ('CB 19', _mhz(27.185))]),
    s(27.360, 27.410, '${t.scannerBandCb} SSB', 'lsb', bw: 2700, step: 10000),
    ...ham['ham10']!,
    ...ham['ham6']!,
    s(87.5, 108.0, t.scannerSegFmBroadcast, 'wfm', bw: 200000, step: 100000),
    s(108.0, 118.0, t.scannerSegAirNavVorIls, 'am', bw: 6000, step: 50000),
    s(118.0, 137.0, t.scannerBandAir, 'am', bw: 8330, step: 25000, marks: [(t.scannerMarkEmergency, _mhz(121.5))]),
    s(137.0, 138.0, t.scannerSegWeatherSatellites, 'wfm', bw: 50000, step: 5000),
    s(138.0, 144.0, t.scannerSegLandMobile, 'fm', bw: 12500),
    ...ham['ham2']!,
    s(146.0, 149.0, t.scannerSegLandMobileBos, 'fm', bw: 12500),
    s(149.025, 149.125, 'Freenet', 'fm', bw: 12500),
    s(149.125, 156.0, t.scannerSegLandMobile, 'fm', bw: 12500),
    s(156.0, 162.05, t.scannerSegMarine(_f(156.8)), 'fm', bw: 12500, step: 25000, marks: [(t.scannerChannel('16'), _mhz(156.8))]),
    s(162.05, 174.0, t.scannerSegLandMobileRail, 'fm', bw: 12500),
    s(174.0, 230.0, t.scannerSegDab, 'wfm', bw: 200000, step: 100000),
    s(230.0, 400.0, t.scannerSegMilAir, 'am', bw: 8330, step: 25000, marks: [(t.scannerMarkEmergency, _mhz(243.0))]),
    s(400.0, 406.0, t.scannerSegRadiosondes, 'fm', bw: 12500, step: 10000),
    s(406.0, 406.1, t.scannerSegDistressBeacons, 'usb', bw: 2700, step: 5000),
    s(406.1, 430.0, t.scannerSegLandMobile, 'fm', bw: 12500),
    ...ham['ham70']!,
    s(440.0, 446.0, t.scannerSegLandMobileBos, 'fm', bw: 12500),
    // Raster from channel 1 (446,00625).
    BandSegment(446006250, _mhz(446.2), 'PMR446', mode: 'fm', bandwidthHz: 12500, stepHz: 12500,
        marks: [for (var n = 1; n <= 16; n++) ('PMR $n', 446006250 + (n - 1) * 12500)]),
    s(446.2, 470.0, '${t.scannerSegLandMobileRail} (DMR)', 'auto'),
    s(470.0, 790.0, t.scannerSegDvbt, 'wfm', bw: 200000, step: 1000000),
    s(790.0, 862.0, t.scannerSegLte, 'wfm', bw: 200000, step: 1000000),
    s(863.0, 870.0, t.scannerSegSensorsLora, 'fm', bw: 12500, step: 25000),
    s(870.0, 960.0, t.scannerSegGsm, 'wfm', bw: 200000, step: 200000),
    s(960.0, 1089.0, t.scannerSegAirNavDme, 'am', bw: 12500, step: 1000000),
    s(1089.0, 1091.0, t.scannerSegAdsb, 'am', bw: 12500, step: 1000000),
    s(1091.0, 1215.0, t.scannerSegAirNavDme, 'am', bw: 12500, step: 1000000),
    s(1215.0, 1240.0, t.scannerSegGnss, 'wfm', bw: 200000, step: 1000000),
    ...ham['ham23']!,
    s(1525.0, 1559.0, t.scannerSegSatPhone, 'usb', bw: 2700, step: 5000),
    s(1559.0, 1610.0, t.scannerSegGnss, 'wfm', bw: 200000, step: 1000000),
    s(1690.0, 1710.0, '${t.scannerSegWeatherSatellites} (HRPT)', 'wfm', bw: 200000, step: 100000),
  ];
}

/// The whole range as one plan: the known bands with their rasters and
/// settings, the gaps in [_gapStepHz] FM channels (named "", not drawn).
BandPlan get worldBandPlan => _perLanguage('world', () {
  final t = l10n;
  final segments = <BandSegment>[];
  // A gap: AM on the 5 kHz raster below [hfTopHz], FM channels above.
  void gap(int from, int to) {
    if (from < hfTopHz) {
      final end = to < hfTopHz ? to : hfTopHz;
      final start = (from + _hfGapStepHz - 1) ~/ _hfGapStepHz * _hfGapStepHz;
      if (start < end) segments.add(BandSegment(start, end, '', mode: 'am', stepHz: _hfGapStepHz));
      from = end;
    }
    if (from >= to) return;
    final start = (from + _gapStepHz - 1) ~/ _gapStepHz * _gapStepHz;
    if (start < to) segments.add(BandSegment(start, to, '', mode: 'fm', bandwidthHz: 0, stepHz: _gapStepHz));
  }

  var at = worldLowHz;
  for (final seg in _worldSegments()) {
    if (seg.lowHz > at) gap(at, seg.lowHz);
    segments.add(seg);
    at = seg.highHz;
  }
  if (at < worldHighHz) gap(at, worldHighHz + 1);
  return BandPlan(
    id: 'world',
    title: t.scannerBandWorld,
    channels: _segmentChannels(segments),
    modes: const ['fm', 'am', 'usb', 'lsb', 'cw', 'wfm', 'auto', 'dmr'],
    longLabel: _mhzLabel,
    segments: segments,
    defaultFreqHz: _mhz(145.500),
    jumpTargets: [
      (t.scannerBandMediumWave, _mhz(0.999)),
      ('${t.scannerBandHam('80 m')} (${_f(3.700)})', _mhz(3.700)),
      (t.scannerBandShortwave('49 m'), _mhz(6.000)),
      ('${t.scannerBandHam('40 m')} (FT8 ${_f(7.074)})', _mhz(7.074)),
      (t.scannerBandShortwave('41 m'), _mhz(7.300)),
      ('Shanwick Oceanic ${_f(8.864)}', _mhz(8.864)),
      (t.scannerBandShortwave('31 m'), _mhz(9.600)),
      ('${t.scannerUtilTimeSignal('RWM')} ${_f(9.996)}', _mhz(9.996)),
      (t.scannerBandShortwave('25 m'), _mhz(11.800)),
      ('${t.scannerBandHam('20 m')} (FT8 ${_f(14.074)})', _mhz(14.074)),
      (t.scannerBandShortwave('19 m'), _mhz(15.400)),
      (t.scannerBandShortwave('13 m'), _mhz(21.600)),
      ('${t.scannerBandCb} ${t.scannerChannel('19')}', _mhz(27.185)),
      ('${t.scannerBandHam('10 m')} (FT8 ${_f(28.074)})', _mhz(28.074)),
      (t.scannerBandHam('6 m'), _mhz(50.150)),
      (t.scannerSegFmBroadcast, _mhz(88.0)),
      (t.scannerBandAir, _mhz(118.0)),
      ('${t.scannerSegWeatherSatellites} 137 MHz', _mhz(137.1)),
      ('${t.scannerBandHam('2 m')} (${_f(145.500)})', _mhz(145.500)),
      ('APRS ${_f(144.800)}', _mhz(144.800)),
      ('ISS ${_f(145.800)}', _mhz(145.800)),
      ('Freenet', _mhz(149.025)),
      (t.scannerJumpMarine, _mhz(156.800)),
      ('DAB+ Band III', _mhz(174.928)),
      (t.scannerJumpMilAir, _mhz(243.0)),
      ('${t.scannerSegRadiosondes} 400–406', _mhz(403.0)),
      ('${t.scannerBandHam('70 cm')} (${_f(433.500)})', _mhz(433.500)),
      ('LPD 433', _mhz(433.075)),
      ('${t.scannerSensors} ${_f(433.920)}', _mhz(433.920)),
      (t.scannerJumpRepeaters70(_f(438.650)), _mhz(438.650)),
      ('PMR446 ${t.scannerChannel('1')}', 446006250),
      ('${t.scannerSensors} 868', _mhz(868.3)),
      ('ADS-B 1090', _mhz(1090.0)),
      ('${t.scannerBandHam('23 cm')} (${_f(1297.500)})', _mhz(1297.500)),
    ],
  );
});

/// Short names of the modulations (the same in German and English).
String modeLabel(String mode) => switch (mode) {
  'auto' => 'Auto',
  'am' => 'AM',
  'fm' => 'FM',
  'usb' => 'USB',
  'lsb' => 'LSB',
  'cw' => 'CW',
  'wfm' => 'WFM',
  'dmr' => 'DMR',
  _ => mode.toUpperCase(),
};
