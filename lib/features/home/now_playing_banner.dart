import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    final displayName = this.displayName;
    return Container(
      height: 110,
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
                      Text(
                        programNumber != null ? '$programNumber · $displayName' : displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        errorMessage ??
                            subtitle ??
                            (isPlaying ? 'Wiedergabe läuft' : 'Pausiert'),
                        style: TextStyle(
                          color: errorMessage != null ? Colors.redAccent : Colors.white70,
                          fontSize: 16,
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
    final color = Theme.of(context).colorScheme.primary;
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
        child: CachedNetworkImage(
          imageUrl: logoUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
        ),
      );
    }
    return placeholder;
  }
}
