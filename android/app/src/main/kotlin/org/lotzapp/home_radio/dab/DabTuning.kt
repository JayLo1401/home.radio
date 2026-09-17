package org.lotzapp.home_radio.dab

/**
 * Live-adjustable DAB+ playback tuning knobs (2026-09-16), exposed via the
 * `dabSetTuning` MethodChannel call so they can be changed from a settings
 * screen while playback is running, instead of needing a rebuild for every
 * experiment - the request that led to this was needing many rebuild/
 * install/listen cycles in a row just to find a workable AudioTrack buffer
 * size. [DabUsbPlugin]'s read loop and [DabAudioPlayer] read these values
 * live (not captured once at playback start), so a change takes effect
 * within a fraction of a second.
 */
object DabTuning {
    /**
     * Ring buffer size target, in milliseconds of audio (2026-09-16: moved
     * from sizing AudioTrack's own buffer to sizing the PCM ring buffer in
     * front of it, matching the real DAB-Z app's architecture - see
     * DabAudioPlayer's doc comment). AudioTrack itself now always uses
     * Android's own getMinBufferSize().
     */
    @Volatile var audioBufferMs: Int = 1000

    /**
     * Minimum repeated-byte run length (within one USB read chunk) that
     * marks it as the chip's "idle/underrun fill" pattern and discards it
     * (forcing a reframer/decoder reset). See DabUsbPlugin.isDegenerateFill.
     */
    @Volatile var degenerateFillThreshold: Int = 64

    /** How many successful reads between periodic (non-empty-read-triggered) MSC1 overrun checks. */
    @Volatile var overrunCheckInterval: Int = 100

    /** Milliseconds with no new decoded AAC frame before the sync watchdog acts (soft reset, then full reopen). */
    @Volatile var watchdogTimeoutMs: Long = 1500L
}
