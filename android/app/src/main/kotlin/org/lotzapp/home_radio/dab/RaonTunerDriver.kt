package org.lotzapp.home_radio.dab

import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.util.Log

/**
 * Kotlin port of the register-level tuner control sequences from the
 * LGPL-2.1-licensed Raontech tuner driver in github.com/hradio/omri-usb
 * (`omriusb/src/main/cpp/platformspecific/android/raontunerinput.cpp`,
 * Copyright (C) 2018 IRT GmbH / Fabian Sattler). A full copy of the original
 * source is kept for reference under docs/dab-research/omri-usb-raon/.
 *
 * This project's own DAB+ USB dongle (VID 0x16C0/PID 0x05DC, "DAB USB
 * Dongle") was empirically confirmed to speak this exact register
 * read/write wire format (see the project plan's DAB+ phase, 2026-09-15):
 * writing register 0x7D=0x06 and reading it back returned exactly 0x06.
 *
 * What this covers: full chip power-up/initialization, tuning to a DAB
 * Band III channel, OFDM/FEC lock status, antenna/signal level, and a raw
 * FIC (Fast Information Channel) dump. What it does NOT cover yet: parsing
 * the FIC into an actual ensemble/service list (that requires decoding
 * ETSI EN 300 401 FIG structures, a substantial separate piece of work -
 * the reference repo has ~30 dedicated fig_*.cpp files for it) or MSC
 * audio decoding/playback. Both are natural next steps once tuning/locking
 * itself is confirmed to work against the real hardware.
 */
class RaonTunerDriver(
    private val connection: UsbDeviceConnection,
    private val outEp: UsbEndpoint,
    private val inEp: UsbEndpoint,
) {
    companion object {
        private const val TAG = "DabProbe"

        // REGISTER_PAGE values (page-select register 0x03 on every page).
        private const val PAGE_FM = 0x06
        private const val PAGE_COMM = 0x04
        private const val PAGE_HOST = 0x07
        private const val PAGE_DD = 0x09
        private const val PAGE_FIC = 0x0A
        private const val PAGE_MSC1 = 0x0C
        private const val PAGE_RF = 0x0F

        // ADC clock types (index into the synth table below).
        private const val CLK_8_MHZ = 0
        private const val CLK_8_192_MHZ = 1
        private const val CLK_9_6_MHZ = 3

        // g_abAdcClkSynTbl from the reference driver: one row per clock type.
        private val ADC_CLK_SYN_TBL = arrayOf(
            intArrayOf(0x08, 0x01, 0x13, 0x25, 0x06, 0x7D, 0xB4), // 8 MHz
            intArrayOf(0x06, 0x01, 0x0F, 0x27, 0x07, 0x60, 0xB8), // 8.192 MHz
            intArrayOf(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF), // 9 MHz (unsupported, unused)
            intArrayOf(0x0C, 0x01, 0x1F, 0x27, 0x06, 0xE1, 0xB8), // 9.6 MHz
        )

        /**
         * DAB Band III channel table (label, frequency in kHz, PLL NF value,
         * ADC clock type), copied verbatim from g_atPllNF_DAB_BAND3 /
         * g_aeAdcClkTypeTbl_DAB_B3 in the reference driver. 41 channels.
         */
        data class Band3Channel(val label: String, val freqKhz: Int, val pllNf: Int, val adcClkType: Int)

        val BAND3_CHANNELS = listOf(
            Band3Channel("5A", 174928, 0x38F3D55, CLK_8_192_MHZ),
            Band3Channel("5B", 176640, 0x3982800, CLK_9_6_MHZ),
            Band3Channel("5C", 178352, 0x3A112AA, CLK_8_192_MHZ),
            Band3Channel("5D", 180064, 0x3A9FD55, CLK_9_6_MHZ),
            Band3Channel("6A", 181936, 0x3B3BD55, CLK_8_192_MHZ),
            Band3Channel("6B", 183648, 0x3BCA800, CLK_9_6_MHZ),
            Band3Channel("6C", 185360, 0x3C592AA, CLK_8_192_MHZ),
            Band3Channel("6D", 187072, 0x3CE7D55, CLK_8_192_MHZ),
            Band3Channel("7A", 188928, 0x3D82800, CLK_8_MHZ),
            Band3Channel("7B", 190640, 0x3E112AA, CLK_8_192_MHZ),
            Band3Channel("7C", 192352, 0x3E9FD55, CLK_8_192_MHZ),
            Band3Channel("7D", 194064, 0x3F2E800, CLK_8_192_MHZ),
            Band3Channel("8A", 195936, 0x3FCA800, CLK_8_MHZ),
            Band3Channel("8B", 197648, 0x40592AA, CLK_8_192_MHZ),
            Band3Channel("8C", 199360, 0x40E7D55, CLK_8_192_MHZ),
            Band3Channel("8D", 201072, 0x4176800, CLK_8_MHZ),
            Band3Channel("9A", 202928, 0x42112AA, CLK_8_192_MHZ),
            Band3Channel("9B", 204640, 0x429FD55, CLK_8_MHZ),
            Band3Channel("9C", 206352, 0x432E800, CLK_8_192_MHZ),
            Band3Channel("9D", 208064, 0x43BD2AA, CLK_9_6_MHZ),
            Band3Channel("10A", 209936, 0x44592AA, CLK_8_192_MHZ),
            Band3Channel("10N", 210096, 0x4466800, CLK_8_192_MHZ),
            Band3Channel("10B", 211648, 0x44E7D55, CLK_8_192_MHZ),
            Band3Channel("10C", 213360, 0x4576800, CLK_8_MHZ),
            Band3Channel("10D", 215072, 0x46052AA, CLK_8_192_MHZ),
            Band3Channel("11A", 216928, 0x469FD55, CLK_9_6_MHZ),
            Band3Channel("11N", 217088, 0x46AD2AA, CLK_8_192_MHZ),
            Band3Channel("11B", 218640, 0x472E800, CLK_8_192_MHZ),
            Band3Channel("11C", 220352, 0x47BD2AA, CLK_8_192_MHZ),
            Band3Channel("11D", 222064, 0x484BD55, CLK_8_MHZ),
            Band3Channel("12A", 223936, 0x48E7D55, CLK_8_192_MHZ),
            Band3Channel("12N", 224096, 0x48F52AA, CLK_8_MHZ),
            Band3Channel("12B", 225648, 0x4976800, CLK_8_MHZ),
            Band3Channel("12C", 227360, 0x4A052AA, CLK_8_192_MHZ),
            Band3Channel("12D", 229072, 0x4A93D55, CLK_8_MHZ),
            Band3Channel("13A", 230784, 0x4B22800, CLK_8_192_MHZ),
            Band3Channel("13B", 232496, 0x4BB12AA, CLK_8_192_MHZ),
            Band3Channel("13C", 234208, 0x4C3FD55, CLK_8_MHZ),
            Band3Channel("13D", 235776, 0x4CC2800, CLK_8_192_MHZ),
            Band3Channel("13E", 237488, 0x4D512AA, CLK_8_MHZ),
            Band3Channel("13F", 239200, 0x4DDFD55, CLK_8_192_MHZ),
        )
    }

    // --- Low-level register access (empirically confirmed wire format) ---

    private fun writeReg(reg: Int, value: Int) {
        val data = byteArrayOf(0x21, 0x00, 0x00, 0x02, reg.toByte(), value.toByte())
        connection.bulkTransfer(outEp, data, data.size, 1000)
    }

    private fun readReg(reg: Int): Int {
        val req = byteArrayOf(0x22, 0x00, 0x01, 0x00, reg.toByte())
        connection.bulkTransfer(outEp, req, req.size, 1000)
        val buf = ByteArray(8)
        val n = connection.bulkTransfer(inEp, buf, buf.size, 1000)
        return if (n >= 5) buf[4].toInt() and 0xFF else -1
    }

    private fun switchPage(page: Int) = writeReg(0x03, page)

    private fun writeRegs(page: Int, vararg regs: Pair<Int, Int>) {
        switchPage(page)
        regs.forEach { (r, v) -> writeReg(r, v) }
    }

    // --- Power-up / initialization sequence (mirrors initializeSync()) ---

    fun tunerPowerUp(): Boolean {
        switchPage(PAGE_HOST)
        repeat(100) {
            writeReg(0x7D, 0x06)
            if (readReg(0x7D) == 0x06) return true
        }
        return false
    }

    private fun configurePowerType() {
        writeRegs(
            PAGE_RF,
            0x54 to 0x1C,
            0x52 to 0x07,
            0x30 to ((0xF2 and 0xF0) or (0x02 shl 1)),
            0x2F to (0x61 or 0x10),
        )
    }

    private fun configureAddClock() {
        writeAdcClkSynth(CLK_8_MHZ)
        repeat(10) {
            if ((readReg(0x15) and 0x01) > 0) return
        }
        Log.w(TAG, "ADC clock synth 1st-step unlock timeout")
    }

    private fun writeAdcClkSynth(clkType: Int) {
        val row = ADC_CLK_SYN_TBL[clkType]
        switchPage(PAGE_RF)
        writeReg(0xE8, (0x46 and 0xC0) or row[0])
        writeReg(0xE9, (0x54 and 0xF0) or row[1])
        writeReg(0xEA, (0x07 and 0xC0) or row[2])
        writeReg(0xEB, (0x27 and 0xC0) or row[3])
        writeReg(0xEC, (0x1E and 0xC0) or row[4])
        writeReg(0xED, (0x18 and 0x00) or row[5])
        writeReg(0xEE, (0xB8 and 0x00) or row[6])
    }

    /** Mirrors changedAdcClock(): re-synth the ADC clock for a given channel's type. */
    private fun changedAdcClock(clkType: Int): Boolean {
        writeAdcClkSynth(clkType)
        var setOk = false
        repeat(10) {
            if (!setOk && (readReg(0x15) and 0x01) > 0) setOk = true
        }
        when (clkType) {
            CLK_8_MHZ -> {
                writeRegs(PAGE_COMM, 0x6A to 0x01)
                writeRegs(
                    PAGE_FM,
                    0x3c to 0x4B, 0x3d to 0x37, 0x3e to 0x89, 0x3f to 0x41, 0x54 to 0x58,
                    0x40 to 0x8F, 0x41 to 0xC2, 0x42 to 0xF5, 0x43 to 0x00,
                )
            }
            CLK_8_192_MHZ -> {
                writeRegs(PAGE_COMM, 0x6A to 0x01)
                writeRegs(
                    PAGE_FM,
                    0x3c to 0x00, 0x3d to 0x00, 0x3e to 0x00, 0x3f to 0x40, 0x54 to 0x58,
                    0x40 to 0x00, 0x41 to 0x00, 0x42 to 0xF0, 0x43 to 0x00,
                )
            }
            CLK_9_6_MHZ -> {
                writeRegs(PAGE_COMM, 0x6A to 0x31)
                writeRegs(
                    PAGE_FM,
                    0x3c to 0x69, 0x3d to 0x03, 0x3e to 0x9D, 0x3f to 0x36, 0x54 to 0x58,
                    0x40 to 0xCC, 0x41 to 0xCC, 0x42 to 0xCC, 0x43 to 0x00,
                )
            }
        }
        return setOk
    }

    private fun tdmbInitTop() = writeRegs(PAGE_FM, 0x07 to 0x08, 0x05 to 0x17, 0x06 to 0x10, 0x0A to 0x00)

    private fun tdmbInitComm() = writeRegs(
        PAGE_COMM,
        0x10 to 0x91, 0xE1 to 0x00, 0x35 to 0x7B, 0x3B to 0x3C, 0x36 to 0x68, 0x3A to 0x44,
        0x3C to 0x20, 0x3D to 0x0B, 0x3D to 0x09, 0xA6 to 0x30, 0xAA to 0x01, 0xAF to 0x07,
    )

    private fun tdmbInitHost() = writeRegs(
        PAGE_HOST,
        0x10 to 0x00, 0x13 to 0x16, 0x14 to 0x00, 0x19 to 0x0A,
        0xF0 to 0x00, 0xF1 to 0x00, 0xF2 to 0x00, 0xF3 to 0x00, 0xF4 to 0x00,
        0xF5 to 0x00, 0xF6 to 0x00, 0xF7 to 0x00, 0xF8 to 0x00, 0xFB to 0xFF,
    )

    private fun tdmbInitOfdm() {
        writeRegs(
            PAGE_FM,
            0x12 to 0x04, 0x13 to 0x72, 0x14 to 0x63, 0x15 to 0x64, 0x16 to 0x6C, 0x38 to 0x01,
            0x1A to 0xB4, 0x20 to 0x5B, 0x25 to 0x09, 0x44 to 0x09, 0x46 to 0xA0, 0x47 to 0x0F,
            0x48 to 0xB8, 0x49 to 0x0B, 0x54 to 0x58, 0x55 to 0x06, 0x56 to 0x10, 0x59 to 0x51,
            0x5A to 0x1C, 0x6D to 0x00, 0x8B to 0x34, 0x6A to 0x1C, 0x6B to 0x2D, 0x85 to 0x32,
            0x8D to 0x0C, 0x8E to 0x01, 0x33 to 0x02, 0x53 to 0x06, 0x6F to 0x03, 0xBA to 0x08,
        )
        writeRegs(PAGE_COMM, 0x6A to 0x01)
        writeRegs(
            PAGE_FM,
            0x3C to 0x4B, 0x3D to 0x37, 0x3E to 0x89, 0x3F to 0x41,
            0x40 to 0x8F, 0x41 to 0xC2, 0x42 to 0xF5, 0x43 to 0x00,
            0x94 to 0x08, 0x98 to 0x05, 0x99 to 0x03, 0x9B to 0xCF, 0x9C to 0x10, 0x9D to 0x1C,
            0x9F to 0x32, 0xA0 to 0x90, 0xA2 to 0xA0, 0xA3 to 0x08, 0xA4 to 0x01, 0xA8 to 0xF6,
            0xA9 to 0x89, 0xAA to 0x0C, 0xAB to 0x32, 0xAC to 0x14, 0xAD to 0x09, 0xAE to 0xFF,
            0xEB to 0x6B, 0x93 to 0x10, 0x94 to 0x29, 0xA2 to 0x50, 0xA4 to 0x02, 0xAF to 0x01,
        )
    }

    private fun tdmbInitFEC() = writeRegs(
        PAGE_DD,
        0x80 to 0x80, 0x81 to 0xFF, 0x87 to 0x07, 0x45 to 0xA1,
        0xDD to 0xD0, 0x39 to 0x07, 0xE6 to 0x10, 0xA5 to 0xA0,
    )

    private fun rtvResetMemoryFIC() = writeRegs(PAGE_DD, 0x46 to 0x00)

    private fun rtvOEMConfigureInterrupt() {
        writeRegs(PAGE_DD, 0x09 to 0x00, 0x0B to 0x00)
        writeRegs(PAGE_HOST, 0x28 to 0x01, 0x2A to 0x13)
    }

    private fun rtvStreamDisable() = writeRegs(PAGE_HOST, 0x29 to 0x08)

    private fun rtvConfigureHostIF() = writeRegs(PAGE_HOST, 0x77 to 0x14, 0x04 to 0x28, 0x0C to 0xF5)

    private fun rtvRFInitilize() {
        writeRegs(
            PAGE_RF,
            0x27 to 0x96, 0x2B to 0x88, 0x2D to 0xEC, 0x2E to 0xB0, 0x31 to 0x04, 0x34 to 0xF8,
            0x35 to 0x14, 0x3A to 0x62, 0x3B to 0x74, 0x3C to 0xA8, 0x43 to 0x36, 0x44 to 0x70,
            0x46 to 0x07, 0x49 to 0x1F, 0x4A to 0x50, 0x4B to 0x80, 0x53 to 0x20, 0x55 to 0xD6,
            0x5A to 0x83, 0x60 to 0x13, 0x6B to 0x85, 0x6E to 0x88, 0x6F to 0x78, 0x72 to 0xF0,
            0x73 to 0xCA, 0x77 to 0x80, 0x78 to 0x47, 0x84 to 0x80, 0x85 to 0x90, 0x86 to 0x80,
            0x87 to 0x98, 0x8A to 0xF6, 0x8B to 0x80, 0x8C to 0x75, 0x8F to 0xF9, 0x90 to 0x91,
            0x93 to 0x2D, 0x94 to 0x23, 0x99 to 0x77, 0x9A to 0x2D, 0x9B to 0x1E, 0x9C to 0x47,
            0x9D to 0x3A, 0x9E to 0x03, 0x9F to 0x1E, 0xA0 to 0x22, 0xA1 to 0x33, 0xA2 to 0x51,
            0xA3 to 0x36, 0xA4 to 0x0C, 0xAE to 0x37, 0xB5 to 0x9B, 0xBD to 0x45, 0xBE to 0x68,
            0xBF to 0x5C, 0xC0 to 0x33, 0xC1 to 0xCA, 0xC2 to 0x43, 0xC3 to 0x90, 0xC4 to 0xEC,
            0xC5 to 0x17, 0xC6 to 0xDA, 0xC7 to 0x41, 0xC8 to 0x49, 0xC9 to 0xBC, 0xCA to 0x3A,
            0xCB to 0x20, 0xCC to 0x43, 0xCD to 0xA6, 0xCE to 0x4C, 0xCF to 0x1F, 0xD0 to 0x8D,
            0xD1 to 0x3D, 0xD2 to 0xDF, 0xD3 to 0xA4, 0xD4 to 0x30, 0xD5 to 0x00, 0xD6 to 0x41,
            0xD7 to 0x81, 0xD8 to 0xD0, 0xD9 to 0x00, 0xDA to 0x00, 0xDB to 0x41, 0xDC to 0x6D,
            0xDD to 0xAC, 0xDE to 0x39, 0xDF to 0x4E, 0xE0 to 0x43, 0xE1 to 0xA0, 0xE2 to 0x4C,
            0xE3 to 0x1D, 0xE4 to 0x99, 0xE5 to 0x3B, 0xE6 to 0x00, 0xE7 to 0x0D, 0xA5 to 0x00,
            0xE9 to 0x41, 0xAE to 0x77, 0xE9 to 0x51, 0x37 to 0x3B, 0x39 to 0x2C,
        )
        val checkVal = ((readReg(0x10) shl 8) or readReg(0x11)) and 0xFFFF
        if (checkVal != 0xFFFF) {
            writeRegs(PAGE_RF, 0x2C to 0x48, 0x47 to 0xE0, 0x35 to 0x04, 0x2A to 0x05, 0x2D to 0x8C, 0x61 to 0x25)
        } else {
            writeRegs(PAGE_RF, 0x2C to 0xC8, 0x47 to 0xB0, 0x35 to 0x04, 0x2A to 0x07, 0x2D to 0xEC, 0x61 to 0x2A)
        }
        writeRegs(PAGE_RF, 0x6B to 0xC5)
    }

    /** Raw bulk exchange with a different (non-register) framing - purpose unconfirmed. */
    private fun rtvRfSpecial() {
        for (req in listOf(byteArrayOf(0x10, 0x00, 0x00, 0x01), byteArrayOf(0, 0, 0, 0), byteArrayOf(1, 0, 0, 0))) {
            connection.bulkTransfer(outEp, req, req.size, 1000)
            val buf = ByteArray(4)
            connection.bulkTransfer(inEp, buf, buf.size, 1000)
        }
    }

    private fun setupMscThreshold() = writeRegs(PAGE_DD, 0x56 to 0x08, 0x57 to 0x00)

    private fun setupMemoryFIC() = writeRegs(PAGE_DD, 0x46 to 0x14, 0x46 to 0x16)

    /**
     * Full chip bring-up, in the exact order from initializeSync(). Returns
     * false (and logs why) if the power-up handshake itself fails - in that
     * case none of the later steps are attempted, matching the reference.
     */
    fun initialize(): Boolean {
        Log.i(TAG, "RaonTunerDriver: initialize() start")
        if (!tunerPowerUp()) {
            Log.w(TAG, "tunerPowerUp() failed")
            return false
        }
        configurePowerType()
        configureAddClock()
        tdmbInitTop()
        tdmbInitComm()
        tdmbInitHost()
        tdmbInitOfdm()
        tdmbInitFEC()
        rtvResetMemoryFIC()
        rtvOEMConfigureInterrupt()
        rtvStreamDisable()
        rtvConfigureHostIF()
        rtvRFInitilize()
        rtvRfSpecial()
        setupMscThreshold()
        setupMemoryFIC()
        Log.i(TAG, "RaonTunerDriver: initialize() done")
        return true
    }

    /** Tunes to one Band III channel by table index (see [BAND3_CHANNELS]). */
    fun tuneToChannel(channel: Band3Channel) {
        Log.i(TAG, "Tuning to ${channel.label} (${channel.freqKhz} kHz)")
        if (!changedAdcClock(channel.adcClkType)) {
            Log.w(TAG, "changedAdcClock() did not report lock for ${channel.label}")
        }
        switchPage(PAGE_RF)
        val pllNf = channel.pllNf
        writeReg(0x23, (pllNf ushr 22) and 0xFF)
        writeReg(0x24, (pllNf ushr 14) and 0xFF)
        writeReg(0x25, (pllNf ushr 5) and 0xFF)
        writeReg(0x26, ((pllNf and 0x3F) shl 2) or 1)
        Thread.sleep(500)
        writeReg(0x20, 0x00)
        val v15 = readReg(0x15)
        Log.i(TAG, "Post-tune verify reg 0x15=0x%02X (bit1 set = locked hint)".format(v15))
        softReset()
    }

    private fun softReset() {
        writeRegs(PAGE_FM, 0x10 to 0x48, 0x10 to 0xC9)
    }

    /** OFDM + FEC lock bits, as in getLockStatus(). Bit0=OFDM, bit1=FEC. */
    fun getLockStatus(): Int {
        switchPage(PAGE_DD)
        var status = 0
        if ((readReg(0x37) and 0x01) != 0) status = status or 0x01
        if ((readReg(0xFB) and 0x03) == 0x03) status = status or 0x02
        return status
    }

    /** Raw CER-derived antenna/signal metric (0-2000, lower is better), plus lock flag. */
    fun getAntennaLevel(): Pair<Boolean, Int> {
        switchPage(PAGE_DD)
        val locked = (readReg(0x37) and 0x01) != 0
        if (!locked) return false to 0
        val periodCnt = (readReg(0x88) shl 24) or (readReg(0x89) shl 16) or (readReg(0x8A) shl 8) or readReg(0x8B)
        val cerCnt = (readReg(0x8C) shl 24) or (readReg(0x8D) shl 16) or (readReg(0x8E) shl 8) or readReg(0x8F)
        val retVal = if (periodCnt == 0) {
            2000
        } else if (cerCnt <= 4000) {
            0
        } else {
            (((cerCnt * 1000) / periodCnt) * 10).coerceAtMost(2000)
        }
        return true to retVal
    }

    /**
     * Reads one raw FIC (Fast Information Channel) burst and returns the
     * payload bytes (header stripped). Not yet decoded into ensemble/service
     * information (see class doc comment) - useful for now as evidence that
     * real, changing broadcast data is being received.
     */
    fun readFicRaw(): ByteArray {
        switchPage(PAGE_FIC)
        val req = byteArrayOf(0x22, 0x00, 0x80.toByte(), 0x01, 0x10)
        connection.bulkTransfer(outEp, req, req.size, 1000)
        val buf = ByteArray(400)
        val n = connection.bulkTransfer(inEp, buf, buf.size, 1000)
        switchPage(PAGE_DD)
        writeReg(0x35, 0x01) // FIC interrupt status clear (INT_E_UCLRL bit0)
        return if (n > 4) buf.copyOfRange(4, n) else ByteArray(0)
    }

    /**
     * Opens one MSC subchannel (0-63, from FIG 0/2's SubChId for the
     * station's audio component) for reading via [readMscRaw] - mirrors
     * openSubChannel() in the reference driver exactly. The chip is
     * expected to already track the ensemble's subchannel layout from FIC
     * reception on its own (there's no separate "configure start
     * address/size" register write anywhere in the reference driver, only
     * this bare subchannel-select), consistent with readMscRaw() returning
     * only that one subchannel's already-demultiplexed bytes.
     */
    fun openSubChannel(subChId: Int) {
        Log.i(TAG, "Opening subchannel $subChId")
        switchPage(PAGE_DD)
        writeReg(0x35, 0x70) // MSC1 interrupt status clear
        switchPage(PAGE_HOST)
        writeReg(0x62, 0x00)
        switchPage(PAGE_DD)
        writeReg(0x3A, 0x80 or subChId)
    }

    /**
     * Resets and (re-)enables the chip's MSC memory/FIFO - mirrors
     * clearAndSetupMscMemory() in the reference driver. There, it's only
     * called reactively on an MSC overrun/underrun interrupt, which implies
     * this memory region isn't enabled by default; called once after
     * [openSubChannel] since nothing else in the init sequence enables it
     * (unlike FIC, which setupMemoryFIC() explicitly enables at startup).
     */
    fun clearAndSetupMscMemory() {
        switchPage(PAGE_DD)
        writeReg(0x48, 0x00)
        writeReg(0x48, 0x05)
    }

    /**
     * Checks the interrupt status register for an MSC1 overrun/underrun
     * condition and recovers from it (clearAndSetupMscMemory() + interrupt
     * clear) if found - mirrors readMsc()'s reactive handling in the
     * reference driver. Without this, once the FIFO overruns the read loop
     * silently stops returning any data at all (observed after ~45s of
     * continuous playback). Returns true if a recovery was performed.
     */
    fun recoverMscOverrunIfNeeded(): Boolean {
        switchPage(PAGE_DD)
        val status = readReg(0x33) // INT_E_STATL: bit6=MSC1 overrun, bit5=MSC1 underrun
        if (status < 0 || (status and 0x60) == 0) return false // -1 = read failure, not a real status
        Log.w(TAG, "MSC1 overrun/underrun detected (status=0x%02X) - resetting MSC memory".format(status))
        clearAndSetupMscMemory()
        writeReg(0x35, 0x04)
        return true
    }

    fun closeSubChannel(subChId: Int) {
        Log.i(TAG, "Closing subchannel $subChId")
        switchPage(PAGE_DD)
        writeReg(0x35, 0x70)
        switchPage(PAGE_HOST)
        writeReg(0x62, 0x00)
        switchPage(PAGE_DD)
        writeReg(0x3A, subChId)
    }

    /**
     * Reads whatever raw MSC bytes have accumulated for the currently open
     * subchannel (see [openSubChannel]) - NOT pre-chunked into fixed-size
     * per-CIF frames (the amount returned depends on how much the chip's
     * FIFO had buffered since the last read); the caller must re-frame this
     * into fixed-size pieces itself (see DabPlusSuperframeDecoder/the
     * subchannel's FIG 0/1 size) before feeding a superframe decoder.
     */
    fun readMscRaw(): ByteArray {
        switchPage(PAGE_MSC1)
        val req = byteArrayOf(0x22, 0x00, 0x00, 0x08, 0x10)
        connection.bulkTransfer(outEp, req, req.size, 1000)
        val buf = ByteArray(4096)
        val n = connection.bulkTransfer(inEp, buf, buf.size, 1000)
        switchPage(PAGE_DD)
        writeReg(0x35, 0x04) // MSC1 interrupt status clear (INT_E_UCLRL bit2)
        return if (n > 4) buf.copyOfRange(4, n) else ByteArray(0)
    }
}
