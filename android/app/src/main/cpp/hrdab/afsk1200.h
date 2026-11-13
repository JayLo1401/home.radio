// AFSK 1200 baud (Bell 202: mark 1200 Hz, space 2200 Hz) packet decoder -
// APRS and packet radio on FM. Demodulated audio in, AX.25 frames out
// (address, control, PID, info; FCS checked and removed).
//
// Tone correlators over one bit, a digital PLL for the bit clock, NRZI and
// HDLC (flags, bit stuffing, CRC-16/X.25). Radios send with pre-emphasis
// (or not), so the two tones arrive with different levels - several
// slicers with different mark/space weights run side by side and the first
// good copy of a frame wins.
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

namespace hrdab {

class Afsk1200Decoder {
public:
    using FrameCallback = std::function<void(const std::vector<uint8_t>& frame)>;

    explicit Afsk1200Decoder(int sampleRate);

    // Mono samples; onFrame is called for every frame with a valid FCS.
    void process(const int16_t* pcm, int n, const FrameCallback& onFrame);
    void reset();

    // CRC-16/X.25 as used by AX.25 (for tests and the encoder).
    static uint16_t crc(const uint8_t* data, size_t n);

private:
    struct Slicer {
        float spaceWeight = 1.f;
        int32_t pll = 0;
        bool lastDemod = false;
        bool lastBit = false;    // NRZI reference
        int ones = 0;
        std::vector<uint8_t> bits;
        bool inFrame = false;
    };

    void bit(Slicer& s, bool b, const FrameCallback& onFrame);
    void frameEnd(Slicer& s, const FrameCallback& onFrame);

    int rate_;
    int window_;                 // samples per bit
    int32_t pllStep_;
    // Tone oscillators and sliding correlations (one bit long).
    double markPhase_ = 0, spacePhase_ = 0, markInc_, spaceInc_;
    std::vector<float> ring_[4];  // mark I/Q, space I/Q products
    double sum_[4] = {0, 0, 0, 0};
    int pos_ = 0;
    std::vector<Slicer> slicers_;

    // Duplicate suppression between slicers.
    long long sampleCount_ = 0;
    struct Recent {
        std::vector<uint8_t> frame;
        long long at;
    };
    std::vector<Recent> recent_;
};

// Test helper: the audio a packet radio would send for `frame` (address ..
// info, without FCS) at `sampleRate`, with flags around it.
std::vector<int16_t> afsk1200Encode(const std::vector<uint8_t>& frame, int sampleRate, float spaceGain = 1.f);

} // namespace hrdab
