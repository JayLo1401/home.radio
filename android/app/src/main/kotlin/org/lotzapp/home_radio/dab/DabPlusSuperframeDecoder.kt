package org.lotzapp.home_radio.dab

import android.util.Log

/**
 * DAB+ superframe decoding: takes the raw per-CIF subchannel byte stream
 * (already demultiplexed by the tuner chip for one subchannel - see
 * RaonTunerDriver.openSubChannel/readMscRaw) and turns it into individual,
 * CRC-verified raw AAC access units plus the AudioSpecificConfig bytes
 * needed to configure a standard raw-AAC decoder (Android's MediaCodec) -
 * ETSI TS 102 563. A superframe is 5 consecutive CIF frames of the
 * subchannel, protected by an outer RS(120,110) code ([ReedSolomon]) plus a
 * "Fire code" CRC (ETSI EN 300 401 Annex F) over its 11-byte header.
 *
 * Faithful Kotlin port of DABlin's SuperframeFilter
 * (dabplus_decoder.h/cpp, GPLv3, Copyright (C) 2015-2018 Stefan Pöschel,
 * github.com/opendigitalradio/dablin) - including its exact frame-alignment
 * search behaviour: once synced, `frameCount` resets after each valid
 * superframe and the next 5 frames are consumed as a fresh block; if sync
 * fails, `frameCount` stays at 5 so the next single new frame slides the
 * 5-frame window by one CIF and sync is retried. The MPEG-4 LATM
 * "untouched stream" re-muxing path (used there for re-streaming, not
 * decoding) is intentionally not ported - not needed here.
 */
class DabPlusSuperframeDecoder(
    private val onAudioUnit: (au: ByteArray, asc: ByteArray, sampleRateHz: Int, channels: Int) -> Unit,
) {
    data class SuperframeFormat(
        val dacRate: Boolean = false, // true = 48 kHz core sample rate, false = 32 kHz
        val sbrFlag: Boolean = false,
        val channelMode: Boolean = false, // true = stereo core
        val psFlag: Boolean = false,
    ) {
        val coreSrIndex: Int get() = if (dacRate) (if (sbrFlag) 6 else 3) else (if (sbrFlag) 8 else 5)
        val coreChConfig: Int get() = if (channelMode) 2 else 1
        val extensionSrIndex: Int get() = if (dacRate) 3 else 5
        val sampleRateHz: Int get() = if (dacRate) 48000 else 32000
        val channels: Int get() = if (channelMode || psFlag) 2 else 1
    }

    private var frameLen = 0
    private var frameCount = 0
    private var sfRaw: ByteArray? = null // sliding window of the last (up to) 5 raw CIF frames

    private var lastFormatRaw = -1
    private var format = SuperframeFormat()
    private var numAus = 0
    private val auStart = IntArray(7) // +1 for the end of the last AU

    // Diagnostics (temporary, while bringing up real audio decoding).
    var syncAttempts = 0L; private set
    var syncSuccesses = 0L; private set
    var rsUncorrectableCodewords = 0L; private set
    var rsCorrectedSymbols = 0L; private set
    var auCrcOk = 0L; private set
    var auCrcFail = 0L; private set

    /** Discards in-progress frame accumulation - call together with [MscReframer.reset]. */
    fun reset() {
        frameCount = 0
    }

    /** Feeds one CIF period's worth of raw subchannel bytes. */
    fun feed(data: ByteArray) {
        if (frameLen == 0) {
            if (data.size < 10 || (5 * data.size) % ReedSolomon.CODEWORD_LEN != 0) {
                Log.w(TAG, "DAB+ superframe: subchannel frame len ${data.size} not usable - ignoring")
                return
            }
            frameLen = data.size
            sfRaw = ByteArray(5 * frameLen)
        }
        if (data.size != frameLen) return // subchannel reconfigured mid-stream - not handled, ignore

        val raw = sfRaw!!
        if (frameCount == 5) {
            System.arraycopy(raw, frameLen, raw, 0, 4 * frameLen)
            System.arraycopy(data, 0, raw, 4 * frameLen, frameLen)
        } else {
            System.arraycopy(data, 0, raw, frameCount * frameLen, frameLen)
            frameCount++
        }
        if (frameCount < 5) return

        val sf = raw.copyOf()
        decodeRs(sf)

        syncAttempts++
        if (!checkSync(sf)) return // frameCount stays 5 -> next feed() slides the window by one CIF
        syncSuccesses++

        val formatRaw = sf[2].toInt() and 0xFF
        if (formatRaw != lastFormatRaw) {
            lastFormatRaw = formatRaw
            format = SuperframeFormat(
                dacRate = formatRaw and 0x40 != 0,
                sbrFlag = formatRaw and 0x20 != 0,
                channelMode = formatRaw and 0x10 != 0,
                psFlag = formatRaw and 0x08 != 0,
            )
            Log.i(
                TAG,
                "DAB+ format: ${if (format.sbrFlag) (if (format.psFlag) "HE-AACv2" else "HE-AAC") else "AAC-LC"}, " +
                    "${format.sampleRateHz} Hz, ${format.channels}ch",
            )
        }

        val asc = buildAsc(format)
        for (i in 0 until numAus) {
            val start = auStart[i]
            val end = auStart[i + 1]
            if (start < 0 || end > sf.size || end - start < 2) continue
            val auLen = end - start - 2
            val crcStored = ((sf[end - 2].toInt() and 0xFF) shl 8) or (sf[end - 1].toInt() and 0xFF)
            val crcCalc = Crc16.CCITT.calc(sf, start, auLen)
            if (crcStored != crcCalc) {
                auCrcFail++
                if (auCrcFail <= 5 || auCrcFail % 500 == 0L) {
                    Log.d(
                        TAG,
                        "AU CRC fail #$auCrcFail: au#$i start=$start end=$end len=$auLen " +
                            "stored=0x%04X calc=0x%04X".format(crcStored, crcCalc),
                    )
                }
                continue
            }
            auCrcOk++
            onAudioUnit(sf.copyOfRange(start, start + auLen), asc, format.sampleRateHz, format.channels)
        }

        frameCount = 0 // got a complete, valid superframe - start fresh for the next one
    }

    private fun decodeRs(sf: ByteArray) {
        val subchIndex = sf.size / ReedSolomon.CODEWORD_LEN
        val codeword = IntArray(ReedSolomon.CODEWORD_LEN)
        for (col in 0 until subchIndex) {
            for (pos in 0 until ReedSolomon.CODEWORD_LEN) codeword[pos] = sf[pos * subchIndex + col].toInt() and 0xFF
            val corrected = ReedSolomon.decode(codeword)
            if (corrected < 0) rsUncorrectableCodewords++ else if (corrected > 0) rsCorrectedSymbols += corrected
            for (pos in 0 until ReedSolomon.CODEWORD_LEN) sf[pos * subchIndex + col] = codeword[pos].toByte()
        }
    }

    /** Fire-code sync on the superframe header + parses the AU count/offsets. */
    private fun checkSync(sf: ByteArray): Boolean {
        if (sf[3] == 0.toByte() && sf[4] == 0.toByte()) return false // avoid syncing on an all-zero array

        val crcStored = ((sf[0].toInt() and 0xFF) shl 8) or (sf[1].toInt() and 0xFF)
        val crcCalc = Crc16.FIRE_CODE.calc(sf, 2, 9)
        if (crcStored != crcCalc) return false

        val formatRaw = sf[2].toInt() and 0xFF
        val dacRate = formatRaw and 0x40 != 0
        val sbrFlag = formatRaw and 0x20 != 0

        numAus = if (dacRate) (if (sbrFlag) 3 else 6) else (if (sbrFlag) 2 else 4)
        auStart[0] = if (dacRate) (if (sbrFlag) 6 else 11) else (if (sbrFlag) 5 else 8)
        auStart[numAus] = sf.size / ReedSolomon.CODEWORD_LEN * 110 // pseudo-next AU (RS parity excluded)

        fun u8(i: Int) = sf[i].toInt() and 0xFF
        auStart[1] = (u8(3) shl 4) or (u8(4) shr 4)
        if (numAus >= 3) auStart[2] = ((u8(4) and 0x0F) shl 8) or u8(5)
        if (numAus >= 4) auStart[3] = (u8(6) shl 4) or (u8(7) shr 4)
        if (numAus == 6) {
            auStart[4] = ((u8(7) and 0x0F) shl 8) or u8(8)
            auStart[5] = (u8(9) shl 4) or (u8(10) shr 4)
        }

        for (i in 0 until numAus) if (auStart[i] >= auStart[i + 1]) return false
        return true
    }

    companion object {
        private const val TAG = "DabProbe"

        /**
         * Builds the AudioSpecificConfig bytes for a raw AAC decoder (the only
         * way to select the DAB+-mandated 960-sample transform): AAC LC, plus
         * explicit (backwards-compatible) SBR/PS extension signalling if
         * present - byte-for-byte the same construction as DABlin's
         * AACDecoder constructor.
         */
        fun buildAsc(format: SuperframeFormat): ByteArray {
            val bytes = mutableListOf<Int>()
            bytes.add((0b00010 shl 3) or (format.coreSrIndex shr 1))
            bytes.add(((format.coreSrIndex and 0x01) shl 7) or (format.coreChConfig shl 3) or 0b100)
            if (format.sbrFlag) {
                bytes.add(0x56)
                bytes.add(0xE5)
                var last = 0x80 or (format.extensionSrIndex shl 3)
                if (format.psFlag) {
                    last = last or 0x05
                }
                bytes.add(last)
                if (format.psFlag) {
                    bytes.add(0x48)
                    bytes.add(0x80)
                }
            }
            return ByteArray(bytes.size) { bytes[it].toByte() }
        }
    }
}
