// ISM band sensors (433,92 / 868,3 MHz): finds the short data bursts of
// wireless thermometers, weather stations and the like, and hands them on
// as pulse trains - the protocols themselves are decoded on the app side.
//
// 1,024 MS/s in, averaged down to 256 kS/s (~4 us resolution). An envelope
// detector with an adaptive noise floor marks the bursts: OOK sensors come
// out as pulse/gap durations. A burst that is one long carrier is FSK - its
// instantaneous frequency is sliced around its middle into high/low runs,
// which come out the same way.
#pragma once

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

#include "ofdm.h"  // IqReader

namespace hrdab {

class IsmSink {
public:
    virtual ~IsmSink() = default;
    // One burst: "ook" or "fsk", alternating high/low durations in
    // microseconds (starting with high), the carrier's offset from the tuned
    // frequency, its level and SNR (dB).
    virtual void onIsmBurst(const char* modulation, const std::vector<int>& durationsUs, float offsetHz,
                            float levelDb, float snrDb) = 0;
    // Input level per read, for the AGC.
    virtual void onIsmLevel(float rms, float clipRatio) = 0;
};

class IsmDemod {
public:
    static constexpr uint32_t kSampleRate = 1024000;
    static constexpr int kDecimation = 4;  // -> 256 kS/s

    IsmDemod(IqReader& reader, IsmSink& sink);

    // Thread body; returns once `stop` is set.
    void run(const std::atomic<bool>& stop);

    // Feeds decimated complex samples (for tests): interleaved I/Q floats.
    void process(const float* iq, int n);

private:
    void pulseEnd(int samples);
    void burstEnd();

    IqReader& reader_;
    IsmSink& sink_;

    // Envelope state
    double noise_ = 0;           // noise floor (power), 0 = not yet known
    double env_ = 0;             // smoothed envelope (power)
    int warmup_ = 0;             // samples measured before detecting
    double recent_ = 0;          // peak of the last pulse, decaying
    bool high_ = false;
    int run_ = 0;                // samples in the current high/low state
    double peak_ = 0;            // of the current pulse
    float prevI_ = 0, prevQ_ = 0;

    // Burst being collected
    bool inBurst_ = false;
    std::vector<int> durations_;  // samples, alternating high/low
    double sigSum_ = 0;
    long sigN_ = 0;
    double freqSum_ = 0;
    std::vector<float> pulseFreq_;    // instantaneous frequency in the current pulse
    std::vector<float> longestFreq_;  // ... of the burst's longest pulse
};

} // namespace hrdab
