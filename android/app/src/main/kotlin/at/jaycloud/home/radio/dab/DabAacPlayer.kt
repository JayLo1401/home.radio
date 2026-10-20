package at.jaycloud.home.radio.dab

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Process
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Audio output of the integrated DAB+ engine: decodes the raw HE-AAC/AAC
 * access units with Android's own MediaCodec (no AAC code in the app) and
 * plays them through an AudioTrack.
 *
 * Three threads, decoupled by non-blocking queues so neither the native
 * receiver nor the decoder can ever be held up by the speaker:
 *  - native receiver thread -> [onAccessUnit] only enqueues (drops if full)
 *  - "DabAac" decoder thread: MediaCodec in, PCM into a ring buffer
 *  - "DabAacOut" playback thread: ring buffer -> AudioTrack
 *
 * DAB+ delivers audio in bursts of one super frame (120 ms), so playback
 * starts only once [PREBUFFER_MS] are buffered and refills the same way after
 * an underrun. The transmitter's audio clock and the TV box's DAC clock never
 * run at exactly the same speed; when the buffer drifts out of a +-60 ms band
 * around the target, single sample frames are dropped or repeated (at most
 * one per 10 ms block - inaudible) until it is back in the band.
 */
class DabAacPlayer(
    private val context: Context,
    private val onAudioFocusLost: () -> Unit,
) {

    private sealed class Item {
        class Config(val asc: ByteArray, val sampleRate: Int, val channels: Int) : Item()
        class Au(val data: ByteArray, val ok: Boolean) : Item()
    }

    private val queue = ArrayBlockingQueue<Item>(64)
    @Volatile private var running = false
    private var decoderThread: Thread? = null
    private var outputThread: Thread? = null

    // PCM ring (interleaved 16-bit), guarded by ringLock.
    private val ringLock = Object()
    private var ring = ShortArray(0)
    private var ringRead = 0
    private var ringFill = 0
    @Volatile private var outRate = 0
    @Volatile private var outChannels = 0

    @Volatile private var writes = 0L
    /** Number of real (non-silence) PCM writes to the AudioTrack so far. */
    val pcmWriteCount: Long get() = writes

    private val audioManager by lazy { context.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private var focusRequest: AudioFocusRequest? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            Log.i(TAG, "audio focus lost ($change)")
            onAudioFocusLost()
        }
    }

    fun start() {
        if (running) return
        running = true
        requestFocus()
        decoderThread = Thread({ decodeLoop() }, "DabAac").apply { start() }
        outputThread = Thread({ outputLoop() }, "DabAacOut").apply { start() }
    }

    fun stop() {
        running = false
        decoderThread?.interrupt()
        outputThread?.interrupt()
        try {
            decoderThread?.join(700)
            outputThread?.join(700)
        } catch (_: InterruptedException) {
        }
        decoderThread = null
        outputThread = null
        queue.clear()
        abandonFocus()
    }

    /** New stream parameters (also sent again after every retune/service change). */
    fun onAudioConfig(asc: ByteArray, sampleRate: Int, channels: Int) {
        if (running) queue.offer(Item.Config(asc, sampleRate, channels))
    }

    fun onAccessUnit(au: ByteArray, ok: Boolean) {
        if (!running) return
        if (!queue.offer(Item.Au(au, ok))) Log.w(TAG, "AU queue full, dropping")
    }

    // --- decoder thread ---

    private fun findDecoderName(): String? {
        val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_AUDIO_AAC, true) }
        }
        // Android's own software decoder handles 960-sample frames, SBR and
        // PS reliably; vendor hardware decoders often don't.
        return (
            infos.firstOrNull { it.name.startsWith("c2.android.aac") }
                ?: infos.firstOrNull { it.name.startsWith("OMX.google.aac") }
                ?: infos.firstOrNull()
            )?.name
    }

    private fun decodeLoop() {
        var codec: MediaCodec? = null
        var frameSamples = 960 // per channel, at the output rate
        var pts = 0L
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val item = try {
                    queue.poll(20, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    break
                }
                when (item) {
                    is Item.Config -> {
                        codec?.let { releaseCodec(it) }
                        codec = createCodec(item)
                        // SBR doubles the 960-sample core frame.
                        frameSamples = if (isSbr(item.asc)) 1920 else 960
                        configureRing(item.sampleRate, item.channels)
                    }
                    is Item.Au -> {
                        val c = codec
                        if (c == null) {
                            // no config yet - nothing to decode against
                        } else if (item.ok && item.data.isNotEmpty()) {
                            val index = c.dequeueInputBuffer(20_000)
                            if (index >= 0) {
                                val buf = c.getInputBuffer(index)!!
                                buf.clear()
                                buf.put(item.data)
                                c.queueInputBuffer(index, 0, item.data.size, pts, 0)
                                pts += frameSamples * 1_000_000L / maxOf(outRate, 1)
                            }
                        } else {
                            // Damaged AU: keep the timeline with silence
                            // rather than feeding garbage to the decoder.
                            pushPcm(ShortArray(frameSamples * maxOf(outChannels, 1)), silent = true)
                        }
                    }
                    null -> {}
                }
                codec?.let { drain(it, info) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "decoder thread failed", e)
        } finally {
            codec?.let { releaseCodec(it) }
        }
    }

    private fun isSbr(asc: ByteArray): Boolean {
        val aot = (asc[0].toInt() and 0xFF) shr 3
        return aot == 5 || aot == 29
    }

    private fun createCodec(cfg: Item.Config): MediaCodec? {
        val name = findDecoderName() ?: run {
            Log.e(TAG, "no AAC decoder on this device")
            return null
        }
        return try {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, cfg.sampleRate, cfg.channels)
            format.setByteBuffer("csd-0", ByteBuffer.wrap(cfg.asc))
            format.setInteger(MediaFormat.KEY_IS_ADTS, 0)
            MediaCodec.createByCodecName(name).apply {
                configure(format, null, null, 0)
                start()
                Log.i(TAG, "decoder $name for ${cfg.sampleRate} Hz x${cfg.channels}, ASC ${cfg.asc.joinToString("") { "%02x".format(it) }}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "could not start $name", e)
            null
        }
    }

    private fun releaseCodec(c: MediaCodec) {
        try {
            c.stop()
        } catch (_: Exception) {
        }
        try {
            c.release()
        } catch (_: Exception) {
        }
    }

    private fun drain(c: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val index = c.dequeueOutputBuffer(info, 0)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = c.outputFormat
                    configureRing(f.getInteger(MediaFormat.KEY_SAMPLE_RATE), f.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
                }
                index >= 0 -> {
                    val buf = c.getOutputBuffer(index)
                    if (buf != null && info.size > 0) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val pcm = ShortArray(info.size / 2)
                        buf.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer().get(pcm)
                        pushPcm(pcm, silent = false)
                    }
                    c.releaseOutputBuffer(index, false)
                }
                else -> return
            }
        }
    }

    private fun configureRing(rate: Int, channels: Int) {
        synchronized(ringLock) {
            if (rate == outRate && channels == outChannels && ring.isNotEmpty()) return
            outRate = rate
            outChannels = channels
            ring = ShortArray(rate * channels * RING_MS / 1000)
            ringRead = 0
            ringFill = 0
            ringLock.notifyAll()
        }
    }

    private fun pushPcm(pcm: ShortArray, silent: Boolean) {
        synchronized(ringLock) {
            val cap = ring.size
            if (cap == 0) return
            // Overflow means playback stalled for seconds - drop the oldest.
            val overflow = ringFill + pcm.size - cap
            if (overflow > 0) {
                ringRead = (ringRead + overflow) % cap
                ringFill -= overflow
            }
            var w = (ringRead + ringFill) % cap
            for (s in pcm) {
                ring[w] = s
                w++
                if (w == cap) w = 0
            }
            ringFill += pcm.size
            if (!silent) realPcmPending = true
            ringLock.notifyAll()
        }
    }

    @Volatile private var realPcmPending = false

    // --- playback thread ---

    private fun outputLoop() {
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        } catch (_: Exception) {
        }
        var track: AudioTrack? = null
        var trackRate = 0
        var trackChannels = 0
        var prebuffering = true
        var fadeStep = 0
        var block = ShortArray(0)
        try {
            while (running) {
                val rate = outRate
                val channels = outChannels
                if (rate <= 0 || channels <= 0) {
                    Thread.sleep(10)
                    continue
                }
                if (track == null || rate != trackRate || channels != trackChannels) {
                    track?.let { releaseTrack(it) }
                    track = createTrack(rate, channels)
                    if (track == null) {
                        Thread.sleep(100)
                        continue
                    }
                    trackRate = rate
                    trackChannels = channels
                    prebuffering = true
                    fadeStep = 0
                }
                val frames = rate / 100 // 10 ms blocks
                val prebufferSamples = rate * channels * PREBUFFER_MS / 1000
                val targetSamples = prebufferSamples
                val band = rate * channels * BAND_MS / 1000
                var real = false
                synchronized(ringLock) {
                    if (prebuffering && ringFill >= prebufferSamples) prebuffering = false
                    if (!prebuffering && ringFill < frames * channels) {
                        prebuffering = true // underrun: rebuild the cushion
                        Log.w(TAG, "underrun, re-buffering")
                    }
                    if (prebuffering) {
                        block = if (block.size == frames * channels) block else ShortArray(frames * channels)
                        block.fill(0)
                    } else {
                        // Clock drift: +-1 frame per block outside the band.
                        val adjust = when {
                            ringFill > targetSamples + band -> 1
                            ringFill < targetSamples - band -> -1
                            else -> 0
                        }
                        val take = (frames + adjust) * channels
                        val out = ShortArray(frames * channels)
                        val cap = ring.size
                        val n = minOf(take, ringFill)
                        val copy = minOf(n, out.size)
                        for (i in 0 until copy) out[i] = ring[(ringRead + i) % cap]
                        // repeating a frame: duplicate the last one
                        for (i in copy until out.size) out[i] = if (copy >= channels) out[copy - channels + (i - copy) % channels] else 0
                        ringRead = (ringRead + n) % cap
                        ringFill -= n
                        block = out
                        real = realPcmPending
                    }
                }
                val t = track!!
                t.write(block, 0, block.size)
                if (real && !prebuffering) {
                    writes++
                    if (fadeStep < FADE_STEPS) {
                        fadeStep++
                        t.setVolume(fadeStep.toFloat() / FADE_STEPS)
                    }
                }
            }
        } catch (_: InterruptedException) {
        } catch (e: Exception) {
            Log.w(TAG, "playback thread failed", e)
        } finally {
            track?.let { releaseTrack(it) }
        }
    }

    private fun createTrack(rate: Int, channels: Int): AudioTrack? {
        val mask = if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val min = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return null
        // ~100 ms inside AudioTrack on top of the ring buffer.
        val size = maxOf(min * 2, rate * channels * 2 / 10)
        return try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(mask)
                        .build(),
                )
                .setBufferSizeInBytes(size)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
                .apply {
                    setVolume(0f)
                    play()
                }
        } catch (e: Exception) {
            Log.w(TAG, "AudioTrack creation failed", e)
            null
        }
    }

    private fun releaseTrack(t: AudioTrack) {
        try {
            t.stop()
        } catch (_: Exception) {
        }
        try {
            t.release()
        } catch (_: Exception) {
        }
    }

    private fun requestFocus() {
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = req
            audioManager.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
    }

    private fun abandonFocus() {
        val req = focusRequest
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && req != null) {
            audioManager.abandonAudioFocusRequest(req)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
        focusRequest = null
    }

    companion object {
        private const val TAG = "DabAac"
        private const val PREBUFFER_MS = 400
        private const val BAND_MS = 60
        private const val RING_MS = 3000
        private const val FADE_STEPS = 30 // x 10 ms
    }
}
