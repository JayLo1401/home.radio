import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/services/enigma2_service.dart';

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// A channel's picon from the receiver (OpenWebif), its name's initials
/// while loading or without one.
class Picon extends StatelessWidget {
  const Picon({super.key, required this.config, required this.channel, this.width = 96, this.height = 58});

  final Enigma2Config config;
  final E2Channel channel;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final path = channel.piconPath;
    final uri = path != null ? config.webUri(path) : config.piconUri(channel.ref);
    final initials = Center(
      child: Text(
        channel.name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join().toUpperCase(),
        style: TextStyle(color: Colors.white70, fontSize: height * 0.35, fontWeight: FontWeight.bold),
      ),
    );
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(4),
      child: Image.network(
        uri.toString(),
        headers: config.authHeaders,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => initials,
        loadingBuilder: (_, child, progress) => progress == null ? child : initials,
      ),
    );
  }
}

/// How far a programme has got, in Home Radio's green.
class EventProgress extends StatelessWidget {
  const EventProgress({super.key, required this.event, this.width});

  final E2Event event;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: event.progressAt(DateTime.now()),
          minHeight: 5,
          backgroundColor: Colors.white24,
          valueColor: const AlwaysStoppedAnimation(brandGreen),
        ),
      ),
    );
  }
}

/// A focusable row with the app's focus frame (remote first).
class TvRow extends StatefulWidget {
  const TvRow({
    super.key,
    required this.child,
    required this.onTap,
    this.autofocus = false,
    this.focusNode,
    this.onFocused,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onFocused;
  final bool selected;

  @override
  State<TvRow> createState() => _TvRowState();
}

class _TvRowState extends State<TvRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(10),
      child: Material(
        color: widget.selected ? brandGreen.withValues(alpha: 0.22) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(10),
          focusColor: Colors.transparent,
          onFocusChange: (v) {
            setState(() => _focused = v);
            if (v) {
              widget.onFocused?.call();
              Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 120));
            }
          },
          onTap: widget.onTap,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Time of day, ticking every few seconds (minute changes).
class TvClock extends StatefulWidget {
  const TvClock({super.key, this.style});

  final TextStyle? style;

  @override
  State<TvClock> createState() => _TvClockState();
}

class _TvClockState extends State<TvClock> {
  late DateTime _now = DateTime.now();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now();
      if (now.minute != _now.minute) setState(() => _now = now);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
        hhmm(_now),
        style: widget.style ?? const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
      );
}
