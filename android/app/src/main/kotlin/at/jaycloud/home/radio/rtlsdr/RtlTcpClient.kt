package at.jaycloud.home.radio.rtlsdr

import android.util.Log
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Client for the `rtl_tcp` wire protocol (see librtlsdr's src/rtl_tcp.c,
 * github.com/steve-m/librtlsdr - protocol verified directly against that
 * source, 2026-09-17). Connects to a running `rtl_tcp` server - either a
 * local Android RTL-SDR driver app (default: localhost) or a remote one,
 * e.g. an RTL-SDR dongle plugged into a Raspberry Pi running `rtl_tcp` as a
 * network server - and streams raw 8-bit unsigned I/Q sample pairs.
 *
 * This project deliberately does NOT talk to the RTL-SDR dongle's own USB
 * protocol directly (unlike the abandoned Raontech DAB dongle driver) -
 * `rtl_tcp` already solves that, tested and working, on both Android
 * (driver apps) and Linux (the Pi case): reinventing it was the exact kind
 * of open-ended USB reverse-engineering that DAB+ needed weeks for and
 * still didn't fully explain, for hardware (RTL2832U) that's actually
 * *already* fully documented and solved upstream.
 *
 * host/port are configurable (see [DEFAULT_PORT]) rather than hardcoded to
 * localhost, specifically so the dongle can live on a different device
 * (e.g. a Pi) than the one running this app.
 */
class RtlTcpClient(
    private val host: String,
    private val port: Int = DEFAULT_PORT,
) {
    data class DongleInfo(val tunerType: Int, val tunerGainCount: Int)

    fun interface SampleListener {
        /** Raw interleaved I/Q bytes (unsigned 8-bit each: I0,Q0,I1,Q1,...) - called off the caller's thread. */
        fun onSamples(data: ByteArray, length: Int)
    }

    @Volatile private var socket: Socket? = null
    @Volatile private var running = false
    private var readThread: Thread? = null

    @Volatile var dongleInfo: DongleInfo? = null
        private set

    /**
     * Connects, reads the dongle-info header, then starts streaming samples
     * to [listener] on a dedicated background thread until [disconnect] is
     * called or the connection drops. Blocks until the header is read (or
     * connection fails) so [dongleInfo] is populated (or an exception is
     * thrown) before this returns.
     */
    @Throws(IOException::class)
    fun connect(listener: SampleListener) {
        val sock = Socket()
        sock.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        sock.tcpNoDelay = true
        socket = sock

        val header = ByteArray(12)
        readFully(sock, header)
        val magic = String(header, 0, 4, Charsets.US_ASCII)
        if (magic != "RTL0") {
            sock.close()
            socket = null
            throw IOException("Unexpected rtl_tcp header magic: $magic")
        }
        val bb = ByteBuffer.wrap(header, 4, 8).order(ByteOrder.BIG_ENDIAN)
        val tunerType = bb.int
        val gainCount = bb.int
        dongleInfo = DongleInfo(tunerType, gainCount)
        Log.i(TAG, "rtl_tcp connected to $host:$port - tunerType=$tunerType gainCount=$gainCount")

        running = true
        readThread = Thread({ readLoop(sock, listener) }, "RtlTcpRead").apply { start() }
    }

    fun disconnect() {
        running = false
        try {
            socket?.close()
        } catch (_: IOException) {
        }
        socket = null
        readThread?.join(500)
        readThread = null
        dongleInfo = null
    }

    fun setFrequencyHz(hz: Long) = sendCommand(0x01, hz.toInt())
    fun setSampleRateHz(hz: Int) = sendCommand(0x02, hz)

    /** true = let the tuner's own AGC pick the gain; false = use [setTunerGainTenthDb]/[setTunerGainByIndex]. */
    fun setTunerGainMode(auto: Boolean) = sendCommand(0x03, if (auto) 0 else 1)
    fun setTunerGainTenthDb(tenthDb: Int) = sendCommand(0x04, tenthDb)
    fun setFreqCorrectionPpm(ppm: Int) = sendCommand(0x05, ppm)
    fun setTunerIfGain(stage: Int, tenthDb: Int) = sendCommand(0x06, (stage shl 16) or (tenthDb and 0xFFFF))
    fun setAgcMode(on: Boolean) = sendCommand(0x08, if (on) 1 else 0)
    fun setDirectSampling(mode: Int) = sendCommand(0x09, mode)
    fun setOffsetTuning(on: Boolean) = sendCommand(0x0A, if (on) 1 else 0)
    fun setTunerGainByIndex(index: Int) = sendCommand(0x0D, index)
    fun setBiasTee(on: Boolean) = sendCommand(0x0E, if (on) 1 else 0)

    private fun sendCommand(cmd: Int, param: Int) {
        val sock = socket ?: return
        val buf = ByteBuffer.allocate(5).order(ByteOrder.BIG_ENDIAN)
        buf.put(cmd.toByte())
        buf.putInt(param)
        try {
            sock.getOutputStream().write(buf.array())
        } catch (e: IOException) {
            Log.w(TAG, "rtl_tcp command 0x%02X failed: %s".format(cmd, e.message))
        }
    }

    private fun readLoop(sock: Socket, listener: SampleListener) {
        val buf = ByteArray(READ_CHUNK_BYTES)
        val input = sock.getInputStream()
        try {
            while (running) {
                val n = input.read(buf)
                if (n < 0) break
                if (n > 0) listener.onSamples(buf, n)
            }
        } catch (e: IOException) {
            if (running) Log.w(TAG, "rtl_tcp read loop ended: ${e.message}")
        } finally {
            running = false
        }
    }

    @Throws(IOException::class)
    private fun readFully(sock: Socket, dest: ByteArray) {
        val input = sock.getInputStream()
        var offset = 0
        while (offset < dest.size) {
            val n = input.read(dest, offset, dest.size - offset)
            if (n < 0) throw IOException("rtl_tcp connection closed while reading header")
            offset += n
        }
    }

    companion object {
        private const val TAG = "DabProbe"
        const val DEFAULT_PORT = 1234
        private const val CONNECT_TIMEOUT_MS = 5000
        private const val READ_CHUNK_BYTES = 65536
    }
}
