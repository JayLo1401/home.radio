// RDS (Radio Data System, EN 50067 / IEC 62106) for the FM receiver: the
// 57 kHz BPSK demodulator working on the 256 kHz MPX signal, and the block /
// group decoder for PI, programme service name (PS) and RadioText (RT).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "fm_dsp.h"

namespace hrdab {

// Offset words of the five block positions.
enum RdsOffset { kRdsA = 0, kRdsB = 1, kRdsC = 2, kRdsCPrime = 3, kRdsD = 4 };

// The 10-bit check word of a block: CRC of the 16 info bits (generator
// x^10+x^8+x^7+x^5+x^4+x^3+1) plus the offset word of its position.
uint16_t rdsCheckword(uint16_t info, RdsOffset offset);

// 57 kHz subcarrier -> data bits. The carrier phase is recovered by a Costas
// loop on the RDS signal itself (not from the pilot), so mono stations
// without a pilot tone decode as well. Bit timing: correlation with one
// biphase symbol and an early/late gate.
class RdsDemod {
public:
    RdsDemod();
    void reset();
    // `mpx` at 256 kHz; appends the differentially decoded data bits (0/1).
    void process(const float* mpx, int n, std::vector<uint8_t>& bits);

private:
    void symbolSample(float x, std::vector<uint8_t>& bits);
    float matchedAt(double t) const;

    uint32_t ncoPhase_ = 0;
    FirDecimator<2> dec8_;   // 256 kHz -> 32 kHz
    FirDecimator<2> dec2_;   // 32 kHz -> 16 kHz
    std::vector<float> mix_, bb32_, bb16_;

    // Costas loop (16 kHz)
    double psi_ = 0, nu_ = 0;
    float power_ = 0;

    // matched filter / timing (16 kHz)
    static constexpr int kHist = 64;
    float x_[kHist] = {};
    float m_[kHist] = {};
    long n_ = 0;            // samples seen
    double next_ = 0;       // index (into m) of the next bit decision
    double period_ = 0;     // samples per bit
    float avgAbs_ = 0;
    int prevBit_ = 0;
};

// Blocks -> groups -> PI / PS / RT.
class RdsDecoder {
public:
    RdsDecoder() { reset(); }
    void reset();
    void pushBit(int bit);

    // True once since the last call if PI, PS or RT changed.
    bool takeChanged()
    {
        const bool c = changed_;
        changed_ = false;
        return c;
    }
    bool synced() const { return synced_; }
    int pi() const { return pi_; }                 // -1 = not (yet) known
    const std::string& ps() const { return ps_; }  // UTF-8, empty = not known
    const std::string& rt() const { return rt_; }  // UTF-8, empty = not known

    // statistics (tests / logging)
    int groups = 0, blocksOk = 0, blocksCorrected = 0, blocksBad = 0;

private:
    void block(int pos, uint32_t raw);
    void processGroup();
    void piCandidate(uint16_t pi);
    void psChars(int pos, uint8_t c0, uint8_t c1);
    void rtChars(bool versionB, int ab, int segment, const uint8_t* chars, int n);

    uint32_t reg_ = 0;
    long bitCount_ = 0;
    bool synced_ = false;
    int expect_ = 0;
    int bitsInBlock_ = 0;
    uint64_t errHist_ = 0;
    struct Seen {
        long at;
        int pos;
    };
    std::vector<Seen> seen_;

    uint16_t group_[4] = {};
    bool valid_[4] = {};
    bool cPrime_ = false;

    int pi_ = -1;
    int piCandidate_ = -1;
    int piCount_ = 0;

    uint8_t psPending_[8] = {};
    uint8_t psCount_[8] = {};
    uint8_t psConfirmed_[8] = {};
    bool psHave_[8] = {};
    std::string ps_;

    uint8_t rtBuf_[64] = {};
    uint32_t rtMask_ = 0;
    int rtAb_ = -1;
    bool rtVersionB_ = false;
    std::string rt_;
    // A segment's content and the A/B flag only count once received twice
    // in a row (see rtChars) - like the PS characters.
    uint8_t rtPending_[16][4] = {};
    uint8_t rtPendingCount_[16] = {};
    int rtAbPending_ = -1;
    int rtAbCount_ = 0;

    bool changed_ = false;
};

} // namespace hrdab
