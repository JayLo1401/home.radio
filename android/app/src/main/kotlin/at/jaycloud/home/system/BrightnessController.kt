package at.jaycloud.home.system

import android.app.Activity
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import android.view.WindowManager
import kotlin.math.abs
import kotlin.math.ln

/**
 * The display's brightness for a wall tablet (Settings → Haussteuerung):
 * - [Mode.SYSTEM]: Android's own setting, nothing is touched;
 * - [Mode.FIXED]: [level] (0..1);
 * - [Mode.ADAPTIVE]: from the light sensor, between [min] and [max] - full
 *   brightness from [luxForMax] on (on a log scale, like the eye). Fire
 *   tablets' own adaptive brightness hardly reacts, and their sensor reads
 *   low behind the glass, hence the adjustable [luxForMax].
 *
 * Applied to Home System's window only (screenBrightness) - leaves the
 * system setting alone. While the display is darkened (MotionService.dim)
 * that wins.
 */
class BrightnessController(context: Context) : SensorEventListener {

    enum class Mode { SYSTEM, FIXED, ADAPTIVE }

    private val sensors = context.getSystemService(SensorManager::class.java)
    private val light: Sensor? = sensors?.getDefaultSensor(Sensor.TYPE_LIGHT)
    private var activity: Activity? = null
    private var listening = false

    var mode = Mode.SYSTEM
        private set
    private var level = 0.6f
    private var min = 0.1f
    private var max = 1f
    private var luxForMax = 200f

    /** Smoothed ambient light, -1 = no reading yet. */
    @Volatile
    var lux = -1f
        private set
    private var applied = -2f
    private var appliedAt = 0L

    val hasSensor get() = light != null

    fun configure(mode: Mode, level: Float, min: Float, max: Float, luxForMax: Float) {
        this.mode = mode
        this.level = level.coerceIn(0.01f, 1f)
        this.min = min.coerceIn(0.01f, 1f)
        this.max = max.coerceIn(this.min, 1f)
        this.luxForMax = luxForMax.coerceAtLeast(1f)
        updateListening()
        apply(force = true)
    }

    fun attach(activity: Activity?) {
        this.activity = activity
        updateListening()
        apply(force = true)
    }

    /** Back from darkened: the brightness as set up. */
    fun restore() = apply(force = true)

    /** What the window should have now (screenBrightness; -1 = the system's). */
    fun target(): Float = when (mode) {
        Mode.SYSTEM -> WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        Mode.FIXED -> level
        Mode.ADAPTIVE -> {
            if (lux < 0) max
            else {
                val f = (ln(1f + lux) / ln(1f + luxForMax)).coerceIn(0f, 1f)
                min + (max - min) * f
            }
        }
    }

    private fun updateListening() {
        val want = mode == Mode.ADAPTIVE && activity != null && light != null
        if (want && !listening) {
            sensors?.registerListener(this, light, SensorManager.SENSOR_DELAY_NORMAL)
            listening = true
        } else if (!want && listening) {
            sensors?.unregisterListener(this)
            listening = false
        }
    }

    /** Also for the settings' live display while not adaptive. */
    fun readOnce() {
        if (listening || light == null) return
        sensors?.registerListener(object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                lux = event.values[0]
                sensors.unregisterListener(this)
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }, light, SensorManager.SENSOR_DELAY_NORMAL)
    }

    override fun onSensorChanged(event: SensorEvent) {
        val value = event.values[0].coerceAtLeast(0f)
        // Smooth: a hand passing the sensor doesn't flicker the display.
        lux = if (lux < 0) value else lux + (value - lux) * 0.3f
        apply(force = false)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun apply(force: Boolean) {
        val window = activity?.window ?: return
        if (MotionService.dimmed) return
        val target = target()
        val now = SystemClock.elapsedRealtime()
        if (!force && (abs(target - applied) < 0.02f || now - appliedAt < 500)) return
        applied = target
        appliedAt = now
        val attrs = window.attributes
        attrs.screenBrightness = target
        window.attributes = attrs
    }
}
