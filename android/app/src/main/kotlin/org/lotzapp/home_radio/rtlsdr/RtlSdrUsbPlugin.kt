package org.lotzapp.home_radio.rtlsdr

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

/**
 * Thin JNI wrapper around the native RTL-SDR USB-TCP service (see
 * cpp/rtlsdr_jni.cpp + cpp/librtlsdr/rtl_tcp.c): once started, it behaves
 * exactly like an external `rtl_tcp` process listening on localhost - the
 * existing [RtlTcpClient]/[RtlSdrPlugin] can connect to it the same way it
 * connects to an external driver app or a network rtl_tcp instance.
 */
private object RtlSdrUsbServer {
    init {
        System.loadLibrary("rtlsdrnative")
    }

    external fun nativeStart(
        usbFd: Int,
        bindAddr: String,
        port: Int,
        frequencyHz: Long,
        sampleRateHz: Int,
        gainTenthsDb: Int,
        ppmError: Int,
        directSampling: Boolean,
        biasTee: Boolean,
    ): Boolean

    external fun nativeStop()

    external fun nativeIsRunning(): Boolean
}

/**
 * Opens our own RTL-SDR dongle over USB directly (no external driver app
 * needed) and serves it as a local `rtl_tcp`-protocol TCP server - "unser
 * eigener USB-TCP Dienst", the alternative to relying on an external rtl_tcp
 * app or a network service (e.g. on a Raspberry Pi).
 *
 * Device discovery is filtered to known RTL2832U-based dongle VID/PIDs only
 * (see [knownRtlSdrIds]) - this project only targets the RTL-SDR stick from
 * here on, so nothing else on a host box (Wi-Fi adapter, hub-internal
 * peripherals, ...) should ever trigger a USB permission prompt.
 */
class RtlSdrUsbPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val TAG = "DabProbe"
        private const val ACTION_USB_PERMISSION = "org.lotzapp.home_radio.RTLSDR_USB_PERMISSION"

        /**
         * Known RTL2832U dongle VID/PIDs (from librtlsdr's own known_devices
         * table): 0x2832 is the bare "Generic RTL2832U" ID some dongles keep,
         * 0x2838 is the "Generic RTL2832U OEM" ID used by most branded
         * dongles (RTL-SDR Blog, NooElec, ...) once the vendor reprograms the
         * EEPROM. Both are Realtek's own VID (0x0bda).
         */
        private val knownRtlSdrIds = setOf(0x0bda to 0x2832, 0x0bda to 0x2838)
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private val usbManager: UsbManager by lazy {
        context.getSystemService(Context.USB_SERVICE) as UsbManager
    }

    // Kept alive for the whole server lifetime: closing this would close the
    // native fd the C++ side is using via libusb_wrap_sys_device().
    private var openConnection: UsbDeviceConnection? = null

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
                        emit(mapOf("type" to "permissionResult", "deviceName" to device?.deviceName, "granted" to granted))
                    }
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    val device = intent.getUsbDeviceExtra()
                    if (device != null && isRtlSdr(device)) {
                        emit(mapOf("type" to "deviceAttached", "deviceName" to device.deviceName))
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val device = intent.getUsbDeviceExtra()
                    if (device != null && isRtlSdr(device)) {
                        stopServer()
                        emit(mapOf("type" to "deviceDetached", "deviceName" to device.deviceName))
                    }
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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "home_radio/rtlsdr_usb")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "home_radio/rtlsdr_usb/events")
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
        }
        stopServer()
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

    private fun UsbDevice.toMap(): Map<String, Any?> = mapOf(
        "deviceName" to deviceName,
        "vendorId" to vendorId,
        "productId" to productId,
        "productName" to (if (Build.VERSION.SDK_INT >= 21) productName else null),
        "manufacturerName" to (if (Build.VERSION.SDK_INT >= 21) manufacturerName else null),
        "hasPermission" to usbManager.hasPermission(this),
    )

    private fun listDevices(): List<Map<String, Any?>> =
        usbManager.deviceList.values.filter { isRtlSdr(it) }.map { it.toMap() }

    private fun requestPermission(deviceName: String?, result: MethodChannel.Result) {
        val device = usbManager.deviceList.values.find { it.deviceName == deviceName && isRtlSdr(it) }
        if (device == null) {
            result.error("not_found", "RTL-SDR device $deviceName not found", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        pendingPermissionDeviceName = deviceName
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
            flags,
        )
        usbManager.requestPermission(device, pendingIntent)
    }

    /**
     * Called at app startup (mirrors the retired DabUsbPlugin's own
     * auto-request, now solely for the RTL-SDR stick): if it's attached and
     * not yet permitted, ask immediately instead of waiting for the user to
     * open Settings.
     */
    private fun autoRequestPermission() {
        val device = usbManager.deviceList.values.find { isRtlSdr(it) } ?: return
        if (usbManager.hasPermission(device)) return
        Log.i(TAG, "RTL-SDR autoRequestPermission: requesting for ${device.deviceName}")
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
            flags,
        )
        usbManager.requestPermission(device, pendingIntent)
    }

    private fun startServer(call: MethodCall, result: MethodChannel.Result) {
        if (RtlSdrUsbServer.nativeIsRunning()) {
            result.error("already_running", "RTL-SDR USB server is already running", null)
            return
        }
        val device = usbManager.deviceList.values.find { isRtlSdr(it) }
        if (device == null) {
            result.error("not_found", "No RTL-SDR dongle attached", null)
            return
        }
        if (!usbManager.hasPermission(device)) {
            result.error("no_permission", "USB permission not granted for ${device.deviceName}", null)
            return
        }
        val connection = usbManager.openDevice(device)
        if (connection == null) {
            result.error("open_failed", "usbManager.openDevice() returned null", null)
            return
        }
        openConnection = connection

        val bindAddr = call.argument<String>("bindAddr") ?: "127.0.0.1"
        val port = call.argument<Int>("port") ?: 1234
        val frequencyHz = (call.argument<Number>("frequencyHz") ?: 100_000_000L).toLong()
        val sampleRateHz = call.argument<Int>("sampleRateHz") ?: 2_048_000
        val gainTenthsDb = call.argument<Int>("gainTenthsDb") ?: 0
        val ppmError = call.argument<Int>("ppmError") ?: 0
        val directSampling = call.argument<Boolean>("directSampling") ?: false
        val biasTee = call.argument<Boolean>("biasTee") ?: false

        val started = RtlSdrUsbServer.nativeStart(
            connection.fileDescriptor,
            bindAddr,
            port,
            frequencyHz,
            sampleRateHz,
            gainTenthsDb,
            ppmError,
            directSampling,
            biasTee,
        )
        if (!started) {
            connection.close()
            openConnection = null
            result.error("start_failed", "Native rtl_tcp server failed to start", null)
            return
        }
        Log.i(TAG, "RTL-SDR USB server started on $bindAddr:$port")
        result.success(mapOf("bindAddr" to bindAddr, "port" to port))
    }

    private fun stopServer() {
        if (RtlSdrUsbServer.nativeIsRunning()) {
            RtlSdrUsbServer.nativeStop()
        }
        openConnection?.close()
        openConnection = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(listDevices())
            "requestPermission" -> requestPermission(call.argument<String>("deviceName"), result)
            "autoRequestPermission" -> {
                autoRequestPermission()
                result.success(null)
            }
            "startServer" -> startServer(call, result)
            "stopServer" -> {
                stopServer()
                result.success(null)
            }
            "isServerRunning" -> result.success(RtlSdrUsbServer.nativeIsRunning())
            else -> result.notImplemented()
        }
    }
}
