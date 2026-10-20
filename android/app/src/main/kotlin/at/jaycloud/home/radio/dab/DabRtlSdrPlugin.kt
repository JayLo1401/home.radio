package at.jaycloud.home.radio.dab

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONArray

/**
 * DAB+ over an RTL-SDR stick with our own receiver ([IntegratedDabEngine],
 * cpp/hrdab): scanning Band III, playing a service, fetching MOT slideshow
 * logos. The stick is either opened directly over USB ("useDirectUsb") or
 * reached through any rtl_tcp server ("setServer" - an external driver app or
 * a network service such as a Raspberry Pi).
 *
 * There is one native session at a time; scan, playback and logo fetch take
 * turns on it.
 */
class DabRtlSdrPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val TAG = "DabRtlSdr"
        private const val ACTION_USB_PERMISSION = "at.jaycloud.home.radio.DAB_RTLSDR_USB_PERMISSION"

        // Known RTL2832U dongle VID/PIDs (same list as RtlSdrUsbPlugin).
        private val knownRtlSdrIds = setOf(0x0bda to 0x2832, 0x0bda to 0x2838)
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private lateinit var context: Context
    private var created = false
    private var lastHost = "127.0.0.1"
    private var lastPort = 1234
    private var sessionEndpoint: String? = null // "host:port" of a live TCP session

    private val engineEvents = object : IntegratedDabEngine.Events {
        override fun onSync(sync: Boolean) = emit(mapOf("type" to "syncChange", "sync" to sync))
        override fun onEnsembleLabel(label: String) = emit(mapOf("type" to "ensembleLabel", "label" to label))
        override fun onServiceDetected(serviceId: Int) = emit(mapOf("type" to "serviceDetected", "serviceId" to serviceId))
        override fun onDynamicLabel(label: String) = emit(mapOf("type" to "dynamicLabel", "label" to label))
        override fun onSnr(snrDb: Float) {
            lastSnrDb = snrDb
            emit(mapOf("type" to "snr", "snrDb" to snrDb))
        }
        override fun onRsErrors(uncorrected: Boolean, corrected: Int) =
            emit(mapOf("type" to "rsErrors", "uncorrected" to uncorrected, "corrected" to corrected))
        override fun onAacErrors(count: Int) = emit(mapOf("type" to "aacErrors", "count" to count))

        // e.g. "HE-AAC v2, 48 kHz Parametric Stereo @ 88 kbit/s", for the
        // Now Playing banner; sent once per service start / format change.
        override fun onAudioFormat(format: String) = emit(mapOf("type" to "audioFormat", "format" to format))
        override fun onAudioConfig(asc: ByteArray, sampleRate: Int, channels: Int) {
            audioPlayer?.onAudioConfig(asc, sampleRate, channels)
        }
        override fun onAccessUnit(au: ByteArray, ok: Boolean) {
            audioPlayer?.onAccessUnit(au, ok)
        }
        override fun onSlide(data: ByteArray, contentSubType: Int) = saveSlide(data, contentSubType)

        // rtl_tcp connection lost/restored (TCP mode) or the stick vanished (USB).
        override fun onStatus(isError: Boolean, message: String) {
            Log.i(TAG, "status: isError=$isError message=$message")
            emit(mapOf("type" to "connectionMessage", "isError" to isError, "message" to message))
        }
    }

    private val engine by lazy { IntegratedDabEngine(engineEvents) }

    // Kept open for as long as the USB session exists: closing it would close
    // the fd the native driver works on.
    private var directConnection: UsbDeviceConnection? = null

    private val usbManager: UsbManager by lazy {
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    }

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionDeviceName: String? = null

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERMISSION) return
            synchronized(this) {
                val device = intent.getUsbDeviceExtra()
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (device?.deviceName == pendingPermissionDeviceName) {
                    pendingPermissionResult?.success(granted)
                    pendingPermissionResult = null
                    pendingPermissionDeviceName = null
                }
            }
        }
    }

    private fun Intent.getUsbDeviceExtra(): UsbDevice? {
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
    }

    private fun isRtlSdr(device: UsbDevice) = (device.vendorId to device.productId) in knownRtlSdrIds

    @Volatile private var audioPlayer: DabAacPlayer? = null

    // Bumped on every "playService" call, so an in-flight retry loop can tell
    // it has been superseded (fast station switches, remote next/previous)
    // and give the shared tuner up immediately instead of fighting the newer
    // request for it.
    private val playRequestId = AtomicInteger(0)

    private val scanRunning = AtomicBoolean(false)
    private var scanThread: Thread? = null
    private val logoFetchRunning = AtomicBoolean(false)
    private var logoFetchThread: Thread? = null

    // The (freqKhz, serviceId) currently tuned - set by playback and by the
    // logo fetch, so a slideshow image can be filed under the right station.
    @Volatile private var currentContext: Pair<Int, Int>? = null

    // Set when a slideshow image was saved for whatever fetchLogos() waits on.
    @Volatile private var lastLogoPath: String? = null

    // Latest SNR (dB) - reported per channel by the scan.
    @Volatile private var lastSnrDb: Float = 0f

    /**
     * A MOT slideshow image of the current station - the broadcaster's own
     * logo/cover art. Saved as filesDir/dab_logos/<freq>_<sid>.jpg|png (one
     * file per station, newer slides overwrite it). Written off the native
     * decoder thread so slow flash I/O can never delay audio decoding.
     */
    private fun saveSlide(data: ByteArray, contentSubType: Int) {
        val ctx = currentContext ?: return
        val ext = if (contentSubType == 3) "png" else "jpg" // MOT sub-type 1 = JPEG, 3 = PNG
        Thread {
            try {
                val dir = File(context.filesDir, "dab_logos").apply { mkdirs() }
                val file = File(dir, "${ctx.first}_${ctx.second}.$ext")
                FileOutputStream(file).use { it.write(data) }
                lastLogoPath = file.absolutePath
                emit(
                    mapOf(
                        "type" to "motLogo",
                        "freqKhz" to ctx.first,
                        "serviceId" to ctx.second,
                        "path" to file.absolutePath,
                    ),
                )
            } catch (e: Exception) {
                Log.w(TAG, "saveSlide: failed to save slideshow image", e)
            }
        }.start()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "home_radio/dab_rtlsdr")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "home_radio/dab_rtlsdr/events")
        eventChannel.setStreamHandler(this)

        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(usbReceiver, filter)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        try {
            context.unregisterReceiver(usbReceiver)
        } catch (_: IllegalArgumentException) {
        }
        stopScanIfRunning()
        stopLogoFetchIfRunning()
        stopPlayback()
        destroySession()
    }

    private fun destroySession() {
        if (created) {
            engine.destroy()
            created = false
        }
        sessionEndpoint = null
        directConnection?.close()
        directConnection = null
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
        created = engine.createTcp(lastHost, lastPort)
        sessionEndpoint = if (created) "$lastHost:$lastPort" else null
        return created
    }

    /**
     * USB counterpart to "setServer": asks for the USB permission if needed,
     * opens the RTL-SDR stick and hands its fd to the native driver.
     */
    private fun useDirectUsb(result: MethodChannel.Result) {
        if (created && directConnection != null) {
            result.success(true)
            return
        }
        if (created) {
            // a TCP session is live - the stick replaces it
            stopPlayback()
            destroySession()
        }
        val device = usbManager.deviceList.values.find { isRtlSdr(it) }
        if (device == null) {
            result.success(false)
            return
        }
        if (!usbManager.hasPermission(device)) {
            pendingPermissionResult = object : MethodChannel.Result {
                override fun success(perm: Any?) {
                    if (perm == true) openDirectUsb(device, result) else result.success(false)
                }
                override fun error(code: String, msg: String?, details: Any?) = result.success(false)
                override fun notImplemented() = result.success(false)
            }
            pendingPermissionDeviceName = device.deviceName
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                0,
                Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
                flags,
            )
            usbManager.requestPermission(device, pendingIntent)
            return
        }
        openDirectUsb(device, result)
    }

    private fun openDirectUsb(device: UsbDevice, result: MethodChannel.Result) {
        val connection = usbManager.openDevice(device)
        if (connection == null) {
            result.success(false)
            return
        }
        // The native driver talks usbfs directly, so the interface must be
        // claimed (this also detaches a kernel DVB driver, if any).
        if (!connection.claimInterface(device.getInterface(0), true)) {
            Log.w(TAG, "openDirectUsb: could not claim the RTL-SDR interface")
        }
        val ok = engine.createUsb(connection.fileDescriptor)
        if (ok) {
            directConnection = connection
            created = true
        } else {
            connection.close()
        }
        result.success(ok)
    }

    private fun stopScanIfRunning() {
        scanRunning.set(false)
        scanThread?.join(1000)
        scanThread = null
    }

    private fun stopLogoFetchIfRunning() {
        logoFetchRunning.set(false)
        logoFetchThread?.join(1000)
        logoFetchThread = null
    }

    private fun stopPlayback() {
        if (created) engine.stopService()
        audioPlayer?.stop()
        audioPlayer = null
        currentContext = null
    }

    /**
     * Tunes through every Band III channel and reports the ensembles and
     * services found. Each channel gets up to 6 s to show anything; once
     * something shows up the window grows, since the service labels trickle
     * in over several FIC repetitions - but it ends early once the service
     * count has not grown for ~2 s.
     */
    private fun scanBand3() {
        if (!ensureCreated()) {
            emit(mapOf("type" to "scanFinished", "foundCount" to 0, "error" to "native_create_failed"))
            return
        }
        stopLogoFetchIfRunning()
        var found = 0
        for ((index, channel) in DabChannels.BAND3.withIndex()) {
            if (!scanRunning.get()) break
            emit(mapOf("type" to "scanProgress", "index" to index, "label" to channel.label, "freqKhz" to channel.freqKhz))
            lastSnrDb = 0f
            engine.tune(channel.freqKhz * 1000)
            var ensembleLabel: String? = null
            var services: List<Map<String, Any>> = emptyList()
            val initialDeadline = System.currentTimeMillis() + 6000
            var deadline = initialDeadline
            var lastServiceCount = 0
            var staleRounds = 0
            while (scanRunning.get() && System.currentTimeMillis() < deadline) {
                try {
                    Thread.sleep(500)
                } catch (_: InterruptedException) {
                    break
                }
                ensembleLabel = engine.ensembleLabel().takeIf { it.isNotBlank() }
                services = try {
                    val arr = JSONArray(engine.serviceListJson())
                    (0 until arr.length()).map { i ->
                        val o = arr.getJSONObject(i)
                        mapOf("serviceId" to o.getInt("serviceId"), "label" to o.getString("label"))
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "scanBand3: failed to parse service list", e)
                    emptyList()
                }
                val foundSomething = ensembleLabel != null || services.isNotEmpty()
                if (foundSomething && deadline == initialDeadline) {
                    deadline = System.currentTimeMillis() + 8000
                }
                if (services.size > lastServiceCount) {
                    lastServiceCount = services.size
                    staleRounds = 0
                } else if (foundSomething) {
                    staleRounds++
                    if (staleRounds >= 4) break
                }
            }
            if (ensembleLabel != null || services.isNotEmpty()) {
                found++
                Log.i(TAG, "Channel ${channel.label} (${channel.freqKhz} kHz): ensemble='$ensembleLabel', ${services.size} service(s), SNR=${lastSnrDb}dB")
                emit(
                    mapOf(
                        "type" to "channelLocked",
                        "index" to index,
                        "label" to channel.label,
                        "freqKhz" to channel.freqKhz,
                        "snrDb" to lastSnrDb,
                        "ensembleLabel" to ensembleLabel,
                        "services" to services,
                    ),
                )
            }
        }
        engine.halt()
        scanRunning.set(false)
        emit(mapOf("type" to "scanFinished", "foundCount" to found))
    }

    /**
     * Tunes to each (freqKhz, serviceId) in turn and waits for a MOT
     * slideshow image (see [saveSlide]). No audio output is created - this
     * is a background probe, nothing the user wants to hear station by
     * station. Slides typically come every 10-20+ s, some stations send none.
     */
    private fun fetchLogos(stations: List<Pair<Int, Int>>) {
        if (!ensureCreated()) {
            emit(mapOf("type" to "logoScanFinished", "foundCount" to 0, "error" to "native_create_failed"))
            return
        }
        var found = 0
        for ((index, station) in stations.withIndex()) {
            if (!logoFetchRunning.get()) break
            val (freqKhz, serviceId) = station
            emit(
                mapOf(
                    "type" to "logoScanProgress",
                    "index" to index,
                    "total" to stations.size,
                    "freqKhz" to freqKhz,
                    "serviceId" to serviceId,
                ),
            )
            stopPlayback()
            lastLogoPath = null
            currentContext = freqKhz to serviceId
            engine.tune(freqKhz * 1000)
            var playing = false
            val playDeadline = System.currentTimeMillis() + 8000
            while (logoFetchRunning.get() && !playing && System.currentTimeMillis() < playDeadline) {
                playing = engine.playService(serviceId)
                if (!playing) {
                    try {
                        Thread.sleep(500)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }
            if (playing) {
                val deadline = System.currentTimeMillis() + 15000
                while (logoFetchRunning.get() && lastLogoPath == null && System.currentTimeMillis() < deadline) {
                    try {
                        Thread.sleep(300)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }
            val path = lastLogoPath
            if (path != null) {
                found++
                emit(mapOf("type" to "logoFound", "freqKhz" to freqKhz, "serviceId" to serviceId, "path" to path))
            } else {
                emit(mapOf("type" to "logoNotFound", "freqKhz" to freqKhz, "serviceId" to serviceId))
            }
        }
        stopPlayback()
        engine.halt()
        logoFetchRunning.set(false)
        emit(mapOf("type" to "logoScanFinished", "foundCount" to found))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setServer" -> {
                val host = call.argument<String>("host") ?: "127.0.0.1"
                val port = call.argument<Int>("port") ?: 1234
                lastHost = host
                lastPort = port
                // The rtl_tcp endpoint (or the USB stick) is bound when the
                // session is created, so a different source needs a new one.
                if (created && sessionEndpoint != "$host:$port") {
                    stopPlayback()
                    destroySession()
                }
                if (!ensureCreated()) {
                    result.error("native_create_failed", "Could not create the DAB decoder", null)
                    return
                }
                // A real TCP probe, so a scan can refuse to start when nothing
                // listens at host:port instead of scanning 41 empty channels.
                Thread {
                    val reachable = try {
                        Socket().use {
                            it.connect(InetSocketAddress(host, port), 1500)
                            true
                        }
                    } catch (e: Exception) {
                        false
                    }
                    mainHandler.post { result.success(reachable) }
                }.start()
            }
            "useDirectUsb" -> useDirectUsb(result)
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
                if (created) engine.halt()
                result.success(null)
            }
            "tuneFrequency" -> {
                val freqKhz = call.argument<Int>("freqKhz") ?: 0
                if (!ensureCreated()) {
                    result.error("native_create_failed", "Could not create the DAB decoder", null)
                    return
                }
                engine.tune(freqKhz * 1000)
                result.success(null)
            }
            "playService" -> {
                val freqKhz = call.argument<Int>("freqKhz") ?: 0
                val serviceId = call.argument<Int>("serviceId") ?: 0
                if (!ensureCreated()) {
                    result.error("native_create_failed", "Could not create the DAB decoder", null)
                    return
                }
                // One shared session: a running scan or logo fetch would keep
                // retuning underneath this request.
                stopScanIfRunning()
                stopLogoFetchIfRunning()
                stopPlayback()
                val myRequestId = playRequestId.incrementAndGet()
                Thread {
                    // A resolved service is not yet proof that audio flows,
                    // so wait for real PCM to reach the AudioTrack and do one
                    // full retune + retry if none arrives.
                    fun superseded() = playRequestId.get() != myRequestId
                    var ok = false
                    var pcmVerified = false
                    var attempt = 0
                    while (!pcmVerified && attempt < 2) {
                        if (superseded()) {
                            mainHandler.post { result.success(false) }
                            return@Thread
                        }
                        attempt++
                        engine.tune(freqKhz * 1000)
                        lateinit var player: DabAacPlayer
                        player = DabAacPlayer(context) {
                            // Another app took the audio focus. Ignore stale
                            // callbacks of a player already replaced by a
                            // station switch (Android may report those too).
                            mainHandler.post {
                                if (audioPlayer !== player) return@post
                                Log.i(TAG, "playService: audio focus lost, stopping DAB+ playback")
                                stopPlayback()
                                emit(mapOf("type" to "audioFocusLost"))
                            }
                        }
                        player.start()
                        audioPlayer = player
                        ok = false
                        val deadline = System.currentTimeMillis() + 8000
                        while (!ok && !superseded() && System.currentTimeMillis() < deadline) {
                            ok = engine.playService(serviceId)
                            if (!ok) {
                                try {
                                    Thread.sleep(200)
                                } catch (_: InterruptedException) {
                                    break
                                }
                            }
                        }
                        if (superseded()) {
                            mainHandler.post { result.success(false) }
                            return@Thread
                        }
                        if (!ok) break // service never resolved - a retry won't help

                        val writeCountAtStart = player.pcmWriteCount
                        val pcmDeadline = System.currentTimeMillis() + 4000
                        while (player.pcmWriteCount == writeCountAtStart && !superseded() && System.currentTimeMillis() < pcmDeadline) {
                            try {
                                Thread.sleep(200)
                            } catch (_: InterruptedException) {
                                break
                            }
                        }
                        if (superseded()) {
                            mainHandler.post { result.success(false) }
                            return@Thread
                        }
                        pcmVerified = player.pcmWriteCount > writeCountAtStart
                        if (!pcmVerified && attempt < 2) {
                            Log.w(TAG, "playService: 'playing' but no PCM arrived, retrying full tune (attempt $attempt)")
                            stopPlayback()
                        }
                    }
                    val reallyOk = ok && pcmVerified
                    currentContext = if (reallyOk) freqKhz to serviceId else null
                    mainHandler.post {
                        emit(mapOf("type" to "playbackStatus", "status" to if (reallyOk) "playing" else "error"))
                        result.success(reallyOk)
                    }
                }.start()
            }
            "stopPlayback" -> {
                // Stopping joins the audio threads - keep that off the UI thread.
                Thread {
                    stopPlayback()
                    mainHandler.post { result.success(null) }
                }.start()
            }
            "resetSession" -> {
                // The stick was unplugged (see RtlSdrUsbService's attach/detach
                // events): drop the session so the next attempt starts fresh.
                // Background thread, since closing a dead USB handle can block.
                Thread {
                    stopScanIfRunning()
                    stopLogoFetchIfRunning()
                    stopPlayback()
                    destroySession()
                    mainHandler.post { result.success(null) }
                }.start()
            }
            "getEnsembleLabel" -> result.success(if (created) engine.ensembleLabel() else "")
            "fetchLogos" -> {
                @Suppress("UNCHECKED_CAST")
                val stationMaps = call.argument<List<Map<String, Any>>>("stations") ?: emptyList()
                val stations = stationMaps.map { (it["freqKhz"] as Number).toInt() to (it["serviceId"] as Number).toInt() }
                if (stations.isEmpty()) {
                    result.success(null)
                    return
                }
                if (!logoFetchRunning.compareAndSet(false, true)) {
                    result.error("busy", "A logo fetch is already running", null)
                    return
                }
                stopScanIfRunning()
                logoFetchThread = Thread {
                    try {
                        fetchLogos(stations)
                    } finally {
                        logoFetchRunning.set(false)
                    }
                }.apply { start() }
                result.success(null)
            }
            "stopLogoFetch" -> {
                stopLogoFetchIfRunning()
                if (created) engine.halt()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
