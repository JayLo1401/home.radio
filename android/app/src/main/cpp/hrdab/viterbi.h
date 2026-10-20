#pragma once

#include <cstdint>
#include <vector>

namespace hrdab {

// Soft-decision Viterbi decoder for the DAB mother code (EN 300 401 clause
// 11.1.1): rate 1/4, constraint length 7, generators 133, 171, 145, 133
// (octal), terminated with 6 zero tail bits.
//
// Soft values: int8, > 0 means "probably 1", < 0 "probably 0", 0 = erased
// (punctured).
class Viterbi {
public:
    Viterbi();

    // soft holds 4 * (bits + 6) values; writes `bits` decoded bits (0/1 per
    // byte) to out.
    void decode(const int8_t* soft, int bits, uint8_t* out);

    // Reference encoder, used for the error count of the last decode and
    // by the self tests: writes 4 * (bits + 6) code bits.
    static void encode(const uint8_t* bits, int count, uint8_t* out);

private:
    uint8_t outputs_[128]; // 4 code bits for each 7-bit encoder word
    std::vector<uint64_t> decisions_;
};

// Expands a punctured block back to the mother code rate, writing 0
// (erasure) where bits were punctured. Returns soft values consumed.
// `pattern` is a keep/drop flag sequence applied cyclically over `outCount`.
int depuncture(const int8_t* in, const uint8_t* pattern, int patternLen, int outCount, int8_t* out);

} // namespace hrdab
