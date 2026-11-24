package at.jaycloud.home.system

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.util.Size
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.abs

/**
 * The Haussteuerung's display by motion: the camera (front, else an external
 * one, else the back one) at low resolution, a few pictures a second. Each
 * picture is reduced to a grid of brightness values; when enough cells change
 * against the last picture - after taking out a change of the whole picture,
 * the camera's own exposure - that's motion.
 *
 * - Motion while the display is off (by us or the power button) or darkened
 *   brings it back and Home System to the front.
 * - While the dashboard is shown, no motion and no key/touch for
 *   [Config.timeoutMinutes] switches the display off (the accessibility
 *   service's "lock screen" - no device administrator needed).
 * - [Config.webhookUrl]: motion on/off goes to Home Assistant
 *   (`{"motion": true|false, "device": ...}`).
 *
 * A foreground service of type camera: started while the app is in front,
 * it keeps the camera when the display goes off (Android 11+ rules).
 */
class MotionService : Service() {

    data class Config(
        val sensitivity: Int,
        val timeoutMinutes: Int,
        val webhookUrl: String,
        val deviceName: String,
        /** "Off" only darkens (see [dim]) - no lock screen afterwards. */
        val dimOnly: Boolean = true,
    )

    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var previous: IntArray? = null
    private var lastFrameAt = 0L
    private var motionReported = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        startInForeground()
        openCamera()
        main.postDelayed(tick, TICK_MS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        main.removeCallbacks(tick)
        closeCamera()
        if (running === this) running = null
        super.onDestroy()
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.motion_channel_name), NotificationManager.IMPORTANCE_MIN),
            )
        }
        val notification = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL)
        else @Suppress("DEPRECATION") Notification.Builder(this))
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(getString(R.string.motion_notification_title))
            .setContentText(getString(R.string.motion_notification_text))
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    // --- Camera ---

    @SuppressLint("MissingPermission")
    private fun openCamera() {
        if (checkSelfPermission(android.Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "no camera permission")
            stopSelf()
            return
        }
        val manager = getSystemService(CameraManager::class.java)
        val id = pickCamera(manager) ?: run {
            Log.w(TAG, "no camera")
            stopSelf()
            return
        }
        val size = smallSize(manager, id)
        val t = HandlerThread("motion").also { it.start() }
        thread = t
        val handler = Handler(t.looper)
        val r = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
        reader = r
        r.setOnImageAvailableListener({ onImage(it) }, handler)
        try {
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    camera = device
                    startCapture(device, r, handler)
                }

                override fun onDisconnected(device: CameraDevice) {
                    device.close()
                    camera = null
                    retryLater()
                }

                override fun onError(device: CameraDevice, error: Int) {
                    Log.w(TAG, "camera error $error")
                    device.close()
                    camera = null
                    retryLater()
                }
            }, handler)
        } catch (e: Exception) {
            Log.w(TAG, "can't open camera", e)
            retryLater()
        }
    }

    @Suppress("DEPRECATION")
    private fun startCapture(device: CameraDevice, r: ImageReader, handler: Handler) {
        try {
            device.createCaptureSession(listOf(r.surface), object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    session = s
                    val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply { addTarget(r.surface) }
                    s.setRepeatingRequest(request.build(), null, handler)
                    Log.i(TAG, "watching (${r.width}x${r.height})")
                }

                override fun onConfigureFailed(s: CameraCaptureSession) {
                    Log.w(TAG, "capture session failed")
                    retryLater()
                }
            }, handler)
        } catch (e: Exception) {
            Log.w(TAG, "can't start capture", e)
            retryLater()
        }
    }

    /** The camera went away (another app took it, USB camera unplugged): try again in a while. */
    private fun retryLater() {
        main.post {
            closeCamera()
            main.postDelayed({ if (running === this) openCamera() }, RETRY_MS)
        }
    }

    private fun closeCamera() {
        try {
            session?.close()
        } catch (_: Exception) {
        }
        camera?.close()
        reader?.close()
        thread?.quitSafely()
        session = null
        camera = null
        reader = null
        thread = null
        previous = null
    }

    private fun pickCamera(manager: CameraManager): String? {
        val ids = manager.cameraIdList
        fun facing(id: String) = manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
        return ids.firstOrNull { facing(it) == CameraCharacteristics.LENS_FACING_FRONT }
            ?: ids.firstOrNull { facing(it) == CameraCharacteristics.LENS_FACING_EXTERNAL }
            ?: ids.firstOrNull()
    }

    /** The smallest picture of at least 160 pixels across - plenty for a 16x12 grid. */
    private fun smallSize(manager: CameraManager, id: String): Size {
        val map = manager.getCameraCharacteristics(id).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
        return sizes.filter { it.width >= 160 }.minByOrNull { it.width * it.height } ?: sizes.firstOrNull() ?: Size(320, 240)
    }

    private fun onImage(r: ImageReader) {
        val image = try {
            r.acquireLatestImage()
        } catch (_: Exception) {
            null
        } ?: return
        try {
            val now = SystemClock.elapsedRealtime()
            if (now - lastFrameAt < FRAME_MS) return
            lastFrameAt = now
            val plane = image.planes[0]
            val grid = brightnessGrid(plane.buffer, plane.rowStride, plane.pixelStride, image.width, image.height)
            val before = previous
            previous = grid
            if (before != null) compare(before, grid)
        } finally {
            image.close()
        }
    }

    private fun brightnessGrid(
        buffer: java.nio.ByteBuffer, rowStride: Int, pixelStride: Int, width: Int, height: Int,
    ): IntArray {
        val grid = IntArray(GRID_W * GRID_H)
        val cellW = width / GRID_W
        val cellH = height / GRID_H
        // Every 4th pixel in both directions is enough for an average.
        for (gy in 0 until GRID_H) {
            for (gx in 0 until GRID_W) {
                var sum = 0
                var n = 0
                var y = gy * cellH
                while (y < (gy + 1) * cellH) {
                    var x = gx * cellW
                    while (x < (gx + 1) * cellW) {
                        sum += buffer.get(y * rowStride + x * pixelStride).toInt() and 0xFF
                        n++
                        x += 4
                    }
                    y += 4
                }
                grid[gy * GRID_W + gx] = if (n == 0) 0 else sum / n
            }
        }
        return grid
    }

    private fun compare(before: IntArray, now: IntArray) {
        // The whole picture brighter or darker (exposure, a lamp) isn't motion.
        val shift = (now.sum() - before.sum()) / now.size
        val changed = now.indices.count { abs(now[it] - before[it] - shift) > CELL_THRESHOLD }
        val level = changed.toDouble() / now.size
        val c = config
        // Share of the picture that must change: 25 % at sensitivity 1, 2 % at 10.
        val needed = 0.25 - (c.sensitivity.coerceIn(1, 10) - 1) * 0.0255
        val moving = level >= needed
        listener?.invoke(level, moving)
        if (moving) main.post { onMotion() }
    }

    // --- Display ---

    private fun onMotion() {
        lastMotionAt = SystemClock.elapsedRealtime()
        if (dimmed) undim()
        else if (screenOffByUs || !isScreenOn(this)) wake(this)
        if (!motionReported) {
            motionReported = true
            report(true)
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val c = config
            if (motionReported && now - lastMotionAt > MOTION_OFF_MS) {
                motionReported = false
                report(false)
            }
            val idle = now - maxOf(lastMotionAt, lastInteractionAt)
            if (dashboardActive && c.timeoutMinutes > 0 && !screenOffByUs && !dimmed && isScreenOn(this@MotionService) &&
                idle > c.timeoutMinutes * 60_000L
            ) {
                Log.i(TAG, "no motion for ${c.timeoutMinutes} min - display off")
                displayOff(this@MotionService)
            }
            main.postDelayed(this, TICK_MS)
        }
    }

    private fun report(motion: Boolean) {
        val c = config
        val url = c.webhookUrl.trim()
        if (url.isEmpty()) return
        Thread {
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 5000
                conn.readTimeout = 5000
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                val device = c.deviceName.replace("\\", "\\\\").replace("\"", "\\\"")
                conn.outputStream.use { it.write("{\"motion\": $motion, \"device\": \"$device\"}".toByteArray()) }
                conn.responseCode
                conn.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "webhook failed: ${e.message}")
            }
        }.start()
    }

    companion object {
        private const val TAG = "MotionService"
        private const val CHANNEL = "motion"
        private const val NOTIFICATION_ID = 4711
        private const val GRID_W = 16
        private const val GRID_H = 12
        private const val CELL_THRESHOLD = 14
        private const val FRAME_MS = 250L
        private const val TICK_MS = 5_000L
        private const val RETRY_MS = 30_000L
        private const val MOTION_OFF_MS = 60_000L

        @Volatile
        var config = Config(sensitivity = 5, timeoutMinutes = 5, webhookUrl = "", deviceName = "")

        /** The running service, null when off. */
        @Volatile
        var running: MotionService? = null
            private set

        /** Motion level (0..1, share of changed cells) and whether it counted - for the settings' test display. */
        @Volatile
        var listener: ((Double, Boolean) -> Unit)? = null

        /** The dashboard is on screen - only then the display goes off by itself. */
        @Volatile
        var dashboardActive = false

        @Volatile
        var screenOffByUs = false

        @Volatile
        var lastMotionAt = SystemClock.elapsedRealtime()

        @Volatile
        var lastInteractionAt = SystemClock.elapsedRealtime()

        fun start(context: Context) {
            lastMotionAt = SystemClock.elapsedRealtime()
            val intent = Intent(context, MotionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MotionService::class.java))
        }

        /** A key or touch: counts like motion for the display timeout, and brings a darkened display back. */
        fun onUserInteraction() {
            lastInteractionAt = SystemClock.elapsedRealtime()
            if (dimmed) undim()
        }

        /** The display is darkened ([dim]). */
        @Volatile
        var dimmed = false
            private set

        /** DisplayPlugin: darkens / brightens the window (black page, lowest brightness). */
        @Volatile
        var dimHandler: ((Boolean) -> Unit)? = null

        /** Darkened instead of off: the screen stays on, so Android doesn't lock. */
        fun dim(): Boolean {
            val handler = dimHandler ?: return false
            dimmed = true
            handler(true)
            return true
        }

        fun undim() {
            if (!dimmed) return
            dimmed = false
            lastMotionAt = SystemClock.elapsedRealtime()
            dimHandler?.invoke(false)
        }

        /** "Display off" as set up: darkened ([Config.dimOnly]) or really off. */
        fun displayOff(context: Context): Boolean = if (config.dimOnly) dim() else screenOff(context)

        /** "Display on": back from darkened or off. */
        fun displayOn(context: Context) {
            if (dimmed) undim() else wake(context)
        }

        fun isScreenOn(context: Context): Boolean = context.getSystemService(PowerManager::class.java).isInteractive

        /**
         * Display off - the accessibility service's "lock screen" (Android 9+).
         * False if it isn't running or the system is too old.
         */
        fun screenOff(context: Context): Boolean {
            val service = HomeButtonService.instance
            if (service == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                Log.w(TAG, "can't switch the display off: accessibility service not running")
                return false
            }
            val done = service.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN)
            if (done) screenOffByUs = true
            return done
        }

        /** Display on and Home System in front (over the lock screen, see MainActivity). */
        @Suppress("DEPRECATION")
        fun wake(context: Context) {
            screenOffByUs = false
            lastMotionAt = SystemClock.elapsedRealtime()
            val power = context.getSystemService(PowerManager::class.java)
            val lock = power.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "home_system:motion",
            )
            lock.acquire(3_000)
            try {
                context.startActivity(
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                        .putExtra(MainActivity.EXTRA_WAKE, true),
                )
            } catch (e: Exception) {
                Log.w(TAG, "can't bring Home System to the front", e)
            }
            // A wall tablet shows the dashboard, not the lock screen: one
            // without PIN is swiped away (Fire OS ignores "show over the
            // lock screen"), once the display is really on.
            Handler(Looper.getMainLooper()).postDelayed({ HomeButtonService.instance?.swipeAwayLockScreen() }, 700)
        }
    }
}
