import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/display_mode.dart';
import '../../core/loading_wave.dart';
import '../../core/providers.dart';

import '../../data/models/launcher_tile.dart' show StartScreen;
import '../../l10n/l10n.dart';
import '../dashboard/dashboard_screen.dart';
import '../home/home_screen.dart';
import '../launcher/launcher_navigation.dart';
import '../launcher/launcher_providers.dart';
import '../setup/setup_wizard_screen.dart';
import '../tv/tv_screen.dart';

/// The start screen right after Android's launch screen (launch_background.xml,
/// the same logo at the same size): logo, name and the loading wave while
/// the settings load, then the setup wizard or the app.
///
/// Renders fully visible on its very first frame (no fade-in from
/// transparent), so the hand-over from the launch screen doesn't flash
/// black. It stays at least [_minShown] - long enough to see the wave, short
/// enough that the start isn't held up.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> with SingleTickerProviderStateMixin {
  static const _minShown = Duration(milliseconds: 1200);

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  late final Animation<double> _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

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

  /// Radio is always the base (it owns playback); the launcher opens
  /// over it when that's the start setting, or the Home key started the app.
  Future<void> _start() async {
    final started = DateTime.now();
    final settings = ref.read(settingsRepositoryProvider);
    // A fresh installation gets the setup wizard first.
    final configured = await settings.isConfigured();
    // The Home key (Android) asks for the launcher, whatever the setting.
    final requested = await ref.read(launcherServiceProvider).takeLaunchRequest();
    var start = requested ? StartScreen.launcher : await settings.getStartScreen();
    // A part that is switched off can't be the start.
    if (start == StartScreen.radio && !await settings.getRadioEnabled()) start = StartScreen.launcher;
    if (start == StartScreen.tv && !await settings.getTvEnabled()) start = StartScreen.launcher;
    if (start == StartScreen.dashboard && !await settings.getDashboardEnabled()) start = StartScreen.launcher;
    final startApp = start == StartScreen.app ? await settings.getStartApp() : '';
    if (start == StartScreen.app && startApp.isEmpty) start = StartScreen.launcher;
    final rest = _minShown - DateTime.now().difference(started);
    if (rest > Duration.zero) await Future<void>.delayed(rest);
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (!configured) {
      nav.pushReplacement(MaterialPageRoute(
        // The wizard's own ref - this screen is gone by then.
        builder: (_) => SetupWizardScreen(onFinished: (wizardRef) => _openApp(nav, wizardRef, StartScreen.launcher)),
      ));
      return;
    }
    _openApp(nav, ref, start);
    if (start == StartScreen.app) _startOtherApp(startApp);
  }

  /// The start app over Home - Back or Home lead to Home System.
  Future<void> _startOtherApp(String package) async {
    final messenger = ScaffoldMessenger.of(context);
    final text = context.l10n.systemStartAppMissing(package);
    ref.read(radioCommandProvider.notifier).send(RadioCommand.pauseForApp);
    if (!await ref.read(launcherServiceProvider).launchApp(package)) {
      messenger.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  /// Radio's screen as the base, Home (and TV) over it as [start] says.
  static void _openApp(NavigatorState nav, WidgetRef ref, StartScreen start) {
    nav.pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
    if (start == StartScreen.radio) return;
    showLauncher(ref);
    // TV / the Haussteuerung on top of the launcher - Back leads there.
    if (start == StartScreen.tv) nav.push(MaterialPageRoute(builder: (_) => const TvScreen()));
    if (start == StartScreen.dashboard) nav.push(MaterialPageRoute(builder: (_) => const DashboardScreen()));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = ref.watch(uiScaleProvider);
    // Back during the start mustn't end Home System (it's the home screen).
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        // The logo exactly in the middle like on the launch screen; name and
        // wave below it.
        body: Column(
          children: [
            const Spacer(),
            // 144dp like the launch screen - divided by the UI scale, which
            // shrinks everything else, so it doesn't jump.
            Image.asset('assets/icon/home_system_logo.png', width: 144 / uiScale, height: 144 / uiScale),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: FadeTransition(
                  opacity: _fade,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(height: 20),
                      Text(
                        'Home System',
                        style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Powered by jaycloud.at',
                        style: TextStyle(color: Colors.green, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 36),
                      LoadingWave(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
