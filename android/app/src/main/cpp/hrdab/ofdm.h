#pragma once

#include <atomic>
#include <cstdint>
#include <vector>

#include "common.h"
#include "fft.h"

namespace hrdab {

// Blocking source of interleaved 8-bit unsigned I/Q bytes at 2.048 MS/s.
class IqReader {
public:
    virtual ~IqReader() = default;
    // Fills exactly `bytes` bytes unless aborted; returns the count filled.
    virtual int readIq(uint8_t* dst, int bytes) = 0;
};

class OfdmSink {
public:
    virtual ~OfdmSink() = default;
    // 75 data symbols worth of soft bits (FIC first), see kFrameSoftBits.
    virtual void onFrame(const int8_t* soft) = 0;
    // A frame could not be demodulated. `inTimeline`: the lock is kept and
    // the next frame follows this one seamlessly, so the decoders can treat
    // it as an erasure (all soft bits 0) instead of a gap in the timeline.
    virtual void onFrameLost(bool inTimeline) = 0;
    virtual void onSync(bool synced) = 0;
    virtual void onSnr(float snrDb) = 0;
    // Input level once per ~100 ms: RMS of the raw samples (0..1 full scale)
    // and the fraction of clipped bytes.
    virtual void onLevel(float rms, float clipRatio) = 0;
    // A requestReset() took effect: everything delivered from now on stems
    // from samples taken after it.
    virtual void onReset() {}
};

// Mode I OFDM receiver: null-symbol detection, fractional frequency offset
// from the cyclic prefix, integer offset and fine timing from the phase
// reference symbol, then FFT + differential QPSK demodulation and frequency
// de-interleaving into soft bits.
class OfdmDemod {
public:
    OfdmDemod(IqReader& reader, OfdmSink& sink);

    // Thread body; returns once the reader is aborted or `stop` is set.
    void run(const std::atomic<bool>& stop);

    // Discard buffered samples and re-acquire (after a retune). The carrier
    // offset is kept in ppm, as it mostly comes from the stick's crystal.
    void requestReset(uint32_t tunedHz);

    float frequencyOffsetHz() const { return static_cast<float>(freqOffsetHz_); }
    // Of the last demodulated frame (diagnostics): sample clock offset from
    // the carrier phase slope, and the common phase error per symbol.
    float sampleClockPpm() const { return slopePpm_; }
    float commonPhaseDeg() const { return commonDeg_; }
    float lastTimingStep() const { return lastTimingStep_; }

private:
    bool ensure(size_t count);
    void consume(long n);
    void remix(size_t from, double hz);
    void spectrumAt(size_t pos, cf32* out);
    bool impulse(const cf32* spectrum, int& peak, float& quality);
    float cyclicPrefixOffsetHz(size_t frameStart, int timingShift);
    int coarseOffset(const cf32* spectrum, float& quality);
    bool acquire();
    bool demodulateFrame();
    void doReset();

    IqReader& reader_;
    OfdmSink& sink_;
    Fft fft_;
    std::vector<float> lut_;

    std::vector<cf32> stash_;
    size_t head_ = 0;
    std::vector<uint8_t> raw_;

    double freqOffsetHz_ = 0;
    double ncoPhase_ = 0;
    uint32_t tunedHz_ = 0;

    std::atomic<bool> resetRequested_{false};
    std::atomic<uint32_t> pendingTunedHz_{0};
    bool locked_ = false;
    bool reportedSync_ = false;
    int misses_ = 0;
    int searchFailures_ = 0;

    std::vector<cf32> prs_;
    std::vector<cf32> cur_;
    std::vector<cf32> prev_;
    std::vector<cf32> work_;
    std::vector<int8_t> soft_;
    std::vector<cf32> refDiff_;
    std::vector<cf32> diff_;      // differential products of a frame, natural carrier order
    std::vector<cf32> phaseFix_;  // per-carrier phase correction of the current frame
    std::vector<cf32> carrierSum_;
    cf32 slopeState_{1, 0};       // smoothed exp(j 4 slope lag); kept across retunes (same crystal)
    // statistics
    double levelSumSq_ = 0;
    long levelClipped_ = 0;
    long levelCount_ = 0;
    double snrAcc_ = 0;
    int snrCount_ = 0;
    int dbgFrames_ = 0;
    int skipSamples_ = 0;
    long absPos_ = 0; // samples consumed since start (diagnostics)
    std::atomic<float> slopePpm_{0};
    std::atomic<float> commonDeg_{0};
    std::atomic<float> lastTimingStep_{0};
};

} // namespace hrdab
