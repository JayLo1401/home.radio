#pragma once

#include <cstdint>

namespace hrdab {

// RS(120,110) as used by DAB+ superframes (TS 102 563 clause 6.1): a
// shortened RS(255,245) over GF(2^8) with field polynomial
// x^8+x^4+x^3+x^2+1 and generator roots alpha^0..alpha^9.
class ReedSolomon {
public:
    static constexpr int kN = 120;
    static constexpr int kK = 110;
    static constexpr int kParity = kN - kK;

    ReedSolomon();

    // Corrects `codeword` (120 bytes, parity last) in place. Returns the
    // number of corrected bytes, or -1 if uncorrectable.
    int decode(uint8_t* codeword) const;

    // Fills codeword[110..119] from codeword[0..109] (self tests).
    void encode(uint8_t* codeword) const;

private:
    uint8_t mul(uint8_t a, uint8_t b) const
    {
        return (a && b) ? exp_[log_[a] + log_[b]] : 0;
    }
    uint8_t inv(uint8_t a) const { return exp_[255 - log_[a]]; }

    uint8_t exp_[512];
    uint8_t log_[256];
    uint8_t gen_[kParity + 1];
};

} // namespace hrdab
