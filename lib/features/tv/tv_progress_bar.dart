import 'package:flutter/material.dart';

import '../../data/services/enigma2_service.dart';

/// The bar's colour for a programme [progress] gone by (0..1): green while
/// it has just started, yellow halfway, red when it's almost over.
Color programmeProgressColor(double progress) {
  const green = Color(0xFF3DBE5F);
  const yellow = Color(0xFFF2C230);
  const red = Color(0xFFE5483B);
  final p = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
  return p <= 0.5 ? Color.lerp(green, yellow, p * 2)! : Color.lerp(yellow, red, (p - 0.5) * 2)!;
}

/// How far a programme has got - the one bar for it everywhere (channel
/// list, info bar, guide, programme list). Its colour runs from green
/// through yellow to red as the programme nears its end
/// ([programmeProgressColor]).
///
/// Drawn as two plain boxes (no animation, no ticker) - cheap enough for
/// every row of the channel list on a weak TV box.
class EventProgress extends StatelessWidget {
  const EventProgress({super.key, required this.event, this.width, this.height = 5});

  final E2Event event;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) =>
      ProgrammeProgressBar(progress: event.progressAt(DateTime.now()), width: width, height: height);
}

/// [EventProgress] for a fraction known otherwise.
class ProgrammeProgressBar extends StatelessWidget {
  const ProgrammeProgressBar({super.key, required this.progress, this.width, this.height = 5});

  /// 0..1 of the programme gone by.
  final double progress;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    final radius = BorderRadius.circular(height / 2);
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.white24, borderRadius: radius),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: p,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(color: programmeProgressColor(p), borderRadius: radius),
            ),
          ),
        ),
      ),
    );
  }
}
