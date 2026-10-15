/// Bitrate/codec of whatever's playing - internet radio (see
/// AudioPlayerService.qualityStream) or DAB+ (the decoder's format report),
/// shown discreetly in the Now Playing banner.
class AudioQuality {
  const AudioQuality({required this.kbps, this.codec});

  final int kbps;

  /// Short display name, e.g. "MP3", "AAC", "HE-AAC v2".
  final String? codec;

  /// Parses welle.io's DAB+ format summary, e.g. "HE-AAC v2, 48 kHz Stereo
  /// @ 88 kbit/s" (AUDIO_SERVICE_FORMAT::GetSummary).
  static AudioQuality? fromDabFormat(String format) {
    final kbps = int.tryParse(RegExp(r'@\s*(\d+)\s*kbit/s').firstMatch(format)?.group(1) ?? '');
    if (kbps == null || kbps <= 0) return null;
    final codec = format.split(',').first.trim();
    return AudioQuality(kbps: kbps, codec: codec.isEmpty ? null : codec);
  }

  /// How good this sounds, 0 (poor) .. 1 (excellent) - not the raw bitrate:
  /// modern codecs sound better per kbit than MP3 (64 kbps HE-AAC, typical
  /// for DAB+, is roughly on par with 128 kbps MP3), so the bitrate is
  /// weighted by codec into an "MP3-equivalent" first. ≤64 equivalent counts
  /// as poor, ≥192 as excellent.
  double get score {
    final factor = switch (codec?.toUpperCase()) {
      'HE-AAC V2' => 2.5,
      'HE-AAC' => 2.0,
      'OPUS' => 2.0,
      'AAC' || 'AAC-LC' => 1.4,
      'OGG' => 1.3,
      'FLAC' => 10.0,
      _ => 1.0, // MP3 or unknown
    };
    return ((kbps * factor - 64) / (192 - 64)).clamp(0.0, 1.0);
  }

  String get label => codec == null ? '$kbps kbps' : '$kbps kbps · $codec';

  @override
  bool operator ==(Object other) => other is AudioQuality && other.kbps == kbps && other.codec == codec;

  @override
  int get hashCode => Object.hash(kbps, codec);
}
