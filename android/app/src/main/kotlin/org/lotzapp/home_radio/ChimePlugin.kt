package org.lotzapp.home_radio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.lotzapp.home_radio.dab.DabAudioPlayer
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

/**
 * Bell for the "Bitte abholen" popup (see Dart's ChimeService).
 *
 * A synthesized bell played through its own AudioTrack (USAGE_MEDIA, so
 * it follows the TV's normal volume like the radio does) without requesting
 * audio focus - taking focus would make the radio stop/pause itself (both
 * AudioPlayerService and DabAudioPlayer react to focus loss). Instead the
 * DAB+ radio is ducked here (DabAudioPlayer.setDuckLevel) for the length of
 * the bell, and internet radio by the Dart side around this call - an
 * earlier short ToneGenerator beep simply mixed in at the radio's full
 * volume was inaudible.
 *
 * "play" only returns once the bell has finished and the radio is back up,
 * so the Dart side can restore internet radio's volume at the same moment.
 */
class ChimePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var playing = false

    // Synthesized once, on first use.
    private val bellPcm: ShortArray by lazy { synthesizeBell() }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "home_radio/chime")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "play") {
            result.notImplemented()
            return
        }
        if (playing) {
            result.success(false)
            return
        }
        playing = true
        Thread({
            var ok = false
            try {
                ok = playBellWithDucking()
            } catch (e: Exception) {
                Log.w(TAG, "Chime failed: ${e.message}")
            } finally {
                DabAudioPlayer.setDuckLevel(1f)
                playing = false
                mainHandler.post { result.success(ok) }
            }
        }, "ChimePlugin").start()
    }

    private fun playBellWithDucking(): Boolean {
        rampDuck(from = 1f, to = DUCK_LEVEL, ms = 250)

        val pcm = bellPcm
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(pcm.size * 2)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()
        try {
            track.write(pcm, 0, pcm.size)
            track.setVolume(1f)
            track.play()
            Thread.sleep(pcm.size * 1000L / SAMPLE_RATE + 100)
        } finally {
            try {
                track.stop()
            } catch (_: Exception) {
            }
            track.release()
        }

        rampDuck(from = DUCK_LEVEL, to = 1f, ms = 600)
        return true
    }

    private fun rampDuck(from: Float, to: Float, ms: Long) {
        val steps = 15
        for (i in 1..steps) {
            DabAudioPlayer.setDuckLevel(from + (to - from) * i / steps)
            Thread.sleep(ms / steps)
        }
    }

    /**
     * The classic kitchen "order up" service bell (the dome bell on the
     * pass that's slapped when food is ready) - "ding! ding!": two quick
     * strikes of a small, bright metal dome. Each strike is a sum of the
     * dome's inharmonic partials (not integer multiples - that's what makes
     * it metallic rather than a beep), each decaying at its own rate, the
     * main tone split into two slightly detuned components for the shimmer
     * ("Schweben") a real bell has, plus a brief high click for the
     * hammer hitting the metal.
     */
    private fun synthesizeBell(): ShortArray {
        val strikeOffsetsSec = doubleArrayOf(0.0, 0.32)
        val ringSec = 2.2
        val totalSamples = ((strikeOffsetsSec.last() + ringSec) * SAMPLE_RATE).toInt()
        val mix = DoubleArray(totalSamples)

        val fundamental = 1760.0 // Hz - a typical service bell's bright main tone
        // (frequency ratio, relative amplitude, decay time constant in s)
        val partials = arrayOf(
            doubleArrayOf(1.000, 1.00, 0.90), // main tone
            doubleArrayOf(1.0018, 0.70, 0.95), // detuned twin -> ~3 Hz shimmer
            doubleArrayOf(2.72, 0.40, 0.45),
            doubleArrayOf(2.7235, 0.25, 0.50),
            doubleArrayOf(5.18, 0.18, 0.20),
            doubleArrayOf(8.30, 0.10, 0.08),
            doubleArrayOf(0.53, 0.12, 0.60), // faint low body resonance
        )

        for ((strikeIndex, offset) in strikeOffsetsSec.withIndex()) {
            val start = (offset * SAMPLE_RATE).toInt()
            // Second slap a touch softer, like a hand hitting it twice.
            val strikeGain = if (strikeIndex == 0) 1.0 else 0.85
            for (n in 0 until (ringSec * SAMPLE_RATE).toInt()) {
                val idx = start + n
                if (idx >= totalSamples) break
                val t = n.toDouble() / SAMPLE_RATE
                // ~1ms attack - sharp like metal being hit, without a
                // digital click.
                val attack = if (t < 0.001) t / 0.001 else 1.0
                var s = 0.0
                for (p in partials) {
                    s += p[1] * exp(-t / p[2]) * sin(2 * PI * fundamental * p[0] * t)
                }
                // Hammer "tick": a very short, high burst at the strike.
                s += 0.25 * exp(-t / 0.004) * sin(2 * PI * 6300.0 * t)
                mix[idx] += s * attack * strikeGain
            }
        }

        // Normalize to ~90% full scale.
        val peak = mix.maxOf { kotlin.math.abs(it) }.takeIf { it > 0 } ?: 1.0
        val gain = 0.9 * Short.MAX_VALUE / peak
        return ShortArray(totalSamples) { (mix[it] * gain).toInt().toShort() }
    }

    companion object {
        private const val TAG = "ChimePlugin"
        private const val SAMPLE_RATE = 44100

        // How far the radio is turned down while the bell rings.
        private const val DUCK_LEVEL = 0.2f
    }
}
