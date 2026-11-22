import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/launcher_tile.dart';
import 'launcher_providers.dart';

/// The launcher's full-screen background: a new picture every few minutes
/// (see [LauncherSettings]), cross-faded. Photos are only shown once fully
/// loaded and decoded; until then, and whenever fetching fails, the built-in
/// gradients stand in.
class LauncherBackground extends ConsumerStatefulWidget {
  const LauncherBackground({super.key});

  @override
  ConsumerState<LauncherBackground> createState() => _LauncherBackgroundState();
}

class _LauncherBackgroundState extends ConsumerState<LauncherBackground> {
  Timer? _timer;
  int _gradient = DateTime.now().minute % builtinBackdrops.length;
  ImageProvider? _image;

  /// Place and photographer of an internet photo, shown small as its credit.
  String? _caption;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restart());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _evict(_image);
    super.dispose();
  }

  void _restart() {
    if (!mounted) return;
    final settings = ref.read(launcherSettingsProvider);
    if (!settings.loaded) return;
    _timer?.cancel();
    _timer = Timer.periodic(Duration(minutes: settings.backgroundInterval), (_) => _next());
    _next();
  }

  Future<void> _next() async {
    final settings = ref.read(launcherSettingsProvider);
    final generation = ++_generation;
    if (settings.backgroundSource == LauncherBackgroundSource.builtin) {
      final old = _image;
      setState(() {
        _image = null;
        _gradient = (_gradient + 1) % builtinBackdrops.length;
      });
      _evict(old);
      return;
    }
    final service = ref.read(launcherBackgroundServiceProvider);
    final size = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    Uint8List? bytes;
    String? caption;
    try {
      if (settings.backgroundSource == LauncherBackgroundSource.photos) {
        final photo = await service.randomPhoto();
        bytes = photo?.bytes;
        caption = photo?.caption;
      } else {
        bytes = await service.fromServer(settings.backgroundUrl);
      }
    } catch (e) {
      debugPrint('launcher background: $e');
    }
    if (!mounted || generation != _generation) return;
    if (bytes == null) {
      // Keep the current photo; without one, the next gradient.
      if (_image == null) setState(() => _gradient = (_gradient + 1) % builtinBackdrops.length);
      return;
    }
    final image = ResizeImage(MemoryImage(bytes), width: size.width.round().clamp(640, 1920));
    try {
      await precacheImage(image, context);
    } catch (_) {
      return;
    }
    if (!mounted || generation != _generation) return;
    final old = _image;
    setState(() {
      _image = image;
      _caption = caption;
    });
    // The old picture stays in the cache until the cross-fade is over.
    Future.delayed(const Duration(seconds: 3), () => _evict(old));
  }

  void _evict(ImageProvider? image) {
    if (image != null) PaintingBinding.instance.imageCache.evict(image);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(launcherSettingsProvider, (previous, next) {
      if (previous?.backgroundSource != next.backgroundSource ||
          previous?.backgroundUrl != next.backgroundUrl ||
          previous?.backgroundInterval != next.backgroundInterval ||
          previous?.loaded != next.loaded) {
        _restart();
      }
    });
    final image = _image;
    final caption = image == null ? null : _caption;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 1500),
          child: image == null
              ? BuiltinBackdrop(key: ValueKey('g$_gradient'), backdrop: builtinBackdrops[_gradient])
              : Image(
                  key: ValueKey(image),
                  image: image,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  gaplessPlayback: true,
                ),
        ),
        if (caption != null && caption.isNotEmpty)
          Positioned(
            right: 24,
            top: 72,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                caption,
                textAlign: TextAlign.right,
                style: const TextStyle(color: Colors.white70, fontSize: 12, shadows: [Shadow(blurRadius: 6)]),
              ),
            ),
          ),
      ],
    );
  }
}

/// A built-in background: a base gradient with soft glows of light, like
/// an aurora or a sky at dusk.
class Backdrop {
  const Backdrop(this.name, this.base, this.glows);

  final String name;
  final List<Color> base;

  /// Glow colour and its centre (-1..1).
  final List<(Color, Alignment, double)> glows;
}

const builtinBackdrops = [
  Backdrop('Nordlicht', [Color(0xFF020B1A), Color(0xFF06243A)], [
    (Color(0xFF1DE9B6), Alignment(-0.6, -0.4), 0.9),
    (Color(0xFF7C4DFF), Alignment(0.7, -0.7), 0.8),
    (Color(0xFF00B8D4), Alignment(0.2, 0.9), 0.7),
  ]),
  Backdrop('Abendrot', [Color(0xFF1A0526), Color(0xFF3A0B2E)], [
    (Color(0xFFFF6E40), Alignment(-0.3, 0.8), 1.0),
    (Color(0xFFFF4081), Alignment(0.6, 0.2), 0.8),
    (Color(0xFFFFC400), Alignment(-0.8, 0.95), 0.6),
  ]),
  Backdrop('Ozean', [Color(0xFF00111F), Color(0xFF002B4A)], [
    (Color(0xFF00E5FF), Alignment(0.6, -0.5), 0.8),
    (Color(0xFF2962FF), Alignment(-0.7, 0.4), 0.9),
    (Color(0xFF64FFDA), Alignment(0.1, 1.0), 0.5),
  ]),
  Backdrop('Wald', [Color(0xFF03140A), Color(0xFF0B2A18)], [
    (Color(0xFF76FF03), Alignment(-0.5, -0.7), 0.6),
    (Color(0xFF00C853), Alignment(0.6, 0.3), 0.9),
    (Color(0xFFFFD740), Alignment(0.9, -0.9), 0.4),
  ]),
  Backdrop('Lavendel', [Color(0xFF120A24), Color(0xFF261447)], [
    (Color(0xFFB388FF), Alignment(-0.4, -0.3), 0.9),
    (Color(0xFFFF80AB), Alignment(0.7, 0.6), 0.7),
    (Color(0xFF8C9EFF), Alignment(0.5, -0.9), 0.6),
  ]),
  Backdrop('Glut', [Color(0xFF140400), Color(0xFF2E0A00)], [
    (Color(0xFFFF3D00), Alignment(0.0, 0.9), 1.0),
    (Color(0xFFFF9100), Alignment(-0.7, 0.3), 0.6),
    (Color(0xFFD50000), Alignment(0.8, -0.2), 0.6),
  ]),
  Backdrop('Nacht', [Color(0xFF02030A), Color(0xFF0A0F2C)], [
    (Color(0xFF304FFE), Alignment(0.5, -0.6), 0.7),
    (Color(0xFF6200EA), Alignment(-0.8, 0.7), 0.6),
    (Color(0xFF00B0FF), Alignment(-0.2, -1.0), 0.4),
  ]),
  Backdrop('Wüste', [Color(0xFF1C1006), Color(0xFF3B2410)], [
    (Color(0xFFFFAB40), Alignment(0.4, -0.5), 0.9),
    (Color(0xFFFF7043), Alignment(-0.6, 0.6), 0.7),
    (Color(0xFFFFE57F), Alignment(0.9, 0.9), 0.5),
  ]),
];

class BuiltinBackdrop extends StatelessWidget {
  const BuiltinBackdrop({super.key, required this.backdrop});

  final Backdrop backdrop;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: backdrop.base,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final (color, center, strength) in backdrop.glows)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: center,
                  radius: 0.9,
                  colors: [color.withValues(alpha: 0.55 * strength), color.withValues(alpha: 0)],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
