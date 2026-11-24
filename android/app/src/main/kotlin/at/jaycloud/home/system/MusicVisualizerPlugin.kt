package at.jaycloud.home.system

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Musik's visualisation following the music ("home_system/music_visualizer"):
 * Android's [Visualizer] on the music player's own audio session (ExoPlayer's,
 * from just_audio) gives the spectrum; it is folded into [BANDS] bands
 * (log spaced, 0..1) and streamed on "home_system/music_visualizer/levels"
 * about 20 times a second while listened to.
 *
 * The Visualizer needs RECORD_AUDIO - Android asks for "Mikrofon/Audio
 * aufnehmen", although only the app's own playback is looked at. Hence
 * optional (Settings → Musik), asked for only when switched on there.
 */
class MusicVisualizerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private var channel: MethodChannel? = null
    private var events: EventChannel? = null
    private lateinit var appContext: Context
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private var visualizer: Visualizer? = null
    private var sink: EventChannel.EventSink? = null
    private var sessionId = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "home_system/music_visualizer").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "home_system/music_visualizer/levels").also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                    val id = (arguments as? Number)?.toInt() ?: 0
                    if (!start(id)) events.error("unavailable", "Visualizer not available", null)
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                    stop()
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        channel?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        channel = null
        events = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasPermission())
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun hasPermission() =
        appContext.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        val a = activity ?: return result.success(false)
        if (hasPermission()) return result.success(true)
        pendingPermission?.success(false)
        pendingPermission = result
        a.requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), REQUEST_RECORD_AUDIO)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_RECORD_AUDIO) return false
        pendingPermission?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pendingPermission = null
        return true
    }

    private fun start(id: Int): Boolean {
        stop()
        if (id <= 0 || !hasPermission()) return false
        return try {
            val v = Visualizer(id)
            val range = Visualizer.getCaptureSizeRange()
            // 512 samples: enough resolution for the bass, cheap.
            v.setCaptureSize(min(max(512, range[0]), range[1]))
            v.setScalingMode(Visualizer.SCALING_MODE_NORMALIZED)
            val rate = min(Visualizer.getMaxCaptureRate(), 20000)
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(visualizer: Visualizer?, waveform: ByteArray?, samplingRate: Int) {}

                override fun onFftDataCapture(visualizer: Visualizer?, fft: ByteArray?, samplingRate: Int) {
                    if (fft == null) return
                    val bands = fold(fft, samplingRate / 1000.0)
                    main.post { sink?.success(bands) }
                }
            }, rate, false, true)
            v.setEnabled(true)
            visualizer = v
            sessionId = id
            true
        } catch (e: Throwable) {
            android.util.Log.w("MusicVisualizer", "start($id): $e")
            stop()
            false
        }
    }

    private fun stop() {
        try {
            visualizer?.setEnabled(false)
        } catch (_: Throwable) {
        }
        try {
            visualizer?.release()
        } catch (_: Throwable) {
        }
        visualizer = null
        sessionId = 0
    }

    /**
     * [fft]: Visualizer's format - [0] DC, [1] Nyquist, then re/im pairs.
     * [sampleRateHz]: the capture's rate. Returns [BANDS] levels 0..1 from
     * 40 Hz to 16 kHz on a log scale, in dB from -60 to 0.
     */
    private fun fold(fft: ByteArray, sampleRateHz: Double): DoubleArray {
        val n = fft.size / 2
        val out = DoubleArray(BANDS)
        if (n < 2 || sampleRateHz <= 0) return out
        val binHz = sampleRateHz / 2 / n
        for (b in 0 until BANDS) {
            val lo = 40.0 * (16000.0 / 40.0).pow(b.toDouble() / BANDS)
            val hi = 40.0 * (16000.0 / 40.0).pow((b + 1).toDouble() / BANDS)
            val from = max(1, (lo / binHz).toInt())
            val to = min(n - 1, max(from, (hi / binHz).toInt()))
            var peak = 0.0
            for (k in from..to) {
                val re = fft[2 * k].toDouble()
                val im = fft[2 * k + 1].toDouble()
                peak = max(peak, hypot(re, im))
            }
            // 128 is full scale for one bin.
            val db = 20 * log10(max(peak / 128.0, 1e-4))
            out[b] = ((db + 60) / 60).coerceIn(0.0, 1.0)
        }
        return out
    }

    companion object {
        private const val REQUEST_RECORD_AUDIO = 7301
        const val BANDS = 16
    }
}
