package org.lotzapp.home_radio.dab

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Decodes DAB+ AAC access units (from [NativeDabDecoder]) to PCM via
 * Android's built-in MediaCodec raw-AAC decoder, and plays them through an
 * AudioTrack. Runs its own decode thread with an input queue so feeding new
 * access units (from the USB MSC-reading thread) never blocks on decoding.
 */
class DabAudioPlayer {
    // au == null means "insert durationMs of silence" (a CRC-failed AU) -
    // keeps output timing continuous instead of jump-cutting ahead to the
    // next surviving AU, which sounded far choppier for the same amount of
    // missing audio (found 2026-09-16).
    private data class AuTask(val au: ByteArray?, val asc: ByteArray, val sampleRateHz: Int, val channels: Int, val durationMs: Int)

    private val queue = LinkedBlockingQueue<AuTask>(64)

    @Volatile private var running = false
    private var thread: Thread? = null

    private var codec: MediaCodec? = null
    private var audioTrack: AudioTrack? = null
    private var configuredAscHex: String? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread({ runLoop() }, "DabAudioPlayer").apply { start() }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread = null
        queue.clear()
        releaseCodec()
    }

    /**
     * Called from the MSC-reading thread for every AU slot in a synced
     * superframe - [au] is null for a CRC-failed AU, meaning [durationMs]
     * of silence should play in its place instead of just dropping it.
     */
    fun submit(au: ByteArray?, asc: ByteArray, sampleRateHz: Int, channels: Int, durationMs: Int) {
        if (!running) return
        // Drop rather than block if the decoder can't keep up - a queue
        // backlog would just mean increasing audio latency, not lost errors.
        if (queue.remainingCapacity() == 0) queue.poll()
        queue.offer(AuTask(au, asc, sampleRateHz, channels, durationMs))
    }

    private fun runLoop() {
        while (running) {
            val task = try {
                queue.poll(500, TimeUnit.MILLISECONDS) ?: continue
            } catch (e: InterruptedException) {
                break
            }
            try {
                ensureConfigured(task.asc, task.sampleRateHz, task.channels)
                val au = task.au
                if (au == null) {
                    writeSilence(task.durationMs)
                } else {
                    decodeAndPlay(au)
                }
            } catch (e: Exception) {
                Log.w(TAG, "DabAudioPlayer: decode error: ${e.message}")
            }
        }
        releaseCodec()
    }

    private fun ensureConfigured(asc: ByteArray, sampleRateHz: Int, channels: Int) {
        val ascHex = asc.joinToString("") { "%02x".format(it) }
        if (ascHex == configuredAscHex && codec != null) return

        releaseCodec()
        configuredAscHex = ascHex

        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRateHz, channels)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(asc))
        // Raw AAC access units (no ADTS/LOAS framing) - matches exactly what
        // NativeDabDecoder hands us (the CRC-stripped AU payload).
        format.setInteger(MediaFormat.KEY_IS_ADTS, 0)

        val newCodec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        newCodec.configure(format, null, null, 0)
        newCodec.start()
        codec = newCodec
        Log.i(TAG, "DabAudioPlayer: (re)configured decoder for asc=$ascHex core=${sampleRateHz}Hz ${channels}ch")
    }

    private fun decodeAndPlay(au: ByteArray) {
        val codec = this.codec ?: return
        val inIndex = codec.dequeueInputBuffer(20_000)
        if (inIndex >= 0) {
            val inBuf = codec.getInputBuffer(inIndex) ?: return
            inBuf.clear()
            inBuf.put(au)
            codec.queueInputBuffer(inIndex, 0, au.size, 0, 0)
        }

        val info = MediaCodec.BufferInfo()
        while (true) {
            val outIndex = codec.dequeueOutputBuffer(info, 20_000)
            when {
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val outFormat = codec.outputFormat
                    // The decoder's actual PCM output rate can differ from
                    // the "core" rate passed into createAudioFormat above -
                    // SBR (HE-AAC) upsamples by 2x in the decoder's output
                    // stage (e.g. 24 kHz core -> 48 kHz PCM out).
                    setupAudioTrack(
                        outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                        outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                    )
                }
                outIndex >= 0 -> {
                    val outBuf = codec.getOutputBuffer(outIndex)
                    if (outBuf != null && info.size > 0) {
                        val pcm = ByteArray(info.size)
                        outBuf.get(pcm)
                        audioTrack?.write(pcm, 0, pcm.size)
                    }
                    val wasEmpty = info.size == 0
                    codec.releaseOutputBuffer(outIndex, false)
                    if (wasEmpty) break
                }
                else -> break // INFO_TRY_AGAIN_LATER or no more output right now
            }
        }
    }

    /**
     * Writes [durationMs] of silence to the currently configured AudioTrack,
     * if any. TRIED (2026-09-16): repeating the last successfully decoded
     * PCM chunk to fill this gap instead of true silence - user-tested on
     * real hardware and reported as sounding *worse* (a looped/buzzing
     * artifact) than a clean silence gap, despite the same underlying
     * missing-audio duration. Reverted.
     */
    private fun writeSilence(durationMs: Int) {
        val track = audioTrack ?: return
        val numSamples = track.sampleRate.toLong() * durationMs / 1000
        val silence = ByteArray((numSamples * track.channelCount * 2).toInt()) // 16-bit PCM
        track.write(silence, 0, silence.size)
    }

    private fun setupAudioTrack(sampleRateHz: Int, channels: Int) {
        if (audioTrack != null && audioTrack?.sampleRate == sampleRateHz && audioTrack?.channelCount == channels) return
        audioTrack?.stop()
        audioTrack?.release()

        val channelConfig = if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minBufSize = AudioTrack.getMinBufferSize(sampleRateHz, channelConfig, AudioFormat.ENCODING_PCM_16BIT)
        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRateHz)
                    .setChannelMask(channelConfig)
                    .build(),
            )
            .setBufferSizeInBytes(minBufSize.coerceAtLeast(4096) * 4)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        audioTrack?.play()
        Log.i(TAG, "DabAudioPlayer: AudioTrack (re)configured: ${sampleRateHz}Hz ${channels}ch")
    }

    private fun releaseCodec() {
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        try {
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
        configuredAscHex = null
        try {
            audioTrack?.stop()
        } catch (_: Exception) {
        }
        try {
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null
    }

    companion object {
        private const val TAG = "DabProbe"
    }
}
