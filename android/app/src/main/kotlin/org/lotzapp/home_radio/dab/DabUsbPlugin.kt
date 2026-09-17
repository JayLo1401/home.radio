package org.lotzapp.home_radio.dab

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native, independent DAB+ USB adapter access via Android's UsbManager (USB
 * Host API) - this app talks to the dongle itself rather than remote-
 * controlling another already-installed DAB player app.
 *
 * This plugin currently covers device discovery, permission handling and
 * opening the device/reading its endpoint layout - the groundwork every USB
 * accessory app needs. The dongle's own command protocol (ensemble scan,
 * tune, service list, DLS text, slideshow/logo, signal strength) is specific
 * to its chipset/firmware and is not publicly documented for this class of
 * generic "car head unit" DAB+ dongle; it still needs to be determined from
 * real USB traffic captured while the dongle is attached and in use (see the
 * project plan's DAB+ phase). Nothing below assumes or depends on that
 * protocol yet - it only exposes what the standard Android USB Host API
 * itself already understands (descriptors, endpoints, permission).
 */
class DabUsbPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val ACTION_USB_PERMISSION = "org.lotzapp.home_radio.USB_PERMISSION"
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private val usbManager: UsbManager by lazy {
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    }

    private var openConnection: UsbDeviceConnection? = null
    private var openDevice: UsbDevice? = null
    private var openEndpoints: Map<Int, UsbEndpoint> = emptyMap()
    // Guards against overlapping runFullDiagnostics() calls: concurrent bulk
    // transfers from two threads on the same UsbDeviceConnection produced
    // corrupted-looking "data" in testing that turned out to just be a race
    // condition artifact, not real device responses.
    private val diagnosticsRunning = java.util.concurrent.atomic.AtomicBoolean(false)

    // DAB+ playback: a long-lived thread (tune -> resolve subchannel via FIC
    // -> open it -> continuously read/decode/play), independent of the
    // one-shot diagnostics above (guarded by diagnosticsRunning too, so a
    // scan/probe can't run concurrently with playback on the same USB
    // connection).
    private val playbackRunning = java.util.concurrent.atomic.AtomicBoolean(false)
    private var playbackThread: Thread? = null
    private var audioPlayer: DabAudioPlayer? = null

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionDeviceName: String? = null

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    synchronized(this) {
                        val device = intent.getUsbDeviceExtra()
                        val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                        if (device?.deviceName == pendingPermissionDeviceName) {
                            pendingPermissionResult?.success(granted)
                            pendingPermissionResult = null
                            pendingPermissionDeviceName = null
                        }
                        emit(
                            mapOf(
                                "type" to "permissionResult",
                                "deviceName" to device?.deviceName,
                                "granted" to granted,
                            ),
                        )
                    }
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    emit(mapOf("type" to "deviceAttached", "deviceName" to intent.getUsbDeviceExtra()?.deviceName))
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    emit(mapOf("type" to "deviceDetached", "deviceName" to intent.getUsbDeviceExtra()?.deviceName))
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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "home_radio/dab_usb")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "home_radio/dab_usb/events")
        eventChannel.setStreamHandler(this)

        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
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
            // already unregistered
        }
        closeDevice()
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(listDevices())
            "requestPermission" -> {
                val deviceName = call.argument<String>("deviceName")
                requestPermission(deviceName, result)
            }
            "openDevice" -> {
                val deviceName = call.argument<String>("deviceName")
                result.success(openDeviceAndDescribe(deviceName))
            }
            "closeDevice" -> {
                closeDevice()
                result.success(null)
            }
            "controlTransfer" -> controlTransfer(call, result)
            "bulkTransfer" -> bulkTransfer(call, result)
            "runRaontechProbe" -> {
                runRaontechProbe()
                result.success(null)
            }
            "runFullDiagnostics" -> {
                if (diagnosticsRunning.compareAndSet(false, true)) {
                    Thread {
                        try {
                            runFullDiagnostics()
                        } finally {
                            diagnosticsRunning.set(false)
                        }
                    }.start()
                } else {
                    Log.w("DabProbe", "runFullDiagnostics already running - ignoring duplicate call")
                }
                result.success(null)
            }
            "autoRequestPermission" -> {
                autoRequestPermissionForKnownAdapter()
                result.success(null)
            }
            "dabInitialize" -> {
                runOnDabThread(result) { driver -> driver.initialize() }
            }
            "dabScanBand3" -> {
                if (diagnosticsRunning.compareAndSet(false, true)) {
                    Thread {
                        try {
                            scanBand3()
                        } finally {
                            diagnosticsRunning.set(false)
                        }
                    }.start()
                } else {
                    Log.w("DabProbe", "A scan/diagnostic is already running - ignoring duplicate call")
                }
                result.success(null)
            }
            "dabTuneChannel" -> {
                val index = call.argument<Int>("index") ?: 0
                runOnDabThread(result) { driver ->
                    val channel = RaonTunerDriver.BAND3_CHANNELS.getOrNull(index)
                    if (channel != null) {
                        driver.tuneToChannel(channel)
                        true
                    } else {
                        false
                    }
                }
            }
            "dabTuneFrequency" -> {
                // Re-tunes by frequency (rather than scan-session index) so a
                // favorite saved in an earlier session can be re-tuned after
                // an app restart without needing to re-run a scan first.
                // BAND3_CHANNELS is a static, deterministic table, so this is
                // just as reliable as the index-based lookup above.
                val freqKhz = call.argument<Int>("freqKhz") ?: 0
                runOnDabThread(result) { driver ->
                    val channel = RaonTunerDriver.BAND3_CHANNELS.find { it.freqKhz == freqKhz }
                    if (channel != null) {
                        driver.tuneToChannel(channel)
                        true
                    } else {
                        false
                    }
                }
            }
            "dabPlayService" -> {
                val freqKhz = call.argument<Int>("freqKhz") ?: 0
                val serviceId = call.argument<Int>("serviceId") ?: 0
                startDabPlayback(freqKhz, serviceId)
                result.success(null)
            }
            "dabStopPlayback" -> {
                stopDabPlayback()
                result.success(null)
            }
            "dabSetTuning" -> {
                call.argument<Int>("audioBufferMs")?.let { DabTuning.audioBufferMs = it }
                call.argument<Int>("degenerateFillThreshold")?.let { DabTuning.degenerateFillThreshold = it }
                call.argument<Int>("overrunCheckInterval")?.let { DabTuning.overrunCheckInterval = it }
                call.argument<Int>("watchdogTimeoutMs")?.let { DabTuning.watchdogTimeoutMs = it.toLong() }
                result.success(null)
            }
            "dabGetTuning" -> {
                result.success(
                    mapOf(
                        "audioBufferMs" to DabTuning.audioBufferMs,
                        "degenerateFillThreshold" to DabTuning.degenerateFillThreshold,
                        "overrunCheckInterval" to DabTuning.overrunCheckInterval,
                        "watchdogTimeoutMs" to DabTuning.watchdogTimeoutMs.toInt(),
                    ),
                )
            }
            "dabGetStatus" -> {
                runOnDabThread(result) { driver ->
                    val lockStatus = driver.getLockStatus()
                    val (locked, level) = driver.getAntennaLevel()
                    mapOf("lockStatus" to lockStatus, "antennaLocked" to locked, "antennaLevel" to level)
                }
            }
            "dabTestChannel" -> {
                val index = call.argument<Int>("index") ?: 0
                if (diagnosticsRunning.compareAndSet(false, true)) {
                    Thread {
                        try {
                            testChannelVerbose(index)
                        } finally {
                            diagnosticsRunning.set(false)
                        }
                    }.start()
                } else {
                    Log.w("DabProbe", "A scan/diagnostic is already running - ignoring duplicate call")
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Known hardware signatures of Raontech-chipset DAB+ USB dongles, taken
     * from the reference driver's own device match list (see
     * jusbdevice.cpp:74 in docs/dab-research/omri-usb-raon/) - this project's
     * own dongle is the third pair; the other two are additional
     * Raontech-compatible dongles the reference app also supports and are
     * kept here so a different physical dongle isn't silently filtered out.
     */
    private val knownDabAdapterIds = setOf(
        0x1D19 to 0x110D,
        0x0FD9 to 0x004C,
        0x16C0 to 0x05DC,
    )

    private fun isDabAdapter(device: UsbDevice) =
        (device.vendorId to device.productId) in knownDabAdapterIds

    /**
     * Only ever list actual DAB+ dongles: a host box (e.g. a Sunmi
     * set-top/POS device) can expose a whole internal USB hub's worth of
     * other peripherals (fingerprint reader, printer, NFC, internal Wi-Fi,
     * ...) as generic host-visible USB devices, which used to all show up
     * here too - this app has no use for any of them, so filter to the
     * known DAB adapter signatures instead of trying to blacklist every
     * possible non-DAB device individually.
     */
    private fun listDevices(): List<Map<String, Any?>> {
        return usbManager.deviceList.values
            .filter { isDabAdapter(it) }
            .map { device -> device.toMap() }
    }

    /**
     * Called once at app startup (see DabUsbService.autoRequestPermissionForAdapter
     * on the Dart side): if the known DAB+ dongle (and only that - never the
     * Wi-Fi adapter or anything else) is attached and not yet permitted, ask
     * for USB permission immediately rather than waiting for the user to
     * open the DAB+ screen and tap a button.
     */
    private fun autoRequestPermissionForKnownAdapter() {
        val device = usbManager.deviceList.values.find { isDabAdapter(it) }
        if (device == null) {
            Log.i("DabProbe", "autoRequestPermission: DAB adapter not currently attached")
            return
        }
        if (usbManager.hasPermission(device)) {
            Log.i("DabProbe", "autoRequestPermission: already permitted")
            return
        }
        Log.i("DabProbe", "autoRequestPermission: requesting for ${device.deviceName}")
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
            flags,
        )
        // No MethodChannel.Result to fulfill here (this wasn't triggered by
        // one call awaiting a reply) - the broadcast receiver still emits a
        // "permissionResult" event over the EventChannel either way.
        usbManager.requestPermission(device, pendingIntent)
    }

    /** Runs [block] against a [RaonTunerDriver] for the currently open device, off the main thread. */
    private fun runOnDabThread(result: MethodChannel.Result, block: (RaonTunerDriver) -> Any?) {
        val connection = openConnection
        val outEp = openEndpoints.values.find {
            it.direction == UsbConstants.USB_DIR_OUT && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK
        }
        val inEp = openEndpoints.values
            .filter { it.direction == UsbConstants.USB_DIR_IN && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
            .maxByOrNull { it.maxPacketSize }
        if (connection == null || outEp == null || inEp == null) {
            result.error("not_open", "No device open with bulk IN+OUT endpoints", null)
            return
        }
        if (!diagnosticsRunning.compareAndSet(false, true)) {
            result.error("busy", "Another DAB operation is already running", null)
            return
        }
        Thread {
            try {
                val driver = RaonTunerDriver(connection, outEp, inEp)
                val value = block(driver)
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                Log.e("DabProbe", "DAB operation failed", e)
                mainHandler.post { result.error("dab_error", "${e.message}", null) }
            } finally {
                diagnosticsRunning.set(false)
            }
        }.start()
    }

    /** Full DAB Band III scan: initialize once, then tune+check-lock on every channel. */
    private fun scanBand3() {
        val tag = "DabProbe"
        val connection = openConnection
        val outEp = openEndpoints.values.find {
            it.direction == UsbConstants.USB_DIR_OUT && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK
        }
        val inEp = openEndpoints.values
            .filter { it.direction == UsbConstants.USB_DIR_IN && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
            .maxByOrNull { it.maxPacketSize }
        if (connection == null || outEp == null || inEp == null) {
            Log.w(tag, "scanBand3: no device open with bulk IN+OUT endpoints")
            return
        }
        val driver = RaonTunerDriver(connection, outEp, inEp)
        Log.i(tag, "======== BAND III SCAN START ========")
        if (!driver.initialize()) {
            Log.w(tag, "Initialize failed - aborting scan")
            emit(mapOf("type" to "scanFinished", "foundCount" to 0))
            return
        }
        var found = 0
        for ((index, channel) in RaonTunerDriver.BAND3_CHANNELS.withIndex()) {
            emit(mapOf("type" to "scanProgress", "index" to index, "label" to channel.label, "freqKhz" to channel.freqKhz))
            driver.tuneToChannel(channel)
            // The reference driver polls getLockStatus() repeatedly for up
            // to ~a couple of seconds per channel (OFDM sync doesn't
            // complete instantly) rather than checking once - a single
            // 300ms check was finding nothing anywhere, including on a
            // channel confirmed to have a real ensemble by another app.
            var lockStatus = 0
            val deadline = System.currentTimeMillis() + 2500
            while (System.currentTimeMillis() < deadline) {
                lockStatus = driver.getLockStatus()
                if (lockStatus == 0x03) break
                Thread.sleep(100)
            }
            val (antennaLocked, antennaLevel) = driver.getAntennaLevel()
            val locked = lockStatus == 0x03
            Log.i(
                tag,
                "Channel ${channel.label} (${channel.freqKhz} kHz): lockStatus=0x%02X locked=%s antennaLevel=%d"
                    .format(lockStatus, locked, antennaLevel),
            )
            if (locked) {
                found++
                // A single FIC read only captures whatever FIGs happened to
                // be in that transmission cycle - the ensemble label and
                // every service's label aren't necessarily all present in
                // one 384-byte burst. Read repeatedly for ~1.5s and merge.
                var ensembleId: Int? = null
                var ensembleLabel: String? = null
                val services = mutableMapOf<Int, String>()
                repeat(12) {
                    val fic = driver.readFicRaw()
                    val parsed = FigParser.parse(fic)
                    if (parsed.ensembleLabel != null) {
                        ensembleId = parsed.ensembleId
                        ensembleLabel = parsed.ensembleLabel
                    }
                    services.putAll(parsed.services)
                    Thread.sleep(120)
                }
                Log.i(
                    tag,
                    "  Ensemble '${ensembleLabel ?: "?"}' (EId=${ensembleId?.let { "0x%04X".format(it) } ?: "?"}), " +
                        "${services.size} service(s): ${services.entries.joinToString { "${it.key}=${it.value}" }}",
                )
                emit(
                    mapOf(
                        "type" to "channelLocked",
                        "index" to index,
                        "label" to channel.label,
                        "freqKhz" to channel.freqKhz,
                        "antennaLevel" to antennaLevel,
                        "ensembleLabel" to ensembleLabel,
                        "services" to services.entries.map { (id, label) ->
                            mapOf("serviceId" to id, "label" to label)
                        },
                    ),
                )
            }
        }
        Log.i(tag, "======== BAND III SCAN END: $found channel(s) locked ========")
        emit(mapOf("type" to "scanFinished", "foundCount" to found))
    }

    /**
     * Tunes to a single channel and logs lock status + antenna level every
     * 200ms for several seconds - much faster to iterate on than a full
     * 41-channel scan when debugging why lock isn't happening on one
     * specific, externally-confirmed-active channel.
     */
    private fun testChannelVerbose(index: Int) {
        val tag = "DabProbe"
        val connection = openConnection
        val outEp = openEndpoints.values.find {
            it.direction == UsbConstants.USB_DIR_OUT && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK
        }
        val inEp = openEndpoints.values
            .filter { it.direction == UsbConstants.USB_DIR_IN && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
            .maxByOrNull { it.maxPacketSize }
        val channel = RaonTunerDriver.BAND3_CHANNELS.getOrNull(index)
        if (connection == null || outEp == null || inEp == null || channel == null) {
            Log.w(tag, "testChannelVerbose: device not open or bad channel index")
            return
        }
        val driver = RaonTunerDriver(connection, outEp, inEp)
        Log.i(tag, "======== SINGLE CHANNEL TEST: ${channel.label} (${channel.freqKhz} kHz) ========")
        if (!driver.initialize()) {
            Log.w(tag, "Initialize failed - aborting test")
            return
        }
        driver.tuneToChannel(channel)
        val deadline = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < deadline) {
            val lockStatus = driver.getLockStatus()
            val (antennaLocked, antennaLevel) = driver.getAntennaLevel()
            Log.i(
                tag,
                "  t+%dms: lockStatus=0x%02X (OFDM=%s FEC=%s) antennaLocked=%s antennaLevel=%d".format(
                    8000 - (deadline - System.currentTimeMillis()),
                    lockStatus,
                    (lockStatus and 0x01) != 0,
                    (lockStatus and 0x02) != 0,
                    antennaLocked,
                    antennaLevel,
                ),
            )
            Thread.sleep(200)
        }
        // Collect FIC over ~1.5s to gather the ensemble label and as many
        // service labels as show up (see the same note in scanBand3()).
        var ensembleId: Int? = null
        var ensembleLabel: String? = null
        val services = mutableMapOf<Int, String>()
        repeat(12) {
            val fic = driver.readFicRaw()
            val parsed = FigParser.parse(fic)
            if (parsed.ensembleLabel != null) {
                ensembleId = parsed.ensembleId
                ensembleLabel = parsed.ensembleLabel
            }
            services.putAll(parsed.services)
            Thread.sleep(120)
        }
        Log.i(
            tag,
            "  Ensemble '${ensembleLabel ?: "?"}' (EId=${ensembleId?.let { "0x%04X".format(it) } ?: "?"}), " +
                "${services.size} service(s):",
        )
        services.forEach { (id, label) -> Log.i(tag, "    SId=$id: \"$label\"") }
        Log.i(tag, "======== SINGLE CHANNEL TEST END ========")
    }

    /**
     * Starts DAB+ playback of one station: tunes to [freqKhz], waits for
     * OFDM+FEC lock, resolves [serviceId]'s audio SubChId + per-CIF byte
     * size from FIC (FIG 0/1 + 0/2 - see FigParser), opens that subchannel,
     * then continuously reads/reframes/decodes/plays its MSC bytes until
     * [stopDabPlayback] is called. Emits `playbackStatus` events
     * (`tuning`/`resolvingSubchannel`/`playing`/`error`/`busy`) so the Dart
     * side can show real status instead of just "tuned".
     */
    private fun startDabPlayback(freqKhz: Int, serviceId: Int) {
        stopDabPlayback()
        if (!diagnosticsRunning.compareAndSet(false, true)) {
            Log.w("DabProbe", "startDabPlayback: another DAB operation is already running")
            emit(mapOf("type" to "playbackStatus", "status" to "busy"))
            return
        }
        playbackRunning.set(true)
        playbackThread = Thread {
            // The MSC1 hardware FIFO needs servicing on a tight, real-time
            // cadence (a 24ms CIF period) - on a loaded/low-power TV box,
            // normal thread scheduling delays (GC pauses, other threads,
            // logging I/O) may be enough to fall behind it, and once behind
            // there's no way to catch back up (matches the permanent,
            // never-recovering sync loss seen in testing this session).
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            try {
                runDabPlayback(freqKhz, serviceId)
            } catch (e: InterruptedException) {
                // Expected: stopDabPlayback() (e.g. switching to another
                // station) interrupts this thread to wake it from whichever
                // Thread.sleep() it's in - without this catch, the exception
                // propagated uncaught and crashed the whole app (found
                // 2026-09-16 while testing station switches).
                Log.i("DabProbe", "runDabPlayback: interrupted (stopped)")
            } finally {
                diagnosticsRunning.set(false)
            }
        }.apply { start() }
    }

    private fun stopDabPlayback() {
        playbackRunning.set(false)
        playbackThread?.interrupt()
        // Wait for the old thread to actually exit (and release
        // diagnosticsRunning in its finally block) before returning -
        // without this, quickly switching stations could hit
        // startDabPlayback's diagnosticsRunning guard and report "busy"
        // even though the old playback was already being stopped (found
        // 2026-09-16 while testing station switches).
        // Short timeout only - this runs on the Flutter platform/UI thread
        // (MethodChannel calls dispatch there by default), so it must not
        // block noticeably; the interrupt should wake the old thread's
        // sleep almost immediately in the common case.
        try {
            playbackThread?.join(300)
        } catch (_: InterruptedException) {
        }
        playbackThread = null
        audioPlayer?.stop()
        audioPlayer = null
    }

    private fun runDabPlayback(freqKhz: Int, serviceId: Int) {
        val tag = "DabProbe"
        val connection = openConnection
        val outEp = openEndpoints.values.find {
            it.direction == UsbConstants.USB_DIR_OUT && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK
        }
        val inEp = openEndpoints.values
            .filter { it.direction == UsbConstants.USB_DIR_IN && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
            .maxByOrNull { it.maxPacketSize }
        val channel = RaonTunerDriver.BAND3_CHANNELS.find { it.freqKhz == freqKhz }
        if (connection == null || outEp == null || inEp == null || channel == null) {
            Log.w(tag, "runDabPlayback: device not open or unknown frequency $freqKhz")
            emit(mapOf("type" to "playbackStatus", "status" to "error", "message" to "device_not_open"))
            return
        }
        val driver = RaonTunerDriver(connection, outEp, inEp)
        Log.i(tag, "======== DAB+ PLAYBACK START: service=$serviceId ${channel.label} (${channel.freqKhz} kHz) ========")
        emit(mapOf("type" to "playbackStatus", "status" to "tuning"))
        if (!driver.initialize()) {
            Log.w(tag, "runDabPlayback: initialize() failed")
            emit(mapOf("type" to "playbackStatus", "status" to "error", "message" to "init_failed"))
            return
        }
        driver.tuneToChannel(channel)

        var locked = false
        val lockDeadline = System.currentTimeMillis() + 2500
        while (playbackRunning.get() && System.currentTimeMillis() < lockDeadline) {
            if (driver.getLockStatus() == 0x03) {
                locked = true
                break
            }
            Thread.sleep(100)
        }
        if (!playbackRunning.get()) return
        if (!locked) {
            Log.w(tag, "runDabPlayback: no OFDM/FEC lock on ${channel.label}")
            emit(mapOf("type" to "playbackStatus", "status" to "error", "message" to "no_lock"))
            return
        }

        emit(mapOf("type" to "playbackStatus", "status" to "resolvingSubchannel"))
        var subChId: Int? = null
        var frameLen: Int? = null
        val ficDeadline = System.currentTimeMillis() + 4000
        while (playbackRunning.get() && System.currentTimeMillis() < ficDeadline && (subChId == null || frameLen == null)) {
            val fic = driver.readFicRaw()
            val parsed = FigParser.parse(fic)
            val components = parsed.audioComponents[serviceId]
            val comp = components?.firstOrNull { it.isDabPlus } ?: components?.firstOrNull()
            if (comp != null) {
                subChId = comp.subChId
                parsed.subchannels[comp.subChId]?.let { frameLen = it.frameLenBytes }
            }
            Thread.sleep(120)
        }
        if (!playbackRunning.get()) return
        val resolvedSubChId = subChId
        val resolvedFrameLen = frameLen
        if (resolvedSubChId == null || resolvedFrameLen == null || resolvedFrameLen <= 0) {
            Log.w(tag, "runDabPlayback: could not resolve subchannel for service $serviceId in time")
            emit(mapOf("type" to "playbackStatus", "status" to "error", "message" to "subchannel_not_found"))
            return
        }
        Log.i(tag, "runDabPlayback: service $serviceId -> subChId=$resolvedSubChId frameLen=$resolvedFrameLen bytes/CIF")

        // RULED OUT (2026-09-16): tried waiting several extra seconds here,
        // continuing to service FIC well past what's needed for our own
        // subChId/frameLen resolution, in case the chip's internal
        // (register-invisible) per-subchannel protection-level setup needs
        // more FIC observation time before openSubChannel() - verified via
        // a standalone PC-side (Windows/libusb) capture that this makes no
        // difference at all (same ~100% AU2-position corruption either
        // way). Not the cause.
        //
        // Order matters and matches the reference's setService() exactly
        // (clearAndSetupMscMemory() then openSubChannel(), found 2026-09-16
        // - this project had it backwards until now).
        // FAITHFUL PORT (2026-09-16): after exhausting every register/timing/
        // architecture comparison against the real reference (byte-for-byte
        // identical at every level checked, including the low-level USB
        // transfer syscall itself), this loop was rebuilt to mirror the
        // reference's actual readData()/commandProcessing() exactly - no
        // watchdog, no degenerate-fill heuristic, no periodic extra overrun
        // check beyond the one the reference itself does. All of those were
        // this project's own additions from earlier debugging sessions, none
        // of which exist in the working reference app.
        driver.clearAndSetupMscMemory()
        driver.openSubChannel(resolvedSubChId)
        // WAV dump (pass context here to re-enable) was left on from an
        // earlier debugging session - synchronous file I/O on the playback
        // thread for every PCM chunk is exactly the kind of extra work that
        // has no business being in the real playback path.
        val player = DabAudioPlayer(null).also { it.start() }
        audioPlayer = player
        var framesFed = 0L
        var ausDecoded = 0L
        val decoder = NativeDabDecoder { pcm, sr, ch ->
            ausDecoded++
            player.submit(pcm, sr, ch)
        }
        val reframer = MscReframer(resolvedFrameLen) { frame ->
            framesFed++
            decoder.feed(frame)
        }

        emit(mapOf("type" to "playbackStatus", "status" to "playing"))
        var totalBytesRead = 0L
        var readCount = 0L
        var notReadyCount = 0L
        var lastLog = System.currentTimeMillis()
        try {
            while (playbackRunning.get()) {
                // Exactly readData(): one combined status read, service FIC
                // if its bit is set, reset MSC memory and skip this
                // iteration on overrun/underrun, else read+feed if ready,
                // else sleep(20) (the reference's own not-ready delay).
                val status = driver.pollStatus()
                driver.serviceFicIfSet(status)
                if (driver.recoverMscOverrunIfSet(status)) {
                    continue
                }
                if (!driver.isMscReadySet(status)) {
                    notReadyCount++
                    // DIAGNOSTIC (2026-09-16): check whether the bridge has
                    // unsolicited data sitting ready on the data endpoint
                    // even though the status register's "ready" bit says no
                    // - would mean our own request/poll cycle, not the
                    // chip/bridge itself, is what's gating byte arrival.
                    val (n, unsolicited) = driver.probeUnsolicitedRead()
                    if (n > 0) {
                        Log.w(tag, "UNSOLICITED: got $n bytes without asking! first bytes=${unsolicited.take(8).joinToString(" ") { "%02X".format(it) }}")
                    }
                    Thread.sleep(20)
                    continue
                }
                val bytes = driver.readMscRaw()
                readCount++
                if (bytes.isNotEmpty()) {
                    totalBytesRead += bytes.size
                    reframer.feed(bytes)
                }
                val now = System.currentTimeMillis()
                if (now - lastLog >= 2000) {
                    lastLog = now
                    Log.i(
                        tag,
                        "MSC stats: reads=$readCount (notReady=$notReadyCount) " +
                            "bytes=$totalBytesRead cifFrames=$framesFed ausDecoded=$ausDecoded | " +
                            "sync=${decoder.syncSuccesses}/${decoder.syncAttempts} " +
                            "rsUncorr=${decoder.rsUncorrectableCodewords} rsCorrected=${decoder.rsCorrectedSymbols} " +
                            "auCrcOk=${decoder.auCrcOk} auCrcFail=${decoder.auCrcFail} " +
                            "perAu=${(0..2).joinToString(",") {
                                "${decoder.auCrcOkForIndex(it)}/${decoder.auCrcOkForIndex(it) + decoder.auCrcFailForIndex(it)}"
                            }}",
                    )
                }
            }
        } finally {
            driver.closeSubChannel(resolvedSubChId)
            player.stop()
            decoder.destroy()
            Log.i(tag, "======== DAB+ PLAYBACK END ========")
        }
    }

    /**
     * Detects the chip's MSC "idle/underrun fill" pattern: a long run of one
     * repeated byte value, seen in a raw capture (2026-09-16 debugging
     * session) instead of real payload whenever the FIFO underran - the read
     * itself still returns non-empty data, so [RaonTunerDriver.recoverMscOverrunIfNeeded]
     * checked only on empty reads doesn't catch it; this heuristic does.
     * Real (RS-protected, effectively-random-looking) MSC bytes essentially
     * never have runs this long, so a conservative threshold is safe.
     *
     * RELAXED (2026-09-16): raised from 24 to 64 - every discard here throws
     * away a whole 2048-byte chunk and forces a full reframer/decoder reset
     * (losing in-flight buffered CIFs too), so a lower threshold risks
     * discarding real, decodable data on a coincidental short run rather
     * than only genuine chip-idle fill. 64 is still far longer than any run
     * plausible in real RS-protected data by chance.
     */
    private fun isDegenerateFill(bytes: ByteArray): Boolean {
        if (bytes.size < 32) return false
        var runLen = 1
        var maxRun = 1
        for (i in 1 until bytes.size) {
            if (bytes[i] == bytes[i - 1]) {
                runLen++
                if (runLen > maxRun) maxRun = runLen
            } else {
                runLen = 1
            }
        }
        return maxRun >= DabTuning.degenerateFillThreshold
    }

    private fun UsbDevice.toMap(): Map<String, Any?> {
        return mapOf(
            "deviceName" to deviceName,
            "vendorId" to vendorId,
            "productId" to productId,
            "deviceClass" to deviceClass,
            "deviceSubclass" to deviceSubclass,
            "deviceProtocol" to deviceProtocol,
            "manufacturerName" to (if (Build.VERSION.SDK_INT >= 21) manufacturerName else null),
            "productName" to (if (Build.VERSION.SDK_INT >= 21) productName else null),
            "serialNumber" to (
                if (Build.VERSION.SDK_INT >= 21 && usbManager.hasPermission(this)) {
                    try {
                        serialNumber
                    } catch (_: SecurityException) {
                        null
                    }
                } else {
                    null
                }
                ),
            "interfaceCount" to interfaceCount,
            "hasPermission" to usbManager.hasPermission(this),
        )
    }

    private fun requestPermission(deviceName: String?, result: MethodChannel.Result) {
        val device = usbManager.deviceList.values.find { it.deviceName == deviceName }
        if (device == null) {
            result.error("not_found", "USB device $deviceName not found", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        pendingPermissionDeviceName = deviceName
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
            flags,
        )
        usbManager.requestPermission(device, pendingIntent)
    }

    /**
     * Opens the device and reports its interface/endpoint layout - the raw
     * material needed to work out the dongle's command protocol from a real
     * USB capture. Does not send or expect any dongle-specific commands.
     */
    private fun openDeviceAndDescribe(deviceName: String?): Map<String, Any?>? {
        val device = usbManager.deviceList.values.find { it.deviceName == deviceName } ?: return null
        if (!usbManager.hasPermission(device)) return null
        closeDevice()
        val connection = usbManager.openDevice(device) ?: return null
        openConnection = connection
        openDevice = device

        val endpointsByAddress = mutableMapOf<Int, UsbEndpoint>()
        val interfaces = (0 until device.interfaceCount).map { i ->
            val iface = device.getInterface(i)
            connection.claimInterface(iface, true)
            val endpoints = (0 until iface.endpointCount).map { e ->
                val ep = iface.getEndpoint(e)
                endpointsByAddress[ep.address] = ep
                mapOf(
                    "address" to ep.address,
                    "direction" to if (ep.direction == UsbConstants.USB_DIR_IN) "in" else "out",
                    "type" to ep.type,
                    "maxPacketSize" to ep.maxPacketSize,
                )
            }
            mapOf(
                "interfaceClass" to iface.interfaceClass,
                "interfaceSubclass" to iface.interfaceSubclass,
                "interfaceProtocol" to iface.interfaceProtocol,
                "endpoints" to endpoints,
            )
        }
        openEndpoints = endpointsByAddress
        return mapOf("device" to device.toMap(), "interfaces" to interfaces)
    }

    private fun closeDevice() {
        stopDabPlayback()
        openConnection?.close()
        openConnection = null
        openDevice = null
        openEndpoints = emptyMap()
    }

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.replace(" ", "").replace("0x", "")
        return ByteArray(clean.length / 2) { i ->
            clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    private fun bytesToHex(bytes: ByteArray, length: Int): String {
        return (0 until length).joinToString(" ") { "%02X".format(bytes[it]) }
    }

    /**
     * Sends one raw USB control transfer (setup packet: bmRequestType,
     * bRequest, wValue, wIndex, + an IN or OUT data stage) and returns the
     * raw response bytes as hex. This is the tool for manually probing the
     * dongle's undocumented vendor protocol (see class doc comment) - it
     * assumes no protocol of its own.
     */
    private fun controlTransfer(call: MethodCall, result: MethodChannel.Result) {
        val connection = openConnection
        if (connection == null) {
            result.error("not_open", "No device is open", null)
            return
        }
        val requestType = call.argument<Int>("requestType") ?: 0
        val request = call.argument<Int>("request") ?: 0
        val value = call.argument<Int>("value") ?: 0
        val index = call.argument<Int>("index") ?: 0
        val length = call.argument<Int>("length") ?: 0
        val dataHex = call.argument<String>("dataHex")
        val timeout = call.argument<Int>("timeoutMs") ?: 1000

        val isIn = (requestType and UsbConstants.USB_DIR_IN) != 0
        val buffer = if (isIn) ByteArray(length) else hexToBytes(dataHex ?: "")
        val transferred = connection.controlTransfer(
            requestType,
            request,
            value,
            index,
            buffer,
            buffer.size,
            timeout,
        )
        result.success(
            mapOf(
                "bytesTransferred" to transferred,
                "dataHex" to if (transferred > 0) bytesToHex(buffer, transferred) else "",
            ),
        )
    }

    /** Same idea as [controlTransfer] but for a bulk/interrupt endpoint. */
    private fun bulkTransfer(call: MethodCall, result: MethodChannel.Result) {
        val connection = openConnection
        if (connection == null) {
            result.error("not_open", "No device is open", null)
            return
        }
        val endpointAddress = call.argument<Int>("endpointAddress")
        val endpoint = openEndpoints[endpointAddress]
        if (endpoint == null) {
            result.error("bad_endpoint", "Unknown endpoint $endpointAddress", null)
            return
        }
        val length = call.argument<Int>("length") ?: 64
        val dataHex = call.argument<String>("dataHex")
        val timeout = call.argument<Int>("timeoutMs") ?: 1000

        val isIn = endpoint.direction == UsbConstants.USB_DIR_IN
        val buffer = if (isIn) ByteArray(length) else hexToBytes(dataHex ?: "")
        val transferred = connection.bulkTransfer(endpoint, buffer, buffer.size, timeout)
        result.success(
            mapOf(
                "bytesTransferred" to transferred,
                "dataHex" to if (transferred > 0) bytesToHex(buffer, transferred) else "",
            ),
        )
    }

    /**
     * Runs the Raontech tuner power-up sequence from the LGPL-licensed
     * reference driver (github.com/hradio/omri-usb, see
     * docs/dab-research/omri-usb-raon/ for the original source and full
     * write-up) against whatever bulk OUT/IN endpoints this device has, and
     * logs every step with `adb logcat -s DabProbe`. This lets us test a
     * hypothesis (Raontech-compatible chip) without the user having to type
     * hex bytes into text fields by hand via a remote control.
     */
    private fun runRaontechProbe() {
        val tag = "DabProbe"
        val connection = openConnection
        if (connection == null) {
            Log.w(tag, "No device open - call openDevice first")
            return
        }
        val outEp = openEndpoints.values.find { it.direction == UsbConstants.USB_DIR_OUT && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
        // Prefer the largest-max-packet bulk IN endpoint: this device has
        // two (0x81 with an 8-byte packet - likely a small notify channel -
        // and 0x82 with 64 bytes, matching the Raontech reference driver's
        // data endpoint exactly). Picking "the first one found" earlier
        // grabbed the wrong (tiny) one.
        val inEp = openEndpoints.values
            .filter { it.direction == UsbConstants.USB_DIR_IN && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
            .maxByOrNull { it.maxPacketSize }
        Log.i(tag, "Endpoints: OUT=${outEp?.address?.let { "0x%02X".format(it) }}, IN=${inEp?.address?.let { "0x%02X".format(it) }}")
        if (outEp == null || inEp == null) {
            Log.w(tag, "No bulk IN+OUT endpoint pair found - can't run the Raontech probe")
            return
        }

        fun writeStep(label: String, bytes: ByteArray) {
            val n = connection.bulkTransfer(outEp, bytes, bytes.size, 1000)
            Log.i(tag, "$label OUT -> wrote $n/${bytes.size} bytes: ${bytes.joinToString(" ") { "%02X".format(it) }}")
        }

        fun readStep(label: String, expectedLength: Int): ByteArray {
            val buf = ByteArray(expectedLength)
            val n = connection.bulkTransfer(inEp, buf, buf.size, 1000)
            Log.i(
                tag,
                "$label IN  -> read $n bytes: " +
                    if (n > 0) (0 until n).joinToString(" ") { "%02X".format(buf[it]) } else "(none)",
            )
            return buf
        }

        Log.i(tag, "--- Raontech probe sequence start ---")
        // 1) switchPage(REGISTER_PAGE_HOST = 0x07): write register 0x03 = 0x07
        writeStep("switchPage(HOST)", byteArrayOf(0x21, 0x00, 0x00, 0x02, 0x03, 0x07))
        // 2) setRegister(0x7D, 0x06)
        writeStep("setRegister(0x7D,0x06)", byteArrayOf(0x21, 0x00, 0x00, 0x02, 0x7D, 0x06))
        // 3) readRegister(0x7D): write read-request, then read 5 bytes; value is byte[4]
        writeStep("readRegister(0x7D) request", byteArrayOf(0x22, 0x00, 0x01, 0x00, 0x7D))
        val response = readStep("readRegister(0x7D) response", 5)
        val value = if (response.size >= 5) response[4] else null
        Log.i(
            tag,
            "PowerUp check: register 0x7D read back as " +
                (value?.let { "0x%02X".format(it) } ?: "?") +
                " (expected 0x06 if this is a Raontech-compatible chip)",
        )
        Log.i(tag, "--- Raontech probe sequence end ---")
    }

    /**
     * Fires a whole battery of hypotheses at the currently open device in
     * one go and logs everything (`adb logcat -s DabProbe`), so a single
     * round-trip (grant permission, open, this) yields as much information
     * as possible - each attempt with the dongle needs the USB port to be
     * in host mode, which conflicts with wireless debugging on this
     * hardware (see project plan), making back-and-forth iteration slow.
     * Runs on a background thread since it's a lot of blocking transfers.
     */
    private fun runFullDiagnostics() {
        val tag = "DabProbe"
        val connection = openConnection
        val device = openDevice
        if (connection == null || device == null) {
            Log.w(tag, "No device open - call openDevice first")
            return
        }
        Log.i(tag, "======== FULL DIAGNOSTIC START ========")
        Log.i(
            tag,
            "Device: VID=0x%04X PID=0x%04X class=%d/%d/%d".format(
                device.vendorId, device.productId, device.deviceClass, device.deviceSubclass, device.deviceProtocol,
            ),
        )

        // A) Raw device+config+interface+endpoint descriptor block, as the
        // OS parsed it off the wire - may contain class-specific
        // descriptors our simplified endpoint listing doesn't show.
        try {
            val raw = connection.rawDescriptors
            if (raw != null) {
                Log.i(tag, "RawDescriptors (${raw.size} bytes): ${raw.joinToString(" ") { "%02X".format(it) }}")
            } else {
                Log.i(tag, "RawDescriptors: null")
            }
        } catch (e: Exception) {
            Log.w(tag, "rawDescriptors failed: $e")
        }

        openEndpoints.values.forEach { ep ->
            Log.i(
                tag,
                "Endpoint 0x%02X dir=%s type=%d maxPacket=%d".format(
                    ep.address,
                    if (ep.direction == UsbConstants.USB_DIR_IN) "IN" else "OUT",
                    ep.type,
                    ep.maxPacketSize,
                ),
            )
        }

        // B) All string descriptor indices 0..8 - sometimes vendor strings
        // (firmware version, protocol hints) are stashed at unused indices.
        for (idx in 0..8) {
            val buf = ByteArray(64)
            val n = connection.controlTransfer(0x80, 0x06, (0x03 shl 8) or idx, 0x0409, buf, buf.size, 300)
            Log.i(
                tag,
                "GET_DESCRIPTOR(string idx=$idx) -> $n bytes: " +
                    if (n > 0) bytesToHex(buf, n) else "-",
            )
        }

        // C) Clear a possible halt/stall condition on every endpoint before
        // the real attempts, in case an earlier failed probe left one stuck.
        openEndpoints.values.forEach { ep ->
            val n = connection.controlTransfer(0x02, 0x01, 0x00, ep.address, null, 0, 300)
            Log.i(tag, "CLEAR_HALT ep=0x%02X -> %d".format(ep.address, n))
        }

        // D) Sweep of plain vendor control requests, both directions, no
        // assumptions about what they mean - looking for anything that
        // returns real (non-zero) data instead of failing/timing out.
        for (req in 0..12) {
            val bufIn = ByteArray(16)
            val nIn = connection.controlTransfer(0xC0, req, 0, 0, bufIn, bufIn.size, 300)
            Log.i(
                tag,
                "VENDOR-IN  req=0x%02X -> %d bytes: %s".format(
                    req,
                    nIn,
                    if (nIn > 0) bytesToHex(bufIn, nIn) else "-",
                ),
            )
            val nOut = connection.controlTransfer(0x40, req, 0, 0, ByteArray(0), 0, 300)
            Log.i(tag, "VENDOR-OUT req=0x%02X -> %d".format(req, nOut))
        }

        val outEp = openEndpoints.values.find {
            it.direction == UsbConstants.USB_DIR_OUT && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK
        }
        // See the same note in runRaontechProbe(): prefer the largest-packet
        // bulk IN endpoint (0x82, 64 bytes) over a small notify-style one
        // (0x81, 8 bytes here).
        val inEp = openEndpoints.values
            .filter { it.direction == UsbConstants.USB_DIR_IN && it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
            .maxByOrNull { it.maxPacketSize }

        // E) Read the bulk IN endpoint with no prior write at all - maybe
        // the device streams status/data unsolicited once opened.
        if (inEp != null) {
            val buf = ByteArray(64)
            val n = connection.bulkTransfer(inEp, buf, buf.size, 500)
            Log.i(tag, "Unsolicited bulk IN read -> $n bytes: ${if (n > 0) bytesToHex(buf, n) else "-"}")
        }

        if (outEp != null && inEp != null) {
            fun tryWrite(label: String, bytes: ByteArray, padTo: Int? = null) {
                val data = if (padTo != null && bytes.size < padTo) bytes + ByteArray(padTo - bytes.size) else bytes
                val n = connection.bulkTransfer(outEp, data, data.size, 1000)
                Log.i(tag, "$label -> wrote $n/${data.size}: ${data.joinToString(" ") { "%02X".format(it) }}")
            }
            fun tryRead(label: String, len: Int, timeoutMs: Int = 1500) {
                val buf = ByteArray(len)
                val n = connection.bulkTransfer(inEp, buf, buf.size, timeoutMs)
                Log.i(tag, "$label -> read $n: ${if (n > 0) bytesToHex(buf, n) else "-"}")
            }

            // F) Raontech-style sequence again, but with a longer read
            // timeout and a read attempt after every step (not just the
            // "read register" one), in case the device replies to writes
            // it wasn't expected to.
            tryWrite("F1 switchPage(HOST)", byteArrayOf(0x21, 0x00, 0x00, 0x02, 0x03, 0x07))
            tryRead("F1 response?", 8, 500)

            tryWrite("F2 setRegister(0x7D,0x06)", byteArrayOf(0x21, 0x00, 0x00, 0x02, 0x7D, 0x06))
            tryRead("F2 response?", 8, 500)

            tryWrite("F3 readRegister(0x7D) request", byteArrayOf(0x22, 0x00, 0x01, 0x00, 0x7D))
            tryRead("F3 response (long timeout)", 8, 3000)

            // G) Same read-register request, but zero-padded to the
            // endpoint's max packet size - some firmwares only react to a
            // full-size bulk packet and silently drop short ones.
            val maxPacket = outEp.maxPacketSize.takeIf { it > 0 } ?: 64
            tryWrite("G readRegister(0x7D) padded", byteArrayOf(0x22, 0x00, 0x01, 0x00, 0x7D), padTo = maxPacket)
            tryRead("G response (long timeout)", maxPacket, 3000)

            // H) A completely different guess: Silicon Labs Si468x-style
            // host command framing (cmd byte + fixed arg layout), in case
            // the AVR/MCU bridge passes commands through close to raw.
            tryWrite("H Si468x-style POWER_UP guess", byteArrayOf(0x01, 0x00, 0x17, 0x00, 0x08, 0x00, 0x11, 0x00))
            tryRead("H response", 16, 1000)

            // I) Plain "identify/get version" style single-byte commands,
            // common in simple vendor protocols on cheap MCUs.
            for (cmd in listOf(0x00, 0x01, 0x02, 0xFF)) {
                tryWrite("I cmd=0x%02X".format(cmd), byteArrayOf(cmd.toByte()))
                tryRead("I cmd=0x%02X response".format(cmd), 16, 500)
            }
        } else {
            Log.w(tag, "No bulk IN+OUT endpoint pair found for steps E-I")
        }

        Log.i(tag, "======== FULL DIAGNOSTIC END ========")
    }
}
