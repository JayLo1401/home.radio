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
    )

    // CRC-CCITT (poly 0x1021) lookup table, copied from FicParser::CRC_CCITT_TABLE.
    private val CRC_TABLE = intArrayOf(
        0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7,
        0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF,
        0x1231, 0x0210, 0x3273, 0x2252, 0x52B5, 0x4294, 0x72F7, 0x62D6,
        0x9339, 0x8318, 0xB37B, 0xA35A, 0xD3BD, 0xC39C, 0xF3FF, 0xE3DE,
        0x2462, 0x3443, 0x0420, 0x1401, 0x64E6, 0x74C7, 0x44A4, 0x5485,
        0xA56A, 0xB54B, 0x8528, 0x9509, 0xE5EE, 0xF5CF, 0xC5AC, 0xD58D,
        0x3653, 0x2672, 0x1611, 0x0630, 0x76D7, 0x66F6, 0x5695, 0x46B4,
        0xB75B, 0xA77A, 0x9719, 0x8738, 0xF7DF, 0xE7FE, 0xD79D, 0xC7BC,
        0x48C4, 0x58E5, 0x6886, 0x78A7, 0x0840, 0x1861, 0x2802, 0x3823,
        0xC9CC, 0xD9ED, 0xE98E, 0xF9AF, 0x8948, 0x9969, 0xA90A, 0xB92B,
        0x5AF5, 0x4AD4, 0x7AB7, 0x6A96, 0x1A71, 0x0A50, 0x3A33, 0x2A12,
        0xDBFD, 0xCBDC, 0xFBBF, 0xEB9E, 0x9B79, 0x8B58, 0xBB3B, 0xAB1A,
        0x6CA6, 0x7C87, 0x4CE4, 0x5CC5, 0x2C22, 0x3C03, 0x0C60, 0x1C41,
        0xEDAE, 0xFD8F, 0xCDEC, 0xDDCD, 0xAD2A, 0xBD0B, 0x8D68, 0x9D49,
        0x7E97, 0x6EB6, 0x5ED5, 0x4EF4, 0x3E13, 0x2E32, 0x1E51, 0x0E70,
        0xFF9F, 0xEFBE, 0xDFDD, 0xCFFC, 0xBF1B, 0xAF3A, 0x9F59, 0x8F78,
        0x9188, 0x81A9, 0xB1CA, 0xA1EB, 0xD10C, 0xC12D, 0xF14E, 0xE16F,
        0x1080, 0x00A1, 0x30C2, 0x20E3, 0x5004, 0x4025, 0x7046, 0x6067,
        0x83B9, 0x9398, 0xA3FB, 0xB3DA, 0xC33D, 0xD31C, 0xE37F, 0xF35E,
        0x02B1, 0x1290, 0x22F3, 0x32D2, 0x4235, 0x5214, 0x6277, 0x7256,
        0xB5EA, 0xA5CB, 0x95A8, 0x8589, 0xF56E, 0xE54F, 0xD52C, 0xC50D,
        0x34E2, 0x24C3, 0x14A0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
        0xA7DB, 0xB7FA, 0x8799, 0x97B8, 0xE75F, 0xF77E, 0xC71D, 0xD73C,
        0x26D3, 0x36F2, 0x0691, 0x16B0, 0x6657, 0x7676, 0x4615, 0x5634,
        0xD94C, 0xC96D, 0xF90E, 0xE92F, 0x99C8, 0x89E9, 0xB98A, 0xA9AB,
        0x5844, 0x4865, 0x7806, 0x6827, 0x18C0, 0x08E1, 0x3882, 0x28A3,
        0xCB7D, 0xDB5C, 0xEB3F, 0xFB1E, 0x8BF9, 0x9BD8, 0xABBB, 0xBB9A,
        0x4A75, 0x5A54, 0x6A37, 0x7A16, 0x0AF1, 0x1AD0, 0x2AB3, 0x3A92,
        0xFD2E, 0xED0F, 0xDD6C, 0xCD4D, 0xBDAA, 0xAD8B, 0x9DE8, 0x8DC9,
        0x7C26, 0x6C07, 0x5C64, 0x4C45, 0x3CA2, 0x2C83, 0x1CE0, 0x0CC1,
        0xEF1F, 0xFF3E, 0xCF5D, 0xDF7C, 0xAF9B, 0xBFBA, 0x8FD9, 0x9FF8,
        0x6E17, 0x7E36, 0x4E55, 0x5E74, 0x2E93, 0x3EB2, 0x0ED1, 0x1EF0,
    )

    /** Parses a raw FIC burst (any multiple of 32 bytes = whole FIBs). */
    fun parse(fic: ByteArray): Result {
        var ensembleId: Int? = null
        var ensembleLabel: String? = null
        val services = mutableMapOf<Int, String>()

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
                if (figType == 1) {
                    parseFig1(data, onEnsemble = { id, label ->
                        ensembleId = id
                        ensembleLabel = label
                    }, onService = { id, label -> services[id] = label })
                }
                i += figLength
            }
        }
        return Result(ensembleId, ensembleLabel, services)
    }

    private fun fibCrcOk(fib: ByteArray): Boolean {
        var crc = 0xFFFF
        for (idx in 0 until 30) {
            val b = fib[idx].toInt() and 0xFF
            crc = ((crc shl 8) xor CRC_TABLE[(crc shr 8) xor b]) and 0xFFFF
        }
        val crcVal = ((fib[30].toInt() and 0xFF) shl 8) or (fib[31].toInt() and 0xFF)
        val crc2 = crcVal xor 0xFFFF
        return crc == crc2
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
