import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Home System's brand: lime to green on black/graphite.
const musicLime = Color(0xFFCDFF23);
const musicGreen = Color(0xFF00C450);
const musicGraphite = Color(0xFF15191B);
const musicBrandGradient = LinearGradient(colors: [musicLime, musicGreen]);

/// "3:07", "1:02:45".
String formatMusicDuration(Duration? d) {
  if (d == null || d.isNegative) return '–:––';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// A cover picture, decoded at the size it's shown (big embedded covers
/// would cost a weak box a lot of memory otherwise) - a note on the brand
/// gradient when there's none.
class MusicCover extends StatelessWidget {
  const MusicCover({super.key, required this.bytes, required this.size, this.radius = 12});

  final Uint8List? bytes;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final bytes = this.bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: bytes == null
            ? const _CoverPlaceholder()
            : Image.memory(
                bytes,
                // Same bytes, same picture: no flicker on rebuilds.
                key: ValueKey(identityHashCode(bytes)),
                cacheWidth: pixels,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const _CoverPlaceholder(),
              ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF243018), Color(0xFF0B2A18)],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) => Center(
          child: ShaderMask(
            shaderCallback: (r) => musicBrandGradient.createShader(r),
            child: Icon(Icons.music_note_rounded, size: c.maxWidth * 0.5, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// A list row for the remote: green frame when focused, scrolled into view,
/// OK/tap [onTap], long OK / long tap / ☰ [onOptions] (see the screens'
/// key handling for ☰).
class MusicRow extends StatefulWidget {
  const MusicRow({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.focusNode,
    this.selected = false,
    this.onFocused,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool selected;
  final VoidCallback? onFocused;

  @override
  State<MusicRow> createState() => _MusicRowState();
}

class _MusicRowState extends State<MusicRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      focused: _focused,
      borderRadius: BorderRadius.circular(10),
      child: Material(
        color: widget.selected ? musicGreen.withValues(alpha: 0.18) : Colors.transparent,
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
          onLongPress: widget.onLongPress,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A round control button (play, next, shuffle ...): the brand gradient
/// when [active] or focused.
class MusicControlButton extends StatefulWidget {
  const MusicControlButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 56,
    this.active = false,
    this.focusNode,
    this.autofocus = false,
    this.primary = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;

  /// A toggle that is on (shuffle, repeat).
  final bool active;

  /// The big play/pause button.
  final bool primary;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<MusicControlButton> createState() => _MusicControlButtonState();
}

class _MusicControlButtonState extends State<MusicControlButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final filled = widget.primary || _focused;
    final iconColor = filled ? Colors.black : (widget.active ? musicLime : Colors.white);
    return Tooltip(
      message: widget.tooltip,
      child: AnimatedScale(
        scale: _focused ? 1.12 : 1,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: filled ? musicBrandGradient : null,
            color: filled ? null : Colors.white.withValues(alpha: widget.active ? 0.14 : 0.08),
            border: _focused ? Border.all(color: Colors.white, width: 3) : null,
            boxShadow: _focused ? [BoxShadow(color: musicGreen.withValues(alpha: 0.6), blurRadius: 18)] : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              focusColor: Colors.transparent,
              onFocusChange: (v) => setState(() => _focused = v),
              onTap: widget.onPressed,
              child: Icon(widget.icon, color: iconColor, size: widget.size * 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// A choice or toggle in Musik's settings (radio circle / switch symbol),
/// green frame when focused.
class MusicChoiceTile extends StatefulWidget {
  const MusicChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.asToggle = false,
    this.subtitle,
    this.enabled = true,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final bool asToggle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<MusicChoiceTile> createState() => _MusicChoiceTileState();
}

class _MusicChoiceTileState extends State<MusicChoiceTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final icon = widget.asToggle
        ? (widget.selected ? Icons.toggle_on : Icons.toggle_off)
        : (widget.selected ? Icons.radio_button_checked : Icons.radio_button_off);
    return TvFocusHighlight(
      focused: _focused,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        focusColor: Colors.transparent,
        canRequestFocus: widget.enabled,
        onFocusChange: (v) => setState(() => _focused = v),
        onTap: widget.enabled ? widget.onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: widget.asToggle ? 34 : 24, color: widget.selected ? musicLime : Colors.white54),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.label,
                        style: TextStyle(fontSize: 16, color: widget.enabled ? Colors.white : Colors.white38)),
                    if (widget.subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(widget.subtitle!, style: const TextStyle(fontSize: 13, color: Colors.white54)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A thin progress line in the brand gradient.
class MusicProgressLine extends StatelessWidget {
  const MusicProgressLine({super.key, required this.value, this.height = 4});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.white.withValues(alpha: 0.12)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value.isNaN ? 0 : value.clamp(0.0, 1.0),
              child: const DecoratedBox(decoration: BoxDecoration(gradient: musicBrandGradient)),
            ),
          ],
        ),
      ),
    );
  }
}
