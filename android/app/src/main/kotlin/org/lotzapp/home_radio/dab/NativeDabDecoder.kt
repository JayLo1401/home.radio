package org.lotzapp.home_radio.dab

/**
 * JNI wrapper around a native (C/C++) port of DABlin's DAB+ superframe
 * decoder (github.com/opendigitalradio/dablin, GPLv3, Copyright (C)
 * 2015-2024 Stefan Poeschel) and Phil Karn's LGPL-2.1 `libfec` RS(120,110)
 * codec (github.com/quiet/libfec) - see android/app/src/main/cpp/dab_native.cpp.
 *
 * Replaces the hand-ported Kotlin [DabPlusSuperframeDecoder]/[ReedSolomon]
 * (2026-09-16, after an extensive, still-unexplained ~35-45% AU-CRC failure
 * rate persisted despite the Kotlin port being verified line-by-line against
 * the same upstream sources multiple times): using the actual reference C
 * sources directly - rather than a from-scratch Kotlin translation - removes
 * any possibility of a subtle porting bug as the explanation, whatever the
 * real cause turns out to be.
 */
class NativeDabDecoder(
    // au == null means "this AU's CRC failed, but the superframe as a whole
    // is synced" - the caller should insert durationMs of silence to keep
    // playback timing continuous instead of jump-cutting to the next
    // surviving AU.
    private val onAudioUnit: (au: ByteArray?, asc: ByteArray, sampleRateHz: Int, channels: Int, durationMs: Int) -> Unit,
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

    /** Called from native code (dab_native.cpp) for every AU slot in a synced superframe. */
    fun onAuFromNative(au: ByteArray?, asc: ByteArray, sampleRateHz: Int, channels: Int, durationMs: Int) {
        onAudioUnit(au, asc, sampleRateHz, channels, durationMs)
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
