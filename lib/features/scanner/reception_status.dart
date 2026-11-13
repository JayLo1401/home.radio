import 'package:flutter/material.dart';

/// What the receiver reports twice a second in the data modes (ADS-B,
/// sensors, ACARS) - see the `rxStatus` event.
class RxStatus {
  final double samplesPerSecond;
  final double levelDb;
  final double clipRatio;
  final double gainDb;
  final List<double> channelLevelsDb;
  final DateTime at;

  RxStatus({
    required this.samplesPerSecond,
    required this.levelDb,
    required this.clipRatio,
    required this.gainDb,
    required this.channelLevelsDb,
    required this.at,
  });

  factory RxStatus.fromEvent(Map<String, dynamic> e) => RxStatus(
        samplesPerSecond: (e['samplesPerSecond'] as num?)?.toDouble() ?? 0,
        levelDb: (e['levelDb'] as num?)?.toDouble() ?? -100,
        clipRatio: (e['clipRatio'] as num?)?.toDouble() ?? 0,
        gainDb: (e['gainDb'] as num?)?.toDouble() ?? 0,
        channelLevelsDb: [for (final v in (e['channelLevelsDb'] as List? ?? const [])) (v as num).toDouble()],
        at: DateTime.now(),
      );
}

/// "Empfang läuft" for the screens without sound: a pulsing dot while data
/// comes from the stick, the rate it arrives at, the input level, and a
/// flash on every received signal ([lastSignal]). Orange when nothing
/// arrives.
class ReceptionStatus extends StatefulWidget {
  final RxStatus? status;

  /// The rate the stick should deliver (S/s).
  final int expectedRate;

  /// The last received signal/message - flashes "Signal" briefly.
  final DateTime? lastSignal;

  const ReceptionStatus({super.key, required this.status, required this.expectedRate, this.lastSignal});

  @override
  State<ReceptionStatus> createState() => _ReceptionStatusState();
}

class _ReceptionStatusState extends State<ReceptionStatus> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    final age = s == null ? null : DateTime.now().difference(s.at);
    final alive = s != null && age! < const Duration(seconds: 3) && s.samplesPerSecond > widget.expectedRate * 0.5;
    final slow = s != null && age! < const Duration(seconds: 3) && !alive;
    final color = alive ? Colors.greenAccent : Colors.orangeAccent;
    final text = s == null
        ? 'Warte auf Daten vom Stick…'
        : !alive && !slow
            ? 'Keine Daten vom Stick'
            : '${slow ? 'Daten kommen zu langsam' : 'Empfang läuft'} · '
                '${(s.samplesPerSecond / 1e6).toStringAsFixed(2).replaceAll('.', ',')} MS/s';
    final flash = widget.lastSignal != null && DateTime.now().difference(widget.lastSignal!) < const Duration(milliseconds: 700);
    // Input level as a bar: -60 dBFS (quiet) .. 0 dBFS (full).
    final level = s == null ? 0.0 : ((s.levelDb + 60) / 60).clamp(0.0, 1.0);
    final clipping = s != null && s.clipRatio > 0.01;
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FadeTransition(
          opacity: alive ? Tween(begin: 0.35, end: 1.0).animate(_pulse) : const AlwaysStoppedAnimation(1),
          child: Icon(Icons.circle, size: 14, color: color),
        ),
        Text(text, style: TextStyle(color: alive ? Colors.white70 : Colors.orangeAccent)),
        if (s != null) ...[
          const Text('Pegel', style: TextStyle(color: Colors.white54)),
          SizedBox(
            width: 120,
            height: 8,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: level,
                backgroundColor: Colors.white12,
                color: clipping ? Colors.redAccent : Colors.greenAccent,
              ),
            ),
          ),
          if (clipping)
            const Text('übersteuert – Verstärkung senken', style: TextStyle(color: Colors.redAccent))
          else
            Text('${s.levelDb.round()} dBFS', style: const TextStyle(color: Colors.white54)),
        ],
        AnimatedOpacity(
          opacity: flash ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt, size: 18, color: Colors.amberAccent),
              Text('Signal', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ],
    );
  }
}

/// A channel's level as a small bar (ACARS): -70 .. -20 dBFS.
class ChannelLevel extends StatelessWidget {
  final double? levelDb;
  final bool active;

  const ChannelLevel({super.key, required this.levelDb, required this.active});

  @override
  Widget build(BuildContext context) {
    final v = levelDb == null ? 0.0 : ((levelDb! + 70) / 50).clamp(0.0, 1.0);
    return SizedBox(
      width: 60,
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: v,
          backgroundColor: Colors.white12,
          color: active ? Colors.greenAccent : Colors.white38,
        ),
      ),
    );
  }
}
