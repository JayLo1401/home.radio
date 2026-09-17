package org.lotzapp.home_radio.dab

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
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
class DabAudioPlayer(private val dumpContext: Context? = null) {
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
    private var configuredSampleRate = -1
    private var configuredChannels = -1
    private val configLock = ReentrantLock()

    // TEMP (2026-09-16): dumps exactly what's sent to the AudioTrack to a
    // WAV file, so the actual playback timeline can be inspected/measured
    // offline instead of relying on how a stutter is described by ear -
    // requested after "is it really just small stutters?" came up.
    private var wavOut: RandomAccessFile? = null
    private var wavFile: File? = null
    private var wavBytesWritten = 0L
    private var wavSampleRate = 0
    private var wavChannels = 0
    private val wavMaxBytes = 8_000_000L // ~40s of 48kHz stereo 16-bit PCM

    fun start() {
        if (running) return
        running = true
        if (dumpContext != null) startWavDump()
        thread = Thread({ runLoop() }, "DabAudioPlayer").apply { start() }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread = null
        ringBuffer?.reset()
        finalizeWavDump()
        releaseTrack()
    }

    /**
     * Called from the native-decode thread with ready-to-play PCM. Blocks
     * (briefly, repeatedly) if the ring buffer is full rather than
     * dropping data - matching DAB-Z's producer/consumer pattern. Safe to
     * block here: the decode thread is already decoupled from raw USB
     * reads via its own queue (see DabUsbPlugin's rawCifQueue), so a short
     * stall doesn't risk losing incoming USB data.
     */
    fun submit(pcm: ByteArray, sampleRateHz: Int, channels: Int) {
        if (!running) return
        val ring = ensureConfigured(sampleRateHz, channels) ?: return
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
                            Log.w(TAG, "DabAudioPlayer: AudioTrack underrunCount=$count")
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
                    writePcm(readBuf, n)
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
        configuredSampleRate = -1
        configuredChannels = -1
    }

    private fun startWavDump() {
        try {
            val dir = dumpContext?.getExternalFilesDir(null)
            val file = File(dir, "dab_audio_dump.wav")
            val raf = RandomAccessFile(file, "rw")
            raf.setLength(0)
            raf.write(ByteArray(44)) // placeholder header, patched in on finalize
            wavFile = file
            wavOut = raf
            wavBytesWritten = 0
            Log.i(TAG, "WAV dump started: ${file.absolutePath}")
        } catch (e: Exception) {
            Log.w(TAG, "WAV dump start failed: ${e.message}")
        }
    }

    private fun writePcm(pcm: ByteArray, len: Int) {
        audioTrack?.write(pcm, 0, len)
        val out = wavOut ?: return
        if (wavBytesWritten >= wavMaxBytes) {
            finalizeWavDump()
            return
        }
        try {
            wavSampleRate = configuredSampleRate.takeIf { it > 0 } ?: wavSampleRate
            wavChannels = configuredChannels.takeIf { it > 0 } ?: wavChannels
            out.write(pcm, 0, len)
            wavBytesWritten += len
        } catch (e: Exception) {
            Log.w(TAG, "WAV dump write failed: ${e.message}")
        }
    }

    private fun finalizeWavDump() {
        val out = wavOut ?: return
        wavOut = null
        try {
            val header = buildWavHeader(wavBytesWritten, wavSampleRate.takeIf { it > 0 } ?: 48000, wavChannels.takeIf { it > 0 } ?: 2)
            out.seek(0)
            out.write(header)
            out.close()
            Log.i(TAG, "WAV dump complete: ${wavFile?.absolutePath} ($wavBytesWritten bytes)")
        } catch (e: Exception) {
            Log.w(TAG, "WAV dump finalize failed: ${e.message}")
        }
    }

    private fun buildWavHeader(dataLen: Long, sampleRateHz: Int, channels: Int): ByteArray {
        val byteRate = sampleRateHz * channels * 2
        val blockAlign = channels * 2
        val buffer = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray())
        buffer.putInt((36 + dataLen).toInt())
        buffer.put("WAVE".toByteArray())
        buffer.put("fmt ".toByteArray())
        buffer.putInt(16)
        buffer.putShort(1) // PCM
        buffer.putShort(channels.toShort())
        buffer.putInt(sampleRateHz)
        buffer.putInt(byteRate)
        buffer.putShort(blockAlign.toShort())
        buffer.putShort(16) // bits per sample
        buffer.put("data".toByteArray())
        buffer.putInt(dataLen.toInt())
        return buffer.array()
    }

    companion object {
        private const val TAG = "DabProbe"
        private const val MAX_CHUNK_BYTES = 65536
    }
}
