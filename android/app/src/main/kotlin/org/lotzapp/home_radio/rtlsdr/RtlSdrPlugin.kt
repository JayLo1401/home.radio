package org.lotzapp.home_radio.rtlsdr

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicLong

/**
 * Flutter bridge to [RtlTcpClient] - lets the Dart side connect to an
 * `rtl_tcp` server (a local Android RTL-SDR driver app, e.g. "SDR driver"
 * by Martin Marinov - marto.rtl_tcp_andro on the Play Store - or a remote
 * one such as a Raspberry Pi with the dongle attached), tune it, and see
 * whether raw I/Q samples are actually flowing.
 *
 * This is deliberately a thin, immediately-testable layer on its own -
 * connect/tune/byte-rate feedback - built *before* any DAB+/FM/AM
 * demodulation exists, so the whole chain (dongle -> driver app -> network
 * -> this app) can be verified the moment the dongle arrives, independent
 * of the much bigger demodulation work that comes after.
 */
class RtlSdrPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var client: RtlTcpClient? = null
    private val bytesReceived = AtomicLong(0)
    private var statsRunnable: Runnable? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "home_radio/rtlsdr")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "home_radio/rtlsdr/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopStatsTimer()
        client?.disconnect()
        client = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emit(map: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(map) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "rtlConnect" -> {
                val host = call.argument<String>("host") ?: "127.0.0.1"
                val port = call.argument<Int>("port") ?: RtlTcpClient.DEFAULT_PORT
                client?.disconnect()
                bytesReceived.set(0)
                val newClient = RtlTcpClient(host, port)
                Thread({
                    try {
                        newClient.connect(RtlTcpClient.SampleListener { _, length ->
                            bytesReceived.addAndGet(length.toLong())
                        })
                        client = newClient
                        val info = newClient.dongleInfo
                        mainHandler.post {
                            result.success(
                                mapOf(
                                    "connected" to true,
                                    "tunerType" to info?.tunerType,
                                    "tunerGainCount" to info?.tunerGainCount,
                                ),
                            )
                        }
                        startStatsTimer()
                    } catch (e: Exception) {
                        Log.w(TAG, "rtlConnect failed: ${e.message}")
                        mainHandler.post { result.success(mapOf("connected" to false, "error" to e.message)) }
                    }
                }, "RtlConnect").start()
            }
            "rtlDisconnect" -> {
                stopStatsTimer()
                client?.disconnect()
                client = null
                result.success(null)
            }
            "rtlSetFrequency" -> {
                val hz = (call.argument<Number>("hz") ?: 0).toLong()
                client?.setFrequencyHz(hz)
                result.success(null)
            }
            "rtlSetSampleRate" -> {
                val hz = call.argument<Int>("hz") ?: 2_048_000
                client?.setSampleRateHz(hz)
                result.success(null)
            }
            "rtlSetGainMode" -> {
                val auto = call.argument<Boolean>("auto") ?: true
                client?.setTunerGainMode(auto)
                result.success(null)
            }
            "rtlSetGain" -> {
                val tenthDb = call.argument<Int>("tenthDb") ?: 0
                client?.setTunerGainTenthDb(tenthDb)
                result.success(null)
            }
            "rtlIsConnected" -> {
                result.success(client != null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startStatsTimer() {
        stopStatsTimer()
        var lastBytes = 0L
        val runnable = object : Runnable {
            override fun run() {
                val total = bytesReceived.get()
                val deltaBytesPerSec = total - lastBytes
                lastBytes = total
                emit(mapOf("type" to "stats", "totalBytes" to total, "bytesPerSec" to deltaBytesPerSec))
                mainHandler.postDelayed(this, 1000)
            }
        }
        statsRunnable = runnable
        mainHandler.postDelayed(runnable, 1000)
    }

    private fun stopStatsTimer() {
        statsRunnable?.let { mainHandler.removeCallbacks(it) }
        statsRunnable = null
    }

    companion object {
        private const val TAG = "DabProbe"
    }
}
