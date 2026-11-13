#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "acars.h"
#include "acars_multi.h"
#include "adsb_demod.h"
#include "afsk1200.h"
#include "byte_ring.h"
#include "ism_demod.h"
#include "ensemble.h"
#include "fic.h"
#include "fm_demod.h"
#include "msc.h"
#include "nb_demod.h"
#include "ofdm.h"
#include "pad.h"
#include "sample_source.h"
#include "superframe.h"

namespace hrdab {

class ReceiverListener {
public:
    virtual ~ReceiverListener() = default;
    virtual void onSync(bool synced) = 0;
    virtual void onEnsembleLabel(const std::string& label) = 0;
    virtual void onServiceDetected(uint32_t sid) = 0;
    virtual void onDynamicLabel(const std::string& text) = 0;
    virtual void onSnr(float snrDb) = 0;
    virtual void onRsErrors(bool uncorrectable, int corrected) = 0;
    virtual void onAacErrors(int count) = 0;
    virtual void onAudioFormat(const std::string& format) = 0;
    virtual void onAudioConfig(const std::vector<uint8_t>& asc, int sampleRate, int channels) = 0;
    virtual void onAccessUnit(const uint8_t* data, int len, bool ok) = 0;
    virtual void onSlide(const std::vector<uint8_t>& data, int contentSubType) = 0;
    virtual void onStatus(bool isError, const std::string& message) = 0;

    // FM (see FmSink); called on the FM thread.
    virtual void onFmAudio(const int16_t* /*pcm*/, int /*frames*/) {}
    virtual void onFmStatus(const FmStatus& /*status*/, float /*gainDb*/) {}
    virtual void onFmRds(int /*pi*/, const std::string& /*ps*/, const std::string& /*rt*/) {}

    // Narrowband (see NbSink); called on the NB thread. Report levels are
    // dBFS - subtract gainDb to refer them to the tuner input.
    virtual void onNbAudio(const int16_t* /*pcm*/, int /*frames*/) {}
    virtual void onNbReport(const NbReport& /*report*/, float /*gainDb*/) {}
    // A packet decoded from the NB audio (see Receiver::nbSetPacketDecoder):
    // kind 1 = AX.25 frame (APRS, FCS checked and removed), 2 = ACARS message
    // (SOH .. ETX/ETB + BCS, CRC checked).
    virtual void onNbPacket(int /*kind*/, const std::vector<uint8_t>& /*frame*/) {}
    // ADS-B / Mode S frame (see AdsbSink); called on the ADS-B thread.
    virtual void onAdsbFrame(const uint8_t* /*bytes*/, int /*length*/, uint32_t /*icao*/, float /*signalDbfs*/) {}
    // Data modes (ADS-B, ISM, ACARS), twice a second: samples per second
    // actually arriving, input level (dBFS), clipped share, tuner gain, and
    // for ACARS each channel's level (dB).
    virtual void onRxStatus(float /*samplesPerSecond*/, float /*levelDbfs*/, float /*clipRatio*/, float /*gainDb*/,
                            const std::vector<float>& /*channelLevelsDb*/)
    {
    }
    // ACARS message from the multi-channel mode (see AcarsSink).
    virtual void onAcarsFrame(uint32_t /*freqHz*/, const std::vector<uint8_t>& /*frame*/) {}
    // ISM sensor burst (see IsmSink); called on the ISM thread.
    virtual void onIsmBurst(const char* /*modulation*/, const std::vector<int>& /*durationsUs*/, float /*offsetHz*/,
                            float /*levelDb*/, float /*snrDb*/)
    {
    }
    // Fast spectrum for the waterfall (~20 Hz, NbDemod::kFastSpectrumBins
    // dBFS values across centerHz +- spanHz/2).
    virtual void onNbSpectrum(uint32_t /*centerHz*/, uint32_t /*spanHz*/, const std::vector<float>& /*binsDbfs*/,
                              float /*gainDb*/)
    {
    }
};

// Owns the whole receive chain: sample source -> OFDM thread -> decoder
// thread (FIC, selected sub-channel, DAB+ super frames, PAD), or, in FM
// mode, sample source -> FM thread (FmDemod), or, in narrowband mode,
// sample source -> NB thread (NbDemod). There is one stick, so the modes
// take turns: switching stops the other mode's threads. DAB runs at 2.048
// MS/s, FM at FmDemod::kRate (1.024 MS/s), NB at its own rate.
//
// The threads are decoupled by queues that drop instead of blocking, so a
// slow consumer (e.g. the audio output) can never stall the USB transfers
// or the OFDM synchronisation.
class Receiver : private OfdmSink, private FicListener, private SuperframeListener, private PadListener,
                 private IqReader, private FmSink, private NbSink, private AdsbSink, private IsmSink,
                 private AcarsSink {
public:
    Receiver(std::unique_ptr<SampleSource> source, ReceiverListener& listener);
    ~Receiver() override;

    // Retunes (starting streaming on first use, leaving FM mode) and forgets
    // the old ensemble.
    // keepIfTuned: when already receiving DAB on hz, only the service stops -
    // the ensemble collected so far stays (retries on a weak channel).
    bool tune(uint32_t hz, bool keepIfTuned = false);
    // Stops streaming and decoding until the next tune()/fmTune().
    void halt();

    // FM: tunes to a station (entering FM mode) and starts demodulating;
    // audio, status and RDS go to the listener's onFm* methods.
    bool fmTune(uint32_t hz);
    // FM: measures the spectrum around `centerHz` (entering FM mode, no
    // audio meanwhile) and returns the carriers found in [lowHz, highHz].
    // Blocks for ~0.3-1 s.
    bool fmSurvey(uint32_t centerHz, uint32_t lowHz, uint32_t highHz, std::vector<FmCarrier>& out);
    FmDemod::Info fmInfo() { return fm_.info(); }
    // {"valid","levelDb","snrDb","stereo","offsetHz","pilot","rdsSync","pi","ps","rt"};
    // levelDb is the channel power referred to the tuner input (dBFS minus
    // tuner gain), so it does not jump with the AGC. pi/ps/rt null if unknown.
    std::string fmInfoJson();
    // [{"freqKhz","levelDb","marginDb"}], levelDb as above.
    std::string fmCarriersJson(const std::vector<FmCarrier>& carriers);
    float gainDb() const { return source_->gainTenthsDb(gainIndex_) / 10.f; }

    // Narrowband: leaves DAB/FM, switches the stick to `sampleRate` (see
    // NbDemod::supportedRate), places the window around centerHz (or around
    // freqHz if that would fall outside), monitors channelsHz and plays
    // freqHz. Audio and reports go to the listener's onNb* methods.
    bool nbStart(uint32_t sampleRate, uint32_t centerHz, const std::vector<uint32_t>& channelsHz, uint32_t freqHz,
                 NbMode mode, float squelchDb);
    // Changes the listened channel/mode; moves the window if freqHz is
    // outside it. False when NB is not running.
    bool nbTune(uint32_t freqHz, NbMode mode);
    void nbSetSquelch(float squelchDb);
    // Tuner gain while listening: a gain step (0 = lowest) held fixed, or -1
    // for the automatic one. Takes effect on the NB thread's next level
    // report. Returns the step's gain in dB (or the current one for -1).
    float nbSetGain(int gainIndex);
    // Packet decoder on the listened channel's audio: 0 off, 1 APRS (AFSK
    // 1200), 2 ACARS (MSK 2400); frames go to the listener's onNbPacket.
    void nbSetPacketDecoder(int kind);
    // Signal filters (see NbFilters); kept across nbStart/nbTune.
    void nbSetFilters(const NbFilters& filters) { nb_.setFilters(filters); }
    // New window centre and/or monitored channels. The listened channel
    // stays; if it is outside the new window it is silent until nbTune.
    bool nbSetChannels(uint32_t centerHz, const std::vector<uint32_t>& channelsHz);

    // ADS-B / Mode S on 1090 MHz at 2 MS/s (leaves DAB/FM/NB); frames go
    // to the listener's onAdsbFrame. The gain follows nbSetGain. Stop with
    // halt().
    bool adsbStart();
    // ISM sensors (433,92 / 868,3 MHz) at 1,024 MS/s: bursts go to the
    // listener's onIsmBurst. Gain as nbSetGain; stop with halt().
    bool ismStart(uint32_t freqHz);
    // ACARS on several channels at once (no audio): messages go to the
    // listener's onAcarsFrame. Gain as nbSetGain; stop with halt().
    bool acarsStart(uint32_t centerHz, const std::vector<uint32_t>& channelsHz);

    // Starts decoding a service's audio. False while the FIC has not yet
    // described its sub-channel, or when it is not a DAB+ service.
    bool playService(uint32_t sid);
    void stopService();

    std::string ensembleLabel();
    std::string serviceListJson();

private:
    struct FrameItem {
        std::vector<int8_t> soft;
        uint32_t generation = 0;
        bool lost = false;   // gap in the frame timeline
        bool erased = false; // in the timeline, but no data (soft bits all 0)
    };
    // Reception statistics, logged every kStatsPeriod while DAB runs.
    struct Stats {
        std::atomic<int> framesOk{0};
        std::atomic<int> framesErased{0};
        std::atomic<int> gaps{0};
        std::atomic<int> syncLosses{0};
        std::atomic<int> queueDrops{0};
        std::atomic<int> gainChanges{0};
        std::atomic<float> snrDb{0};
        // decoder thread only
        int rsCorrected = 0;
        int rsUncorrectable = 0;
        int superframes = 0;
        int ficOkBase = 0;
        int ficBadBase = 0;
        int auErrorsBase = 0;
        int auTotal = 0;
        std::chrono::steady_clock::time_point since{};
    };
    struct ServiceRequest {
        int version = 0;
        bool active = false;
        Subchannel sub;
    };

    // OfdmSink
    void onFrame(const int8_t* soft) override;
    void onFrameLost(bool inTimeline) override;
    void onSync(bool synced) override;
    void onSnr(float snrDb) override;
    void onLevel(float rms, float clipRatio) override;
    void onReset() override;
    // FicListener
    void onEnsembleLabel(const std::string& label) override;
    void onServiceDetected(uint32_t sid) override;
    // SuperframeListener
    void onAudioParams(const AudioParams& params) override;
    void onAccessUnit(const uint8_t* data, int len, bool ok) override;
    void onSuperframeStats(bool rsUncorrectable, int rsCorrected) override;
    // PadListener
    void onDynamicLabel(const std::string& text) override;
    void onSlide(const std::vector<uint8_t>& data, int contentSubType) override;
    // IqReader
    int readIq(uint8_t* dst, int bytes) override;
    // FmSink
    bool onFmLevel(float rms, float clipRatio, bool settled) override;
    void onFmAudio(const int16_t* pcm, int frames) override;
    void onFmStatus(const FmStatus& status) override;
    void onFmRds(int pi, const std::string& ps, const std::string& rt) override;
    // NbSink
    bool onNbLevel(float rms, float clipRatio, bool settled) override;
    void onNbAudio(const int16_t* pcm, int frames) override;
    void onNbReport(const NbReport& report) override;
    void onNbSpectrum(uint32_t centerHz, uint32_t spanHz, const std::vector<float>& binsDbfs) override;
    // AdsbSink
    void onAdsbFrame(const uint8_t* bytes, int length, uint32_t icao, float signalDbfs) override;
    void onAdsbLevel(float rms, float clipRatio) override;
    // IsmSink
    void onIsmBurst(const char* modulation, const std::vector<int>& durationsUs, float offsetHz, float levelDb,
                    float snrDb) override;
    void onIsmLevel(float rms, float clipRatio) override;
    // AcarsSink
    void onAcarsFrame(uint32_t freqHz, const std::vector<uint8_t>& frame) override;
    void onAcarsLevel(float rms, float clipRatio) override;

    enum class Mode { Dab, Fm, Nb, Adsb, Ism, Acars };

    void statusTick(float rms, float clipRatio, const std::vector<float>& channelLevelsDb);
    // ADS-B automatic gain: this step (~40 dB on the R820T) and never above.
    static constexpr int kAdsbAutoGain = 22;
    std::atomic<long long> bytesRead_{0};
    std::chrono::steady_clock::time_point statusSince_{};
    double statusRmsSum_ = 0, statusClipSum_ = 0;
    int statusN_ = 0;

    bool startLocked(Mode mode);
    bool nbRetuneLocked(uint32_t centerHz);
    void nbConfigureLocked();
    void stopLocked();
    bool adjustGain(float rms, float clipRatio, bool settled, std::chrono::milliseconds searchInterval);
    void decoderLoop();
    void pushItem(const int8_t* soft, bool lost, bool erased);
    void applyServiceRequest();
    void logStats(bool force);

    std::unique_ptr<SampleSource> source_;
    ReceiverListener& listener_;
    ByteRing ring_;
    Ensemble ensemble_;
    OfdmDemod ofdm_;
    FicDecoder fic_;
    SubchannelDecoder sub_;
    SuperframeDecoder superframe_;
    PadDecoder pad_;
    FmDemod fm_;
    NbDemod nb_;
    AdsbDemod adsb_;
    IsmDemod ism_;
    AcarsMultiDemod acarsMulti_;

    std::mutex lifecycleMutex_;
    bool running_ = false;
    Mode mode_ = Mode::Dab; // of the running threads
    std::atomic<bool> stop_{false};
    std::thread ofdmThread_;
    std::thread decoderThread_;
    std::thread fmThread_;
    std::thread nbThread_;
    std::thread adsbThread_;
    std::thread ismThread_;
    std::thread acarsThread_;

    // Narrowband state (lifecycleMutex_)
    uint32_t nbRate_ = kSampleRate;
    uint32_t nbLoHz_ = 0;
    std::vector<uint32_t> nbChannels_;
    uint32_t nbFreqHz_ = 0;
    NbMode nbMode_ = NbMode::Auto;
    int nbRetune_ = 0;

    // Frames from before the latest tune() must not reach the decoders.
    std::atomic<uint32_t> generation_{0};
    std::atomic<uint32_t> ofdmGeneration_{0};

    std::mutex queueMutex_;
    std::condition_variable queueCv_;
    std::deque<FrameItem> queue_;
    std::vector<std::vector<int8_t>> pool_;

    std::mutex serviceMutex_;
    ServiceRequest request_;
    int appliedVersion_ = 0;       // decoder thread only
    bool serviceActive_ = false;   // decoder thread only
    std::atomic<bool> playing_{false};
    std::vector<uint8_t> cifBytes_;
    uint32_t decoderGeneration_ = 0; // decoder thread only

    // AGC (OFDM thread)
    std::atomic<int> gainIndex_{12};
    std::chrono::steady_clock::time_point lastGainChange_{};
    std::atomic<bool> synced_{false};
    uint32_t dabHz_ = 0;           // last DAB tune (lifecycleMutex_)
    // NB manual gain: step, -1 = automatic; pending until the NB thread
    // applies it (onNbLevel).
    std::atomic<int> nbManualGain_{-1};
    // Packet decoders (NB thread); packetKind_ set from any thread.
    std::unique_ptr<Afsk1200Decoder> afsk_;
    std::unique_ptr<AcarsDecoder> acars_;
    std::atomic<int> packetKind_{0};
    std::atomic<bool> nbGainPending_{false};

    // Error reporting (decoder thread)
    std::chrono::steady_clock::time_point lastRsReport_{};
    std::chrono::steady_clock::time_point lastAacReport_{};
    int auErrorsReported_ = 0;

    Stats stats_;
};

} // namespace hrdab
