import 'package:flutter/material.dart';

import '../home/home_screen.dart';

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
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  static const _popDuration = Duration(milliseconds: 500);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _popDuration,
  );
  late final Animation<double> _scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);

  @override
  void initState() {
    super.initState();
    _controller.forward();
    Future.delayed(_popDuration, () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                child: Image.asset('assets/icon/applogo1.png', width: 140, height: 140),
              ),
              const SizedBox(height: 20),
              const Text(
                'Home Radio',
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
    );
  }
}
