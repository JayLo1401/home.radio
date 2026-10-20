// Test-only DAB+ transmitter: builds a complete mode I ensemble signal
// (FIC with FIG 0/0, 0/1, 0/2, 1/0, 1/1; one DAB+ sub-channel with super
// frames, PAD with dynamic label and a MOT slide) and passes it through a
// simple channel model (carrier offset, sample clock offset, echo, noise).
#pragma once

#include <cstdint>
#include <functional>
#include <random>
#include <string>
#include <vector>

#include "common.h"
#include "fft.h"

namespace hrdab::test {

struct TxConfig {
    uint16_t eid = 0x10A5;
    std::string ensembleLabel = "HR Test Mux";
    uint16_t sid = 0xD3A1;
    std::string serviceLabel = "Radio \x91\x97\x99 Test"; // EBU Latin a/o/u umlauts
    uint16_t sid2 = 0xD3A2;                                // second, listed only
    std::string serviceLabel2 = "Zweites Prog";
    int subchId = 3;
    int startCu = 100;
    int bitrateKbps = 96;     // EEP-3A
    int level = 2;            // protection level 3
    bool sbr = true;          // HE-AAC
    bool dac48k = true;
    bool stereo = true;
    bool ps = false;
    std::string dls = "Hallo Welt - integrierter DAB+ Empf\x91nger";
    std::vector<uint8_t> slide;  // MOT slideshow body (JPEG bytes), empty = none

    // channel
    double freqOffsetHz = 4321.0;
    double clockPpm = 30.0;
    double snrDb = 14.0;
    double echoDelay = 23.0;     // samples
    double echoGain = 0.3;
    double rms = 0.22;           // of full scale before quantisation
    unsigned seed = 1234;
};

// Supplies the AU payloads (without CRC) of one super frame; `sizes` are
// the exact payload sizes available. The default fills random bytes after
// the PAD data stream element.
using AuProvider = std::function<std::vector<std::vector<uint8_t>>(int numAus, int capacityBytes)>;

class TxSim {
public:
    explicit TxSim(const TxConfig& cfg);

    // Generates `frames` transmission frames of 8-bit I/Q.
    std::vector<uint8_t> generate(int frames);

    void setAuProvider(AuProvider p) { auProvider_ = std::move(p); }

    // Every AU payload that was sent, in order (for comparison).
    const std::vector<std::vector<uint8_t>>& sentAus() const { return sentAus_; }
    int auPerSuperframe() const;
    // Coded bits (75 x 3072) of every generated frame.
    std::vector<std::vector<uint8_t>> frameBits;

private:
    std::vector<uint8_t> buildFib(int fibIndex);
    void encodeFic(std::vector<uint8_t>& frameBits);
    void encodeMscCif(std::vector<uint8_t>& cifBits);
    std::vector<uint8_t> nextLogicalFrame();
    void buildSuperframe();
    std::vector<uint8_t> makePad(int capacity);
    void modulateFrame(const std::vector<uint8_t>& bits, std::vector<cf32>& out);
    void channel(const std::vector<cf32>& in, std::vector<uint8_t>& out);

    TxConfig cfg_;
    Fft fft_;
    std::mt19937 rng_;
    AuProvider auProvider_;

    int cifCount_ = 0;
    std::vector<std::vector<uint8_t>> logicalFrames_; // pending, from super frames
    std::vector<std::vector<uint8_t>> interleaveHist_; // last 16 logical frames (coded bits)
    std::vector<std::vector<uint8_t>> sentAus_;

    // PAD scheduler state
    struct PadStream {
        int startApp, contApp;
        std::vector<uint8_t> bytes;
        size_t pos = 0;
    };
    std::vector<PadStream> padQueue_;
    int padRound_ = 0;

    // channel state
    double phase_ = 0;
    double resamplePos_ = 0;
    std::vector<cf32> history_;
    std::vector<cf32> rawTail_;
    double gain_ = 0;
};

} // namespace hrdab::test
