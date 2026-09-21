package org.lotzapp.home_radio.dab

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Process
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock

/**
 * Plays PCM handed back from [NativeDabDecoder] through an AudioTrack.
 *
 * Architecture ported from the real, confirmed-working DAB-Z app
 * (com.zoulou.dab - decompiled 2026-09-16 for direct comparison after our
 * own USB-protocol/register-level implementation turned out to be a
 * byte-for-byte match with the reference source and still didn't explain
 * the stutter; see H0.c/J0.n0/V3.o in their classes.dex): a fixed-size
 * byte ring buffer sits between the native PCM callback and AudioTrack.
 * The *producer* (native decode callback) blocks briefly and retries when
 * the buffer is full instead of dropping data. AudioTrack itself is sized
 * at Android's own minimum - the ring buffer is the real elastic buffer,
 * not AudioTrack's. Playback drains the ring buffer in fixed
 * minBufferSize-sized chunks. The playback thread runs at
 * Process.THREAD_PRIORITY_AUDIO.
 *
 * Our previous approach - a bounded queue of variable-sized PCM chunks
 * that silently dropped the oldest entry when full, plus an artificially
 * large AudioTrack buffer and default thread priority - still audibly
 * stuttered on this station's bursty ~9000 B/s USB throughput even at
 * every buffer size tried. This mirrors what actually works instead of
 * guessing at another buffer size.
 */
/**
 * @param onAudioFocusLost Called when another app (e.g. Spotify) takes over
 * audio focus while this is playing - DAB+ is a native AudioTrack, entirely
 * outside Flutter's own audio_session/just_audio integration (see
 * AudioPlayerService, which only governs the internet-radio path), so
 * without explicitly requesting focus here neither direction of "don't play
 * two things at once" worked: Android had no reason to signal us to stop,
 * and we never told Android we needed the speaker in the first place either.
 */
class DabAudioPlayer(
    private val context: Context,
    private val onAudioFocusLost: () -> Unit,
) {
    /** Circular byte buffer with wraparound, guarded by [lock]. */
    private class RingBuffer(val capacity: Int) {
        private val buf = ByteArray(capacity)
        private val lock = ReentrantLock()
        private var writePos = 0
        private var readPos = 0
        private var filled = 0

        /** Writes as much of data[offset until offset+len) as fits; returns bytes actually written. */
        fun write(data: ByteArray, offset: Int, len: Int): Int {
            lock.lock()
            try {
                val free = capacity - filled
                val n = minOf(len, free)
                if (n <= 0) return 0
                val tail = capacity - writePos
                if (n > tail) {
                    System.arraycopy(data, offset, buf, writePos, tail)
                    System.arraycopy(data, offset + tail, buf, 0, n - tail)
                    writePos = n - tail
                } else {
                    System.arraycopy(data, offset, buf, writePos, n)
                    writePos = (writePos + n) % capacity
                }
                filled += n
                return n
            } finally {
                lock.unlock()
            }
        }

        /** Reads up to len bytes into out[0 until len); returns bytes actually read. */
        fun read(out: ByteArray, len: Int): Int {
            lock.lock()
            try {
                val n = minOf(len, filled)
                if (n <= 0) return 0
                val tail = capacity - readPos
                if (n > tail) {
                    System.arraycopy(buf, readPos, out, 0, tail)
                    System.arraycopy(buf, 0, out, tail, n - tail)
                    readPos = n - tail
                } else {
                    System.arraycopy(buf, readPos, out, 0, n)
                    readPos = (readPos + n) % capacity
                }
                filled -= n
                return n
            } finally {
                lock.unlock()
            }
        }

        fun availableToRead(): Int {
            lock.lock()
            try {
                return filled
            } finally {
                lock.unlock()
            }
        }

        fun reset() {
            lock.lock()
            try {
                writePos = 0
                readPos = 0
                filled = 0
            } finally {
                lock.unlock()
            }
        }
    }

    @Volatile private var running = false
    private var thread: Thread? = null

    private var audioTrack: AudioTrack? = null
    private var ringBuffer: RingBuffer? = null
    private var chunkSize = 0
    @Volatile private var configuredSampleRate = -1
    @Volatile private var configuredChannels = -1
    private val configLock = ReentrantLock()
    private val configuring = AtomicBoolean(false)

    // Which AudioTrack instance the fade-in has already been kicked off
    // for - see runLoop()'s own comment on why that happens there now,
    // not right after creating the track in ensureConfigured().
    @Volatile private var fadeStartedForTrack: AudioTrack? = null

    // How many times PCM was actually handed to AudioTrack.write() - the
    // real "is audio actually reaching the speaker" signal, as opposed to
    // native decode merely having produced PCM (see submit()'s own doc
    // comment: that can succeed while ensureConfigured() keeps failing -
    // e.g. right after a fresh app start, before the audio subsystem is
    // fully ready - leaving every chunk silently dropped with no
    // AudioTrack to write to at all). DabRtlSdrPlugin's "playService"
    // watches this to verify a "playing" report is actually true.
    @Volatile private var trackWriteCount = 0L
    val pcmWriteCount: Long get() = trackWriteCount

    private val audioManager: AudioManager by lazy {
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    private var focusRequest: AudioFocusRequest? = null
    private val focusChangeListener =
        AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    // DAB+ is a live broadcast with no "ducking" concept
                    // that makes sense (there's nothing to duck to, unlike
                    // a paused music track) - even a transient loss just
                    // stops outright; the Dart side re-tunes from scratch
                    // if the user presses Play again.
                    Log.i(TAG, "DabAudioPlayer: audio focus lost ($change), stopping")
                    onAudioFocusLost()
                }
            }
        }

    private fun requestAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request =
                AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build(),
                    )
                    .setOnAudioFocusChangeListener(focusChangeListener)
                    .build()
            focusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                focusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
    }

    private fun abandonAudioFocus() {
        val request = focusRequest
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && request != null) {
            audioManager.abandonAudioFocusRequest(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusChangeListener)
        }
        focusRequest = null
    }

    fun start() {
        if (running) return
        running = true
        requestAudioFocus()
        thread = Thread({ runLoop() }, "DabAudioPlayer").apply { start() }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread = null
        ringBuffer?.reset()
        releaseTrack()
        abandonAudioFocus()
    }

    /**
     * Called from the native-decode thread with ready-to-play PCM. Blocks
     * (briefly, repeatedly) if the ring buffer is full rather than
     * dropping data - matching DAB-Z's producer/consumer pattern. Safe to
     * block here: the decode thread is already decoupled from raw USB
     * reads via its own queue (see DabUsbPlugin's rawCifQueue), so a short
     * stall doesn't risk losing incoming USB data.
     *
     * On the very first call for a station (or after a format change),
     * [ensureConfigured] used to run right here, inline. That's exactly
     * the wrong place for it: this is called straight out of the native
     * AAC decode step, itself inside OFDMProcessor::run()'s own thread
     * (see dabcore_jni.cpp's onNewAudio()/nativeOnAudioPcm) - the same
     * time-critical OFDM sync loop the whole priority-boosting effort
     * elsewhere in this app exists to protect. AudioTrack.Builder().build()
     * + .play() are slow Binder/AudioFlinger calls (tens of ms, sometimes
     * more), and running them there stalled OFDM sync at exactly the worst
     * possible moment - right after a fresh tune, when sync is still
     * fragile - matching the "hakelt vor allem beim Starten eines Senders"
     * symptom. Now handed off to a plain background thread instead; this
     * call just drops PCM chunks that arrive before setup finishes (a few
     * ms of silence on a station nobody has heard yet is inaudible).
     */
    fun submit(pcm: ByteArray, sampleRateHz: Int, channels: Int) {
        if (!running) return
        if (configuredSampleRate != sampleRateHz || configuredChannels != channels) {
            if (configuring.compareAndSet(false, true)) {
                Thread {
                    try {
                        ensureConfigured(sampleRateHz, channels)
                    } finally {
                        configuring.set(false)
                    }
                }.start()
            }
            return
        }
        val ring = ringBuffer ?: return
        var offset = 0
        var waitedMs = 0L
        while (offset < pcm.size && running) {
            val written = ring.write(pcm, offset, pcm.size - offset)
            offset += written
            if (offset < pcm.size) {
                if (waitedMs >= 3000) {
                    Log.w(TAG, "DabAudioPlayer: ring buffer stayed full for 3s, dropping ${pcm.size - offset} bytes")
                    break
                }
                try {
                    Thread.sleep(10)
                } catch (e: InterruptedException) {
                    break
                }
                waitedMs += 10
            }
        }
        // This runs on the same native decode thread that also drives OFDM
        // sync (see AndroidProgrammeHandler::onNewAudio in dabcore_jni.cpp -
        // it's called straight out of the AAC decode step, itself inside
        // OFDMProcessor::run()'s loop) - a submit() that blocks a
        // significant amount of time here isn't just a playback-side stall,
        // it directly starves the synchronizer too. Logged whenever it's
        // long enough to plausibly matter, not just at the 3s drop timeout.
        if (waitedMs >= 100) {
            Log.w(TAG, "DabAudioPlayer: submit() blocked ${waitedMs}ms (ring buffer was full)")
        }
    }

    private fun runLoop() {
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        } catch (e: Exception) {
            Log.w(TAG, "DabAudioPlayer: setThreadPriority failed: ${e.message}")
        }
        val readBuf = ByteArray(MAX_CHUNK_BYTES)
        var lastUnderrunLogAt = 0L
        var lastUnderrunCount = -1
        while (running) {
            // DIAGNOSTIC (2026-09-16): confirms whether the audible stutter
            // is genuine AudioTrack starvation (ring buffer running dry -
            // i.e. a real, sustained input-rate deficit that no buffering
            // strategy can fix) versus something else entirely (e.g. the
            // AAC decode itself producing bad/gappy PCM even though enough
            // bytes are technically flowing).
            val now = System.currentTimeMillis()
            if (now - lastUnderrunLogAt >= 3000) {
                lastUnderrunLogAt = now
                val track = audioTrack
                if (track != null && android.os.Build.VERSION.SDK_INT >= 24) {
                    try {
                        val count = track.underrunCount
                        if (count != lastUnderrunCount) {
                            val fillPct = ringBuffer?.let { it.availableToRead() * 100 / it.capacity } ?: -1
                            Log.w(TAG, "DabAudioPlayer: AudioTrack underrunCount=$count ringFill=$fillPct%")
                            lastUnderrunCount = count
                        }
                    } catch (_: Exception) {
                    }
                }
            }
            val ring = ringBuffer
            val size = chunkSize
            if (ring == null || size <= 0 || size > readBuf.size) {
                try {
                    Thread.sleep(10)
                } catch (e: InterruptedException) {
                    break
                }
                continue
            }
            if (ring.availableToRead() < size) {
                try {
                    Thread.sleep(10)
                } catch (e: InterruptedException) {
                    break
                }
                continue
            }
            val n = ring.read(readBuf, size)
            if (n > 0) {
                try {
                    val track = audioTrack
                    val written = track?.write(readBuf, 0, n) ?: -1
                    if (written > 0) {
                        trackWriteCount++
                        // Kick off the fade-in on the very first real write
                        // for this track, not back when ensureConfigured()
                        // created it - the ring buffer needing to fill up
                        // to chunkSize first (the check just above) means
                        // there can be a real gap between "AudioTrack
                        // exists" and "actual playback begins", during
                        // which a fade timer started too early would
                        // already be back at full volume by the time
                        // anything audible actually starts.
                        if (track != null && fadeStartedForTrack !== track) {
                            fadeStartedForTrack = track
                            fadeIn(track)
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "DabAudioPlayer: playback error: ${e.message}")
                }
            }
        }
        releaseTrack()
    }

    /**
     * (Re)builds the ring buffer + AudioTrack pair when the stream format
     * changes. Returns the ring buffer new PCM should be written to, or
     * null if setup failed. Callable from the producer thread; the
     * consumer ([runLoop]) reads [ringBuffer]/[chunkSize] afterwards.
     */
    private fun ensureConfigured(sampleRateHz: Int, channels: Int): RingBuffer? {
        if (configuredSampleRate == sampleRateHz && configuredChannels == channels && ringBuffer != null) {
            return ringBuffer
        }
        configLock.lock()
        try {
            if (configuredSampleRate == sampleRateHz && configuredChannels == channels && ringBuffer != null) {
                return ringBuffer
            }
            audioTrack?.let {
                try {
                    it.stop()
                    it.release()
                } catch (_: Exception) {
                }
            }
            val channelConfig = if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
            val minBufSize = AudioTrack.getMinBufferSize(sampleRateHz, channelConfig, AudioFormat.ENCODING_PCM_16BIT)
            if (minBufSize <= 0 || minBufSize > MAX_CHUNK_BYTES) {
                Log.w(TAG, "DabAudioPlayer: unusable minBufferSize=$minBufSize for ${sampleRateHz}Hz ${channels}ch")
                return null
            }
            val newTrack = AudioTrack.Builder()
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
                .setBufferSizeInBytes(minBufSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            // Starts silent; runLoop() kicks off the actual fade-in once
            // real playback begins (see that function's own comment for
            // why not here).
            newTrack.setVolume(0f)
            newTrack.play()

            val bytesPerSecond = sampleRateHz * channels * 2 // 16-bit PCM
            val ringBytes = bytesPerSecond * DabTuning.audioBufferMs / 1000
            val newRing = RingBuffer(maxOf(ringBytes, minBufSize * 2))

            audioTrack = newTrack
            ringBuffer = newRing
            chunkSize = minBufSize
            configuredSampleRate = sampleRateHz
            configuredChannels = channels
            Log.i(
                TAG,
                "DabAudioPlayer: (re)configured ${sampleRateHz}Hz ${channels}ch, " +
                    "minBufferSize=$minBufSize, ringBuffer=${newRing.capacity} bytes",
            )
            return newRing
        } finally {
            configLock.unlock()
        }
    }

    private fun fadeIn(track: AudioTrack) {
        Thread {
            val steps = 90
            val stepMs = 10L
            for (i in 1..steps) {
                if (audioTrack !== track) return@Thread // superseded by a newer station/track
                try {
                    track.setVolume(i.toFloat() / steps)
                } catch (_: Exception) {
                    return@Thread
                }
                try {
                    Thread.sleep(stepMs)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }.start()
    }

    private fun releaseTrack() {
        try {
            audioTrack?.stop()
        } catch (_: Exception) {
        }
        try {
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null
        fadeStartedForTrack = null
        configuredSampleRate = -1
        configuredChannels = -1
    }

    companion object {
        private const val TAG = "DabProbe"
        private const val MAX_CHUNK_BYTES = 65536
    }
}
