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

#include "byte_ring.h"
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
};

// Owns the whole receive chain: sample source -> OFDM thread -> decoder
// thread (FIC, selected sub-channel, DAB+ super frames, PAD), or, in FM
// mode, sample source -> FM thread (FmDemod), or, in narrowband mode,
// sample source -> NB thread (NbDemod). There is one stick, so the modes
// take turns: switching stops the other mode's threads. DAB and FM always
// run at 2.048 MS/s; NB sets its own rate and the others restore theirs.
//
// The threads are decoupled by queues that drop instead of blocking, so a
// slow consumer (e.g. the audio output) can never stall the USB transfers
// or the OFDM synchronisation.
class Receiver : private OfdmSink, private FicListener, private SuperframeListener, private PadListener,
                 private IqReader, private FmSink, private NbSink {
public:
    Receiver(std::unique_ptr<SampleSource> source, ReceiverListener& listener);
    ~Receiver() override;

    // Retunes (starting streaming on first use, leaving FM mode) and forgets
    // the old ensemble.
    bool tune(uint32_t hz);
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
    // Signal filters (see NbFilters); kept across nbStart/nbTune.
    void nbSetFilters(const NbFilters& filters) { nb_.setFilters(filters); }
    // New window centre and/or monitored channels. The listened channel
    // stays; if it is outside the new window it is silent until nbTune.
    bool nbSetChannels(uint32_t centerHz, const std::vector<uint32_t>& channelsHz);

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

    enum class Mode { Dab, Fm, Nb };

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

    std::mutex lifecycleMutex_;
    bool running_ = false;
    Mode mode_ = Mode::Dab; // of the running threads
    std::atomic<bool> stop_{false};
    std::thread ofdmThread_;
    std::thread decoderThread_;
    std::thread fmThread_;
    std::thread nbThread_;

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

    // Error reporting (decoder thread)
    std::chrono::steady_clock::time_point lastRsReport_{};
    std::chrono::steady_clock::time_point lastAacReport_{};
    int auErrorsReported_ = 0;

    Stats stats_;
};

} // namespace hrdab
