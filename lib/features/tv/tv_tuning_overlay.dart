import 'package:flutter/material.dart';

import '../../core/loading_wave.dart';

/// While a channel tunes: Home System's start animation (logo and the
/// loading wave, as on the start screen) over the picture's place instead
/// of black or the old picture. Appears at once when [visible] turns on
/// and fades out when it turns off - at the new channel's first picture,
/// which shows through as it fades.
///
/// Light on weak boxes: nothing is built while hidden (no ticker runs),
/// the logo is decoded small and in advance ([precache]), only the wave
/// repaints. It never takes the remote's keys or the mouse.
class TvTuningOverlay extends StatefulWidget {
  const TvTuningOverlay({super.key, required this.visible});

  final bool visible;

  /// The logo as shown - 1024 px in the assets, decoded no bigger than
  /// needed.
  static const _logo = ResizeImage(AssetImage('assets/icon/home_system_logo.png'), width: 256, height: 256);

  /// Decodes the logo before the first channel switch needs it.
  static Future<void> precache(BuildContext context) async {
    try {
      await precacheImage(_logo, context);
    } catch (_) {}
  }

  @override
  State<TvTuningOverlay> createState() => _TvTuningOverlayState();
}

class _TvTuningOverlayState extends State<TvTuningOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
    value: widget.visible ? 1 : 0,
  )..addStatusListener(_onStatus);

  void _onStatus(AnimationStatus status) {
    // Gone completely: the wave and its ticker go too.
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(TvTuningOverlay old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (widget.visible) {
      // At once - no fade in, the switch is already under way.
      _fade.value = 1;
    } else {
      _fade.reverse();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_fade.isDismissed && !widget.visible) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeFocus(
        child: FadeTransition(
          opacity: _fade,
          child: const ColoredBox(
            color: Colors.black,
            child: Align(
              // A little above the middle - the info bar takes the bottom.
              alignment: Alignment(0, -0.3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image(image: TvTuningOverlay._logo, width: 128, height: 128, gaplessPlayback: true),
                  SizedBox(height: 18),
                  Text(
                    'Home System',
                    style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Powered by jaycloud.at',
                    style: TextStyle(color: Colors.green, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 28),
                  LoadingWave(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
