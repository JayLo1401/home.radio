package at.jaycloud.home.radio.dab

/**
 * Kotlin side of our own DAB+ receiver (cpp/hrdab, libhrdab.so): OFDM,
 * FIC/MSC decoding, DAB+ super frames and PAD in native code, the RTL-SDR
 * driven directly over usbfs (or an rtl_tcp server). It hands out the raw
 * AAC access units; [DabAacPlayer] decodes them with Android's MediaCodec.
 *
 * The onNative* methods are called from native threads by name (see
 * hrdab_jni.cpp) and are kept by proguard-rules.pro. They must not call back
 * into the native* methods synchronously - the native side may hold its
 * session lock while it waits for those threads.
 */
class IntegratedDabEngine(private val events: Events) {

    interface Events {
        fun onSync(sync: Boolean)
        fun onEnsembleLabel(label: String)
        fun onServiceDetected(serviceId: Int)
        fun onDynamicLabel(label: String)
        fun onSnr(snrDb: Float)
        fun onRsErrors(uncorrected: Boolean, corrected: Int)
        fun onAacErrors(count: Int)
        fun onAudioFormat(format: String)
        fun onAudioConfig(asc: ByteArray, sampleRate: Int, channels: Int)
        fun onAccessUnit(au: ByteArray, ok: Boolean)
        fun onSlide(data: ByteArray, contentSubType: Int)
        fun onStatus(isError: Boolean, message: String)
    }

    companion object {
        init {
            System.loadLibrary("hrdab")
        }
    }

    private external fun nativeCreateUsb(fd: Int): Boolean
    private external fun nativeCreateTcp(host: String, port: Int): Boolean
    private external fun nativeDestroy()
    private external fun nativeTune(hz: Int): Boolean
    private external fun nativeHalt()
    private external fun nativeGetEnsembleLabel(): String
    private external fun nativeGetServiceListJson(): String
    private external fun nativePlayService(serviceId: Int): Boolean
    private external fun nativeStopService()

    /** rtl_tcp client session to [host]:[port]. */
    fun createTcp(host: String, port: Int) = nativeCreateTcp(host, port)

    /** Direct USB session on an opened, interface-claimed RTL-SDR fd. */
    fun createUsb(fd: Int) = nativeCreateUsb(fd)

    fun destroy() = nativeDestroy()

    /** Retune (starting streaming if needed) and forget the old ensemble. */
    fun tune(hz: Int) {
        nativeTune(hz)
    }

    /** Stop streaming and decoding until the next [tune]. */
    fun halt() = nativeHalt()

    fun ensembleLabel(): String = nativeGetEnsembleLabel()

    /** JSON array of `{"serviceId":..,"label":".."}` for the audio services found so far. */
    fun serviceListJson(): String = nativeGetServiceListJson()

    /** False while the FIC has not described the service yet, or for non-DAB+ services. */
    fun playService(serviceId: Int) = nativePlayService(serviceId)

    fun stopService() = nativeStopService()

    // --- called from native code ---

    private fun onNativeSync(sync: Boolean) = events.onSync(sync)

    private fun onNativeEnsembleLabel(label: String) = events.onEnsembleLabel(label)

    private fun onNativeServiceDetected(serviceId: Int) = events.onServiceDetected(serviceId)

    private fun onNativeDynamicLabel(label: String) = events.onDynamicLabel(label)

    private fun onNativeSnr(snrDb: Float) = events.onSnr(snrDb)

    private fun onNativeRsErrors(uncorrected: Boolean, corrected: Int) = events.onRsErrors(uncorrected, corrected)

    private fun onNativeAacErrors(count: Int) = events.onAacErrors(count)

    private fun onNativeAudioFormat(format: String) = events.onAudioFormat(format)

    private fun onNativeAudioConfig(asc: ByteArray, sampleRate: Int, channels: Int) =
        events.onAudioConfig(asc, sampleRate, channels)

    private fun onNativeAccessUnit(au: ByteArray, ok: Boolean) = events.onAccessUnit(au, ok)

    private fun onNativeSlide(data: ByteArray, contentSubType: Int) = events.onSlide(data, contentSubType)

    private fun onNativeStatus(isError: Boolean, message: String) = events.onStatus(isError, message)
}
