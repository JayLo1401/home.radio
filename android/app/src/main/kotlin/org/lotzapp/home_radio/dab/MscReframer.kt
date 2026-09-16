package org.lotzapp.home_radio.dab

/**
 * The tuner chip's raw MSC subchannel byte stream (RaonTunerDriver.readMscRaw)
 * isn't pre-chunked into fixed-size CIF frames - each USB read returns
 * whatever happened to have accumulated in the chip's FIFO since the last
 * read. This buffers that stream and emits it back out in exact,
 * fixed-size [frameLen]-byte pieces (one per 24ms CIF), which is what
 * [NativeDabDecoder.feed] requires.
 */
class MscReframer(private val frameLen: Int, private val onFrame: (ByteArray) -> Unit) {
    private var pending = ByteArray(0)

    fun feed(data: ByteArray) {
        val combined = if (pending.isEmpty()) data else pending + data
        var offset = 0
        while (offset + frameLen <= combined.size) {
            onFrame(combined.copyOfRange(offset, offset + frameLen))
            offset += frameLen
        }
        pending = if (offset < combined.size) combined.copyOfRange(offset, combined.size) else ByteArray(0)
    }

    /**
     * Discards any buffered partial bytes - must be called whenever the
     * chip's MSC FIFO was reset (see RaonTunerDriver.recoverMscOverrunIfNeeded)
     * so the byte stream's known discontinuity there doesn't otherwise get
     * silently spliced together with old bytes, corrupting frame alignment
     * for good (this project's own bug, found 2026-09-15 - without this,
     * the chosen frame phase is fixed forever at whatever arbitrary byte
     * the very first read happened to start at, and a reset is the only
     * thing that can give a fresh, hopefully CIF-aligned, starting point).
     */
    fun reset() {
        pending = ByteArray(0)
    }
}
