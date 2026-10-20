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
#include "msc.h"
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
};

// Owns the whole receive chain: sample source -> OFDM thread -> decoder
// thread (FIC, selected sub-channel, DAB+ super frames, PAD).
//
// The threads are decoupled by queues that drop instead of blocking, so a
// slow consumer (e.g. the audio output) can never stall the USB transfers
// or the OFDM synchronisation.
class Receiver : private OfdmSink, private FicListener, private SuperframeListener, private PadListener,
                 private IqReader {
public:
    Receiver(std::unique_ptr<SampleSource> source, ReceiverListener& listener);
    ~Receiver() override;

    // Retunes (starting streaming on first use) and forgets the old ensemble.
    bool tune(uint32_t hz);
    // Stops streaming and decoding until the next tune().
    void halt();

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
        bool lost = false;
    };
    struct ServiceRequest {
        int version = 0;
        bool active = false;
        Subchannel sub;
    };

    // OfdmSink
    void onFrame(const int8_t* soft) override;
    void onFrameLost() override;
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

    bool startLocked();
    void stopLocked();
    void decoderLoop();
    void pushItem(const int8_t* soft, bool lost);
    void applyServiceRequest();

    std::unique_ptr<SampleSource> source_;
    ReceiverListener& listener_;
    ByteRing ring_;
    Ensemble ensemble_;
    OfdmDemod ofdm_;
    FicDecoder fic_;
    SubchannelDecoder sub_;
    SuperframeDecoder superframe_;
    PadDecoder pad_;

    std::mutex lifecycleMutex_;
    bool running_ = false;
    std::atomic<bool> stop_{false};
    std::thread ofdmThread_;
    std::thread decoderThread_;

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
};

} // namespace hrdab
