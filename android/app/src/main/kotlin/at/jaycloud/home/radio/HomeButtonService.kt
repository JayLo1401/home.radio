package at.jaycloud.home.radio

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * Makes the Home key open Home Media on devices that don't let another app
 * be the launcher - Fire TV (always Amazon's home screen) and Google TV
 * (always its own). An accessibility service sees that home screen come to
 * the front - by the Home key, leaving an app, or at boot - and starts Home
 * Media's launcher over it (MainActivity.EXTRA_SHOW_LAUNCHER).
 *
 * It only looks at which app is in front: no window content, no keys.
 * "Home-Taste öffnet Home Media" in the settings switches the redirect off.
 *
 * Switched on in the system's accessibility settings, over adb, or by the app
 * itself once WRITE_SECURE_SETTINGS was granted (see [enable]).
 */
class HomeButtonService : AccessibilityService() {

    private var homePackages = emptySet<String>()
    private var lastRedirectAt = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        homePackages = findHomePackages()
        // Wanted - and as of this version (see restoreAfterUpdate).
        prefs(this).edit()
            .putBoolean(KEY_WANTED, true)
            .putLong(KEY_CONFIRMED_VERSION, installTime(this))
            .apply()
        Log.i(TAG, "connected, home screens: $homePackages")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg !in homePackages || !redirectEnabled(this)) return
        val now = SystemClock.elapsedRealtime()
        // One home screen shows as several window changes.
        if (now - lastRedirectAt < 1500) return
        lastRedirectAt = now
        Log.i(TAG, "home screen ($pkg, ${event.className}) -> Home Media")
        try {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    .putExtra(MainActivity.EXTRA_SHOW_LAUNCHER, true),
            )
        } catch (e: Exception) {
            Log.w(TAG, "can't start Home Media", e)
        }
    }

    override fun onInterrupt() = Unit

    /**
     * The system's home screen: whatever the HOME intent resolves to, plus
     * the known stock launchers. Not every app with a HOME activity - the
     * TV settings and the setup wizard have one too (a boot fallback), and
     * opening the settings must not bounce back to Home Media.
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

        /**
         * Android drops an app's accessibility service when the app is
         * updated. Switched back on when it was on before and only the app's
         * version changed since - not when the user switched it off.
         */
        fun restoreAfterUpdate(context: Context) {
            val app = context.applicationContext
            if (!needsRestore(app)) return
            // Android takes the service out a little after the update, not
            // right away - so it's put back now and a few more times, until
            // it has connected again for this version.
            val main = android.os.Handler(android.os.Looper.getMainLooper())
            for (delay in longArrayOf(0L, 3_000L, 10_000L, 30_000L)) {
                main.postDelayed({
                    if (needsRestore(app)) Log.i(TAG, "restoring the service after an update: ${enable(app)}")
                }, delay)
            }
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
