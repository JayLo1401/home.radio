#include "acars.h"

#include <algorithm>
#include <cmath>

namespace hrdab {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kBaud = 2400;
constexpr double kCentreHz = 1800.0;
constexpr double kPllInertia = 0.74;
constexpr size_t kMaxBytes = 260;
constexpr uint8_t kSoh = 0x01, kEtx = 0x03, kEtb = 0x17;

// "+*" SYN SYN SOH as 7-bit characters, the order they are sent in.
constexpr uint8_t kSync[] = {0x2B, 0x2A, 0x16, 0x16, kSoh};

uint8_t withOddParity(uint8_t c)
{
    int ones = 0;
    for (int i = 0; i < 7; i++) ones += (c >> i) & 1;
    return static_cast<uint8_t>((c & 0x7F) | ((ones % 2 == 0) ? 0x80 : 0));
}

} // namespace

uint16_t AcarsDecoder::crc(const uint8_t* data, size_t n)
{
    uint16_t c = 0;
    for (size_t i = 0; i < n; i++) {
        c ^= data[i];
        for (int b = 0; b < 8; b++) c = (c & 1) ? static_cast<uint16_t>((c >> 1) ^ 0x8408) : static_cast<uint16_t>(c >> 1);
    }
    return c;
}

AcarsDecoder::AcarsDecoder(int sampleRate) : rate_(sampleRate)
{
    window_ = static_cast<int>(std::lround(static_cast<double>(sampleRate) / kBaud));
    phaseInc_ = 2 * kPi * kCentreHz / sampleRate;
    pllStep_ = static_cast<int32_t>(std::llround(4294967296.0 * kBaud / sampleRate));
    ringI_.assign(static_cast<size_t>(window_), 0.f);
    ringQ_.assign(static_cast<size_t>(window_), 0.f);
    histI_.assign(static_cast<size_t>(window_), 0.f);
    histQ_.assign(static_cast<size_t>(window_), 0.f);
    for (bool inv : {false, true}) {
        for (bool diff : {false, true}) {
            Framer f;
            f.invert = inv;
            f.differential = diff;
            framers_.push_back(f);
        }
    }
}

void AcarsDecoder::process(const int16_t* pcm, int n, const FrameCallback& onFrame)
{
    for (int k = 0; k < n; k++) {
        const float x = pcm[k] / 32768.f;
        // Down to 0 Hz around the MSK centre, then a one-bit moving average.
        const float i = static_cast<float>(x * std::cos(phase_));
        const float q = static_cast<float>(-x * std::sin(phase_));
        phase_ += phaseInc_;
        if (phase_ > 2 * kPi) phase_ -= 2 * kPi;
        const size_t p = static_cast<size_t>(pos_);
        sumI_ += i - ringI_[p];
        sumQ_ += q - ringQ_[p];
        ringI_[p] = i;
        ringQ_[p] = q;
        // Phase turn over one bit: z[n] * conj(z[n - bit]).
        const double zi = sumI_, zq = sumQ_;
        const double oi = histI_[p], oq = histQ_[p];
        histI_[p] = static_cast<float>(zi);
        histQ_[p] = static_cast<float>(zq);
        pos_ = (pos_ + 1) % window_;
        const double turn = zq * oi - zi * oq;  // imaginary part: sign = direction
        const bool demod = turn > 0;

        const int32_t prev = pll_;
        pll_ = static_cast<int32_t>(static_cast<uint32_t>(pll_) + static_cast<uint32_t>(pllStep_));
        if (pll_ < 0 && prev >= 0) bit(demod, onFrame);
        if (demod != lastDemod_) {
            pll_ = static_cast<int32_t>(pll_ * kPllInertia);
            lastDemod_ = demod;
        }
    }
}

void AcarsDecoder::bit(bool raw, const FrameCallback& onFrame)
{
    for (auto& f : framers_) {
        bool b = raw != f.invert;
        if (f.differential) {
            const bool d = b == f.lastRaw;
            f.lastRaw = b;
            b = d;
        }
        framerBit(f, b, onFrame);
    }
}

void AcarsDecoder::framerBit(Framer& f, bool b, const FrameCallback& onFrame)
{
    // Newest bit in at the top: the last 40 bits, the oldest lowest.
    f.shift = (f.shift >> 1) | (static_cast<uint64_t>(b) << 39);
    if (!f.inFrame) {
        // The sync characters, LSB first, parity ignored.
        bool match = true;
        for (int c = 0; c < 5 && match; c++) {
            const uint8_t ch = static_cast<uint8_t>((f.shift >> (8 * c)) & 0x7F);
            if (ch != kSync[c]) match = false;
        }
        if (match) {
            f.inFrame = true;
            f.bitCount = 0;
            f.cur = 0;
            f.bytes.assign(1, kSoh);
            f.trailer = -1;
        }
        return;
    }
    f.cur = static_cast<uint8_t>(f.cur | (b ? 1 : 0) << f.bitCount);
    if (++f.bitCount < 8) return;
    const uint8_t byte = f.cur;
    f.cur = 0;
    f.bitCount = 0;
    f.bytes.push_back(byte);
    if (f.trailer > 0) {
        if (--f.trailer == 0) {
            // SOH .. ETX/ETB + BCS: the CRC from after SOH over the BCS is 0.
            const auto& m = f.bytes;
            if (m.size() > 4 && crc(m.data() + 1, m.size() - 1) == 0) {
                if (std::find(recent_.begin(), recent_.end(), m) == recent_.end()) {
                    recent_.push_back(m);
                    if (recent_.size() > 8) recent_.erase(recent_.begin());
                    onFrame(m);
                }
            }
            f.inFrame = false;
        }
        return;
    }
    const uint8_t c = byte & 0x7F;
    if (c == kEtx || c == kEtb) {
        f.trailer = 2;
        return;
    }
    // A character with wrong parity or a runaway message: give up.
    if (withOddParity(c) != byte || f.bytes.size() > kMaxBytes) f.inFrame = false;
}

std::vector<int16_t> acarsEncode(const std::vector<uint8_t>& sohToEtx, int sampleRate)
{
    std::vector<uint8_t> bytes;
    for (int i = 0; i < 16; i++) bytes.push_back(0xFF);  // pre-key
    for (uint8_t c : {0x2B, 0x2A, 0x16, 0x16}) bytes.push_back(withOddParity(c));
    std::vector<uint8_t> msg;
    for (size_t i = 0; i < sohToEtx.size(); i++) msg.push_back(withOddParity(sohToEtx[i]));
    const uint16_t c = AcarsDecoder::crc(msg.data() + 1, msg.size() - 1);
    msg.push_back(static_cast<uint8_t>(c & 0xFF));
    msg.push_back(static_cast<uint8_t>(c >> 8));
    msg.push_back(0x7F);  // DEL
    bytes.insert(bytes.end(), msg.begin(), msg.end());
    // MSK: each bit turns the phase +-90 degrees around 1800 Hz.
    std::vector<int16_t> out;
    double phase = 0, t = 0;
    const double samplesPerBit = static_cast<double>(sampleRate) / kBaud;
    for (uint8_t byte : bytes) {
        for (int i = 0; i < 8; i++) {
            const bool b = (byte >> i) & 1;
            const double hz = b ? 2400.0 : 1200.0;
            t += samplesPerBit;
            while (static_cast<double>(out.size()) < t) {
                phase += 2 * kPi * hz / sampleRate;
                out.push_back(static_cast<int16_t>(10000 * std::sin(phase)));
            }
        }
    }
    return out;
}

} // namespace hrdab
