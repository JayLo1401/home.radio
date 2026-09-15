package org.lotzapp.home_radio.dab

/**
 * Minimal parser for DAB FIC (Fast Information Channel) data, extracting
 * just the ensemble label (FIG type 1/0) and programme (station) service
 * labels (FIG type 1/1) - i.e. real, human-readable names, rather than the
 * full ensemble/service-component/subchannel structure needed to actually
 * decode audio (see RaonTunerDriver's doc comment for what's still missing).
 *
 * Ported from the LGPL-2.1-licensed github.com/hradio/omri-usb reference
 * (`ficparser.cpp`/`fig_01_ext_00.cpp`/`fig_01_ext_01.cpp`, Copyright (C)
 * 2018 IRT GmbH / Fabian Sattler) - a full copy is kept under
 * docs/dab-research/omri-usb-raon/ for reference. FIG bit layout per
 * ETSI EN 300 401 clause 5.2.2.
 */
object FigParser {

    data class Result(
        val ensembleId: Int?,
        val ensembleLabel: String?,
        // ServiceId (SId) -> programme/station label.
        val services: Map<Int, String>,
        // SubChId -> subchannel definition (FIG 0/1), needed to size the raw
        // MSC byte stream per CIF once a subchannel is opened.
        val subchannels: Map<Int, SubchannelInfo> = emptyMap(),
        // ServiceId (SId) -> its audio service component(s) (FIG 0/2),
        // needed to find which SubChId carries a given station's audio.
        val audioComponents: Map<Int, List<AudioComponent>> = emptyMap(),
    )

    /** FIG 0/1: basic sub-channel organization (EN 300 401 clause 6.3.1). */
    data class SubchannelInfo(
        val subChId: Int,
        val startAddr: Int,
        // Subchannel size in Capacity Units (1 CU = 64 bits = 8 bytes); only
        // populated for EEP (long form) subchannels - UEP (short form,
        // uncommon for DAB+) isn't supported (would need the EN 300 401
        // Table 9 UEP profile table to resolve a size).
        val sizeCu: Int,
    ) {
        val frameLenBytes: Int get() = sizeCu * 8
    }

    /** FIG 0/2: a service's audio component (EN 300 401 clause 6.3.2). */
    data class AudioComponent(
        val subChId: Int,
        // Audio Service Component Type: 0 = MPEG Layer II (DAB), 63 = DAB+.
        val ascty: Int,
        val isPrimary: Boolean,
    ) {
        val isDabPlus: Boolean get() = ascty == 63
    }

    /** Parses a raw FIC burst (any multiple of 32 bytes = whole FIBs). */
    fun parse(fic: ByteArray): Result {
        var ensembleId: Int? = null
        var ensembleLabel: String? = null
        val services = mutableMapOf<Int, String>()
        val subchannels = mutableMapOf<Int, SubchannelInfo>()
        val audioComponents = mutableMapOf<Int, MutableList<AudioComponent>>()

        var offset = 0
        while (offset + 32 <= fic.size) {
            val fib = fic.copyOfRange(offset, offset + 32)
            offset += 32
            if (!fibCrcOk(fib)) continue

            var i = 0
            while (i < 30) {
                val header = fib[i].toInt() and 0xFF
                val figType = (header shr 5) and 0x07
                val figLength = header and 0x1F
                i += 1
                if (figType == 7 || figLength == 0) break // padding/empty - rest of FIB is filler
                if (i + figLength > 30) break // malformed/truncated, bail on this FIB
                val data = fib.copyOfRange(i, i + figLength)
                when (figType) {
                    0 -> parseFig0(
                        data,
                        onSubchannel = { sub -> subchannels[sub.subChId] = sub },
                        onAudioComponent = { sid, comp ->
                            audioComponents.getOrPut(sid) { mutableListOf() }.add(comp)
                        },
                    )
                    1 -> parseFig1(data, onEnsemble = { id, label ->
                        ensembleId = id
                        ensembleLabel = label
                    }, onService = { id, label -> services[id] = label })
                }
                i += figLength
            }
        }
        return Result(ensembleId, ensembleLabel, services, subchannels, audioComponents)
    }

    /**
     * FIG type 0 dispatch: extension 1 (basic sub-channel organization) and
     * extension 2 (basic service/service-component definition) - the two
     * pieces needed to resolve a station (ServiceId) to its audio SubChId
     * and that subchannel's per-CIF byte size. Ported from welle.io's
     * `FIBProcessor::HandleFIG0Extension1/2` (fib-processor.cpp, GPL-2.0),
     * bit-for-bit - only the array indexing differs, since our `data` here
     * already has the FIG header byte stripped (welle.io's bit offsets
     * count from that header byte, ours from the byte right after it).
     */
    private fun parseFig0(
        data: ByteArray,
        onSubchannel: (SubchannelInfo) -> Unit,
        onAudioComponent: (serviceId: Int, component: AudioComponent) -> Unit,
    ) {
        if (data.isEmpty()) return
        val ext = data[0].toInt() and 0x1F
        val pd = (data[0].toInt() and 0x20) != 0 // P/D: 0 = 16-bit SId (programme), 1 = 32-bit (data)
        when (ext) {
            1 -> parseFig0Ext1(data, onSubchannel)
            2 -> parseFig0Ext2(data, pd, onAudioComponent)
        }
    }

    private fun parseFig0Ext1(data: ByteArray, onSubchannel: (SubchannelInfo) -> Unit) {
        var byteOffset = 1 // entries start right after the CN/OE/PD byte (data[0])
        while (byteOffset + 3 <= data.size) {
            val bitOffset = byteOffset * 8
            val subChId = getBits(data, bitOffset, 6)
            val shortLongFlag = getBits(data, bitOffset + 16, 1)
            if (shortLongFlag == 0) {
                // UEP (short form) - not supported (see SubchannelInfo doc).
                byteOffset += 3
                continue
            }
            if (byteOffset + 4 > data.size) break
            val startAddr = getBits(data, bitOffset + 6, 10)
            val option = getBits(data, bitOffset + 17, 3)
            val sizeCu = getBits(data, bitOffset + 22, 10)
            if (option == 0 || option == 1) { // EEP-A or EEP-B (the only supported/common profiles)
                onSubchannel(SubchannelInfo(subChId, startAddr, sizeCu))
            }
            byteOffset += 4
        }
    }

    private fun parseFig0Ext2(
        data: ByteArray,
        pd: Boolean,
        onAudioComponent: (serviceId: Int, component: AudioComponent) -> Unit,
    ) {
        var byteOffset = 1
        val sidBytes = if (pd) 4 else 2
        while (byteOffset + sidBytes <= data.size) {
            var bitOffset = byteOffset * 8
            val serviceId = getBits(data, bitOffset, sidBytes * 8)
            bitOffset += sidBytes * 8
            if (bitOffset / 8 >= data.size) break
            val numComponents = getBits(data, bitOffset + 4, 4)
            bitOffset += 8
            for (c in 0 until numComponents) {
                if (bitOffset / 8 + 2 > data.size) break
                val tmid = getBits(data, bitOffset, 2)
                if (tmid == 0) { // MSC stream audio
                    val ascty = getBits(data, bitOffset + 2, 6)
                    val subChId = getBits(data, bitOffset + 8, 6)
                    onAudioComponent(serviceId, AudioComponent(subChId, ascty, isPrimary = c == 0))
                }
                bitOffset += 16
            }
            byteOffset = bitOffset / 8
        }
    }

    /** MSB-first bit reader (bit 0 = MSB of byte 0), matching DAB FIG bit numbering. */
    private fun getBits(data: ByteArray, bitOffset: Int, bitLength: Int): Int {
        var value = 0
        for (n in 0 until bitLength) {
            val pos = bitOffset + n
            val byteIndex = pos / 8
            val bit = if (byteIndex < data.size) (data[byteIndex].toInt() shr (7 - pos % 8)) and 0x01 else 0
            value = (value shl 1) or bit
        }
        return value
    }

    private fun fibCrcOk(fib: ByteArray): Boolean {
        val crc = Crc16.CCITT.calc(fib, 0, 30)
        val crcVal = ((fib[30].toInt() and 0xFF) shl 8) or (fib[31].toInt() and 0xFF)
        return crc == crcVal
    }

    private fun parseFig1(
        data: ByteArray,
        onEnsemble: (Int, String) -> Unit,
        onService: (Int, String) -> Unit,
    ) {
        if (data.isEmpty()) return
        val extension = data[0].toInt() and 0x07
        // Both ensemble (ext 0) and programme service (ext 1) labels share
        // the same layout: [header][2-byte Id][16-byte label][2-byte flags].
        if ((extension == 0 || extension == 1) && data.size >= 21) {
            val id = ((data[1].toInt() and 0xFF) shl 8) or (data[2].toInt() and 0xFF)
            val label = decodeEbuLatin(data, 3, 16).trimEnd()
            if (label.isNotEmpty()) {
                if (extension == 0) onEnsemble(id, label) else onService(id, label)
            }
        }
    }

    /**
     * DAB "EBU Latin" (charset 0000) is single-byte but NOT Latin-1 - byte
     * values 0x80+ map to a different, ETSI-defined repertoire (e.g. 'ö' is
     * 0x98, not Latin-1's 0xF6). [EBU_LATIN_TABLE] is the exact mapping per
     * ETSI TS 101 756 Annex C (byte value N -> EBU_LATIN_TABLE[N-1]; byte 0
     * is unused/NUL). Table content cross-checked against the equivalent
     * table in Opendigitalradio/ODR-PadEnc's charset.cpp.
     */
    private fun decodeEbuLatin(data: ByteArray, offset: Int, length: Int): String {
        val sb = StringBuilder(length)
        for (i in 0 until length) {
            val b = data[offset + i].toInt() and 0xFF
            sb.append(if (b in 1..255) EBU_LATIN_TABLE[b - 1] else ' ')
        }
        return sb.toString()
    }

    // Index 0 = byte value 0x01, ..., index 254 = byte value 0xFF.
    private val EBU_LATIN_TABLE = arrayOf(
        "Ę", "Į", "Ų", "Ă", "Ė", "Ď", "Ș", "Ț", "Ċ", "\n", "", "Ġ", "Ĺ", "Ż", "Ń",
        "ą", "ę", "į", "ų", "ă", "ė", "ď", "ș", "ț", "ċ", "Ň", "Ě", "ġ", "ĺ", "ż", "",
        " ", "!", "\"", "#", "ł", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
        "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
        "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "Ů", "]", "Ł", "_",
        "Ą", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
        "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "«", "ů", "»", "Ľ", "Ħ",
        "á", "à", "é", "è", "í", "ì", "ó", "ò", "ú", "ù", "Ñ", "Ç", "Ş", "ß", "¡", "Ÿ",
        "â", "ä", "ê", "ë", "î", "ï", "ô", "ö", "û", "ü", "ñ", "ç", "ş", "ğ", "ı", "ÿ",
        "Ķ", "Ņ", "©", "Ģ", "Ğ", "ě", "ň", "ő", "Ő", "€", "£", "\$", "Ā", "Ē", "Ī", "Ū",
        "ķ", "ņ", "Ļ", "ģ", "ļ", "İ", "ń", "ű", "Ű", "¿", "ľ", "°", "ā", "ē", "ī", "ū",
        "Á", "À", "É", "È", "Í", "Ì", "Ó", "Ò", "Ú", "Ù", "Ř", "Č", "Š", "Ž", "Ð", "Ŀ",
        "Â", "Ä", "Ê", "Ë", "Î", "Ï", "Ô", "Ö", "Û", "Ü", "ř", "č", "š", "ž", "đ", "ŀ",
        "Ã", "Å", "Æ", "Œ", "ŷ", "Ý", "Õ", "Ø", "Þ", "Ŋ", "Ŕ", "Ć", "Ś", "Ź", "Ť", "ð",
        "ã", "å", "æ", "œ", "ŵ", "ý", "õ", "ø", "þ", "ŋ", "ŕ", "ć", "ś", "ź", "ť", "ħ",
    )
}
