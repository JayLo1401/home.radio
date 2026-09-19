package org.lotzapp.home_radio.dab

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
        private const val ACTION_USB_PERMISSION = "org.lotzapp.home_radio.DAB_RTLSDR_USB_PERMISSION"

        // Same known RTL2832U dongle VID/PIDs as RtlSdrUsbPlugin (see that
        // class's own doc comment) - duplicated rather than shared, since
        // this plugin's direct-USB path is deliberately independent of
        // RtlSdrUsbPlugin (see direct_rtlsdr_input.h): they're mutually
        // exclusive consumers of the same physical dongle, not collaborators.
        private val knownRtlSdrIds = setOf(0x0bda to 0x2832, 0x0bda to 0x2838)

        init {
            System.loadLibrary("dabrtlsdrnative")
        }
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private lateinit var context: Context
    private var created = false

    // Kept alive for as long as direct-USB mode is active: closing this
    // would close the native fd DirectRtlSdrInput uses (see
    // RtlSdrUsbPlugin.openConnection for the same pattern).
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
    private var audioPlayer: DabAudioPlayer? = null
    private val scanRunning = AtomicBoolean(false)
    private var scanThread: Thread? = null
    private val logoFetchRunning = AtomicBoolean(false)
    private var logoFetchThread: Thread? = null

    // Whichever (freqKhz, serviceId) is currently tuned/playing - set by both
    // "playService" (normal listening) and the logo-fetch loop below, so a
    // MOT slideshow image arriving via nativeOnMot() can always be tagged
    // with the right station, whether it showed up during a dedicated logo
    // scan or just from listening normally.
    @Volatile private var currentContext: Pair<Int, Int>? = null

    // Set by nativeOnMot() when a slideshow image was captured for whatever
    // fetchLogos() is currently waiting on - a plain field rather than a
    // queue/latch since only one station is ever being probed at a time.
    @Volatile private var lastLogoPath: String? = null

    // Latest onSNR() reading (dB) - read by the scan loop for its per-
    // channel result and forwarded live during normal playback.
    @Volatile private var lastSnrDb: Float = 0f

    // --- native side (dabcore_jni.cpp) ---
    private external fun nativeCreate(): Boolean
    private external fun nativeCreateDirect(fd: Int): Boolean
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

    private fun nativeOnSnr(snr: Float) {
        lastSnrDb = snr
        emit(mapOf("type" to "snr", "snrDb" to snr))
    }

    /**
     * A DAB+ MOT slideshow image arrived for whichever station is currently
     * tuned (see [currentContext]) - the real, broadcast-provided station
     * logo/cover art welle.io itself shows, as opposed to the best-effort
     * Radio-Browser name lookup already used elsewhere in this app. Saved
     * under the app's own files dir, keyed by freqKhz+serviceId so it's
     * stable across scans (one file per station, overwritten as newer
     * slides arrive - this project isn't trying to show a rotating
     * slideshow, just capture *a* representative image).
     */
    private fun nativeOnMot(data: ByteArray, contentSubType: Int) {
        val ctx = currentContext ?: return
        val ext = when (contentSubType) {
            1 -> "jpg" // MOT content sub-type 0x01
            3 -> "png" // MOT content sub-type 0x03
            else -> "jpg"
        }
        // This callback fires straight out of native code on the same
        // real-time decode thread that also produces PCM (see
        // AndroidProgrammeHandler::onMOT in dabcore_jni.cpp) - the same
        // thread the AudioTrack-setup fix in DabAudioPlayer.submit() exists
        // to protect. A slideshow image is tens of KB; writing it to flash
        // storage synchronously here would block that thread for however
        // long that write takes, which can spike well beyond typical under
        // I/O contention (e.g. a concurrent Drift/SQLite write). Now that
        // this fires during every normal playback, not just the dedicated
        // logo-fetch action, do the write on a plain background thread
        // instead - a slideshow image landing a few ms later than the
        // instant it was decoded is completely unnoticeable, unlike an
        // audio glitch.
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
                Log.w(TAG, "nativeOnMot: failed to save slideshow image", e)
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
        if (created) {
            nativeDestroy()
            created = false
        }
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
        created = nativeCreate()
        return created
    }

    /**
     * Direct-USB counterpart to "setServer": for "own USB service" mode,
     * opens the RTL-SDR dongle ourselves and hands the fd straight to
     * nativeCreateDirect() (DirectRtlSdrInput, see that header's doc
     * comment) instead of going through RtlSdrUsbPlugin's rtl_tcp TCP
     * server/CRTL_TCP_Client loopback - eliminating that redundant
     * in-process network round trip, suspected to add CPU/scheduling
     * overhead behind the OFDM-sync/audio-underrun instability seen during
     * long playback.
     *
     * Deliberately does not call RtlSdrUsbPlugin at all: direct mode and
     * that TCP server are mutually exclusive consumers of the same USB
     * device (only one open rtlsdr_dev_t/UsbDeviceConnection can claim it),
     * matching the existing scan/playback/logo-fetch mutual-exclusion
     * precedent within this same session.
     */
    private fun useDirectUsb(result: MethodChannel.Result) {
        if (created) {
            result.success(true)
            return
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
        val ok = nativeCreateDirect(connection.fileDescriptor)
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
        nativeStopPlayback()
        audioPlayer?.stop()
        audioPlayer = null
        currentContext = null
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
        stopLogoFetchIfRunning()
        var found = 0
        for ((index, channel) in RaonTunerDriver.BAND3_CHANNELS.withIndex()) {
            if (!scanRunning.get()) break
            emit(mapOf("type" to "scanProgress", "index" to index, "label" to channel.label, "freqKhz" to channel.freqKhz))
            lastSnrDb = 0f
            nativeSetFrequency(channel.freqKhz * 1000)
            nativeRestart(true)
            // OFDM sync needs the software AGC (see CRTL_TCP_Client) to
            // settle first - observed taking a few hundred ms right after
            // (re)tuning, on top of the sync/FIC time itself - so poll
            // repeatedly instead of a single fixed sleep: channels with no
            // real signal still take the full budget, but a channel that
            // locks quickly doesn't need to wait for it.
            //
            // Once *something* (ensemble label or a first service) shows
            // up, the window is extended: a single FIC capture rarely
            // contains every service's label (see the old Raontech-era
            // scanBand3's own comment on the same issue) - the full list
            // fills in gradually over more FIC repetitions. Extending
            // blindly would slow down every found channel by the same
            // amount though, so this stops early instead once the service
            // count has gone a couple of seconds without growing.
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
                ensembleLabel = nativeGetEnsembleLabel().takeIf { it.isNotBlank() }
                services = try {
                    val arr = JSONArray(nativeGetServiceListJson())
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
                    if (staleRounds >= 4) break // ~2s with no new services after finding something
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
        nativeStop()
        scanRunning.set(false)
        emit(mapOf("type" to "scanFinished", "foundCount" to found))
    }

    /**
     * Tunes to each given (freqKhz, serviceId) in turn and waits for a real
     * DAB+ MOT slideshow image (see [nativeOnMot]) - the actual broadcast
     * logo/cover art, as opposed to the best-effort Radio-Browser name
     * lookup used elsewhere in this app. Deliberately does not create a
     * [DabAudioPlayer] (audioPlayer stays null, so [nativeOnAudioPcm] just
     * discards the decoded PCM) - this is a background probe, not something
     * the user wants to hear station after station.
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
            nativeSetFrequency(freqKhz * 1000)
            nativeRestart(false)
            // A single fixed 2s sleep before one nativePlayService() attempt
            // used to be the whole story here - if OFDM sync/FIC-subchannel
            // resolution for THIS particular channel hadn't finished by then
            // (which, per scanBand3()'s own adaptive-timing comment, varies
            // a lot per channel - anywhere from a few hundred ms to several
            // seconds), playService() returned false and the station was
            // reported "not found" without ever waiting for a slideshow
            // image at all. That's the likely reason only a couple of ~37
            // stations ever got a logo. Retry like scanBand3() does instead
            // of giving up after one attempt.
            var playing = false
            val playDeadline = System.currentTimeMillis() + 8000
            while (logoFetchRunning.get() && !playing && System.currentTimeMillis() < playDeadline) {
                playing = nativePlayService(serviceId)
                if (!playing) {
                    try {
                        Thread.sleep(500)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }
            if (playing) {
                // Slideshow images are typically sent every 10-20+ seconds
                // (some stations don't send any at all) - this is
                // deliberately the slow part of a dedicated, separate
                // action, not something run as part of the regular scan.
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
        nativeStop()
        logoFetchRunning.set(false)
        emit(mapOf("type" to "logoScanFinished", "foundCount" to found))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setServer" -> {
                val host = call.argument<String>("host") ?: "127.0.0.1"
                val port = call.argument<Int>("port") ?: 1234
                if (!ensureCreated()) {
                    result.error("native_create_failed", "Could not create the DAB decoder", null)
                    return
                }
                nativeSetServer(host, port)
                // A quick real TCP probe, not just "did the native session get
                // created" - that always succeeds regardless of whether
                // anything is actually listening at host:port (the rtl_tcp
                // client only tries to connect once a scan/tune starts). This
                // way "Sendersuchlauf starten" can refuse to even begin when
                // the configured RTL-SDR source isn't reachable, instead of
                // running the whole ~41-channel scan and finding nothing.
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
                // There is only one shared DAB session (one RadioReceiver/
                // CRTL_TCP_Client) - a scan still running in the background
                // would keep re-tuning to other channels via its own
                // nativeSetFrequency/nativeRestart calls and fight with
                // whatever this playback request just set, which is exactly
                // what looked like "can't connect to source" from the UI.
                stopScanIfRunning()
                stopLogoFetchIfRunning()
                stopPlayback()
                nativeSetFrequency(freqKhz * 1000)
                nativeRestart(false)
                Thread {
                    // Give the OFDM processor a moment to (re-)sync and
                    // populate the FIC/service list before asking it to
                    // resolve+play a specific service - playService()
                    // returning false the instant after restart() would
                    // otherwise be the common case, not a real failure.
                    //
                    // A single fixed 2.5s sleep then one attempt used to be
                    // the whole story here - fine on an already-warmed-up
                    // session, but how long OFDM sync/FIC-subchannel
                    // resolution actually takes varies a lot per channel
                    // (scanBand3() already accounts for this with its own
                    // adaptive per-channel timing) and is worst right after
                    // a cold app start (fresh AGC convergence, no prior lock
                    // on anything) - exactly when this showed up as "Kein
                    // Empfang auf dieser Frequenz" on the very first
                    // autostart. Retry for longer instead of giving up after
                    // one shot.
                    try {
                        Thread.sleep(1500)
                    } catch (_: InterruptedException) {
                        return@Thread
                    }
                    val player = DabAudioPlayer(null).also { it.start() }
                    audioPlayer = player
                    var ok = false
                    val deadline = System.currentTimeMillis() + 8000
                    while (!ok && System.currentTimeMillis() < deadline) {
                        ok = nativePlayService(serviceId)
                        if (!ok) {
                            try {
                                Thread.sleep(500)
                            } catch (_: InterruptedException) {
                                break
                            }
                        }
                    }
                    currentContext = if (ok) freqKhz to serviceId else null
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
            "resetSession" -> {
                // Called from Dart when RtlSdrUsbService reports the known
                // RTL-SDR dongle was unplugged (see its own USB attach/
                // detach BroadcastReceiver - this plugin doesn't need a
                // second one). In direct-USB mode, the native session's
                // rtlsdr_dev_t/UsbDeviceConnection are now pointing at
                // hardware that's gone - previously nothing ever tore that
                // down, so `created` stayed true forever and every future
                // play attempt silently failed until the app was force-
                // stopped. Runs on a background thread since nativeDestroy()
                // can block briefly closing a (now invalid) USB handle - see
                // RtlSdrUsbPlugin.stopServer()'s own comment on why that
                // must never run on the platform/UI thread.
                Thread {
                    stopScanIfRunning()
                    stopLogoFetchIfRunning()
                    stopPlayback()
                    if (created) {
                        nativeDestroy()
                        created = false
                    }
                    directConnection?.close()
                    directConnection = null
                    mainHandler.post { result.success(null) }
                }.start()
            }
            "getEnsembleLabel" -> result.success(if (created) nativeGetEnsembleLabel() else "")
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
                nativeStop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
