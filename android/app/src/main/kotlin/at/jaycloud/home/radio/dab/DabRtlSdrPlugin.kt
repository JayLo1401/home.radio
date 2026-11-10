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
 *
 * FM (UKW) runs on the same session and stick ("fmPlay", "fmTune", "fmSeek",
 * "fmStop", "fmScan", "stopFmScan"; events fmStatus, fmRds, fmSeekResult,
 * fmScanProgress, fmStationFound, fmScanFinished). Any DAB action leaves FM
 * and any FM action leaves DAB.
 *
 * Narrowband listening (CB/airband: AM, NFM, USB, LSB, auto) as well
 * ("nbStart", "nbTune", "nbSetSquelch", "nbSetChannels", "nbStop"; events
 * nbStatus, nbActivity, nbSpectrum ~5 Hz). NB switches the stick to its own
 * sample rate; any DAB or FM action leaves NB and restores 2.048 MS/s.
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

        // How long a scan waits for OFDM sync before calling a channel empty.
        private const val EMPTY_CHANNEL_MS = 3000L

        // FM (UKW) band and scan parameters, in kHz.
        private const val FM_LOW_KHZ = 87_500
        private const val FM_HIGH_KHZ = 108_000
        // Survey windows: the inner +-400 kHz of the stick's 1.024 MHz in FM
        // mode (FmDemod::kSurveySpanHz).
        private const val FM_WINDOW_KHZ = 800
        // A carrier this far off the raster point is a neighbour's sideband.
        private const val FM_MAX_OFFSET_HZ = 30_000f
        // Carrier-to-noise (dB, in the 256 kHz channel) that makes a station
        // even without RDS; below FM_MIN_SNR_DB it's noise.
        // A stereo pilot or RDS also make a station (see fmProbe). Lowered
        // from 12/8 dB after a real scan missed stations found by hand.
        private const val FM_STATION_SNR_DB = 10f
        private const val FM_MIN_SNR_DB = 6f
        // A weak candidate gets this long to show a pilot or RDS - longer
        // once RDS is syncing, since PI then usually follows.
        private const val FM_WEAK_WAIT_MS = 2500L
        private const val FM_WEAK_RDS_WAIT_MS = 5000L
        // Scan: how long to wait for PI + PS on a station.
        private const val FM_RDS_WAIT_MS = 4000L
        private const val FM_NO_RDS_MS = 2000L
        private const val FM_AUDIO_RATE = 48000
        private const val FM_PREBUFFER_MS = 250

        // Narrowband (CB/airband) audio: 48 kHz mono, delivered continuously.
        private const val NB_AUDIO_RATE = 48000
        private const val NB_PREBUFFER_MS = 250
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
        override fun onSync(sync: Boolean) {
            if (sync) scanSyncSeen = true
            emit(mapOf("type" to "syncChange", "sync" to sync))
        }
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

        override fun onFmPcm(pcm: ShortArray) {
            if (!fmMuted) fmPlayer?.onPcm(pcm, FM_AUDIO_RATE, 2)
        }

        override fun onFmStatus(levelDb: Float, snrDb: Float, stereo: Boolean, offsetHz: Float, pilot: Float) {
            if (!fmActive || fmMuted) return
            emit(
                mapOf(
                    "type" to "fmStatus",
                    "freqKhz" to fmFreqKhz,
                    "levelDb" to levelDb.toDouble(),
                    "snrDb" to snrDb.toDouble(),
                    "stereo" to stereo,
                    "offsetHz" to offsetHz.toDouble(),
                ),
            )
        }

        override fun onFmRds(pi: Int, ps: String?, rt: String?) {
            if (!fmActive || fmMuted) return
            emitFmRds(fmFreqKhz, if (pi >= 0) pi else null, ps, rt)
        }

        override fun onNbPcm(pcm: ShortArray) {
            if (nbActive) nbPlayer?.onPcm(pcm, NB_AUDIO_RATE, 1)
        }

        override fun onNbReport(
            freqHz: Int,
            levelDb: Float,
            noiseDb: Float,
            snrDb: Float,
            squelchOpen: Boolean,
            mode: String,
            centerHz: Int,
            spanHz: Int,
            channelsHz: IntArray,
            levelsDb: FloatArray,
            channelNoiseDb: Float,
            spectrumDb: FloatArray,
            bandwidthHz: Int,
            noiseBlanker: Boolean,
            voiceFilter: Boolean,
            agc: String,
        ) {
            if (!nbActive) return
            emit(
                mapOf(
                    "type" to "nbStatus",
                    "freqHz" to freqHz,
                    "levelDb" to levelDb.toDouble(),
                    "noiseDb" to noiseDb.toDouble(),
                    "snrDb" to snrDb.toDouble(),
                    "squelchOpen" to squelchOpen,
                    "mode" to mode,
                    "bandwidthHz" to bandwidthHz,
                    "noiseBlanker" to noiseBlanker,
                    "voiceFilter" to voiceFilter,
                    "agc" to agc,
                ),
            )
            if (spectrumDb.isEmpty()) return // no monitor data this time (gain change)
            emit(
                mapOf(
                    "type" to "nbActivity",
                    "channelsHz" to channelsHz.toList(),
                    "levelsDb" to levelsDb.map { if (it.isNaN()) null else it.toDouble() },
                    "noiseDb" to channelNoiseDb.toDouble(),
                ),
            )
            emit(
                mapOf(
                    "type" to "nbSpectrum",
                    "centerHz" to centerHz,
                    "spanHz" to spanHz,
                    "binsDb" to spectrumDb.map { it.toDouble() },
                ),
            )
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

    // Whether the receiver has found OFDM sync since the scan tuned to the
    // current channel - see scanBand3's early exit for empty channels.
    @Volatile private var scanSyncSeen = false
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

    // --- FM state ---
    @Volatile private var fmPlayer: DabAacPlayer? = null
    // FM playback is on: status/RDS events go out (not during scan/seek probing).
    @Volatile private var fmActive = false
    // Seek probing: audio and events of the candidates are suppressed.
    @Volatile private var fmMuted = false
    @Volatile private var fmFreqKhz = 0
    private val fmScanRunning = AtomicBoolean(false)
    @Volatile private var fmScanThread: Thread? = null
    // Bumped by every FM/DAB action that supersedes a running seek.
    private val fmSeekId = AtomicInteger(0)
    @Volatile private var fmSeekThread: Thread? = null
    // fmPlay/fmTune/fmStop and all nb* calls run here, in call order, off the UI thread.
    private val fmExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    // --- NB (narrowband) state ---
    @Volatile private var nbPlayer: DabAacPlayer? = null
    // NB is on: audio and nbStatus/nbActivity/nbSpectrum events go out.
    @Volatile private var nbActive = false

    // Last "nbSetFilters" (bandwidthHz, noiseBlanker, voiceFilter, agc code);
    // re-applied on nbStart, since a new native session starts with defaults.
    private data class NbFilterSettings(val bandwidthHz: Int, val noiseBlanker: Boolean, val voiceFilter: Boolean, val agc: Int)
    @Volatile private var nbFilters = NbFilterSettings(0, false, true, 0)

    private fun applyNbFilters() {
        val f = nbFilters
        if (created) engine.nbSetFilters(f.bandwidthHz, f.noiseBlanker, f.voiceFilter, f.agc)
    }

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
        leaveFm()
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
        sessionEndpoint = if (created) endpointKey() else null
        return created
    }

    // Host and port: a change needs a new session.
    private fun endpointKey() = "$lastHost:$lastPort"

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
            leaveFm()
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
     * count has not grown for ~2 s. A channel without even OFDM sync after
     * [EMPTY_CHANNEL_MS] is skipped: a real ensemble syncs within a few
     * 96 ms frames once the AGC has settled, so waiting the full 6 s on the
     * ~35 empty channels of a typical scan only made it take minutes.
     *
     * With [onlyFreqKhz] just that one channel is searched (manual search
     * from the app), more patiently: 15 s and no early skip, for weak
     * ensembles the full scan might pass over.
     */
    private fun scanBand3(onlyFreqKhz: Int? = null) {
        if (!ensureCreated()) {
            emit(mapOf("type" to "scanFinished", "foundCount" to 0, "error" to "native_create_failed"))
            return
        }
        stopLogoFetchIfRunning()
        val channels = if (onlyFreqKhz == null) DabChannels.BAND3 else DabChannels.BAND3.filter { it.freqKhz == onlyFreqKhz }
        val single = onlyFreqKhz != null
        var found = 0
        for ((index, channel) in channels.withIndex()) {
            if (!scanRunning.get()) break
            emit(
                mapOf(
                    "type" to "scanProgress",
                    "index" to index,
                    "total" to channels.size,
                    "label" to channel.label,
                    "freqKhz" to channel.freqKhz,
                ),
            )
            lastSnrDb = 0f
            scanSyncSeen = false
            engine.tune(channel.freqKhz * 1000)
            var ensembleLabel: String? = null
            var services: List<Map<String, Any>> = emptyList()
            val channelStart = System.currentTimeMillis()
            val initialDeadline = channelStart + if (single) 15000 else 6000
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
                if (!single && !foundSomething && !scanSyncSeen &&
                    System.currentTimeMillis() - channelStart >= EMPTY_CHANNEL_MS
                ) {
                    break // no DAB+ signal here at all
                }
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

    // ------------------------------------------------------------------
    // FM (UKW). Same stick and native session as DAB; the native receiver
    // switches modes by itself, here only the Kotlin-side activities (scan,
    // seek, players) have to make room for each other.
    // ------------------------------------------------------------------

    private fun emitFmRds(freqKhz: Int, pi: Int?, ps: String?, rt: String?) =
        emit(mapOf("type" to "fmRds", "freqKhz" to freqKhz, "pi" to pi, "ps" to ps, "rt" to rt))

    private fun stopDabActivities() {
        stopScanIfRunning()
        stopLogoFetchIfRunning()
        playRequestId.incrementAndGet() // abort an in-flight playService retry loop
        stopPlayback()
    }

    private fun stopFmActivities() {
        fmScanRunning.set(false) // also cancels a scan still queued on fmExecutor
        stopFmScanIfRunning()
        cancelFmSeek()
        stopFmPlayback()
    }

    /** Everything DAB (and NB) stops before FM takes the stick. */
    private fun leaveDab() {
        stopDabActivities()
        leaveNb()
    }

    /** Everything FM (and NB) stops before DAB takes the stick. */
    private fun leaveFm() {
        stopFmActivities()
        leaveNb()
    }

    /** NB's Kotlin side; the native receiver leaves NB by itself on the next DAB/FM call. */
    private fun leaveNb() {
        nbActive = false
        nbPlayer?.stop()
        nbPlayer = null
    }

    private fun ensureNbPlayer() {
        if (nbPlayer != null) return
        lateinit var player: DabAacPlayer
        player = DabAacPlayer(context, NB_PREBUFFER_MS) {
            mainHandler.post {
                if (nbPlayer !== player) return@post
                Log.i(TAG, "NB: audio focus lost, stopping")
                fmExecutor.execute {
                    leaveNb()
                    if (created) engine.halt()
                }
                emit(mapOf("type" to "audioFocusLost"))
            }
        }
        player.start()
        nbPlayer = player
    }

    private fun intList(call: MethodCall, key: String): IntArray =
        (call.argument<List<Any?>>(key) ?: emptyList()).mapNotNull { (it as? Number)?.toInt() }.toIntArray()

    /** "nbStart", "nbTune", "nbSetSquelch", "nbSetFilters", "nbSetChannels", "nbStop"; all run on [fmExecutor]. */
    private fun handleNbCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "nbStart" -> {
                val sampleRate = call.argument<Int>("sampleRate") ?: 2_048_000
                val centerHz = call.argument<Int>("centerHz") ?: 0
                val channels = intList(call, "channelsHz")
                val freqHz = call.argument<Int>("freqHz") ?: 0
                val mode = IntegratedDabEngine.nbModeCode(call.argument<String>("mode") ?: "auto")
                val squelchDb = (call.argument<Number>("squelchDb") ?: 10.0).toFloat()
                if (mode == null) {
                    result.error("bad_mode", "Unknown NB mode: ${call.argument<String>("mode")}", null)
                    return true
                }
                if (freqHz <= 0) {
                    result.error("bad_frequency", "NB frequency missing", null)
                    return true
                }
                fmExecutor.execute {
                    stopDabActivities()
                    stopFmActivities()
                    val ok = if (!ensureCreated()) {
                        false
                    } else {
                        ensureNbPlayer()
                        nbActive = true
                        applyNbFilters()
                        engine.nbStart(sampleRate, if (centerHz > 0) centerHz else freqHz, channels, freqHz, mode, squelchDb)
                    }
                    if (!ok) leaveNb()
                    mainHandler.post { result.success(ok) }
                }
            }
            "nbTune" -> {
                val freqHz = call.argument<Int>("freqHz") ?: 0
                val mode = IntegratedDabEngine.nbModeCode(call.argument<String>("mode") ?: "auto")
                if (mode == null) {
                    result.error("bad_mode", "Unknown NB mode: ${call.argument<String>("mode")}", null)
                    return true
                }
                fmExecutor.execute {
                    val ok = nbActive && created && engine.nbTune(freqHz, mode)
                    mainHandler.post { result.success(ok) }
                }
            }
            "nbSetSquelch" -> {
                val squelchDb = (call.argument<Number>("squelchDb") ?: 0.0).toFloat()
                fmExecutor.execute {
                    if (created) engine.nbSetSquelch(squelchDb)
                    mainHandler.post { result.success(null) }
                }
            }
            "nbSetFilters" -> {
                val agcName = call.argument<String>("agc") ?: "auto"
                val agc = IntegratedDabEngine.nbAgcCode(agcName)
                if (agc == null) {
                    result.error("bad_agc", "Unknown NB AGC mode: $agcName", null)
                    return true
                }
                nbFilters = NbFilterSettings(
                    bandwidthHz = maxOf(0, call.argument<Int>("bandwidthHz") ?: 0),
                    noiseBlanker = call.argument<Boolean>("noiseBlanker") ?: false,
                    voiceFilter = call.argument<Boolean>("voiceFilter") ?: true,
                    agc = agc,
                )
                fmExecutor.execute {
                    applyNbFilters()
                    mainHandler.post { result.success(null) }
                }
            }
            "nbSetChannels" -> {
                val centerHz = call.argument<Int>("centerHz") ?: 0
                val channels = intList(call, "channelsHz")
                fmExecutor.execute {
                    val ok = nbActive && created && engine.nbSetChannels(centerHz, channels)
                    mainHandler.post { result.success(ok) }
                }
            }
            "nbStop" -> {
                fmExecutor.execute {
                    val wasActive = nbActive
                    leaveNb()
                    if (created && wasActive) engine.halt()
                    mainHandler.post { result.success(null) }
                }
            }
            else -> return false
        }
        return true
    }

    private fun stopFmScanIfRunning() {
        // No thread yet: an fmScan queued behind this call on fmExecutor was
        // requested later and must not be cancelled by it.
        val thread = fmScanThread ?: return
        fmScanRunning.set(false)
        thread.join(3000) // a survey in progress takes up to ~1 s
        fmScanThread = null
    }

    private fun cancelFmSeek() {
        fmSeekId.incrementAndGet()
        fmSeekThread?.join(3000)
        fmSeekThread = null
        fmMuted = false
    }

    private fun stopFmPlayback() {
        fmActive = false
        fmPlayer?.stop()
        fmPlayer = null
    }

    private fun ensureFmPlayer() {
        if (fmPlayer != null) return
        lateinit var player: DabAacPlayer
        player = DabAacPlayer(context, FM_PREBUFFER_MS) {
            mainHandler.post {
                if (fmPlayer !== player) return@post
                Log.i(TAG, "FM: audio focus lost, stopping playback")
                fmExecutor.execute { stopFmPlayback() }
                emit(mapOf("type" to "audioFocusLost"))
            }
        }
        player.start()
        fmPlayer = player
    }

    /** Tunes and plays [freqKhz] (fmPlay / fmTune); runs on [fmExecutor]. */
    private fun fmPlayBlocking(freqKhz: Int): Boolean {
        leaveDab()
        stopFmScanIfRunning()
        cancelFmSeek()
        if (!ensureCreated()) return false
        fmFreqKhz = freqKhz
        val ok = engine.fmTune(freqKhz * 1000)
        if (ok) {
            ensureFmPlayer()
            fmActive = true
        }
        emitFmRds(freqKhz, null, null, null)
        return ok
    }

    private data class FmInfo(
        val valid: Boolean,
        val levelDb: Double,
        val snrDb: Double,
        val stereo: Boolean,
        val offsetHz: Double,
        val rdsSync: Boolean,
        val pi: Int?,
        val ps: String?,
        val rt: String?,
    )

    private fun fmInfo(): FmInfo? = try {
        val o = org.json.JSONObject(engine.fmInfoJson())
        FmInfo(
            valid = o.optBoolean("valid", false),
            levelDb = o.optDouble("levelDb", -100.0),
            snrDb = o.optDouble("snrDb", 0.0),
            stereo = o.optBoolean("stereo", false),
            offsetHz = o.optDouble("offsetHz", 0.0),
            rdsSync = o.optBoolean("rdsSync", false),
            pi = if (o.isNull("pi")) null else o.optInt("pi"),
            ps = if (o.isNull("ps")) null else o.optString("ps"),
            rt = if (o.isNull("rt")) null else o.optString("rt"),
        )
    } catch (e: Exception) {
        Log.w(TAG, "fmInfo: bad JSON", e)
        null
    }

    private data class FmCandidate(val freqKhz: Int, val levelDb: Double)

    /** Carriers on the 50 kHz raster within ~+-800 kHz of [centerKhz] (see FmDemod's survey). */
    private fun fmSurvey(centerKhz: Int): List<FmCandidate> {
        val json = engine.fmSurvey(centerKhz * 1000, FM_LOW_KHZ * 1000, FM_HIGH_KHZ * 1000) ?: return emptyList()
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                FmCandidate(o.getInt("freqKhz"), o.getDouble("levelDb"))
            }
        } catch (e: Exception) {
            Log.w(TAG, "fmSurvey: bad JSON", e)
            emptyList()
        }
    }

    private data class FmStation(
        val freqKhz: Int,
        val levelDb: Double,
        val stereo: Boolean,
        val pi: Int?,
        val ps: String?,
    )

    /**
     * Tunes to a candidate and decides whether a station is there: a carrier
     * close to the raster point (not a neighbour's sideband) with a decent
     * carrier-to-noise ratio, or decodable RDS. With [waitRds] it then waits
     * (up to [FM_RDS_WAIT_MS]) for PI and PS, giving up early when no RDS
     * shows up at all. Returns null for "no station" or when [keepGoing]
     * turns false.
     */
    private fun fmProbe(freqKhz: Int, waitRds: Boolean, keepGoing: () -> Boolean): FmStation? {
        engine.fmTune(freqKhz * 1000)
        val start = System.currentTimeMillis()
        var isStation = false
        var last: FmInfo? = null
        while (keepGoing()) {
            try {
                Thread.sleep(120)
            } catch (_: InterruptedException) {
                return null
            }
            val elapsed = System.currentTimeMillis() - start
            val info = fmInfo() ?: continue
            if (!info.valid) {
                if (elapsed > 2000) return null // no status at all - source trouble
                continue
            }
            last = info
            if (!isStation) {
                if (Math.abs(info.offsetHz) > FM_MAX_OFFSET_HZ) return null
                // A 19 kHz stereo pilot is as sure a sign of a broadcast as
                // RDS - and often there before RDS is.
                if (info.snrDb >= FM_STATION_SNR_DB || info.pi != null || info.stereo) {
                    isStation = true
                } else {
                    // Weak: give the pilot / RDS time to show up.
                    val limit = when {
                        info.rdsSync -> FM_WEAK_RDS_WAIT_MS
                        info.snrDb >= FM_MIN_SNR_DB -> FM_WEAK_WAIT_MS
                        else -> 1500L
                    }
                    if (elapsed > limit) return null
                    continue
                }
            }
            if (!waitRds) break
            if (info.pi != null && info.ps != null) break
            if (elapsed >= FM_RDS_WAIT_MS) break
            if (!info.rdsSync && info.pi == null && elapsed >= FM_NO_RDS_MS) break
        }
        val info = last ?: return null
        if (!isStation || !keepGoing()) return null
        return FmStation(freqKhz, info.levelDb, info.stereo, info.pi, info.ps)
    }

    /**
     * FM band scan, 87.5-108 MHz. Phase 1 ("survey"): power spectra of 26
     * windows of 800 kHz, carriers on the 50 kHz raster that stand clearly
     * above the noise floor (~0.3 s per window). Phase 2 ("probe"): each
     * candidate is tuned and checked ([fmProbe]); stations closer than
     * 100 kHz are one station's splatter unless their PIs differ - only the
     * strongest is kept. Stations are reported as they are confirmed.
     */
    private fun scanFm() {
        if (!ensureCreated()) {
            emit(mapOf("type" to "fmScanFinished", "foundCount" to 0, "error" to "native_create_failed"))
            return
        }
        val running = { fmScanRunning.get() }
        val windows = generateSequence(FM_LOW_KHZ + FM_WINDOW_KHZ / 2) { it + FM_WINDOW_KHZ }
            .takeWhile { it - FM_WINDOW_KHZ / 2 <= FM_HIGH_KHZ }
            .toList()
        val candidates = sortedMapOf<Int, FmCandidate>()
        for ((index, center) in windows.withIndex()) {
            if (!running()) break
            emit(mapOf("type" to "fmScanProgress", "index" to index, "total" to windows.size, "freqKhz" to center, "phase" to "survey"))
            for (c in fmSurvey(center)) candidates[c.freqKhz] = c
        }
        Log.i(TAG, "FM scan: ${candidates.size} candidate(s): ${candidates.keys.joinToString()}")

        var found = 0
        var pending: FmStation? = null
        fun report(st: FmStation) {
            found++
            Log.i(TAG, "FM station ${st.freqKhz} kHz: ${st.levelDb} dB, stereo=${st.stereo}, PI=${st.pi}, PS='${st.ps}'")
            emit(
                mapOf(
                    "type" to "fmStationFound",
                    "freqKhz" to st.freqKhz,
                    "levelDb" to st.levelDb,
                    "stereo" to st.stereo,
                    "pi" to st.pi,
                    "ps" to st.ps,
                ),
            )
        }
        val list = candidates.values.toList()
        for ((index, cand) in list.withIndex()) {
            if (!running()) break
            emit(mapOf("type" to "fmScanProgress", "index" to index, "total" to list.size, "freqKhz" to cand.freqKhz, "phase" to "probe"))
            val st = fmProbe(cand.freqKhz, waitRds = true, keepGoing = running) ?: continue
            val prev = pending
            if (prev != null && st.freqKhz - prev.freqKhz <= 100 &&
                (prev.pi == null || st.pi == null || prev.pi == st.pi)
            ) {
                // Same station seen twice (splatter / strong sideband): keep the stronger.
                if (st.levelDb > prev.levelDb) pending = st
                continue
            }
            prev?.let { report(it) }
            pending = st
        }
        pending?.let { if (running()) report(it) }
        engine.halt()
        val completed = running()
        fmScanRunning.set(false)
        emit(mapOf("type" to "fmScanFinished", "foundCount" to found) + if (completed) emptyMap() else mapOf("cancelled" to true))
    }

    /**
     * Seek from [fromKhz] to the next station up/down (wrapping around the
     * band once), using the same survey + probe as the scan. Candidates are
     * probed muted; the found one keeps playing, otherwise [fromKhz] is
     * tuned again (if FM was playing).
     */
    private fun seekFm(fromKhz: Int, up: Boolean, myId: Int) {
        val current = { fmSeekId.get() == myId }
        val wasPlaying = fmActive
        fmMuted = true
        var result: Int? = null
        try {
            if (!ensureCreated()) return
            val half = FM_WINDOW_KHZ / 2
            // Window centres in seek direction: from just past fromKhz to the
            // band edge, then from the other edge back to fromKhz.
            val first = mutableListOf<Int>()
            val wrap = mutableListOf<Int>()
            if (up) {
                var c = fromKhz + 50 + half
                while (c - half <= FM_HIGH_KHZ) { first += c; c += FM_WINDOW_KHZ }
                c = FM_LOW_KHZ + half
                while (c - half < fromKhz) { wrap += c; c += FM_WINDOW_KHZ }
            } else {
                var c = fromKhz - 50 - half
                while (c + half >= FM_LOW_KHZ) { first += c; c -= FM_WINDOW_KHZ }
                c = FM_HIGH_KHZ - half
                while (c + half > fromKhz) { wrap += c; c -= FM_WINDOW_KHZ }
            }
            val probed = mutableSetOf<Int>()
            outer@ for ((pass, centers) in listOf(first, wrap).withIndex()) {
                for (center in centers) {
                    if (!current()) return
                    val beyond = { f: Int ->
                        if (pass == 0) (if (up) f > fromKhz else f < fromKhz) else (if (up) f < fromKhz else f > fromKhz)
                    }
                    val cands = fmSurvey(center).map { it.freqKhz }.filter { beyond(it) && it !in probed }
                    for (f in if (up) cands.sorted() else cands.sortedDescending()) {
                        if (!current()) return
                        probed += f
                        if (fmProbe(f, waitRds = false, keepGoing = current) != null) {
                            result = f
                            break@outer
                        }
                    }
                }
            }
        } finally {
            if (current()) {
                val found = result
                if (found != null) {
                    // The probe left the receiver playing the station.
                    fmFreqKhz = found
                    ensureFmPlayer()
                    fmActive = true
                } else if (wasPlaying) {
                    engine.fmTune(fromKhz * 1000)
                } else {
                    engine.halt()
                }
                fmMuted = false
                emit(mapOf("type" to "fmSeekResult", "freqKhz" to found))
                if (fmActive) {
                    val info = fmInfo()
                    emitFmRds(fmFreqKhz, info?.pi, info?.ps, info?.rt)
                }
            }
        }
    }

    private fun handleFmCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "fmPlay", "fmTune" -> {
                val freqKhz = call.argument<Int>("freqKhz") ?: 0
                if (freqKhz < FM_LOW_KHZ - 500 || freqKhz > FM_HIGH_KHZ + 500) {
                    result.error("bad_frequency", "FM frequency out of range: $freqKhz kHz", null)
                    return true
                }
                // fmTune keeps the audio running (same player); fmPlay too,
                // since a running player is simply reused.
                fmExecutor.execute {
                    val ok = fmPlayBlocking(freqKhz)
                    mainHandler.post { result.success(ok) }
                }
            }
            "fmSeek" -> {
                val fromKhz = call.argument<Int>("fromKhz") ?: fmFreqKhz.takeIf { it > 0 } ?: FM_LOW_KHZ
                val up = call.argument<Boolean>("up") ?: true
                val myId = fmSeekId.incrementAndGet()
                fmExecutor.execute {
                    leaveDab()
                    stopFmScanIfRunning()
                    fmSeekThread?.join(3000) // the superseded seek
                    if (fmSeekId.get() != myId) return@execute
                    fmSeekThread = Thread { seekFm(fromKhz, up, myId) }.apply { start() }
                }
                result.success(null)
            }
            "fmStop" -> {
                fmExecutor.execute {
                    cancelFmSeek()
                    stopFmPlayback()
                    if (created && !fmScanRunning.get()) engine.halt()
                    mainHandler.post { result.success(null) }
                }
            }
            "fmScan" -> {
                if (!fmScanRunning.compareAndSet(false, true)) {
                    result.error("busy", "An FM scan is already running", null)
                    return true
                }
                fmExecutor.execute {
                    if (!fmScanRunning.get()) {
                        // cancelled (DAB took over) before it started
                        emit(mapOf("type" to "fmScanFinished", "foundCount" to 0, "cancelled" to true))
                        return@execute
                    }
                    leaveDab()
                    cancelFmSeek()
                    stopFmPlayback()
                    fmScanThread = Thread {
                        try {
                            scanFm()
                        } finally {
                            fmScanRunning.set(false)
                            if (fmScanThread === Thread.currentThread()) fmScanThread = null
                        }
                    }.apply { start() }
                }
                result.success(null)
            }
            "stopFmScan" -> {
                fmExecutor.execute {
                    val wasRunning = fmScanThread != null
                    stopFmScanIfRunning()
                    if (created && wasRunning && !fmActive) engine.halt()
                    mainHandler.post { result.success(null) }
                }
            }
            else -> return false
        }
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (handleFmCall(call, result)) return
        if (handleNbCall(call, result)) return
        when (call.method) {
            "setServer" -> {
                val host = call.argument<String>("host") ?: "127.0.0.1"
                val port = call.argument<Int>("port") ?: 1234
                lastHost = host
                lastPort = port
                // The rtl_tcp endpoint (or the USB stick) is bound when the
                // session is created, so a different source needs a new one.
                if (created && sessionEndpoint != endpointKey()) {
                    stopPlayback()
                    leaveFm()
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
                val onlyFreqKhz = call.argument<Int>("freqKhz")
                if (scanRunning.compareAndSet(false, true)) {
                    leaveFm() // one stick: DAB takes it over
                    scanThread = Thread {
                        try {
                            scanBand3(onlyFreqKhz)
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
                leaveFm()
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
                leaveFm()
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
                    leaveFm()
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
                leaveFm()
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
