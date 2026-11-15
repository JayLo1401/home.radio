// Test-only DMR transmitter: builds bursts with the encoders of dmr_fec -
// voice LC headers, voice superframes with embedded LC (and talker alias),
// terminator, idle bursts and the CACH of a repeater - carrying random
// AMBE+2 frames, and modulates them as 4FSK (root-raised-cosine shaped,
// 4800 symbols/s, +-648/1944 Hz) into 8-bit I/Q with noise.
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace hrdab::test {

// Repeater output: continuous, CACH between the bursts, idle bursts on a
// free slot. Radio (MS sourced) and TDMA direct mode: only the bursts of a
// call, the carrier off in between.
enum class DmrTxKind { Repeater, Radio, Direct };

struct DmrTxCall {
    int slot = 0;                 // 0/1
    bool group = true;
    uint32_t src = 2620001, dst = 262;
    std::string alias;            // 7-bit talker alias, "" = none
    bool header = true;           // voice LC headers first (else late entry)
    bool privacy = false;
    int superframes = 3;          // 360 ms each
    double startS = 0.3;          // first burst at or after this time
};

struct DmrTxConfig {
    uint32_t sampleRate = 2048000;
    double offsetHz = 0;          // carrier relative to the tuner
    double snrDb = 30;            // carrier vs. noise in 12.5 kHz
    DmrTxKind kind = DmrTxKind::Repeater;
    int colorCode = 1;
    double deviationScale = 1;
    double clockPpm = 0;          // symbol clock error of the transmitter
    double rms = 0.25;            // per component, of full scale
    unsigned seed = 7;
    std::vector<DmrTxCall> calls;
};

using AmbeBits = std::array<char, 49>;

struct DmrTx {
    std::vector<int8_t> symbols;          // +-1/+-3 at 4800/s
    std::vector<uint8_t> on;              // carrier on, per symbol
    std::vector<AmbeBits> frames[2];      // AMBE+2 data sent on each slot, in order
};

DmrTx buildDmr(const DmrTxConfig& cfg, double seconds);
std::vector<uint8_t> modulateDmr(const DmrTxConfig& cfg, const DmrTx& tx);
// The transmitter's frequency deviation (Hz) at `rate` - what an ideal FM
// discriminator gives.
std::vector<float> dmrDeviationHz(const DmrTx& tx, int rate, double deviationScale = 1);

// AMBE+2 frame encoding as mbelib expects it (Golay 24/23 + scrambling of
// C1, then the over-the-air order), for the unit tests.
void ambeEncode(const AmbeBits& data, uint8_t* tx72);

} // namespace hrdab::test
