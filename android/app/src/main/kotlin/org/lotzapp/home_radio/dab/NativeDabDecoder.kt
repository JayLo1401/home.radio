package org.lotzapp.home_radio.dab

/**
 * JNI wrapper around a native (C/C++) port of DABlin's DAB+ superframe
 * transport-layer decoder (github.com/opendigitalradio/dablin, GPLv3,
 * Copyright (C) 2015-2024 Stefan Poeschel), Phil Karn's LGPL-2.1 `libfec`
 * RS(120,110) codec (github.com/quiet/libfec), and the Fraunhofer FDK AAC
 * decoder (github.com/mstorsjo/fdk-aac) - see
 * android/app/src/main/cpp/dab_native.cpp. Hands back ready-to-play PCM
 * directly (AAC decoding, including FDK-AAC's own error concealment for
 * CRC-failed AUs, happens natively) rather than raw AAC access units.
 *
 * Replaces the hand-ported Kotlin [DabPlusSuperframeDecoder]/[ReedSolomon]
 * (2026-09-16, after an extensive, still-unexplained ~35-45% AU-CRC failure
 * rate persisted despite the Kotlin port being verified line-by-line against
 * the same upstream sources multiple times): using the actual reference C
 * sources directly - rather than a from-scratch Kotlin translation - removes
 * any possibility of a subtle porting bug as the explanation, whatever the
 * real cause turns out to be. MediaCodec (Android's own AAC decoder) was
 * replaced the same way shortly after, to get access to FDK-AAC's built-in
 * concealment - a hand-rolled "silence" and "repeat last PCM" substitute for
 * CRC-failed AUs were both tried in the Kotlin layer and sounded worse than
 * doing nothing, which real concealment needs the decoder's own internal
 * state to do properly.
 */
class NativeDabDecoder(
    private val onPcm: (pcm: ByteArray, sampleRateHz: Int, channels: Int) -> Unit,
) {
    private val handle: Long = nativeCreate()

    fun feed(data: ByteArray) = nativeFeed(handle, data)
    fun reset() = nativeReset(handle)
    fun destroy() = nativeDestroy(handle)

    val syncAttempts: Long get() = nativeGetStat(handle, 0)
    val syncSuccesses: Long get() = nativeGetStat(handle, 1)
    val rsUncorrectableCodewords: Long get() = nativeGetStat(handle, 2)
    val rsCorrectedSymbols: Long get() = nativeGetStat(handle, 3)
    val auCrcOk: Long get() = nativeGetStat(handle, 4)
    val auCrcFail: Long get() = nativeGetStat(handle, 5)
    fun auCrcOkForIndex(i: Int): Long = nativeGetStat(handle, 6 + i)
    fun auCrcFailForIndex(i: Int): Long = nativeGetStat(handle, 12 + i)

    /** Called from native code (dab_native.cpp) with decoded PCM for every AU slot in a synced superframe. */
    fun onPcmFromNative(pcm: ByteArray, sampleRateHz: Int, channels: Int) {
        onPcm(pcm, sampleRateHz, channels)
    }

    private external fun nativeCreate(): Long
    private external fun nativeFeed(handle: Long, data: ByteArray)
    private external fun nativeReset(handle: Long)
    private external fun nativeDestroy(handle: Long)
    private external fun nativeGetStat(handle: Long, index: Int): Long

    companion object {
        init {
            System.loadLibrary("dabnative")
        }
    }
}
