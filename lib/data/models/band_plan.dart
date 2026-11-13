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

  const BandPlan({
    required this.id,
    required this.title,
    required this.channels,
    required this.modes,
    required this.longLabel,
    this.segments = const [],
    this.defaultFreqHz,
    this.jumpTargets = const [],
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

String formatMhz(int freqHz, {int decimals = 3}) => (freqHz / 1e6).toStringAsFixed(decimals).replaceAll('.', ',');

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

/// CB radio: channels 1-40 (26.965-27.405 MHz, the CEPT plan with its
/// historic gaps/swaps), with [all80] also 41-80 (26.565-26.955 MHz, 10 kHz
/// apart, allowed in Germany; Austria uses 1-40). Sorted by frequency.
BandPlan cbBandPlan({bool all80 = false}) => BandPlan(
  id: 'cb',
  title: 'CB-Funk',
  channels: () {
    const ch1to40 = [
      26965, 26975, 26985, 27005, 27015, 27025, 27035, 27055, 27065, 27075, //
      27085, 27105, 27115, 27125, 27135, 27155, 27165, 27175, 27185, 27205,
      27215, 27225, 27255, 27235, 27245, 27265, 27275, 27285, 27295, 27305,
      27315, 27325, 27335, 27345, 27355, 27365, 27375, 27385, 27395, 27405,
    ];
    const names = {9: 'Notruf', 19: 'Fernfahrer'};
    final list = [
      if (all80)
        for (var n = 41; n <= 80; n++) BandChannel('$n', (26565 + (n - 41) * 10) * 1000),
      for (var i = 0; i < 40; i++) BandChannel('${i + 1}', ch1to40[i] * 1000, name: names[i + 1]),
    ]..sort((a, b) => a.freqHz.compareTo(b.freqHz));
    return list;
  }(),
  modes: const ['auto', 'fm', 'am', 'usb', 'lsb'],
  longLabel: (c) => 'Kanal ${c.label}${c.name == null ? '' : ' · ${c.name}'}',
  segments: [
    BandSegment(_mhz(26.560), _mhz(27.360), 'Sprechfunk FM (Kanal 9 Notruf, 19 Fernfahrer)', mode: 'fm', bandwidthHz: 10000),
    BandSegment(_mhz(27.360), _mhz(27.410), 'SSB-Bereich (Kanal 36–40)', mode: 'lsb', bandwidthHz: 2700),
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
  modes: const ['fm', 'auto', 'am'],
  longLabel: (c) => 'Kanal ${c.label}',
  segments: [BandSegment(_mhz(446.0), _mhz(446.2), 'PMR446 (FM)', mode: 'fm', bandwidthHz: 12500)],
  defaultFreqHz: 446006250,
);

/// Civil airband voice, 118.000-136.975 MHz on the 25 kHz raster (8.33 kHz
/// channels fall inside those), AM only.
final airBandPlan = BandPlan(
  id: 'air',
  title: 'Flugfunk',
  channels: [for (var khz = 118000; khz <= 136975; khz += 25) BandChannel(formatMhz(khz * 1000), khz * 1000)],
  modes: const ['am'],
  longLabel: (c) => '${c.label} MHz',
  segments: [BandSegment(_mhz(118), _mhz(137), 'Flugfunk (AM)', mode: 'am', bandwidthHz: 8330)],
);

/// Military airband, 225.000-399.975 MHz on the 25 kHz raster, AM.
final milBandPlan = BandPlan(
  id: 'mil',
  title: 'Militärfunk',
  channels: [for (var khz = 225000; khz <= 399975; khz += 25) BandChannel(formatMhz(khz * 1000), khz * 1000)],
  modes: const ['am'],
  longLabel: (c) => '${c.label} MHz',
  segments: [BandSegment(_mhz(225), _mhz(400), 'Militärischer Flugfunk (AM)', mode: 'am', bandwidthHz: 8330)],
);

const _hamModes = ['usb', 'lsb', 'cw', 'fm', 'am', 'auto'];

BandPlan _hamPlan(String id, String title, int defaultHz, List<BandSegment> segments) => BandPlan(
  id: id,
  title: title,
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

/// The amateur radio bands this stick (R820T2, from ~24 MHz) can receive -
/// shortwave below would need direct sampling. Built from the IARU Region 1
/// band plans: each part of a band with its own raster and the settings the
/// scanner switches to there.
final hamBandPlans = [
  _hamPlan('ham10', 'Amateurfunk 10 m', _mhz(28.074), [
    _cw(28.000, 28.070, 'Telegrafie'),
    _ssb(28.070, 28.190, 'Digitale Betriebsarten', step: 1000, marks: [('FT8', _mhz(28.074))]),
    _cw(28.190, 28.225, 'Baken', marks: [('NCDXF', _mhz(28.200))]),
    _ssb(28.225, 28.300, 'Baken & alle Betriebsarten'),
    _ssb(28.300, 29.000, 'Sprechfunk (SSB)'),
    BandSegment(_mhz(29.000), _mhz(29.100), 'AM-Sprechfunk', mode: 'am', bandwidthHz: 6000, stepHz: 5000),
    _nfm(29.100, 29.200, 'FM-Direkt', step: 10000, bw: 10000),
    _nfm(29.200, 29.300, 'Digital (Packet)', step: 10000, bw: 10000),
    _ssb(29.300, 29.510, 'Satelliten'),
    _nfm(29.510, 29.600, 'FM-Relais-Eingaben', step: 10000, bw: 10000),
    _nfm(29.600, 29.620, 'FM-Direkt (29,600 Anruf)', step: 10000, bw: 10000, marks: [('Anruf', _mhz(29.600))]),
    _nfm(29.620, 29.700, 'FM-Relais-Ausgaben', step: 10000, bw: 10000),
  ]),
  _hamPlan('ham6', 'Amateurfunk 6 m', _mhz(50.313), [
    _cw(50.000, 50.100, 'Telegrafie & Baken'),
    _ssb(50.100, 50.500, 'Sprechfunk (SSB, 50,150 Anruf)', marks: [('Anruf', _mhz(50.150)), ('FT8', _mhz(50.313))]),
    _ssb(50.500, 51.100, 'Digital & alle Betriebsarten', step: 5000),
    _nfm(51.100, 51.410, 'FM-Relais-Eingaben', step: 10000),
    _nfm(51.410, 51.600, 'FM-Direkt (51,510 Anruf)', step: 10000, marks: [('Anruf', _mhz(51.510))]),
    _nfm(51.600, 51.810, 'Alle Betriebsarten', step: 10000),
    _nfm(51.810, 52.000, 'FM-Relais-Ausgaben', step: 10000),
  ]),
  _hamPlan('ham2', 'Amateurfunk 2 m', _mhz(145.500), [
    _cw(144.000, 144.110, 'Telegrafie (EME)'),
    _ssb(144.110, 144.400, 'Sprechfunk (SSB, 144,300 Anruf)', marks: [('FT8', _mhz(144.174)), ('Anruf', _mhz(144.300))]),
    _cw(144.400, 144.500, 'Baken'),
    _nfm(144.500, 144.800, 'Alle Betriebsarten (SSTV, Digital)'),
    _nfm(144.800, 145.000, 'Digital (144,800 APRS)', marks: [('APRS', _mhz(144.800))]),
    _nfm(145.000, 145.200, 'FM-Relais-Eingaben'),
    _nfm(145.200, 145.600, 'FM-Direkt (145,500 Anruf)', marks: [('Anruf', _mhz(145.500))]),
    _nfm(145.600, 145.800, 'FM-Relais-Ausgaben'),
    _nfm(
      145.800,
      146.000,
      'Satelliten (145,800 ISS)',
      marks: [('ISS', _mhz(145.800)), (aprsIssName, _mhz(145.825))],
    ),
  ]),
  _hamPlan('ham70', 'Amateurfunk 70 cm', _mhz(433.500), [
    _nfm(430.000, 432.000, 'Digital & Relais-Eingaben'),
    _cw(432.000, 432.100, 'Telegrafie (EME)'),
    _ssb(432.100, 432.400, 'Sprechfunk (SSB, 432,200 Anruf)', marks: [('FT8', _mhz(432.174)), ('Anruf', _mhz(432.200))]),
    _cw(432.400, 432.500, 'Baken'),
    _nfm(432.500, 433.000, 'Alle Betriebsarten'),
    _nfm(433.000, 433.400, 'FM-Relais-Eingaben, LPD-Funkgeräte'),
    _nfm(433.400, 433.600, 'FM-Direkt (433,500 Anruf), LPD', marks: [('Anruf', _mhz(433.500))]),
    _nfm(433.600, 435.000, 'LPD-Funkgeräte & ISM (433,920 Sensoren)', marks: [('Sensoren', _mhz(433.920))]),
    _nfm(435.000, 438.000, 'Satelliten'),
    _nfm(438.000, 438.650, 'Digital (DMR, C4FM)'),
    _nfm(438.650, 439.450, 'Relais-Ausgaben (auch DMR/C4FM)'),
    _nfm(439.450, 440.000, 'Digital'),
  ]),
  _hamPlan('ham23', 'Amateurfunk 23 cm', _mhz(1297.500), [
    _nfm(1240.000, 1243.250, 'Digital', step: 25000),
    BandSegment(_mhz(1243.250), _mhz(1260), 'Amateurfernsehen (ATV)', mode: 'fm', stepHz: 250000),
    _nfm(1260.000, 1270.000, 'Satelliten (Uplink)', step: 25000),
    BandSegment(_mhz(1270), _mhz(1291), 'ATV & Digital', mode: 'fm', stepHz: 250000),
    _nfm(1291.000, 1291.500, 'FM-Relais-Eingaben', step: 25000),
    _nfm(1291.500, 1296.000, 'Alle Betriebsarten', step: 25000),
    _cw(1296.000, 1296.150, 'Telegrafie (EME)'),
    _ssb(1296.150, 1296.800, 'Sprechfunk (SSB, 1296,200 Anruf)', marks: [('Anruf', _mhz(1296.200))]),
    _cw(1296.800, 1297.000, 'Baken'),
    _nfm(1297.000, 1297.500, 'FM-Relais-Ausgaben', step: 25000),
    _nfm(1297.500, 1298.000, 'FM-Direkt (1297,500 Anruf)', step: 25000, marks: [('Anruf', _mhz(1297.500))]),
    _nfm(1298.000, 1300.000, 'Digital', step: 25000),
  ]),
];

const aprsIssName = 'ISS APRS';

/// APRS frequencies - the scanner turns its packet decoder on there
/// (Europe 144,800, the ISS digipeater 145,825).
const aprsFrequenciesHz = {144800000, 145825000};

/// Short names for switching between [hamBandPlans].
String hamBandShort(BandPlan p) => p.title.replaceFirst('Amateurfunk ', '');

// --- Freier Band-Scan: the whole range of the stick, SDR style ---

/// The tuner's range (R820T/R828D without direct sampling).
const worldLowHz = 24000000, worldHighHz = 1766000000;

/// Raster in the gaps between known bands.
const _gapStepHz = 25000;

/// What's where in Austria/Germany (CEPT), each with its usual modulation,
/// filter and raster - the amateur bands with their own band plans. Sorted,
/// not overlapping; [worldBandPlan] fills the gaps.
final List<BandSegment> _worldSegments = () {
  BandSegment s(double lo, double hi, String name, String mode, {int bw = 0, int step = 12500, List<(String, int)> marks = const []}) =>
      BandSegment(_mhz(lo), _mhz(hi), name, mode: mode, bandwidthHz: bw, stepHz: step, marks: marks);
  final ham = {for (final p in hamBandPlans) p.id: p.segments};
  return [
    s(26.565, 27.360, 'CB-Funk', 'fm', bw: 10000, step: 10000, marks: [('CB 9', _mhz(27.065)), ('CB 19', _mhz(27.185))]),
    s(27.360, 27.410, 'CB-Funk SSB', 'lsb', bw: 2700, step: 10000),
    ...ham['ham10']!,
    ...ham['ham6']!,
    s(87.5, 108.0, 'UKW-Rundfunk', 'wfm', bw: 200000, step: 100000),
    s(108.0, 118.0, 'Flugnavigation (VOR/ILS)', 'am', bw: 6000, step: 50000),
    s(118.0, 137.0, 'Flugfunk', 'am', bw: 8330, step: 25000, marks: [('Notruf', _mhz(121.5))]),
    s(137.0, 138.0, 'Wettersatelliten', 'wfm', bw: 50000, step: 5000),
    s(138.0, 144.0, 'Betriebsfunk', 'fm', bw: 12500),
    ...ham['ham2']!,
    s(146.0, 149.0, 'Betriebsfunk / BOS', 'fm', bw: 12500),
    s(149.025, 149.125, 'Freenet', 'fm', bw: 12500),
    s(149.125, 156.0, 'Betriebsfunk', 'fm', bw: 12500),
    s(156.0, 162.05, 'Seefunk (Kanal 16 = 156,800)', 'fm', bw: 12500, step: 25000, marks: [('Kanal 16', _mhz(156.8))]),
    s(162.05, 174.0, 'Betriebsfunk / Bahnfunk', 'fm', bw: 12500),
    s(174.0, 230.0, 'DAB+ Band III (digital, nicht hörbar)', 'wfm', bw: 200000, step: 100000),
    s(230.0, 400.0, 'Militärischer Flugfunk', 'am', bw: 8330, step: 25000, marks: [('Notruf', _mhz(243.0))]),
    s(400.0, 406.0, 'Wettersonden', 'fm', bw: 12500, step: 10000),
    s(406.0, 406.1, 'Notfunkbaken (digital)', 'usb', bw: 2700, step: 5000),
    s(406.1, 430.0, 'Betriebsfunk', 'fm', bw: 12500),
    ...ham['ham70']!,
    s(440.0, 446.0, 'Betriebsfunk / BOS', 'fm', bw: 12500),
    // Raster from channel 1 (446,00625).
    BandSegment(446006250, _mhz(446.2), 'PMR446', mode: 'fm', bandwidthHz: 12500, stepHz: 12500,
        marks: [for (var n = 1; n <= 16; n++) ('PMR $n', 446006250 + (n - 1) * 12500)]),
    s(446.2, 470.0, 'Betriebsfunk / Bahnfunk (DMR)', 'fm', bw: 12500),
    s(470.0, 790.0, 'Fernsehen DVB-T2 (digital)', 'wfm', bw: 200000, step: 1000000),
    s(790.0, 862.0, 'Mobilfunk LTE (digital)', 'wfm', bw: 200000, step: 1000000),
    s(863.0, 870.0, 'Funksensoren / LoRa 868', 'fm', bw: 12500, step: 25000),
    s(870.0, 960.0, 'Mobilfunk / GSM-R (digital)', 'wfm', bw: 200000, step: 200000),
    s(960.0, 1089.0, 'Flugnavigation (DME)', 'am', bw: 12500, step: 1000000),
    s(1089.0, 1091.0, 'ADS-B 1090 (→ Flugzeuge)', 'am', bw: 12500, step: 1000000),
    s(1091.0, 1215.0, 'Flugnavigation (DME)', 'am', bw: 12500, step: 1000000),
    s(1215.0, 1240.0, 'Satellitennavigation (GNSS)', 'wfm', bw: 200000, step: 1000000),
    ...ham['ham23']!,
    s(1525.0, 1559.0, 'Satelliten-Telefonie (Inmarsat)', 'usb', bw: 2700, step: 5000),
    s(1559.0, 1610.0, 'Satellitennavigation (GNSS)', 'wfm', bw: 200000, step: 1000000),
    s(1690.0, 1710.0, 'Wettersatelliten (HRPT)', 'wfm', bw: 200000, step: 100000),
  ];
}();

/// The whole range as one plan: the known bands with their rasters and
/// settings, the gaps in [_gapStepHz] FM channels (named "", not drawn).
final BandPlan worldBandPlan = () {
  final segments = <BandSegment>[];
  var at = worldLowHz;
  for (final seg in _worldSegments) {
    if (seg.lowHz > at) {
      final start = (at + _gapStepHz - 1) ~/ _gapStepHz * _gapStepHz;
      segments.add(BandSegment(start, seg.lowHz, '', mode: 'fm', bandwidthHz: 0, stepHz: _gapStepHz));
    }
    segments.add(seg);
    at = seg.highHz;
  }
  if (at < worldHighHz) segments.add(BandSegment(at, worldHighHz + 1, '', mode: 'fm', stepHz: _gapStepHz));
  return BandPlan(
    id: 'world',
    title: 'Freier Band-Scan',
    channels: _segmentChannels(segments),
    modes: const ['fm', 'am', 'usb', 'lsb', 'cw', 'wfm', 'auto'],
    longLabel: _mhzLabel,
    segments: segments,
    defaultFreqHz: _mhz(145.500),
    jumpTargets: [
      ('CB-Funk Kanal 19', _mhz(27.185)),
      ('Amateurfunk 10 m (FT8 28,074)', _mhz(28.074)),
      ('Amateurfunk 6 m', _mhz(50.150)),
      ('UKW-Rundfunk', _mhz(88.0)),
      ('Flugfunk', _mhz(118.0)),
      ('Wettersatelliten 137 MHz', _mhz(137.1)),
      ('Amateurfunk 2 m (145,500)', _mhz(145.500)),
      ('APRS 144,800', _mhz(144.800)),
      ('ISS 145,800', _mhz(145.800)),
      ('Freenet', _mhz(149.025)),
      ('Seefunk Kanal 16', _mhz(156.800)),
      ('DAB+ Band III', _mhz(174.928)),
      ('Militärflugfunk', _mhz(243.0)),
      ('Wettersonden 400–406', _mhz(403.0)),
      ('Amateurfunk 70 cm (433,500)', _mhz(433.500)),
      ('LPD 433', _mhz(433.075)),
      ('Funksensoren 433,920', _mhz(433.920)),
      ('Relais 70 cm (438,650)', _mhz(438.650)),
      ('PMR446 Kanal 1', 446006250),
      ('Funksensoren 868', _mhz(868.3)),
      ('ADS-B 1090', _mhz(1090.0)),
      ('Amateurfunk 23 cm (1297,500)', _mhz(1297.500)),
    ],
  );
}();

/// German names of the modulations.
String modeLabel(String mode) => switch (mode) {
  'auto' => 'Auto',
  'am' => 'AM',
  'fm' => 'FM',
  'usb' => 'USB',
  'lsb' => 'LSB',
  'cw' => 'CW',
  'wfm' => 'WFM',
  _ => mode.toUpperCase(),
};
