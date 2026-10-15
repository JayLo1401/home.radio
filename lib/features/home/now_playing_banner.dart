import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/retrying_network_image.dart';
import '../../data/models/audio_quality.dart';

/// Bottom banner showing the currently playing station, logo and metadata.
/// Source-agnostic (internet radio vs. DAB+, favorite or a DAB+ station
/// played directly from "Alle DAB+ Sender" without being one - see
/// FavoritesSidebar) - the caller resolves whatever's actually playing into
/// these plain fields; [programNumber] is null for the latter case.
class NowPlayingBanner extends StatelessWidget {
  final int? programNumber;
  final String? displayName;
  final String? logoUrl;
  final String? logoLocalPath;
  final bool isPlaying;
  final bool isBuffering;
  final String? subtitle;
  final String? errorMessage;
  final double? snrDb;

  /// Bitrate/codec of what's playing (internet radio or DAB+), shown
  /// discreetly next to the station name - null while unknown/not playing.
  final AudioQuality? quality;

  const NowPlayingBanner({
    super.key,
    required this.programNumber,
    required this.displayName,
    required this.logoUrl,
    required this.logoLocalPath,
    required this.isPlaying,
    this.isBuffering = false,
    this.subtitle,
    this.errorMessage,
    this.snrDb,
    this.quality,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = this.displayName;
    return Container(
      height: 122,
      color: Colors.black.withValues(alpha: 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: displayName == null
          ? const Center(
              child: Text('Kein Sender ausgewählt',
                  style: TextStyle(color: Colors.white54, fontSize: 20)),
            )
          : Row(
              children: [
                _BannerLogo(logoUrl: logoUrl, logoLocalPath: logoLocalPath),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              programNumber != null ? '$programNumber · $displayName' : displayName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (snrDb != null) ...[
                            const SizedBox(width: 10),
                            Icon(
                              snrDb! >= 12
                                  ? Icons.signal_cellular_alt
                                  : (snrDb! >= 6 ? Icons.signal_cellular_alt_2_bar : Icons.signal_cellular_alt_1_bar),
                              color: snrDb! >= 12
                                  ? Colors.greenAccent
                                  : (snrDb! >= 6 ? Colors.orangeAccent : Colors.redAccent),
                              size: 28,
                            ),
                          ],
                          if (quality != null) ...[
                            const SizedBox(width: 12),
                            _QualityLabel(quality: quality!),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        errorMessage ??
                            subtitle ??
                            (isPlaying ? 'Wiedergabe läuft' : 'Pausiert'),
                        style: TextStyle(
                          color: errorMessage != null ? Colors.redAccent : Colors.white70,
                          fontSize: 22,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (isBuffering)
                  const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                else if (isPlaying)
                  const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: _PlayingPulse(),
                  ),
              ],
            ),
    );
  }
}

/// "88 kbps · HE-AAC v2" - deliberately understated (small, thin outline,
/// muted colour) so it's there at a glance without competing with the
/// station name. Colour runs red (poor) through yellow to green (good) by
/// [AudioQuality.score], which accounts for the codec, not just the number.
class _QualityLabel extends StatelessWidget {
  const _QualityLabel({required this.quality});

  final AudioQuality quality;

  @override
  Widget build(BuildContext context) {
    // Hue 0 (red) .. 120 (green); low saturation keeps it muted.
    final color = HSVColor.fromAHSV(1, 120 * quality.score, 0.55, 0.9).toColor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        quality.label,
        style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Small looping equalizer-bar animation, shown only while audio is
/// actually playing (not during buffering/paused/error states).
class _PlayingPulse extends StatefulWidget {
  const _PlayingPulse();

  @override
  State<_PlayingPulse> createState() => _PlayingPulseState();
}

class _PlayingPulseState extends State<_PlayingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const color = Colors.greenAccent;
    return SizedBox(
      width: 28,
      height: 24,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(3, (i) {
              final phase = _controller.value * 2 * 3.14159265 + i * 2.0;
              final height = 6 + (1 + math.sin(phase)) * 8;
              return Container(
                width: 4,
                height: height,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class _BannerLogo extends StatelessWidget {
  final String? logoUrl;
  final String? logoLocalPath;
  const _BannerLogo({required this.logoUrl, required this.logoLocalPath});

  @override
  Widget build(BuildContext context) {
    const size = 80.0;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.radio, color: Colors.white38, size: 36),
    );
    if (logoLocalPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(File(logoLocalPath!),
            width: size, height: size, fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder),
      );
    }
    if (logoUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: RetryingNetworkImage(
          imageUrl: logoUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_) => placeholder,
          errorWidget: (_) => placeholder,
        ),
      );
    }
    return placeholder;
  }
}
