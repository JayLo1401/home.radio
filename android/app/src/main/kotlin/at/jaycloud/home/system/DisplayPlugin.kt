package at.jaycloud.home.system

import android.app.Activity
import android.app.ActivityManager
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.Locale

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

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val pendingSpeech = mutableListOf<String>()

    /** Display on/off - for Home Assistant (Dart's DisplayService.screenOn). */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val on = intent.action == Intent.ACTION_SCREEN_ON
            main.post { channel?.invokeMethod("screen", on) }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        brightness = BrightnessController(appContext)
        channel = MethodChannel(binding.binaryMessenger, "home_system/display").also { it.setMethodCallHandler(this) }
        MotionService.motionListener = { on -> main.post { channel?.invokeMethod("motion", on) } }
        MotionService.frameListener = { jpeg -> main.post { channel?.invokeMethod("cameraFrame", jpeg) } }
        try {
            appContext.registerReceiver(
                screenReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_ON)
                    addAction(Intent.ACTION_SCREEN_OFF)
                },
            )
        } catch (e: Exception) {
            Log.w(TAG, "no screen on/off broadcasts", e)
        }
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
        MotionService.motionListener = null
        MotionService.frameListener = null
        try {
            appContext.unregisterReceiver(screenReceiver)
        } catch (_: Exception) {
        }
        tts?.shutdown()
        tts = null
        ttsReady = false
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
            // For Home Assistant: battery, light, memory, storage, display.
            "deviceStatus" -> Thread {
                val status = try {
                    deviceStatus()
                } catch (e: Exception) {
                    Log.w(TAG, "deviceStatus failed", e)
                    emptyMap<String, Any?>()
                }
                main.post { result.success(status) }
            }.start()
            // The media volume (0..100) - Home Assistant's "Lautstärke".
            "setVolume" -> {
                try {
                    val audio = appContext.getSystemService(AudioManager::class.java)
                    val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    val percent = (call.argument<Int>("percent") ?: 0).coerceIn(0, 100)
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, (percent * max + 50) / 100, 0)
                    result.success(true)
                } catch (e: Exception) {
                    Log.w(TAG, "can't set the volume", e)
                    result.success(false)
                }
            }
            "setCameraSharing" -> {
                MotionService.setSharing(call.argument<Boolean>("on") ?: false)
                result.success(null)
            }
            "speak" -> {
                speak(call.argument<String>("text") ?: "")
                result.success(null)
            }
            // Home System in front again (from another app, or the display off).
            "bringToFront" -> {
                MotionService.wake(appContext)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun deviceStatus(): Map<String, Any?> {
        val battery = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val present = battery?.getBooleanExtra(BatteryManager.EXTRA_PRESENT, false) ?: false
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val plugged = (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        val temperature = battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) ?: Int.MIN_VALUE
        val memory = ActivityManager.MemoryInfo()
        appContext.getSystemService(ActivityManager::class.java)?.getMemoryInfo(memory)
        val data = StatFs(Environment.getDataDirectory().path)
        val audio = appContext.getSystemService(AudioManager::class.java)
        val maxVolume = audio?.getStreamMaxVolume(AudioManager.STREAM_MUSIC) ?: 0
        val volume = if (audio != null && maxVolume > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC) * 100 / maxVolume else null
        val b = brightness
        b?.readOnce()
        return mapOf(
            // TV boxes have no battery (some report one that isn't there).
            "hasBattery" to (present && level >= 0 && scale > 0),
            "battery" to if (level >= 0 && scale > 0) level * 100 / scale else null,
            "plugged" to plugged,
            "batteryTemperature" to if (temperature != Int.MIN_VALUE) temperature / 10.0 else null,
            "hasLight" to (b?.hasSensor ?: false),
            "lux" to (b?.lux ?: -1f).toDouble(),
            "freeMemory" to memory.availMem,
            "totalMemory" to memory.totalMem,
            "freeStorage" to data.availableBytes,
            "totalStorage" to data.totalBytes,
            "screenOn" to (MotionService.isScreenOn(appContext) && !MotionService.dimmed),
            "hasCamera" to appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY),
            "volume" to volume,
        )
    }

    /** Text to speech (Home Assistant's notify) - in the device's language. */
    private fun speak(text: String) {
        if (text.isBlank()) return
        val engine = tts
        if (engine != null && ttsReady) {
            engine.speak(text, TextToSpeech.QUEUE_ADD, null, "home_system_" + System.nanoTime())
            return
        }
        pendingSpeech.add(text)
        if (engine != null) return
        tts = TextToSpeech(appContext) { status ->
            main.post {
                ttsReady = status == TextToSpeech.SUCCESS
                if (!ttsReady) {
                    Log.w(TAG, "text to speech not available ($status)")
                    pendingSpeech.clear()
                    tts?.shutdown()
                    tts = null
                    return@post
                }
                tts?.language = Locale.getDefault()
                val queued = pendingSpeech.toList()
                pendingSpeech.clear()
                queued.forEach { speak(it) }
            }
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
        private const val TAG = "DisplayPlugin"
        private const val REQUEST_CAMERA = 4712

        /** After waking by motion: away with a lock screen without PIN (one with a PIN stays). */
        fun dismissKeyguard(activity: Activity) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.getSystemService(KeyguardManager::class.java)?.requestDismissKeyguard(activity, null)
            }
        }
    }
}
