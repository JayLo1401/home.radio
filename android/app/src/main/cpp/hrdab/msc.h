#pragma once

#include <cstdint>
#include <vector>

#include "dab_tables.h"
#include "ensemble.h"
#include "viterbi.h"

namespace hrdab {

// One MSC sub-channel: time de-interleaving (EN 300 401 clause 12), EEP
// depuncturing + Viterbi (clause 11.3.2) and energy dispersal.
class SubchannelDecoder {
public:
    bool configure(const Subchannel& sc);
    void reset();
    bool configured() const { return bits_ > 0; }
    int bitrateKbps() const { return profile_.bitrateKbps; }
    const Subchannel& subchannel() const { return sub_; }

    // cif: the 55296 soft bits of one common interleaved frame. Returns
    // true and fills `out` (bitrate * 3 bytes) once the de-interleaver has
    // seen enough CIFs.
    bool processCif(const int8_t* cif, std::vector<uint8_t>& out);

private:
    Subchannel sub_;
    EepProfile profile_;
    int softLen_ = 0;   // sizeCu * 64
    int bits_ = 0;      // information bits per CIF
    std::vector<int8_t> history_; // 16 CIFs of this sub-channel, ring
    int newest_ = 0;
    int filled_ = 0;
    std::vector<int8_t> deinterleaved_;
    std::vector<int8_t> mother_;
    std::vector<uint8_t> decoded_;
    Viterbi viterbi_;
};

} // namespace hrdab
