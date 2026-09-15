package org.lotzapp.home_radio.dab

/**
 * DAB "energy dispersal" descrambler (ETSI EN 300 401 clause 5.3.1): a
 * 9-bit PRBS (generator polynomial x^9 + x^5 + 1, shift register seeded to
 * all-ones) is XORed onto the MSC bit/byte stream at the transmitter to
 * avoid long runs of identical bits reaching the channel coder; the
 * receiver must XOR the *same* sequence back in. The tuner chip's
 * convolutional (Viterbi) decoding does NOT undo this - it's a separate
 * step that has to happen here, before RS/superframe decoding, or RS
 * decoding sees effectively-random bytes and fails almost every codeword
 * (exactly the symptom that led to adding this class).
 *
 * The PRBS resets to its initial state at the start of every frame (one CIF
 * period) rather than running continuously - ported from welle.io's
 * EnergyDispersal (energy_dispersal.h, GPL-2.0, Copyright (C) 2013 Jan van
 * Katwijk / 2018 Matthias P. Braendli): regenerating the same fixed-length
 * dispersal vector fresh from the seeded shift register every time is
 * equivalent to resetting it per frame.
 */
class EnergyDispersal(frameLen: Int) {
    private val vector = ByteArray(frameLen).also { v ->
        val shiftRegister = IntArray(9) { 1 }
        for (i in v.indices) {
            val b = shiftRegister[8] xor shiftRegister[4]
            for (j in 8 downTo 1) shiftRegister[j] = shiftRegister[j - 1]
            shiftRegister[0] = b
            v[i] = b.toByte()
        }
    }

    /** Descrambles [data] in place; `data.size` must equal the configured frame length. */
    fun dedisperse(data: ByteArray) {
        for (i in data.indices) data[i] = (data[i].toInt() xor vector[i].toInt()).toByte()
    }
}
