package at.jaycloud.home.system

import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import at.jaycloud.home.system.dab.DabRtlSdrPlugin
import at.jaycloud.home.system.rtlsdr.RtlSdrUsbPlugin

// AudioServiceActivity (extends FlutterActivity) is required by the
// audio_service plugin for its MediaSession/notification integration.
// The rtl_tcp test connection is plain Dart (rtl_sdr_service.dart).
class MainActivity : AudioServiceActivity() {
    private val launcher = LauncherPlugin()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(RtlSdrUsbPlugin())
        flutterEngine.plugins.add(DabRtlSdrPlugin())
        flutterEngine.plugins.add(BackupPlugin())
        flutterEngine.plugins.add(UpdatePlugin())
        flutterEngine.plugins.add(launcher)
        flutterEngine.plugins.add(DisplayPlugin())
        // Musik: the visualisation follows the sound (only with RECORD_AUDIO, an opt-in setting).
        flutterEngine.plugins.add(MusicVisualizerPlugin())
        flutterEngine.plugins.add(PermissionsPlugin())
        flutterEngine.plugins.add(at.jaycloud.home.system.browser.BrowserPlugin())
        // Uncaught native errors: an error message in the app instead of a crash.
        flutterEngine.plugins.add(CrashGuard.Plugin())
    }

    private var createdAt = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        CrashGuard.install()
        createdAt = SystemClock.elapsedRealtime()
        super.onCreate(savedInstanceState)
        HomeButtonService.ensureRunning(this)
        // A cold start by the Home key opens the launcher; at boot (also a
        // HOME intent, or HomeButtonService) the app's own start setting
        // decides, as for any other start.
        if (savedInstanceState == null && isHomeIntent(intent) && SystemClock.elapsedRealtime() > BOOT_GRACE_MS) {
            launcher.pendingShowLauncher = true
        }
    }

    override fun onResume() {
        super.onResume()
        HomeButtonService.ensureRunning(this)
        // Display by motion: shown over the lock screen, and a lock screen
        // without PIN goes away when the display comes back.
        if (MotionService.running != null) {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            }
            DisplayPlugin.dismissKeyguard(this)
        }
    }

    /** Keys and touches count as presence for the Haussteuerung's display timeout. */
    override fun onUserInteraction() {
        super.onUserInteraction()
        MotionService.onUserInteraction()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // The display came back on by motion (MotionService.wake).
        if (intent.getBooleanExtra(EXTRA_WAKE, false)) {
            DisplayPlugin.dismissKeyguard(this)
            return
        }
        // Right after the start the system's home screen can still flash up
        // (boot, an update) and HomeButtonService sends us here again - that
        // must not close what the start setting opened (e.g. TV).
        val justStarted = SystemClock.elapsedRealtime() - createdAt < 5_000
        if (isHomeIntent(intent) && !(justStarted && intent.getBooleanExtra(EXTRA_SHOW_LAUNCHER, false))) {
            launcher.requestShowLauncher()
        }
    }

    private fun isHomeIntent(intent: Intent?): Boolean =
        intent != null && (intent.hasCategory(Intent.CATEGORY_HOME) || intent.getBooleanExtra(EXTRA_SHOW_LAUNCHER, false))

    companion object {
        const val EXTRA_SHOW_LAUNCHER = "at.jaycloud.home.system.SHOW_LAUNCHER"
        const val EXTRA_WAKE = "at.jaycloud.home.system.WAKE"
        private const val BOOT_GRACE_MS = 180_000L
    }
}
