package org.lotzapp.home_radio.dab

/**
 * Reed-Solomon(120,110) decoder over GF(256) - the DAB+ "outer" forward
 * error correction applied to every superframe (ETSI TS 102 563 clause 6),
 * layered on top of (and independent from) whatever convolutional/Viterbi
 * FEC the tuner chip already applies at the physical layer. The chip's FEC
 * lock (see RaonTunerDriver.getLockStatus) does NOT cover this - it has to
 * be done here in software.
 *
 * Faithful Kotlin port of Phil Karn's classic LGPL-2.1-licensed `libfec` RS
 * codec (github.com/quiet/libfec, `init_rs.h`/`decode_rs.h`), specialized to
 * this code's fixed parameters exactly as used by DABlin/welle.io for DAB+:
 * `init_rs_char(8, 0x11D, 0, 1, 10, 135)` - 8-bit symbols, field generator
 * polynomial 0x11D, first consecutive root 0, primitive element 1, 10 roots
 * (parity bytes, i.e. RS(120,110)), 135 pad bytes (since the code is
 * shortened from the full RS(255,245)). Erasure support is omitted - the
 * chip gives no per-byte reliability info, so `no_eras` is always 0, which
 * let the erasure-locator-polynomial setup from the original algorithm be
 * dropped entirely (it's a no-op for `no_eras == 0`).
 */
object ReedSolomon {
    private const val MM = 8
    private const val NN = 255 // (1 shl MM) - 1
    private const val GF_POLY = 0x11D
    private const val FCR = 0
    private const val PRIM = 1
    private const val NROOTS = 10
    const val PAD = 135
    const val CODEWORD_LEN = 120 // NN - PAD
    private const val A0 = NN // "index of zero" sentinel

    private val alphaTo = IntArray(NN + 1)
    private val indexOf = IntArray(NN + 1)

    init {
        indexOf[0] = A0
        alphaTo[A0] = 0
        var sr = 1
        for (i in 0 until NN) {
            indexOf[sr] = i
            alphaTo[i] = sr
            sr = sr shl 1
            if (sr and (1 shl MM) != 0) sr = sr xor GF_POLY
            sr = sr and NN
        }
        check(sr == 1) { "GF(256) generator polynomial 0x$GF_POLY is not primitive" }
    }

    private fun modnn(x: Int): Int {
        var v = x
        while (v >= NN) {
            v -= NN
            v = (v shr MM) + (v and NN)
        }
        return v
    }

    /**
     * Decodes one 120-byte RS codeword (`data[0..109]` message + `data[110..119]`
     * parity) in place. Returns the number of corrected symbols, or -1 if the
     * block has more errors than the code can correct (in which case `data`
     * is left unmodified, matching the reference decoder).
     */
    fun decode(data: IntArray): Int {
        require(data.size == CODEWORD_LEN)

        val s = IntArray(NROOTS)
        for (i in 0 until NROOTS) s[i] = data[0]
        for (j in 1 until CODEWORD_LEN) {
            for (i in 0 until NROOTS) {
                s[i] = if (s[i] == 0) data[j] else data[j] xor alphaTo[modnn(indexOf[s[i]] + (FCR + i) * PRIM)]
            }
        }

        var synError = 0
        for (i in 0 until NROOTS) {
            synError = synError or s[i]
            s[i] = indexOf[s[i]]
        }
        if (synError == 0) return 0 // codeword is clean, nothing to do

        val lambda = IntArray(NROOTS + 1)
        lambda[0] = 1
        val b = IntArray(NROOTS + 1)
        for (i in 0..NROOTS) b[i] = indexOf[lambda[i]]

        // Berlekamp-Massey algorithm to determine the error locator polynomial.
        var el = 0
        var r = 0
        val t = IntArray(NROOTS + 1)
        while (true) {
            r++
            if (r > NROOTS) break
            var discrR = 0
            for (i in 0 until r) {
                if (lambda[i] != 0 && s[r - i - 1] != A0) {
                    discrR = discrR xor alphaTo[modnn(indexOf[lambda[i]] + s[r - i - 1])]
                }
            }
            discrR = indexOf[discrR]
            if (discrR == A0) {
                for (k in NROOTS downTo 1) b[k] = b[k - 1]
                b[0] = A0
            } else {
                t[0] = lambda[0]
                for (i in 0 until NROOTS) {
                    t[i + 1] = if (b[i] != A0) lambda[i + 1] xor alphaTo[modnn(discrR + b[i])] else lambda[i + 1]
                }
                if (2 * el <= r - 1) {
                    el = r - el
                    for (i in 0..NROOTS) b[i] = if (lambda[i] == 0) A0 else modnn(indexOf[lambda[i]] - discrR + NN)
                } else {
                    for (k in NROOTS downTo 1) b[k] = b[k - 1]
                    b[0] = A0
                }
                for (i in 0..NROOTS) lambda[i] = t[i]
            }
        }

        // Convert lambda to index form and find deg(lambda).
        var degLambda = 0
        for (i in 0..NROOTS) {
            lambda[i] = indexOf[lambda[i]]
            if (lambda[i] != A0) degLambda = i
        }

        // Chien search for the roots of the error locator polynomial.
        val reg = IntArray(NROOTS + 1)
        for (i in 1..NROOTS) reg[i] = lambda[i]
        val root = IntArray(NROOTS)
        val loc = IntArray(NROOTS)
        var count = 0
        // IPRIM (prim-th root of 1, index form) is trivially 1 for PRIM=1.
        var k = 1 - 1
        var i = 1
        while (i <= NN) {
            var q = 1
            var j = degLambda
            while (j > 0) {
                if (reg[j] != A0) {
                    reg[j] = modnn(reg[j] + j)
                    q = q xor alphaTo[reg[j]]
                }
                j--
            }
            if (q == 0) {
                root[count] = i
                loc[count] = k
                count++
                if (count == degLambda) break
            }
            i++
            k = modnn(k + 1)
        }
        if (degLambda != count) return -1 // more errors than can be corrected

        // Error evaluator polynomial omega(x) = s(x)*lambda(x) mod x**NROOTS.
        val degOmega = degLambda - 1
        val omega = IntArray(NROOTS + 1)
        for (ii in 0..degOmega) {
            var tmp = 0
            for (jj in ii downTo 0) {
                if (s[ii - jj] != A0 && lambda[jj] != A0) {
                    tmp = tmp xor alphaTo[modnn(s[ii - jj] + lambda[jj])]
                }
            }
            omega[ii] = indexOf[tmp]
        }

        // Compute error values and apply corrections in place.
        for (j in count - 1 downTo 0) {
            var num1 = 0
            for (ii in degOmega downTo 0) {
                if (omega[ii] != A0) num1 = num1 xor alphaTo[modnn(omega[ii] + ii * root[j])]
            }
            val num2 = alphaTo[modnn(root[j] * (FCR - 1) + NN)]
            var den = 0
            var ii = minOf(degLambda, NROOTS - 1) and 1.inv()
            while (ii >= 0) {
                if (lambda[ii + 1] != A0) den = den xor alphaTo[modnn(lambda[ii + 1] + ii * root[j])]
                ii -= 2
            }
            if (num1 != 0 && loc[j] >= PAD) {
                data[loc[j] - PAD] = data[loc[j] - PAD] xor alphaTo[modnn(indexOf[num1] + indexOf[num2] + NN - indexOf[den])]
            }
        }
        return count
    }
}
