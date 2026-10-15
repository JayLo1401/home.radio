import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/services/order_service.dart';

/// "Bestellung aufgeben für <title>" tile - shown under a halved weather
/// tile while bestell_manager reports an order day for today (see
/// orderDayProvider): the kitchen's current status, plus the QR code
/// guests scan to order. The QR code always sits on its own white box with
/// a quiet-zone margin, so it stays scannable against this dark tile.
class OrderPanel extends StatelessWidget {
  const OrderPanel({super.key, required this.day});

  final OrderDay day;

  static const _statusColors = {
    'starter': Color(0xFF2E7D32),
    'main': Color(0xFFE65100),
    'dessert': Color(0xFF6A1B9A),
    'closed': Color(0xFF616161),
  };

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.blueGrey.shade900.withValues(alpha: 0.88), Colors.black.withValues(alpha: 0.8)],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const padding = 14.0;
          // QR as large as the tile's height allows, but never more than
          // half its width so the text beside it still has room.
          final qrSize = (constraints.maxHeight - 2 * padding).clamp(0.0, constraints.maxWidth * 0.5);
          // Text sizes follow the tile's size (relative to the 420x260 base
          // tile), so a bigger tile gets proportionally bigger text, not
          // just more space - and a small one doesn't overflow.
          final s = math.min(constraints.maxHeight / 260, constraints.maxWidth / 420).clamp(0.4, 2.0);
          return Padding(
            padding: const EdgeInsets.all(padding),
            child: Row(
              children: [
                Expanded(
                  // On very small tiles (50% tile size, halved) the text
                  // block can still end up taller than the tile - shrink it
                  // as a whole then, rather than overflowing. The fixed
                  // width keeps line wrapping as it would be unscaled.
                  child: LayoutBuilder(
                    builder: (context, textConstraints) => FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: textConstraints.maxWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Bestellung aufgeben für',
                              style: TextStyle(color: Colors.white60, fontSize: 14 * s, fontWeight: FontWeight.w600),
                            ),
                            SizedBox(height: 2 * s),
                            Text(
                              day.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20 * s,
                                fontWeight: FontWeight.w700,
                                height: 1.15,
                              ),
                            ),
                            SizedBox(height: 6 * s),
                            Row(
                              children: [
                                Icon(Icons.qr_code_scanner_rounded, color: Colors.white70, size: 16 * s),
                                SizedBox(width: 6 * s),
                                Flexible(
                                  child: Text(
                                    'Scanne einfach den QR-Code',
                                    style: TextStyle(color: Colors.white70, fontSize: 13 * s),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 12 * s),
                            _StatusBadge(
                              day: day,
                              scale: s,
                              color: _statusColors[day.statusCode] ?? _statusColors['closed']!,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: padding),
                _QrCode(day: day, size: qrSize),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.day, required this.scale, required this.color});

  final OrderDay day;
  final double scale;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 6 * scale),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (day.statusIcon.isNotEmpty) ...[
            Text(day.statusIcon, style: TextStyle(fontSize: 15 * scale)),
            SizedBox(width: 6 * scale),
          ],
          Flexible(
            child: Text(
              day.statusLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: 15 * scale, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _QrCode extends StatelessWidget {
  const _QrCode({required this.day, required this.size});

  final OrderDay day;
  final double size;

  @override
  Widget build(BuildContext context) {
    final png = day.qrPng;
    return Container(
      width: size,
      height: size,
      // White quiet zone around the code - required for scanning, and what
      // keeps it readable against the dark tile.
      padding: EdgeInsets.all(size * 0.06),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
      child: png == null
          ? const Center(child: Icon(Icons.qr_code_2_rounded, color: Colors.black26, size: 48))
          : Image.memory(
              png,
              fit: BoxFit.contain,
              // Nearest-neighbour scaling keeps the modules' edges sharp
              // instead of blurring them, whatever the tile's size.
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
            ),
    );
  }
}
