package at.jaycloud.home.system

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * The launcher side of Home System ("home_system/launcher"): installed apps
 * with their TV banners/icons, starting them, and the Home key - Home System
 * is registered as a HOME activity (Android TV boxes, Google TV with the
 * stock launcher disabled), and on Fire TV, which ignores other launchers,
 * [HomeButtonService] brings it back whenever Amazon's home screen appears.
 *
 * Dart is told to show the launcher via "showLauncher"; a request that came
 * with the activity's very first intent waits in [pendingShowLauncher] until
 * Dart asks for it ("takeLaunchRequest").
 */
class LauncherPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private lateinit var appContext: Context
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var pendingShowLauncher = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "home_system/launcher").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /** The Home key while the app runs (see MainActivity.onNewIntent). */
    fun requestShowLauncher() {
        main.post { channel?.invokeMethod("showLauncher", null) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takeLaunchRequest" -> {
                val pending = pendingShowLauncher
                pendingShowLauncher = false
                result.success(pending)
            }
            "listApps" -> background(result) { listApps() }
            "appImage" -> {
                val pkg = call.argument<String>("package") ?: return result.error("ARGS", "package missing", null)
                background(result) { appImage(pkg) }
            }
            "listIconPacks" -> background(result) { listIconPacks() }
            "iconPackImage" -> {
                val pack = call.argument<String>("pack") ?: return result.error("ARGS", "pack missing", null)
                val pkg = call.argument<String>("package") ?: return result.error("ARGS", "package missing", null)
                background(result) { iconPackImage(pack, pkg) }
            }
            "launchApp" -> {
                val pkg = call.argument<String>("package") ?: return result.error("ARGS", "package missing", null)
                result.success(launchApp(pkg))
            }
            "openSystemSettings" -> result.success(openDeviceSettings(Intent(Settings.ACTION_SETTINGS)))
            "openAppInfo" -> {
                val pkg = call.argument<String>("package") ?: return result.error("ARGS", "package missing", null)
                // Its own settings page - also on Fire TV not part of the
                // home screen.
                result.success(start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", pkg, null))))
            }
            "isFireTv" -> result.success(isFireTv(appContext))
            "isDefaultHome" -> result.success(isDefaultHome())
            "openHomeSettings" -> result.success(
                openDeviceSettings(Intent(Settings.ACTION_HOME_SETTINGS)) ||
                    openDeviceSettings(Intent(Settings.ACTION_SETTINGS)),
            )
            "homeButtonStatus" -> result.success(
                mapOf(
                    "serviceEnabled" to HomeButtonService.isEnabled(appContext),
                    "canEnable" to canWriteSecureSettings(),
                    "redirect" to HomeButtonService.redirectEnabled(appContext),
                ),
            )
            "enableHomeButtonService" -> result.success(enableHomeButtonService())
            "openAccessibilitySettings" -> result.success(
                openDeviceSettings(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) ||
                    openDeviceSettings(Intent(Settings.ACTION_SETTINGS)),
            )
            "setHomeRedirect" -> {
                HomeButtonService.setRedirectEnabled(appContext, call.argument<Boolean>("enabled") ?: true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                Log.w(TAG, "launcher call failed", e)
                main.post { result.error("LAUNCHER", e.message, null) }
            }
        }.start()
    }

    private fun start(intent: Intent): Boolean = try {
        appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: Exception) {
        Log.w(TAG, "can't start $intent", e)
        false
    }

    /**
     * A page of the device's settings - on Fire TV part of Amazon's home
     * screen, so [HomeButtonService] must not send it back to Home System.
     */
    private fun openDeviceSettings(intent: Intent): Boolean {
        HomeButtonService.onDeviceSettingsOpened()
        return start(intent)
    }

    /** Every app with a TV or phone launcher entry, except this one. */
    private fun listApps(): List<Map<String, Any>> {
        val pm = appContext.packageManager
        val apps = linkedMapOf<String, Map<String, Any>>()
        for (category in listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER)) {
            val query = Intent(Intent.ACTION_MAIN).addCategory(category)
            for (info in pm.queryIntentActivities(query, 0)) {
                val pkg = info.activityInfo.packageName
                if (pkg == appContext.packageName || apps.containsKey(pkg)) continue
                apps[pkg] = mapOf(
                    "package" to pkg,
                    "label" to info.loadLabel(pm).toString(),
                    "tv" to (category == Intent.CATEGORY_LEANBACK_LAUNCHER),
                )
            }
        }
        return apps.values.sortedBy { (it["label"] as String).lowercase() }
    }

    /**
     * The app's TV banner (16:9, what Android TV launchers show) as PNG, or
     * its icon when it has none - {bytes, banner}.
     */
    private fun appImage(pkg: String): Map<String, Any>? {
        val pm = appContext.packageManager
        val banner: Drawable? = try {
            pm.getLeanbackLaunchIntentForPackage(pkg)?.let { pm.getActivityBanner(it) }
                ?: pm.getApplicationBanner(pkg)
        } catch (e: Exception) {
            null
        }
        if (banner != null) return mapOf("bytes" to toPng(banner, 320, 180, 640), "banner" to true)
        val icon = try {
            pm.getApplicationIcon(pkg)
        } catch (e: PackageManager.NameNotFoundException) {
            return null
        }
        return mapOf("bytes" to toPng(icon, 192, 192, 256), "banner" to false)
    }

    /**
     * Installed icon packs - the usual ADW/Nova/GO format every icon pack
     * app supports: an appfilter.xml mapping "ComponentInfo{package/activity}"
     * to a drawable of the pack.
     */
    private fun listIconPacks(): List<Map<String, Any>> {
        val pm = appContext.packageManager
        val packs = linkedMapOf<String, Map<String, Any>>()
        for (action in ICON_PACK_ACTIONS) {
            for (info in pm.queryIntentActivities(Intent(action), 0)) {
                val pkg = info.activityInfo.packageName
                if (packs.containsKey(pkg)) continue
                packs[pkg] = mapOf("package" to pkg, "label" to info.loadLabel(pm).toString())
            }
        }
        return packs.values.sortedBy { (it["label"] as String).lowercase() }
    }

    /** Drawable name per app package, per icon pack (parsed once). */
    private val iconPackMaps = mutableMapOf<String, Map<String, String>>()

    private fun iconPackImage(pack: String, pkg: String): Map<String, Any>? {
        val map = synchronized(iconPackMaps) { iconPackMaps.getOrPut(pack) { parseAppFilter(pack) } }
        val name = map[pkg] ?: return null
        val res = appContext.packageManager.getResourcesForApplication(pack)
        val id = res.getIdentifier(name, "drawable", pack).takeIf { it != 0 }
            ?: res.getIdentifier(name, "mipmap", pack).takeIf { it != 0 }
            ?: return null
        @Suppress("DEPRECATION")
        val drawable = res.getDrawable(id) ?: return null
        return mapOf("bytes" to toPng(drawable, 256, 256, 384), "banner" to false)
    }

    private fun parseAppFilter(pack: String): Map<String, String> {
        val map = mutableMapOf<String, String>()
        try {
            val res = appContext.packageManager.getResourcesForApplication(pack)
            val xmlId = res.getIdentifier("appfilter", "xml", pack)
            val parser: org.xmlpull.v1.XmlPullParser = if (xmlId != 0) {
                res.getXml(xmlId)
            } else {
                org.xmlpull.v1.XmlPullParserFactory.newInstance().newPullParser().apply {
                    setInput(res.assets.open("appfilter.xml"), "UTF-8")
                }
            }
            var event = parser.eventType
            while (event != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
                if (event == org.xmlpull.v1.XmlPullParser.START_TAG && parser.name == "item") {
                    val component = parser.getAttributeValue(null, "component")
                    val drawable = parser.getAttributeValue(null, "drawable")
                    // ComponentInfo{com.netflix.ninja/com.netflix.ninja.MainActivity}
                    val pkg = component?.substringAfter('{', "")?.substringBefore('/')
                    if (!pkg.isNullOrEmpty() && !drawable.isNullOrEmpty() && !map.containsKey(pkg)) {
                        map[pkg] = drawable
                    }
                }
                event = parser.next()
            }
        } catch (e: Exception) {
            Log.w(TAG, "can't read the appfilter of $pack", e)
        }
        return map
    }

    private fun toPng(drawable: Drawable, defaultW: Int, defaultH: Int, maxW: Int): ByteArray {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            drawable.bitmap
        } else {
            var w = drawable.intrinsicWidth.takeIf { it > 0 } ?: defaultW
            var h = drawable.intrinsicHeight.takeIf { it > 0 } ?: defaultH
            if (w > maxW) {
                h = h * maxW / w
                w = maxW
            }
            Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also {
                val canvas = Canvas(it)
                drawable.setBounds(0, 0, w, h)
                drawable.draw(canvas)
            }
        }
        val scaled = if (bitmap.width > maxW) {
            Bitmap.createScaledBitmap(bitmap, maxW, bitmap.height * maxW / bitmap.width, true)
        } else {
            bitmap
        }
        return ByteArrayOutputStream().use {
            scaled.compress(Bitmap.CompressFormat.PNG, 100, it)
            it.toByteArray()
        }
    }

    private fun launchApp(pkg: String): Boolean {
        val pm = appContext.packageManager
        val intent = pm.getLeanbackLaunchIntentForPackage(pkg) ?: pm.getLaunchIntentForPackage(pkg) ?: return false
        return start(intent)
    }

    private fun isDefaultHome(): Boolean {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val info = appContext.packageManager.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)
        return info?.activityInfo?.packageName == appContext.packageName
    }

    private fun canWriteSecureSettings(): Boolean = HomeButtonService.canWriteSecureSettings(appContext)

    /**
     * Switches [HomeButtonService] on by itself - only possible once
     * WRITE_SECURE_SETTINGS was granted over adb
     * (`pm grant at.jaycloud.home.system android.permission.WRITE_SECURE_SETTINGS`).
     */
    private fun enableHomeButtonService(): Boolean = HomeButtonService.enable(appContext)

    companion object {
        const val TAG = "LauncherPlugin"

        private val ICON_PACK_ACTIONS = listOf(
            "org.adw.launcher.THEMES",
            "com.novalauncher.THEME",
            "com.teslacoilsw.launcher.THEME",
            "com.gau.go.launcherex.theme",
        )

        fun isFireTv(context: Context): Boolean =
            context.packageManager.hasSystemFeature("amazon.hardware.fire_tv")
    }
}
