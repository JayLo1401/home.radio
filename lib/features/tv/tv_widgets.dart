import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models/iptv_channel.dart';
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
    final name = Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          shortChannelName(channel.name),
          textAlign: TextAlign.center,
          maxLines: 2,
          style: TextStyle(color: Colors.white70, fontSize: height * 0.3, fontWeight: FontWeight.bold, height: 1.1),
        ),
      ),
    );
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(4),
      // No picon on the receiver: the name instead of OpenWebif's logo.
      child: !channel.hasPicon
          ? name
          : Image.network(
              uri.toString(),
              headers: config.authHeaders,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => name,
              loadingBuilder: (_, child, progress) => progress == null ? child : name,
            ),
    );
  }
}

/// An Internet-TV channel's logo (from the iptv-org catalogue) in the
/// picon's place - its name's initials while loading or without one.
class IptvLogo extends StatelessWidget {
  const IptvLogo({super.key, required this.channel, this.width = 96, this.height = 58});

  final IptvChannel channel;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final name = Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          shortChannelName(channel.name),
          textAlign: TextAlign.center,
          maxLines: 2,
          style: TextStyle(color: Colors.white70, fontSize: height * 0.3, fontWeight: FontWeight.bold, height: 1.1),
        ),
      ),
    );
    final logo = channel.logo;
    // Decoded no bigger than shown - some logos are 2000 px wide, and the
    // Fire TV Stick has little memory.
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round();
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(4),
      child: logo == null
          ? name
          : CachedNetworkImage(
              imageUrl: logo,
              fit: BoxFit.contain,
              memCacheWidth: cacheWidth,
              fadeInDuration: const Duration(milliseconds: 150),
              placeholder: (_, _) => name,
              errorWidget: (_, _, _) => name,
            ),
    );
  }
}

/// A channel's name without what every second one has ("HD", "Austria",
/// "Oesterreich", ...), in two lines at most - in place of a picon.
String shortChannelName(String name) {
  const noise = {'HD', 'UHD', 'AUSTRIA', 'ÖSTERREICH', 'OESTERREICH', 'AT', 'A', 'DEUTSCHLAND', 'SCHWEIZ', 'CH'};
  final words = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final kept = words.where((w) => !noise.contains(w.toUpperCase())).toList();
  final parts = kept.isEmpty ? words : kept;
  final oneLine = parts.join(' ');
  if (parts.length <= 1 || oneLine.length <= 8) return oneLine;
  // Two lines: the first word, then the rest.
  return '${parts.first}\n${parts.skip(1).join(' ')}';
}

/// How far a programme has got, in Radio's green.
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
