package at.jaycloud.home.radio.dab

/**
 * Kotlin side of our own DAB+ receiver (cpp/hrdab, libhrdab.so): OFDM,
 * FIC/MSC decoding, DAB+ super frames and PAD in native code, the RTL-SDR
 * driven directly over usbfs (or an rtl_tcp server). It hands out the raw
 * AAC access units; [DabAacPlayer] decodes them with Android's MediaCodec.
 *
 * The same receiver also does FM (UKW) on the same stick ([fmTune],
 * [fmSurvey]): demodulation, stereo decoding and RDS in native code, 48 kHz
 * stereo PCM out via [Events.onFmPcm]. DAB and FM take turns - any DAB call
 * leaves FM mode and vice versa.
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

        /** FM: 48 kHz interleaved stereo PCM, ~32 ms per call. */
        fun onFmPcm(pcm: ShortArray)

        /** FM: about every 500 ms; [levelDb] is referred to the tuner input (AGC-independent). */
        fun onFmStatus(levelDb: Float, snrDb: Float, stereo: Boolean, offsetHz: Float, pilot: Float)

        /** FM: PI (-1 = unknown), PS and RadioText (null = unknown) whenever one of them changes. */
        fun onFmRds(pi: Int, ps: String?, rt: String?)

        /** NB: 48 kHz mono PCM, ~32 ms per call, continuous (silence while the squelch is closed). */
        fun onNbPcm(pcm: ShortArray)

        /**
         * NB: every ~200 ms. All levels in dB referred to the tuner input.
         * [mode] is "am"/"fm"/"usb"/"lsb"/"wfm", or "auto" while auto mode has not
         * detected anything yet. [levelsDb] has NaN for channels outside the
         * window; [spectrumDb] is empty when there is no activity data this
         * time (then [channelsHz]/[levelsDb] are empty too). The last four are
         * the filters in effect: channel width after defaults/clamping for
         * the mode in use, and the AGC resolved to "fast"/"slow".
         */
        fun onNbReport(
            freqHz: Int,
            levelDb: Float,
            noiseDb: Float,
            snrDb: Float,
            squelchOpen: Boolean,
            mode: String,
            centerHz: Int,
            spanHz: Int,
            channelsHz: IntArray,
            levelsDb: FloatArray,
            channelNoiseDb: Float,
            spectrumDb: FloatArray,
            bandwidthHz: Int,
            noiseBlanker: Boolean,
            voiceFilter: Boolean,
            agc: String,
        )

        /** NB: waterfall spectrum ~20 times a second, dB referred to the tuner input; [gainDb] = tuner gain now. */
        fun onNbSpectrum(centerHz: Int, spanHz: Int, binsDb: FloatArray, gainDb: Float) {}

        /** NB: a packet from the packet decoder - [kind] 1 = AX.25 (APRS), 2 = ACARS message; checksums checked. */
        fun onNbPacket(kind: Int, frame: ByteArray) {}

        /** ADS-B: a verified Mode S frame (7/14 bytes), its aircraft address and level (dBFS). */
        fun onAdsbFrame(frame: ByteArray, icao: Int, signalDb: Float) {}

        /** Data modes (ADS-B, ISM, ACARS), twice a second: arriving rate, input level, clipping, gain, ACARS channel levels. */
        fun onRxStatus(samplesPerSecond: Float, levelDb: Float, clipRatio: Float, gainDb: Float, channelLevelsDb: FloatArray) {}

        /** ACARS (multi-channel mode): a message on [freqHz], CRC checked. */
        fun onAcarsFrame(freqHz: Int, frame: ByteArray) {}

        /** ISM sensors: a burst as "ook"/"fsk" high/low durations (us), carrier offset, level, SNR. */
        fun onIsmBurst(modulation: String, durationsUs: IntArray, offsetHz: Float, levelDb: Float, snrDb: Float) {}
    }

    companion object {
        init {
            System.loadLibrary("hrdab")
        }

        /** NB mode names as the method channel uses them -> native code (NbMode). */
        fun nbModeCode(mode: String): Int? = when (mode) {
            "auto" -> 0
            "am" -> 1
            "fm" -> 2
            "usb" -> 3
            "lsb" -> 4
            "wfm" -> 5
            else -> null
        }

        /** NB AGC names -> native code (NbAgc). */
        fun nbAgcCode(agc: String): Int? = when (agc) {
            "auto" -> 0
            "fast" -> 1
            "slow" -> 2
            else -> null
        }
    }

    private external fun nativeCreateUsb(fd: Int): Boolean
    private external fun nativeCreateTcp(host: String, port: Int): Boolean
    private external fun nativeDestroy()
    private external fun nativeTune(hz: Int): Boolean
    private external fun nativeTuneKeep(hz: Int): Boolean
    private external fun nativeHalt()
    private external fun nativeGetEnsembleLabel(): String
    private external fun nativeGetServiceListJson(): String
    private external fun nativePlayService(serviceId: Int): Boolean
    private external fun nativeStopService()
    private external fun nativeFmTune(hz: Int): Boolean
    private external fun nativeFmSurvey(centerHz: Int, lowHz: Int, highHz: Int): String?
    private external fun nativeFmInfoJson(): String
    private external fun nativeNbStart(
        sampleRate: Int,
        centerHz: Int,
        channelsHz: IntArray,
        freqHz: Int,
        mode: Int,
        squelchDb: Float,
    ): Boolean
    private external fun nativeNbTune(freqHz: Int, mode: Int): Boolean
    private external fun nativeNbSetSquelch(squelchDb: Float)
    private external fun nativeNbSetChannels(centerHz: Int, channelsHz: IntArray): Boolean
    private external fun nativeNbSetFilters(bandwidthHz: Int, noiseBlanker: Boolean, voiceFilter: Boolean, agc: Int)
    private external fun nativeNbSetGain(gainIndex: Int): Float
    private external fun nativeNbSetPacketDecoder(kind: Int)
    private external fun nativeAdsbStart(): Boolean
    private external fun nativeIsmStart(freqHz: Int): Boolean
    private external fun nativeAcarsStart(centerHz: Int, channelsHz: IntArray): Boolean

    /** ACARS on all [channelsHz] at once around [centerHz] (no audio); messages via [Events.onAcarsFrame]. */
    fun acarsStart(centerHz: Int, channelsHz: IntArray): Boolean = nativeAcarsStart(centerHz, channelsHz)

    /** ISM sensors on [freqHz] (433,92 / 868,3 MHz) at 1,024 MS/s; bursts via [Events.onIsmBurst]. Stop with [halt]. */
    fun ismStart(freqHz: Int): Boolean = nativeIsmStart(freqHz)

    /** ADS-B on 1090 MHz at 2 MS/s (leaves DAB/FM/NB); frames via [Events.onAdsbFrame]. Stop with [halt]. */
    fun adsbStart(): Boolean = nativeAdsbStart()

    /** NB: packet decoder on the listened channel - 0 off, 1 APRS, 2 ACARS; frames via [Events.onNbPacket]. */
    fun nbSetPacketDecoder(kind: Int) = nativeNbSetPacketDecoder(kind)

    /** NB tuner gain: step 0..30 held fixed, -1 = automatic. Returns its gain in dB. */
    fun nbSetGain(gainIndex: Int): Float = nativeNbSetGain(gainIndex)

    /**
     * rtl_tcp client session to [host]:[port]; the protocol (rtl_tcp or
     * rtl_tcp Jay extended) is negotiated on every connect.
     */
    fun createTcp(host: String, port: Int) = nativeCreateTcp(host, port)

    /** Direct USB session on an opened, interface-claimed RTL-SDR fd. */
    fun createUsb(fd: Int) = nativeCreateUsb(fd)

    fun destroy() = nativeDestroy()

    /** Retune (starting streaming if needed) and forget the old ensemble. */
    fun tune(hz: Int) {
        nativeTune(hz)
    }

    /**
     * Like [tune], but when DAB is already being received on [hz] only the
     * service stops - what the FIC collected so far stays (play retries on
     * a weak ensemble build on each other instead of starting over).
     */
    fun tuneKeep(hz: Int) {
        nativeTuneKeep(hz)
    }

    /** Stop streaming and decoding until the next [tune]. */
    fun halt() = nativeHalt()

    fun ensembleLabel(): String = nativeGetEnsembleLabel()

    /** JSON array of `{"serviceId":..,"label":".."}` for the audio services found so far. */
    fun serviceListJson(): String = nativeGetServiceListJson()

    /** False while the FIC has not described the service yet, or for non-DAB+ services. */
    fun playService(serviceId: Int) = nativePlayService(serviceId)

    fun stopService() = nativeStopService()

    /** FM: tune to a station (entering FM mode) and start demodulating; resets RDS. */
    fun fmTune(hz: Int) = nativeFmTune(hz)

    /**
     * FM: power spectrum survey of the 800 kHz around [centerHz] (no audio
     * meanwhile); blocks for ~0.3-1 s. JSON array of
     * `{"freqKhz":..,"levelDb":..,"marginDb":..}` for the carriers on the
     * 50 kHz raster within [lowHz]..[highHz], or null if it failed.
     */
    fun fmSurvey(centerHz: Int, lowHz: Int, highHz: Int): String? = nativeFmSurvey(centerHz, lowHz, highHz)

    /**
     * FM: current state as JSON: valid, levelDb, snrDb, stereo, offsetHz,
     * pilot, rdsSync, pi/ps/rt (null if unknown).
     */
    fun fmInfoJson(): String = nativeFmInfoJson()

    /**
     * Narrowband (CB/airband): leaves DAB/FM, switches the stick to
     * [sampleRate] (960000, 1024000, 1440000, 1920000, 2048000 or 2400000),
     * places the window around [centerHz], monitors [channelsHz] and plays
     * [freqHz] in [mode] (see [nbModeCode]). [squelchDb] <= 0 = squelch off.
     * Stop with [halt]; the next DAB/FM call restores 2.048 MS/s.
     */
    fun nbStart(sampleRate: Int, centerHz: Int, channelsHz: IntArray, freqHz: Int, mode: Int, squelchDb: Float) =
        nativeNbStart(sampleRate, centerHz, channelsHz, freqHz, mode, squelchDb)

    /** NB: other channel/mode; moves the window if [freqHz] is outside it. */
    fun nbTune(freqHz: Int, mode: Int) = nativeNbTune(freqHz, mode)

    fun nbSetSquelch(squelchDb: Float) = nativeNbSetSquelch(squelchDb)

    /** NB: new window centre and/or monitored channels (the listened channel stays). */
    fun nbSetChannels(centerHz: Int, channelsHz: IntArray) = nativeNbSetChannels(centerHz, channelsHz)

    /**
     * NB signal filters, kept across [nbTune] and mode changes: channel width
     * ([bandwidthHz], 0 = mode default), impulse noise blanker, 300-3000 Hz
     * voice filter, AGC speed ([agc] from [nbAgcCode]).
     */
    fun nbSetFilters(bandwidthHz: Int, noiseBlanker: Boolean, voiceFilter: Boolean, agc: Int) =
        nativeNbSetFilters(bandwidthHz, noiseBlanker, voiceFilter, agc)

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

    private fun onNativeFmPcm(pcm: ShortArray) = events.onFmPcm(pcm)

    private fun onNativeFmStatus(levelDb: Float, snrDb: Float, stereo: Boolean, offsetHz: Float, pilot: Float) =
        events.onFmStatus(levelDb, snrDb, stereo, offsetHz, pilot)

    private fun onNativeFmRds(pi: Int, ps: String?, rt: String?) = events.onFmRds(pi, ps, rt)

    private fun onNativeNbPcm(pcm: ShortArray) = events.onNbPcm(pcm)

    private fun onNativeNbReport(
        freqHz: Int,
        levelDb: Float,
        noiseDb: Float,
        snrDb: Float,
        squelchOpen: Boolean,
        mode: String,
        centerHz: Int,
        spanHz: Int,
        channelsHz: IntArray,
        levelsDb: FloatArray,
        channelNoiseDb: Float,
        spectrumDb: FloatArray,
        bandwidthHz: Int,
        noiseBlanker: Boolean,
        voiceFilter: Boolean,
        agc: String,
    ) = events.onNbReport(
        freqHz, levelDb, noiseDb, snrDb, squelchOpen, mode, centerHz, spanHz, channelsHz, levelsDb, channelNoiseDb,
        spectrumDb, bandwidthHz, noiseBlanker, voiceFilter, agc,
    )

    private fun onNativeNbPacket(kind: Int, frame: ByteArray) = events.onNbPacket(kind, frame)

    private fun onNativeRxStatus(samplesPerSecond: Float, levelDb: Float, clipRatio: Float, gainDb: Float, channelLevelsDb: FloatArray) =
        events.onRxStatus(samplesPerSecond, levelDb, clipRatio, gainDb, channelLevelsDb)

    private fun onNativeAcarsFrame(freqHz: Int, frame: ByteArray) = events.onAcarsFrame(freqHz, frame)

    private fun onNativeIsmBurst(modulation: String, durationsUs: IntArray, offsetHz: Float, levelDb: Float, snrDb: Float) =
        events.onIsmBurst(modulation, durationsUs, offsetHz, levelDb, snrDb)

    private fun onNativeAdsbFrame(frame: ByteArray, icao: Int, signalDb: Float) =
        events.onAdsbFrame(frame, icao, signalDb)

    private fun onNativeNbSpectrum(centerHz: Int, spanHz: Int, binsDb: FloatArray, gainDb: Float) =
        events.onNbSpectrum(centerHz, spanHz, binsDb, gainDb)
}
