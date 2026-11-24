package at.jaycloud.home.system

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The Haussteuerung's display ("home_system/display"): keeping it on while the
 * dashboard shows, switching it off/on (also for Home Assistant via the admin
 * page), and display-by-motion with the camera ([MotionService]).
 * "home_system/motion" streams the motion level for the settings' test.
 */
class DisplayPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private var channel: MethodChannel? = null
    private var events: EventChannel? = null
    private lateinit var appContext: Context
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private var brightness: BrightnessController? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        brightness = BrightnessController(appContext)
        channel = MethodChannel(binding.binaryMessenger, "home_system/display").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "home_system/motion").also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    MotionService.listener = { level, moving ->
                        main.post { sink.success(mapOf("level" to level, "motion" to moving)) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    MotionService.listener = null
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        MotionService.listener = null
        channel = null
        events = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
        MotionService.dimHandler = { on -> main.post { setDimmed(on) } }
        brightness?.attach(binding.activity)
    }

    /** Darkened: lowest brightness, and Dart lays a black page over everything. */
    private fun setDimmed(on: Boolean) {
        activity?.window?.let { w ->
            val attrs = w.attributes
            attrs.screenBrightness = if (on) 0f else (brightness?.target() ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE)
            w.attributes = attrs
            if (on) {
                w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else if (!MotionService.dashboardActive) {
                w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
        channel?.invokeMethod("dimmed", on)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        MotionService.dimHandler = null
        brightness?.attach(null)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setKeepScreenOn" -> {
                val on = call.argument<Boolean>("on") ?: false
                activity?.window?.let {
                    if (on) it.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else it.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "setDashboardActive" -> {
                MotionService.dashboardActive = call.argument<Boolean>("active") ?: false
                MotionService.onUserInteraction()
                result.success(null)
            }
            "screenOff" -> result.success(MotionService.displayOff(appContext))
            "screenOn" -> {
                MotionService.displayOn(appContext)
                result.success(true)
            }
            "hasCamera" -> result.success(appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY))
            "hasCameraPermission" -> result.success(hasCameraPermission())
            "requestCameraPermission" -> requestCameraPermission(result)
            "canSwitchOff" -> result.success(HomeButtonService.instance != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            "startMotion" -> {
                MotionService.config = MotionService.Config(
                    sensitivity = call.argument<Int>("sensitivity") ?: 5,
                    timeoutMinutes = call.argument<Int>("timeoutMinutes") ?: 5,
                    webhookUrl = call.argument<String>("webhookUrl") ?: "",
                    deviceName = call.argument<String>("deviceName") ?: "",
                    dimOnly = call.argument<Boolean>("dimOnly") ?: false,
                )
                if (!hasCameraPermission()) return result.success(false)
                // Over the lock screen once the display came back on by motion.
                showWhenLocked(true)
                if (MotionService.running == null) {
                    try {
                        MotionService.start(appContext)
                    } catch (e: Exception) {
                        // Android 12+: a foreground service can't start from the background.
                        return result.error("START", e.message, null)
                    }
                }
                result.success(true)
            }
            "stopMotion" -> {
                MotionService.stop(appContext)
                showWhenLocked(false)
                result.success(null)
            }
            "motionRunning" -> result.success(MotionService.running != null)
            "setBrightness" -> {
                val mode = when (call.argument<String>("mode")) {
                    "fixed" -> BrightnessController.Mode.FIXED
                    "adaptive" -> BrightnessController.Mode.ADAPTIVE
                    else -> BrightnessController.Mode.SYSTEM
                }
                brightness?.configure(
                    mode,
                    level = (call.argument<Int>("level") ?: 60) / 100f,
                    min = (call.argument<Int>("min") ?: 10) / 100f,
                    max = (call.argument<Int>("max") ?: 100) / 100f,
                    luxForMax = (call.argument<Int>("luxForMax") ?: 200).toFloat(),
                )
                result.success(null)
            }
            // The light sensor now, for setting up adaptive brightness.
            "ambientLight" -> {
                val b = brightness
                b?.readOnce()
                result.success(mapOf("hasSensor" to (b?.hasSensor ?: false), "lux" to (b?.lux ?: -1f).toDouble()))
            }
            else -> result.notImplemented()
        }
    }

    private fun hasCameraPermission() =
        appContext.checkSelfPermission(android.Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun requestCameraPermission(result: MethodChannel.Result) {
        val a = activity ?: return result.success(false)
        if (hasCameraPermission()) return result.success(true)
        pendingPermission?.success(false)
        pendingPermission = result
        a.requestPermissions(arrayOf(android.Manifest.permission.CAMERA), REQUEST_CAMERA)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CAMERA) return false
        pendingPermission?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pendingPermission = null
        return true
    }

    private fun showWhenLocked(on: Boolean) {
        val a = activity ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            a.setShowWhenLocked(on)
            a.setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) a.window.addFlags(flags) else a.window.clearFlags(flags)
        }
    }

    companion object {
        private const val REQUEST_CAMERA = 4712

        /** After waking by motion: away with a lock screen without PIN (one with a PIN stays). */
        fun dismissKeyguard(activity: Activity) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.getSystemService(KeyguardManager::class.java)?.requestDismissKeyguard(activity, null)
            }
        }
    }
}
