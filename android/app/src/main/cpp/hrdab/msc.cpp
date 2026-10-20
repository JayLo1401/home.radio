#include "msc.h"

#include <cstring>

namespace hrdab {

namespace {

// The transmitter delays bit i of a logical frame by kInterleaveDelay[i % 16]
// CIFs, so the frame that becomes complete with the newest CIF has bit i in
// the CIF that arrived 15 - delay CIFs ago.
const int kInterleaveDelay[16] = {0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15};

} // namespace

bool SubchannelDecoder::configure(const Subchannel& sc)
{
    bits_ = 0;
    if (!sc.eep || !eepProfile(sc.optionB, sc.level, sc.sizeCu, profile_)) return false;
    if (sc.startCu + sc.sizeCu > kCusPerCif) return false;
    sub_ = sc;
    softLen_ = sc.sizeCu * kCuBits;
    bits_ = (profile_.l1 + profile_.l2) * 32;
    history_.assign(static_cast<size_t>(16 * softLen_), 0);
    deinterleaved_.assign(static_cast<size_t>(softLen_), 0);
    mother_.assign(static_cast<size_t>(4 * (bits_ + 6)), 0);
    decoded_.assign(static_cast<size_t>(bits_), 0);
    reset();
    return true;
}

void SubchannelDecoder::reset()
{
    newest_ = 0;
    filled_ = 0;
}

bool SubchannelDecoder::processCif(const int8_t* cif, std::vector<uint8_t>& out)
{
    if (!bits_) return false;
    newest_ = (newest_ + 1) & 15;
    std::memcpy(&history_[static_cast<size_t>(newest_ * softLen_)], cif + sub_.startCu * kCuBits,
                static_cast<size_t>(softLen_));
    if (filled_ < 16) filled_++;
    if (filled_ < 16) return false;

    for (int i = 0; i < softLen_; i++) {
        const int slot = (newest_ - (15 - kInterleaveDelay[i & 15])) & 15;
        deinterleaved_[static_cast<size_t>(i)] = history_[static_cast<size_t>(slot * softLen_ + i)];
    }

    const auto& pi1 = puncturingVector(profile_.pi1);
    const auto& pi2 = puncturingVector(profile_.pi2);
    const int8_t* in = deinterleaved_.data();
    int8_t* m = mother_.data();
    in += depuncture(in, pi1.data(), 32, profile_.l1 * 128, m);
    m += profile_.l1 * 128;
    in += depuncture(in, pi2.data(), 32, profile_.l2 * 128, m);
    m += profile_.l2 * 128;
    depuncture(in, puncturingTail().data(), 24, 24, m);

    viterbi_.decode(mother_.data(), bits_, decoded_.data());
    energyDispersal(decoded_.data(), bits_);

    out.resize(static_cast<size_t>(bits_ / 8));
    for (int i = 0; i < bits_ / 8; i++) {
        uint8_t v = 0;
        for (int b = 0; b < 8; b++) v = static_cast<uint8_t>((v << 1) | decoded_[static_cast<size_t>(i * 8 + b)]);
        out[static_cast<size_t>(i)] = v;
    }
    return true;
}

} // namespace hrdab
