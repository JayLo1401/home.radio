// ACARS (ARINC 618) on the AM-demodulated audio of a VHF channel: MSK at
// 2400 bit/s (1200/2400 Hz around 1800 Hz). Messages out from SOH to ETX/ETB
// plus the two BCS bytes, only when the CRC checks out.
//
// Differential detection over one bit (the phase turns +-90 degrees per bit
// around 1800 Hz), a PLL for the bit clock, then the character framing:
// "+*" SYN SYN SOH starts a message, 7 data bits + odd parity per character,
// LSB first. Polarity and differential coding are not assumed - four
// variants run side by side and the first good copy wins.
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

namespace hrdab {

class AcarsDecoder {
public:
    using FrameCallback = std::function<void(const std::vector<uint8_t>& frame)>;

    explicit AcarsDecoder(int sampleRate);

    void process(const int16_t* pcm, int n, const FrameCallback& onFrame);

    // CRC-16 as used for the block check sequence (reflected CCITT, init 0).
    static uint16_t crc(const uint8_t* data, size_t n);

private:
    struct Framer {
        bool invert = false;
        bool differential = false;
        bool lastRaw = false;
        uint64_t shift = 0;        // last raw bits, newest in the top
        bool inFrame = false;
        int bitCount = 0;
        uint8_t cur = 0;
        std::vector<uint8_t> bytes;
        int trailer = -1;          // BCS bytes still to come after ETX/ETB
    };

    void bit(bool raw, const FrameCallback& onFrame);
    void framerBit(Framer& f, bool b, const FrameCallback& onFrame);

    int rate_;
    int window_;                   // samples per bit
    double phase_ = 0, phaseInc_;
    std::vector<float> ringI_, ringQ_;  // mixed-down samples, one bit long
    double sumI_ = 0, sumQ_ = 0;
    std::vector<float> histI_, histQ_;  // filtered outputs, one bit ago
    int pos_ = 0;
    int32_t pll_ = 0;
    int32_t pllStep_;
    bool lastDemod_ = false;
    std::vector<Framer> framers_;
    std::vector<std::vector<uint8_t>> recent_;
};

// Test helper: MSK audio of a message (bytes from SOH on, BCS appended)
// with the usual pre-key and sync in front.
std::vector<int16_t> acarsEncode(const std::vector<uint8_t>& sohToEtx, int sampleRate);

} // namespace hrdab
