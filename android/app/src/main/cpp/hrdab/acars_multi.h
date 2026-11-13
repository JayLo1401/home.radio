// ACARS on several VHF channels at once (the European ones lie within
// ~330 kHz): one stick window, each channel mixed down, decimated to
// 48 kHz, filtered to +-5 kHz, AM-demodulated and fed to its own
// AcarsDecoder. No audio - only the messages.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

#include "acars.h"
#include "ofdm.h"  // IqReader

namespace hrdab {

class AcarsSink {
public:
    virtual ~AcarsSink() = default;
    // A message (SOH .. ETX/ETB + BCS, CRC checked) on channel freqHz.
    virtual void onAcarsFrame(uint32_t freqHz, const std::vector<uint8_t>& frame) = 0;
    // Input level per read, for the AGC.
    virtual void onAcarsLevel(float rms, float clipRatio) = 0;
};

class AcarsMultiDemod {
public:
    // 24 x 48 kHz: each channel decimates by an integer to 48 kHz.
    static constexpr uint32_t kSampleRate = 1152000;
    static constexpr int kDecimation = 24;
    static constexpr int kAudioRate = 48000;

    AcarsMultiDemod(IqReader& reader, AcarsSink& sink);

    // Before run(): tuner frequency and the channels (within +-450 kHz).
    void configure(uint32_t centerHz, const std::vector<uint32_t>& channelsHz);

    // Thread body; returns once `stop` is set.
    void run(const std::atomic<bool>& stop);

    // Feeds raw 8-bit I/Q (for tests).
    void process(const uint8_t* iq, int samples);

    // Each channel's strongest carrier level (dBFS) since the last call, in
    // configure() order; call on the demodulator's thread.
    std::vector<float> channelLevelsDb();

private:
    struct Channel {
        uint32_t freqHz = 0;
        uint32_t phase = 0, inc = 0;      // NCO (2^32 = one turn)
        // CIC order 2 (wrapping integer arithmetic)
        int64_t i1 = 0, q1 = 0, i2 = 0, q2 = 0;
        int64_t ci1 = 0, cq1 = 0, ci2 = 0, cq2 = 0;
        int count = 0;
        // Channel filter at 48 kHz
        std::vector<float> hi, hq;
        int hpos = 0;
        // AM: carrier level
        float carrier = 0;
        float peak = 0;  // strongest carrier since channelLevelsDb()
        std::vector<int16_t> pcm;
        std::unique_ptr<AcarsDecoder> decoder;
    };

    void output(Channel& c, float i, float q);

    IqReader& reader_;
    AcarsSink& sink_;
    std::vector<Channel> channels_;
    std::vector<float> fir_;
    std::vector<int16_t> cos_, sin_;  // NCO table
};

} // namespace hrdab
