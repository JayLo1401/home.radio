package org.lotzapp.home_radio.dab

/**
 * Generic table-driven CRC-16, parameterized by generator polynomial and
 * initial/final inversion - used for the standard CRC-16/CCITT (FIC FIB
 * validation, DAB+ audio-unit validation) and the DAB+-specific "Fire code"
 * (superframe header sync/validation, ETSI TS 102 563 clause 5.2.1 via
 * ETSI EN 300 401 Annex F). Table generation and processing algorithm
 * ported from DABlin's CalcCRC (tools.h/cpp, GPLv3, Copyright (C) 2015-2018
 * Stefan Pöschel) - verified to produce the same result as the CRC-16/CCITT
 * table this project already had hand-rolled in FigParser.kt for FIC.
 */
class Crc16(private val initialInvert: Boolean, private val finalInvert: Boolean, genPolynomial: Int) {
    private val lut = IntArray(256).also { table ->
        for (value in 0 until 256) {
            var crc = value shl 8
            repeat(8) {
                crc = if (crc and 0x8000 != 0) (crc shl 1) xor genPolynomial else crc shl 1
                crc = crc and 0xFFFF
            }
            table[value] = crc
        }
    }

    fun calc(data: ByteArray, offset: Int = 0, length: Int = data.size - offset): Int {
        var crc = if (initialInvert) 0xFFFF else 0x0000
        for (i in offset until offset + length) {
            val b = data[i].toInt() and 0xFF
            crc = ((crc shl 8) xor lut[(crc shr 8) xor b]) and 0xFFFF
        }
        return if (finalInvert) crc.inv() and 0xFFFF else crc
    }

    companion object {
        val CCITT = Crc16(initialInvert = true, finalInvert = true, genPolynomial = 0x1021)
        val FIRE_CODE = Crc16(initialInvert = false, finalInvert = false, genPolynomial = 0x782F)
    }
}
