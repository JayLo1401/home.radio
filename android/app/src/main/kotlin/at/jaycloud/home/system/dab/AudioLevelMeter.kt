package at.jaycloud.home.system.dab

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Spectrum bars for the equalizer in the Now Playing banner, computed from
 * the PCM [DabAacPlayer] writes to the AudioTrack. Same analysis as the
 * desktop's audio_levels.h:
 *  - the output is mixed to mono into a ring of the last [SIZE] samples
 *  - every [HOP_MS] (25 times a second) those get a Hann window and a
 *    1024-point FFT, and the power is summed into [BANDS] octave-wide bands
 *    (log-spaced from 60 Hz up to 14 kHz, or a bit below Nyquist)
 *  - each band in dB (re a full-scale sine, slightly tilted up towards the
 *    treble, where music has less energy) is mapped to 0..1, rises fast and
 *    falls slowly, and is sent as one byte (0..255)
 *
 * Used by the playback thread only - no locking.
 */
class AudioLevelMeter {

    private val window = FloatArray(SIZE) { (0.5 - 0.5 * cos(2 * PI * it / SIZE)).toFloat() }
    private val cosT = FloatArray(SIZE / 2) { cos(2 * PI * it / SIZE).toFloat() }
    private val sinT = FloatArray(SIZE / 2) { (-sin(2 * PI * it / SIZE)).toFloat() }
    private val rev = IntArray(SIZE) { i ->
        var r = 0
        for (b in 0 until BITS) r = r or (((i shr b) and 1) shl (BITS - 1 - b))
        r
    }

    private val ring = FloatArray(SIZE)
    private var pos = 0
    private var pending = 0
    private var rate = 0

    private val re = FloatArray(SIZE)
    private val im = FloatArray(SIZE)
    private val binLo = IntArray(BANDS)
    private val binHi = IntArray(BANDS)
    private val smooth = FloatArray(BANDS)
    private var silentFrames = 0

    /**
     * Appends [samples] interleaved values of [pcm]; returns the new band
     * levels when an update is due and worth sending, else null (nothing
     * new yet, or silence already sent - repeated once a second only, so the
     * app knows the player is alive).
     */
    fun push(pcm: ShortArray, samples: Int, channels: Int, sampleRate: Int): ByteArray? {
        if (channels <= 0 || sampleRate <= 0) return null
        if (sampleRate != rate) {
            rate = sampleRate
            pending = 0
            setupBands(sampleRate)
        }
        val frames = samples / channels
        var i = 0
        for (f in 0 until frames) {
            var sum = 0
            for (c in 0 until channels) sum += pcm[i++]
            ring[pos] = sum / (32768f * channels)
            pos = (pos + 1) and (SIZE - 1)
        }
        pending += frames
        val hop = rate * HOP_MS / 1000
        if (pending < hop) return null
        pending = min(pending - hop, hop) // never queue up a backlog
        return analyze()
    }

    private fun analyze(): ByteArray? {
        for (k in 0 until SIZE) {
            val r = rev[k]
            re[r] = ring[(pos + k) and (SIZE - 1)] * window[k]
            im[r] = 0f
        }
        fft()
        val out = ByteArray(BANDS)
        var any = false
        for (b in 0 until BANDS) {
            var power = 0f
            for (k in binLo[b] until binHi[b]) power += re[k] * re[k] + im[k] * im[k]
            val db = 10f * log10(power / REF + 1e-12f) + TILT_DB * b
            val target = ((db - FLOOR_DB) / (TOP_DB - FLOOR_DB)).coerceIn(0f, 1f)
            var v = smooth[b]
            v = if (target > v) v + (target - v) * ATTACK else max(target, v - FALL)
            smooth[b] = v
            val byte = (v * 255).roundToInt()
            out[b] = byte.toByte()
            if (byte != 0) any = true
        }
        // Silence: send the first all-zero set (bars down), then a heartbeat.
        if (!any) {
            if (silentFrames++ % (1000 / HOP_MS) != 0) return null
        } else {
            silentFrames = 0
        }
        return out
    }

    private fun setupBands(sampleRate: Int) {
        val lo = 60.0
        val hi = min(14000.0, 0.45 * sampleRate)
        for (b in 0 until BANDS) {
            val f0 = lo * (hi / lo).pow(b.toDouble() / BANDS)
            val f1 = lo * (hi / lo).pow((b + 1).toDouble() / BANDS)
            val k0 = (f0 * SIZE / sampleRate).roundToInt().coerceIn(1, SIZE / 2 - 1)
            val k1 = (f1 * SIZE / sampleRate).roundToInt()
            binLo[b] = k0
            binHi[b] = k1.coerceIn(k0 + 1, SIZE / 2)
        }
    }

    /** In-place radix-2 FFT of [re]/[im] (already in bit-reversed order). */
    private fun fft() {
        var len = 2
        while (len <= SIZE) {
            val half = len shr 1
            val step = SIZE / len
            var i = 0
            while (i < SIZE) {
                for (j in 0 until half) {
                    val wr = cosT[j * step]
                    val wi = sinT[j * step]
                    val a = i + j
                    val b = a + half
                    val tr = re[b] * wr - im[b] * wi
                    val ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                i += len
            }
            len = len shl 1
        }
    }

    companion object {
        const val BANDS = 8
        const val HOP_MS = 40
        private const val SIZE = 1024
        private const val BITS = 10
        // Full-scale sine through the Hann window: sum of |X|^2 over the
        // positive half = N^2 * 3/32.
        private const val REF = 1024f * 1024f * 3f / 32f
        private const val FLOOR_DB = -50f
        private const val TOP_DB = -8f
        private const val TILT_DB = 2f // per band, towards the treble
        private const val ATTACK = 0.7f
        private const val FALL = 0.06f // per hop: full scale in ~0.7 s
    }
}
