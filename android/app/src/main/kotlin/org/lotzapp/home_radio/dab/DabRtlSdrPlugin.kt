package org.lotzapp.home_radio.dab

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray

/**
 * DAB+ over the RTL-SDR stick, via the vendored welle.io DAB decoding core
 * (see cpp/dabcore/ and cpp/dabcore_jni.cpp for the native side). This is
 * the real "so wie welle.io" DAB+ decode path - OFDM demodulation, FIC/MSC
 * decoding, DAB+ superframe/RS/AAC - replacing the old, Raontech-chip-only
 * [DabUsbPlugin]/[RaonTunerDriver], which is left in place (see its own doc
 * comment) but permanently unmatched now that the device filter targets
 * RTL-SDR only.
 *
 * Sample input is not a direct USB connection here: the decoder is an
 * rtl_tcp client (see dabcore/input/rtl_tcp.cpp), pointed at whichever
 * source the user picked in Settings - our own USB-TCP service
 * (RtlSdrUsbPlugin), an external driver app, or a network service. This
 * mirrors how RtlSdrTestScreen's own client already works, and lets several
 * things (this decoder, the raw test screen) share one dongle without
 * fighting over direct USB access.
 */
class DabRtlSdrPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val TAG = "DabRtlSdr"

        init {
            System.loadLibrary("dabrtlsdrnative")
        }
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var created = false
    private var audioPlayer: DabAudioPlayer? = null
    private val scanRunning = AtomicBoolean(false)
    private var scanThread: Thread? = null

    // --- native side (dabcore_jni.cpp) ---
    private external fun nativeCreate(): Boolean
    private external fun nativeDestroy()
    private external fun nativeSetServer(host: String, port: Int)
    private external fun nativeSetFrequency(hz: Int)
    private external fun nativeRestart(scan: Boolean)
    private external fun nativeStop()
    private external fun nativeGetEnsembleLabel(): String
    private external fun nativeGetServiceListJson(): String
    private external fun nativePlayService(serviceId: Int): Boolean
    private external fun nativeStopPlayback()

    // --- callbacks invoked FROM native code (see dabcore_jni.cpp's
    // GetMethodID calls) - names/signatures must match exactly. ---
    private fun nativeOnSyncChange(sync: Boolean) {
        emit(mapOf("type" to "syncChange", "sync" to sync))
    }

    private fun nativeOnEnsembleLabel(label: String) {
        emit(mapOf("type" to "ensembleLabel", "label" to label))
    }

    private fun nativeOnServiceDetected(serviceId: Int) {
        emit(mapOf("type" to "serviceDetected", "serviceId" to serviceId))
    }

    private fun nativeOnDynamicLabel(label: String) {
        emit(mapOf("type" to "dynamicLabel", "label" to label))
    }

    private fun nativeOnAudioPcm(pcm: ByteArray, sampleRate: Int, channels: Int) {
        audioPlayer?.submit(pcm, sampleRate, channels)
    }

    private fun nativeOnRsErrors(uncorrected: Boolean, corrected: Int) {
        emit(mapOf("type" to "rsErrors", "uncorrected" to uncorrected, "corrected" to corrected))
    }

    private fun nativeOnAacErrors(count: Int) {
        emit(mapOf("type" to "aacErrors", "count" to count))
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "home_radio/dab_rtlsdr")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "home_radio/dab_rtlsdr/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopScanIfRunning()
        stopPlayback()
        if (created) {
            nativeDestroy()
            created = false
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }

    private fun ensureCreated(): Boolean {
        if (created) return true
        created = nativeCreate()
        return created
    }

    private fun stopScanIfRunning() {
        scanRunning.set(false)
        scanThread?.join(1000)
        scanThread = null
    }

    private fun stopPlayback() {
        nativeStopPlayback()
        audioPlayer?.stop()
        audioPlayer = null
    }

    /**
     * Tunes across every DAB Band III channel (same table the old Raontech
     * driver used - it's a fixed, standard channel plan, not chip-specific),
     * giving the OFDM sync + FIC decode a few seconds per channel, and
     * records whichever ensembles/services were found. Mirrors the shape of
     * the old DabUsbPlugin.scanBand3() so the existing scan UI/event
     * handling in dab_stations_screen.dart could be reused almost as-is.
     */
    private fun scanBand3() {
        if (!ensureCreated()) {
            emit(mapOf("type" to "scanFinished", "foundCount" to 0, "error" to "native_create_failed"))
            return
        }
        var found = 0
        for ((index, channel) in RaonTunerDriver.BAND3_CHANNELS.withIndex()) {
            if (!scanRunning.get()) break
            emit(mapOf("type" to "scanProgress", "index" to index, "label" to channel.label, "freqKhz" to channel.freqKhz))
            nativeSetFrequency(channel.freqKhz * 1000)
            nativeRestart(true)
            // OFDM sync + a handful of FIC repetitions take a few seconds -
            // same order of magnitude as the old per-channel lock wait.
            try {
                Thread.sleep(3000)
            } catch (_: InterruptedException) {
                break
            }
            val ensembleLabel = nativeGetEnsembleLabel().takeIf { it.isNotBlank() }
            val services = try {
                val arr = JSONArray(nativeGetServiceListJson())
                (0 until arr.length()).map { i ->
                    val o = arr.getJSONObject(i)
                    mapOf("serviceId" to o.getInt("serviceId"), "label" to o.getString("label"))
                }
            } catch (e: Exception) {
                Log.w(TAG, "scanBand3: failed to parse service list", e)
                emptyList()
            }
            if (ensembleLabel != null || services.isNotEmpty()) {
                found++
                Log.i(TAG, "Channel ${channel.label} (${channel.freqKhz} kHz): ensemble='$ensembleLabel', ${services.size} service(s)")
                emit(
                    mapOf(
                        "type" to "channelLocked",
                        "index" to index,
                        "label" to channel.label,
                        "freqKhz" to channel.freqKhz,
                        "antennaLevel" to 0,
                        "ensembleLabel" to ensembleLabel,
                        "services" to services,
                    ),
                )
            }
        }
        nativeStop()
        scanRunning.set(false)
        emit(mapOf("type" to "scanFinished", "foundCount" to found))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setServer" -> {
                val host = call.argument<String>("host") ?: "127.0.0.1"
                val port = call.argument<Int>("port") ?: 1234
                if (ensureCreated()) {
                    nativeSetServer(host, port)
                    result.success(true)
                } else {
                    result.error("native_create_failed", "Could not create the DAB decoder", null)
                }
            }
            "scanBand3" -> {
                if (scanRunning.compareAndSet(false, true)) {
                    scanThread = Thread {
                        try {
                            scanBand3()
                        } finally {
                            scanRunning.set(false)
                        }
                    }.apply { start() }
                    result.success(null)
                } else {
                    result.error("busy", "A scan is already running", null)
                }
            }
            "stopScan" -> {
                stopScanIfRunning()
                nativeStop()
                result.success(null)
            }
            "tuneFrequency" -> {
                val freqKhz = call.argument<Int>("freqKhz") ?: 0
                if (!ensureCreated()) {
                    result.error("native_create_failed", "Could not create the DAB decoder", null)
                    return
                }
                nativeSetFrequency(freqKhz * 1000)
                nativeRestart(false)
                result.success(null)
            }
            "playService" -> {
                val freqKhz = call.argument<Int>("freqKhz") ?: 0
                val serviceId = call.argument<Int>("serviceId") ?: 0
                if (!ensureCreated()) {
                    result.error("native_create_failed", "Could not create the DAB decoder", null)
                    return
                }
                stopPlayback()
                nativeSetFrequency(freqKhz * 1000)
                nativeRestart(false)
                Thread {
                    // Give the OFDM processor a moment to (re-)sync and
                    // populate the FIC/service list before asking it to
                    // resolve+play a specific service - playService()
                    // returning false the instant after restart() would
                    // otherwise be the common case, not a real failure.
                    try {
                        Thread.sleep(2500)
                    } catch (_: InterruptedException) {
                        return@Thread
                    }
                    val player = DabAudioPlayer(null).also { it.start() }
                    audioPlayer = player
                    val ok = nativePlayService(serviceId)
                    mainHandler.post {
                        emit(mapOf("type" to "playbackStatus", "status" to if (ok) "playing" else "error"))
                        result.success(ok)
                    }
                }.start()
            }
            "stopPlayback" -> {
                stopPlayback()
                result.success(null)
            }
            "getEnsembleLabel" -> result.success(if (created) nativeGetEnsembleLabel() else "")
            else -> result.notImplemented()
        }
    }
}
