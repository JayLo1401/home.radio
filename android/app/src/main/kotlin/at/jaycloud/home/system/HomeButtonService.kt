package at.jaycloud.home.system

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityEvent

/**
 * Makes the Home key open Home System on devices that don't let another app
 * be the launcher - Fire TV (always Amazon's home screen) and Google TV
 * (always its own). An accessibility service sees that home screen come to
 * the front - by the Home key, leaving an app, or at boot - and starts Home
 * Media's launcher over it (MainActivity.EXTRA_SHOW_LAUNCHER).
 *
 * It only looks at which app is in front - no window content - and, on Fire
 * TV, at the Home key (see [onKeyEvent]); all other keys pass untouched.
 * "Home-Taste öffnet Home System" in the settings switches the redirect off.
 *
 * Switched on in the system's accessibility settings, over adb, or by the app
 * itself once WRITE_SECURE_SETTINGS was granted (see [enable]).
 */
class HomeButtonService : AccessibilityService() {

    private var homePackages = emptySet<String>()
    private var homeActivities = emptySet<String>()
    private val launcherActivities = mutableMapOf<String, Set<String>>()
    private var launcherShowsOtherScreen = false
    private var lastRedirectAt = 0L
    private val handler = Handler(Looper.getMainLooper())
    private var homeKeyDown = false
    private var homeLongPressed = false
    private val homeLongPress = Runnable {
        homeLongPressed = true
        onHomeLongPress()
    }

    /** The display came on (motion, power key, Home Assistant): away with the lock screen at once. */
    private val screenOn = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (MotionService.running != null) unlockSoon()
        }
    }
    private var unlockTries = 0
    private val unlockTry = object : Runnable {
        override fun run() {
            if (!swipeAwayLockScreen()) return
            // The lock screen may not take the swipe in its first moments.
            if (++unlockTries < 8) handler.postDelayed(this, 200)
        }
    }

    /** Swipes the lock screen (without PIN) away now - and again shortly if it's still there. */
    fun unlockSoon() {
        handler.removeCallbacks(unlockTry)
        unlockTries = 0
        handler.post(unlockTry)
    }

    override fun onServiceConnected() {
        // At boot the service can start the app's process before any screen.
        CrashGuard.install()
        super.onServiceConnected()
        instance = this
        val filter = android.content.IntentFilter(Intent.ACTION_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenOn, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenOn, filter)
        }
        homePackages = findHomePackages()
        homeActivities = findHomeActivities()
        if (FILTER_HOME_KEY) {
            serviceInfo = serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS }
        }
        // Wanted - and as of this version (see ensureRunning).
        prefs(this).edit()
            .putBoolean(KEY_WANTED, true)
            .putLong(KEY_CONFIRMED_VERSION, installTime(this))
            .apply()
        Log.i(TAG, "connected, home screens: $homePackages, home key filter: $FILTER_HOME_KEY")
    }

    /**
     * Fire TV only (see [FILTER_HOME_KEY]): the Home key itself. Once the
     * system has seen Home it blocks other apps from coming to the front for
     * 5 seconds - Amazon's home screen would show that long before Home System
     * appears. Caught here, before the system sees it, Home System opens right
     * away. A long press opens Amazon's quick menu as usual. Every other key
     * is passed on untouched.
     */
    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode != KeyEvent.KEYCODE_HOME || !redirectEnabled(this)) return false
        when (event.action) {
            KeyEvent.ACTION_DOWN -> if (!homeKeyDown) {
                homeKeyDown = true
                homeLongPressed = false
                handler.postDelayed(homeLongPress, ViewConfiguration.getLongPressTimeout().toLong())
            } else if (event.repeatCount > 0 && !homeLongPressed) {
                // Synthetic long press (input keyevent --longpress).
                handler.removeCallbacks(homeLongPress)
                homeLongPress.run()
            }
            KeyEvent.ACTION_UP -> {
                handler.removeCallbacks(homeLongPress)
                if (homeKeyDown && !homeLongPressed) {
                    deviceSettingsOpen = false
                    lastRedirectAt = SystemClock.elapsedRealtime()
                    Log.i(TAG, "home key -> Home System")
                    openHomeSystem()
                }
                homeKeyDown = false
            }
        }
        return true
    }

    /** Amazon's quick menu (what a long Home press opens on Fire TV). */
    private fun onHomeLongPress() {
        Log.i(TAG, "home key long press -> quick menu")
        try {
            startActivity(Intent(ACTION_FIRE_TV_QUICK_MENU).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            Log.w(TAG, "no quick menu - device home screen instead", e)
            lastRedirectAt = SystemClock.elapsedRealtime() + 3000 // let it stay
            performGlobalAction(GLOBAL_ACTION_HOME)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg !in homePackages) {
            // Some other app is in front: the device's settings, opened from
            // Home System, are left again.
            if (!pkg.contains("settings") && pkg != "android" && pkg != "com.android.systemui") {
                deviceSettingsOpen = false
            }
            return
        }
        if (deviceSettingsOpen || !redirectEnabled(this)) return
        // The launcher's own other screens are no home screen - on Fire TV
        // the settings are an activity of Amazon's launcher. Window changes
        // that aren't an activity (dialogs, views) count as the activity
        // that was last in front.
        val cls = event.className?.toString().orEmpty()
        if (cls in activitiesOf(pkg)) launcherShowsOtherScreen = cls !in homeActivities
        if (launcherShowsOtherScreen) return
        val now = SystemClock.elapsedRealtime()
        // One home screen shows as several window changes.
        if (now - lastRedirectAt < 1500) return
        lastRedirectAt = now
        Log.i(TAG, "home screen ($pkg, ${event.className}) -> Home System")
        openHomeSystem()
    }

    private fun openHomeSystem() {
        try {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    .putExtra(MainActivity.EXTRA_SHOW_LAUNCHER, true),
            )
        } catch (e: Exception) {
            Log.w(TAG, "can't start Home System", e)
        }
    }

    override fun onInterrupt() = Unit

    /**
     * The Haussteuerung: after the display came back on (MotionService.wake),
     * a lock screen without PIN/password is swiped up like with a finger -
     * a secure one stays. False if there was none or it can't.
     */
    fun swipeAwayLockScreen(): Boolean {
        val keyguard = getSystemService(android.app.KeyguardManager::class.java) ?: return false
        if (!keyguard.isKeyguardLocked || keyguard.isDeviceSecure) return false
        val metrics = resources.displayMetrics
        val x = metrics.widthPixels / 2f
        val path = android.graphics.Path().apply {
            moveTo(x, metrics.heightPixels * 0.92f)
            lineTo(x, metrics.heightPixels * 0.35f)
        }
        val gesture = android.accessibilityservice.GestureDescription.Builder()
            .addStroke(android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, 120))
            .build()
        val sent = dispatchGesture(gesture, null, null)
        return sent
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(screenOn)
        } catch (_: Exception) {
        }
        handler.removeCallbacks(unlockTry)
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun activitiesOf(pkg: String): Set<String> = launcherActivities.getOrPut(pkg) {
        try {
            packageManager.getPackageInfo(pkg, PackageManager.GET_ACTIVITIES).activities
                ?.map { it.name }?.toSet().orEmpty()
        } catch (e: Exception) {
            emptySet()
        }
    }

    /**
     * Every HOME activity, e.g. com.amazon.tv.launcher.ui.HomeActivity_vNext
     * - for an activity-alias also the activity behind it, the one whose
     * window shows up.
     */
    private fun findHomeActivities(): Set<String> =
        packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)
            .flatMap { listOfNotNull(it.activityInfo.name, it.activityInfo.targetActivity) }.toSet()

    /**
     * The system's home screen: whatever the HOME intent resolves to, plus
     * the known stock launchers. Not every app with a HOME activity - the
     * TV settings and the setup wizard have one too (a boot fallback), and
     * opening the settings must not bounce back to Home System.
     */
    private fun findHomePackages(): Set<String> {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val found = KNOWN_LAUNCHERS.toMutableSet()
        packageManager.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName?.let {
            if (it != "android" && !it.contains("settings") && !it.contains("setup")) found += it
        }
        found -= packageName
        return found
    }

    companion object {
        const val TAG = "HomeButtonService"

        /** The connected service - the Haussteuerung switches the display off through it (MotionService). */
        @Volatile
        var instance: HomeButtonService? = null
            private set

        /** Only Fire TV holds other apps back for 5 s after Home (see onKeyEvent). */
        private val FILTER_HOME_KEY = Build.MANUFACTURER.equals("Amazon", ignoreCase = true)
        private const val ACTION_FIRE_TV_QUICK_MENU = "com.amazon.device.settings.action.SHOW_HUD"

        /**
         * Home System opened the device's settings. On Fire TV they are a page
         * of Amazon's home screen (android.settings.SETTINGS lands in
         * HomeActivity_vNext) - not sent back to Home System until another app
         * comes to the front or Home is pressed.
         */
        @Volatile
        private var deviceSettingsOpen = false

        fun onDeviceSettingsOpened() {
            deviceSettingsOpen = true
        }
        private val KNOWN_LAUNCHERS = setOf(
            "com.amazon.tv.launcher", // Fire TV
            "com.google.android.apps.tv.launcherx", // Google TV
            "com.google.android.tvlauncher", // Android TV
            "com.google.android.leanbacklauncher", // older Android TV
            "com.mitv.tvhome.atv", // Xiaomi PatchWall
        )
        private const val PREFS = "home_media_launcher"
        private const val KEY_REDIRECT = "home_redirect"
        private const val KEY_WANTED = "service_wanted"
        private const val KEY_CONFIRMED_VERSION = "service_confirmed_install"

        private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun redirectEnabled(context: Context) = prefs(context).getBoolean(KEY_REDIRECT, true)

        fun setRedirectEnabled(context: Context, enabled: Boolean) =
            prefs(context).edit().putBoolean(KEY_REDIRECT, enabled).apply()

        private fun installTime(context: Context): Long = try {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        } catch (e: Exception) {
            0L
        }

        fun canWriteSecureSettings(context: Context): Boolean =
            context.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) ==
                PackageManager.PERMISSION_GRANTED

        /**
         * Switches the service on by itself - only possible once
         * WRITE_SECURE_SETTINGS was granted over adb.
         */
        fun enable(context: Context): Boolean {
            if (!canWriteSecureSettings(context)) return false
            return try {
                val resolver = context.contentResolver
                val me = ComponentName(context, HomeButtonService::class.java).flattenToString()
                val current = Settings.Secure.getString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
                val services = current.split(':').filter { it.isNotBlank() && !it.equals(me, ignoreCase = true) } + me
                Settings.Secure.putString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, services.joinToString(":"))
                Settings.Secure.putInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
                true
            } catch (e: Exception) {
                Log.w(TAG, "can't enable the service", e)
                false
            }
        }

        /** Connected and working right now (it runs in the app's process). */
        fun isRunning(): Boolean = instance != null

        /**
         * Switches the service off and on again: Android binds it anew. Needed
         * when it is still switched on in the settings but Android doesn't
         * run it - after the app's process died (crash, or killed for
         * memory) Android counts it as crashed and leaves it be; writing the
         * same setting again changes nothing.
         */
        fun restart(context: Context): Boolean {
            if (!canWriteSecureSettings(context)) return false
            return try {
                val resolver = context.contentResolver
                val me = ComponentName(context, HomeButtonService::class.java).flattenToString()
                val current = Settings.Secure.getString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
                val others = current.split(':').filter { it.isNotBlank() && !it.equals(me, ignoreCase = true) }
                Settings.Secure.putString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, others.joinToString(":"))
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    try {
                        Settings.Secure.putString(
                            resolver,
                            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
                            (others + me).joinToString(":"),
                        )
                        Settings.Secure.putInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
                    } catch (e: Exception) {
                        Log.w(TAG, "can't switch the service back on", e)
                    }
                }, 700)
                true
            } catch (e: Exception) {
                Log.w(TAG, "can't restart the service", e)
                false
            }
        }

        /** On: switched on and not running - restart. Off: switch on. */
        private fun bringBack(context: Context): Boolean =
            if (isEnabled(context)) restart(context) else enable(context)

        private var checksPosted = false

        /**
         * Keeps the Home key working (each time the app opens or comes back):
         * - after an update Android drops the service - switched back on when
         *   it was on before and only the app's version changed since (not
         *   when the user switched it off);
         * - after the app's process died Android leaves it switched on but
         *   doesn't run it - restarted.
         * A service the user switched off (no longer in the settings) stays off.
         */
        fun ensureRunning(context: Context) {
            val app = context.applicationContext
            if (checksPosted) return
            checksPosted = true
            val main = android.os.Handler(android.os.Looper.getMainLooper())
            // Give Android a moment to bind it by itself first.
            for (delay in longArrayOf(4_000L, 15_000L, 40_000L)) {
                main.postDelayed({
                    try {
                        if (isRunning() || !canWriteSecureSettings(app)) return@postDelayed
                        val wanted = prefs(app).getBoolean(KEY_WANTED, false)
                        when {
                            needsRestore(app) -> Log.i(TAG, "bringing the service back after an update: ${bringBack(app)}")
                            wanted && isEnabled(app) -> Log.i(TAG, "on but not running - restarting it: ${restart(app)}")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "ensureRunning", e)
                    }
                }, delay)
            }
            main.postDelayed({ checksPosted = false }, 41_000L)
        }

        /** Wanted, but not connected since the app was last updated. */
        private fun needsRestore(context: Context): Boolean {
            val p = prefs(context)
            return p.getBoolean(KEY_WANTED, false) && p.getLong(KEY_CONFIRMED_VERSION, 0L) != installTime(context)
        }

        fun isEnabled(context: Context): Boolean {
            val me = ComponentName(context, HomeButtonService::class.java).flattenToString()
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ).orEmpty()
            return enabled.split(':').any { it.equals(me, ignoreCase = true) }
        }
    }
}
