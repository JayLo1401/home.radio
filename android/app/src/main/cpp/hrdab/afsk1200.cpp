#include "afsk1200.h"

#include <algorithm>
#include <cmath>

namespace hrdab {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kBaud = 1200;
constexpr double kMarkHz = 1200.0, kSpaceHz = 2200.0;
// PLL pull towards a demodulator transition (1 = none, 0 = snap).
constexpr double kPllInertia = 0.74;
constexpr size_t kMinFrame = 17;      // 2 addresses + control + FCS (+ at least PID-less)
constexpr size_t kMaxFrameBits = 8 * 400;
constexpr long long kDupWindowS = 2;

} // namespace

uint16_t Afsk1200Decoder::crc(const uint8_t* data, size_t n)
{
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; i++) {
        c ^= data[i];
        for (int b = 0; b < 8; b++) c = (c & 1) ? static_cast<uint16_t>((c >> 1) ^ 0x8408) : static_cast<uint16_t>(c >> 1);
    }
    return static_cast<uint16_t>(c ^ 0xFFFF);
}

Afsk1200Decoder::Afsk1200Decoder(int sampleRate) : rate_(sampleRate)
{
    window_ = static_cast<int>(std::lround(static_cast<double>(sampleRate) / kBaud));
    pllStep_ = static_cast<int32_t>(std::llround(4294967296.0 * kBaud / sampleRate));
    markInc_ = 2 * kPi * kMarkHz / sampleRate;
    spaceInc_ = 2 * kPi * kSpaceHz / sampleRate;
    for (auto& r : ring_) r.assign(static_cast<size_t>(window_), 0.f);
    // Weights on the space tone's power: flat, and for space up to ~3x
    // weaker or stronger in amplitude (de-/pre-emphasis).
    for (float w : {1.f, 0.3f, 3.f, 0.1f, 10.f}) {
        Slicer s;
        s.spaceWeight = w;
        slicers_.push_back(s);
    }
}

void Afsk1200Decoder::reset()
{
    for (auto& r : ring_) std::fill(r.begin(), r.end(), 0.f);
    for (double& s : sum_) s = 0;
    pos_ = 0;
    for (auto& s : slicers_) {
        const float w = s.spaceWeight;
        s = Slicer();
        s.spaceWeight = w;
    }
    recent_.clear();
}

void Afsk1200Decoder::process(const int16_t* pcm, int n, const FrameCallback& onFrame)
{
    for (int i = 0; i < n; i++) {
        const float x = pcm[i] / 32768.f;
        const float v[4] = {
            static_cast<float>(x * std::cos(markPhase_)),
            static_cast<float>(x * std::sin(markPhase_)),
            static_cast<float>(x * std::cos(spacePhase_)),
            static_cast<float>(x * std::sin(spacePhase_)),
        };
        markPhase_ += markInc_;
        spacePhase_ += spaceInc_;
        if (markPhase_ > 2 * kPi) markPhase_ -= 2 * kPi;
        if (spacePhase_ > 2 * kPi) spacePhase_ -= 2 * kPi;
        for (int k = 0; k < 4; k++) {
            sum_[k] += v[k] - ring_[k][static_cast<size_t>(pos_)];
            ring_[k][static_cast<size_t>(pos_)] = v[k];
        }
        pos_ = (pos_ + 1) % window_;
        const double mark = sum_[0] * sum_[0] + sum_[1] * sum_[1];
        const double space = sum_[2] * sum_[2] + sum_[3] * sum_[3];
        sampleCount_++;

        for (auto& s : slicers_) {
            const bool demod = mark > s.spaceWeight * space;
            // Bit clock: sample when the PLL wraps; a demodulator
            // transition pulls the PLL towards the bit edge.
            const int32_t prev = s.pll;
            s.pll = static_cast<int32_t>(static_cast<uint32_t>(s.pll) + static_cast<uint32_t>(pllStep_));
            if (s.pll < 0 && prev >= 0) {
                // NRZI: no change = 1, change = 0.
                const bool b = demod == s.lastBit;
                s.lastBit = demod;
                bit(s, b, onFrame);
            }
            if (demod != s.lastDemod) {
                s.pll = static_cast<int32_t>(s.pll * kPllInertia);
                s.lastDemod = demod;
            }
        }
    }
}

void Afsk1200Decoder::bit(Slicer& s, bool b, const FrameCallback& onFrame)
{
    if (b) {
        s.ones++;
        if (s.ones > 6) {  // abort / idle line
            s.inFrame = false;
            s.bits.clear();
            return;
        }
        s.bits.push_back(1);
    } else {
        if (s.ones == 6) {  // flag 01111110
            // The flag's 0 and six 1s went into the frame - take them out.
            if (s.bits.size() >= 7) s.bits.resize(s.bits.size() - 7);
            else s.bits.clear();
            if (s.inFrame) frameEnd(s, onFrame);
            s.inFrame = true;
            s.bits.clear();
            s.ones = 0;
            return;
        }
        if (s.ones == 5) {  // stuffed bit
            s.ones = 0;
            return;
        }
        s.ones = 0;
        s.bits.push_back(0);
    }
    if (s.bits.size() > kMaxFrameBits) {
        s.inFrame = false;
        s.bits.clear();
    }
}

void Afsk1200Decoder::frameEnd(Slicer& s, const FrameCallback& onFrame)
{
    if (s.bits.size() % 8 != 0 || s.bits.size() / 8 < kMinFrame) return;
    std::vector<uint8_t> bytes(s.bits.size() / 8, 0);
    for (size_t i = 0; i < s.bits.size(); i++) {
        if (s.bits[i]) bytes[i / 8] |= static_cast<uint8_t>(1u << (i % 8));  // LSB first
    }
    const size_t n = bytes.size() - 2;
    const uint16_t fcs = static_cast<uint16_t>(bytes[n] | (bytes[n + 1] << 8));
    if (crc(bytes.data(), n) != fcs) return;
    bytes.resize(n);
    // The same frame from another slicer (or a repeat within a moment).
    const long long window = kDupWindowS * rate_;
    std::vector<Recent> kept;
    bool dup = false;
    for (auto& r : recent_) {
        if (sampleCount_ - r.at > window) continue;
        if (r.frame == bytes) dup = true;
        kept.push_back(std::move(r));
    }
    recent_ = std::move(kept);
    if (dup) return;
    recent_.push_back({bytes, sampleCount_});
    onFrame(bytes);
}

std::vector<int16_t> afsk1200Encode(const std::vector<uint8_t>& frame, int sampleRate, float spaceGain)
{
    std::vector<uint8_t> withFcs = frame;
    const uint16_t c = Afsk1200Decoder::crc(frame.data(), frame.size());
    withFcs.push_back(static_cast<uint8_t>(c & 0xFF));
    withFcs.push_back(static_cast<uint8_t>(c >> 8));
    // Raw HDLC bits: flags, stuffed data, flags.
    std::vector<int> bits;
    auto flag = [&] {
        for (int i = 0; i < 8; i++) bits.push_back((0x7E >> i) & 1);
    };
    for (int i = 0; i < 30; i++) flag();
    int ones = 0;
    for (uint8_t byte : withFcs) {
        for (int i = 0; i < 8; i++) {
            const int b = (byte >> i) & 1;
            bits.push_back(b);
            if (b) {
                if (++ones == 5) {
                    bits.push_back(0);
                    ones = 0;
                }
            } else {
                ones = 0;
            }
        }
    }
    for (int i = 0; i < 4; i++) flag();
    // NRZI + phase-continuous tones.
    std::vector<int16_t> out;
    bool tone = true;  // true = mark
    double phase = 0;
    double t = 0;
    const double samplesPerBit = static_cast<double>(sampleRate) / kBaud;
    for (int b : bits) {
        if (!b) tone = !tone;
        t += samplesPerBit;
        while (static_cast<double>(out.size()) < t) {
            const double hz = tone ? kMarkHz : kSpaceHz;
            phase += 2 * kPi * hz / sampleRate;
            // Louder tone at 12000, so nothing clips.
            const double amp = (tone ? 1.0 : spaceGain) / std::max(1.0, static_cast<double>(spaceGain));
            out.push_back(static_cast<int16_t>(12000 * amp * std::sin(phase)));
        }
    }
    return out;
}

} // namespace hrdab
