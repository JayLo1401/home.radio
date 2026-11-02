/// A listening band for the ScannerScreen: its channels and how they're
/// usually modulated. Nothing here is saved as a station or favorite - the
/// listening bands are deliberately separate from everyday radio.
class BandChannel {
  /// Short label shown on the channel button, e.g. "19" or "121,500".
  final String label;
  final int freqHz;

  const BandChannel(this.label, this.freqHz);
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

  const BandPlan({
    required this.id,
    required this.title,
    required this.channels,
    required this.modes,
    required this.longLabel,
  });

  int get lowHz => channels.first.freqHz;
  int get highHz => channels.last.freqHz;
}

String formatMhz(int freqHz, {int decimals = 3}) => (freqHz / 1e6).toStringAsFixed(decimals).replaceAll('.', ',');

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
    final list = [
      if (all80)
        for (var n = 41; n <= 80; n++) BandChannel('$n', (26565 + (n - 41) * 10) * 1000),
      for (var i = 0; i < 40; i++) BandChannel('${i + 1}', ch1to40[i] * 1000),
    ]..sort((a, b) => a.freqHz.compareTo(b.freqHz));
    return list;
  }(),
  modes: const ['auto', 'fm', 'am', 'usb', 'lsb'],
  longLabel: (c) => 'Kanal ${c.label}',
);

/// Civil airband voice, 118.000-136.975 MHz on the 25 kHz raster (8.33 kHz
/// channels fall inside those), AM only.
final airBandPlan = BandPlan(
  id: 'air',
  title: 'Flugfunk',
  channels: [for (var khz = 118000; khz <= 136975; khz += 25) BandChannel(formatMhz(khz * 1000), khz * 1000)],
  modes: const ['am'],
  longLabel: (c) => '${c.label} MHz',
);

/// Military airband, 225.000-399.975 MHz on the 25 kHz raster, AM.
final milBandPlan = BandPlan(
  id: 'mil',
  title: 'Militärfunk',
  channels: [for (var khz = 225000; khz <= 399975; khz += 25) BandChannel(formatMhz(khz * 1000), khz * 1000)],
  modes: const ['am'],
  longLabel: (c) => '${c.label} MHz',
);

/// A raster of frequencies (kHz) as channels labelled with the frequency.
List<BandChannel> _raster(int fromKhz, int toKhz, int stepHz, {int decimals = 3}) => [
  for (var hz = fromKhz * 1000; hz <= toKhz * 1000; hz += stepHz) BandChannel(formatMhz(hz, decimals: decimals), hz),
];

/// The amateur radio bands this stick (R820T2, from ~24 MHz) can receive -
/// shortwave below would need direct sampling. Rasters: SSB-heavy bands in
/// 5 kHz steps (fine tuning on the waterfall), FM bands in the usual 12.5 or
/// 25 kHz channel spacing. Default modulation first.
final hamBandPlans = [
  BandPlan(
    id: 'ham10',
    title: 'Amateurfunk 10 m',
    channels: _raster(28000, 29700, 5000),
    modes: const ['usb', 'lsb', 'fm', 'am', 'auto'],
    longLabel: (c) => '${c.label} MHz',
  ),
  BandPlan(
    id: 'ham6',
    title: 'Amateurfunk 6 m',
    channels: _raster(50000, 52000, 5000),
    modes: const ['usb', 'lsb', 'fm', 'am', 'auto'],
    longLabel: (c) => '${c.label} MHz',
  ),
  BandPlan(
    id: 'ham2',
    title: 'Amateurfunk 2 m',
    channels: _raster(144000, 146000, 12500, decimals: 4),
    modes: const ['fm', 'usb', 'lsb', 'am', 'auto'],
    longLabel: (c) => '${c.label} MHz',
  ),
  BandPlan(
    id: 'ham70',
    title: 'Amateurfunk 70 cm',
    channels: _raster(430000, 440000, 12500, decimals: 4),
    modes: const ['fm', 'usb', 'lsb', 'am', 'auto'],
    longLabel: (c) => '${c.label} MHz',
  ),
  BandPlan(
    id: 'ham23',
    title: 'Amateurfunk 23 cm',
    channels: _raster(1240000, 1300000, 25000),
    modes: const ['fm', 'usb', 'lsb', 'am', 'auto'],
    longLabel: (c) => '${c.label} MHz',
  ),
];

/// Short names for switching between [hamBandPlans].
String hamBandShort(BandPlan p) => p.title.replaceFirst('Amateurfunk ', '');

/// German names of the modulations.
String modeLabel(String mode) => switch (mode) {
  'auto' => 'Auto',
  'am' => 'AM',
  'fm' => 'FM',
  'usb' => 'USB',
  'lsb' => 'LSB',
  _ => mode.toUpperCase(),
};
