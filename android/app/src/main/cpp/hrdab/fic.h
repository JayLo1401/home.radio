#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "common.h"
#include "ensemble.h"
#include "viterbi.h"

namespace hrdab {

class FicListener {
public:
    virtual ~FicListener() = default;
    virtual void onEnsembleLabel(const std::string& label) = 0;
    virtual void onServiceDetected(uint32_t sid) = 0;
};

// Fast information channel: depuncturing, Viterbi, energy dispersal, FIB CRC
// check and FIG parsing (EN 300 401 clauses 5.2, 6, 8 and 11.2).
class FicDecoder {
public:
    FicDecoder(Ensemble& ensemble, FicListener& listener);

    // soft: the 3 FIC symbols of one transmission frame (9216 soft bits).
    void processFrame(const int8_t* soft);

    // Feeds one already-decoded FIB (32 bytes incl. CRC); used by the tests.
    bool processFib(const uint8_t* fib);

    int fibsOk() const { return fibsOk_; }
    int fibsBad() const { return fibsBad_; }
    void resetStats() { fibsOk_ = fibsBad_ = 0; }

private:
    void fig0(const uint8_t* d, int len);
    void fig1(const uint8_t* d, int len);

    Ensemble& ensemble_;
    FicListener& listener_;
    Viterbi viterbi_;
    std::vector<int8_t> mother_;
    std::vector<uint8_t> bits_;
    int fibsOk_ = 0;
    int fibsBad_ = 0;
};

} // namespace hrdab
