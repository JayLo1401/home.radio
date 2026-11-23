import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/display_mode.dart';
import '../../core/providers.dart';

import '../../data/models/launcher_tile.dart' show StartScreen;
import '../home/home_screen.dart';
import '../launcher/launcher_navigation.dart';
import '../launcher/launcher_providers.dart';
import '../tv/tv_screen.dart';

/// Brief branded startup animation shown right after the native Android
/// launch background (which already shows the app icon on black - see
/// launch_background.xml) hands off to Flutter, before the actual UI
/// (device/favorites lookups, DAB+ auto-permission, autostart, ...) takes
/// over. Purely cosmetic - no app logic lives here.
///
/// Renders fully visible on its very first frame (no fade-in from
/// transparent) so there's no perceptible flash of plain black between the
/// native launch background disappearing and this content appearing -
/// only a brief scale-in "pop" animates in on top of the already-visible
/// logo/text. [HomeScreen] is pushed as soon as that pop finishes rather
/// than after a longer, purely decorative wait, so its own startup work
/// (DAB+ auto-permission, autostart, favorites lookups, ...) begins as
/// early as possible instead of being gated behind this screen.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> with SingleTickerProviderStateMixin {
  static const _popDuration = Duration(milliseconds: 500);

  late final AnimationController _controller = AnimationController(vsync: this, duration: _popDuration);
  late final Animation<double> _scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);

  @override
  void initState() {
    super.initState();
    _controller.forward();
    final settings = ref.read(settingsRepositoryProvider);
    () async {
      await applyDisplayMode(
        fullscreen: await settings.getFullscreen(),
        monitor: await settings.getFullscreenMonitor(),
      );
    }();
    _start();
  }

  /// Home Radio is always the base (it owns playback); the launcher opens
  /// over it when that's the start setting, or the Home key started the app.
  Future<void> _start() async {
    final started = DateTime.now();
    // The Home key (Android) asks for the launcher, whatever the setting.
    final requested = await ref.read(launcherServiceProvider).takeLaunchRequest();
    final start = requested ? StartScreen.launcher : await ref.read(settingsRepositoryProvider).getStartScreen();
    final rest = _popDuration - DateTime.now().difference(started);
    if (rest > Duration.zero) await Future<void>.delayed(rest);
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
    if (start == StartScreen.radio) return;
    showLauncher(ref);
    // Home TV on top of the launcher - Back leads there.
    if (start == StartScreen.tv) nav.push(MaterialPageRoute(builder: (_) => const TvScreen()));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Back during the start mustn't end Home Media (it's the home screen).
    return PopScope(
      canPop: false,
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Transform.scale(scale: 0.85 + 0.15 * _scale.value, child: child),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset('assets/icon/home_media_logo.png', width: 140, height: 140),
              ),
              const SizedBox(height: 20),
              const Text(
                'Home Media',
                style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Powered by Jay',
                style: TextStyle(color: Colors.green, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
