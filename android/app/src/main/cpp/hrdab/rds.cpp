#include "rds.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "charset.h"
#include "common.h"

namespace hrdab {

namespace {

constexpr int kMpxRate = 256000;
constexpr int kBasebandRate = 16000;
constexpr double kBitRate = 1187.5;                       // 57 kHz / 48
constexpr uint32_t kInc57 = 57u << 24;                    // 57/256 of a cycle per sample
constexpr uint16_t kOffsetWords[5] = {0x0FC, 0x198, 0x168, 0x350, 0x1B4};
constexpr uint32_t kGenerator = 0x5B9;                    // x^10+x^8+x^7+x^5+x^4+x^3+1

uint32_t syndrome(uint32_t block26)
{
    uint32_t x = block26;
    for (int i = 25; i >= 10; i--) {
        if (x & (1u << i)) x ^= kGenerator << (i - 10);
    }
    return x & 0x3FF;
}

struct ErrorPattern {
    uint32_t syndrome;
    uint32_t pattern;
};

// Burst errors of one or two adjacent bits - the common case after a short
// fade. Longer bursts are correctable in principle, but each additional
// pattern also raises the odds of "correcting" a block into a wrong one.
const std::vector<ErrorPattern>& errorPatterns()
{
    static const std::vector<ErrorPattern> patterns = [] {
        std::vector<ErrorPattern> p;
        for (int i = 0; i < 26; i++) p.push_back({syndrome(1u << i), 1u << i});
        for (int i = 0; i < 25; i++) p.push_back({syndrome(3u << i), 3u << i});
        return p;
    }();
    return patterns;
}

// RDS text bytes (basic G0 table = EBU Latin) to UTF-8; control codes
// (line breaks, soft hyphens) become spaces. Trimmed on both sides.
std::string rdsText(const uint8_t* data, int len)
{
    uint8_t clean[64];
    for (int i = 0; i < len; i++) clean[i] = data[i] < 0x20 ? ' ' : data[i];
    std::string s = dabTextToUtf8(clean, len, 0);
    size_t start = 0;
    while (start < s.size() && s[start] == ' ') start++;
    return s.substr(start);
}

} // namespace

uint16_t rdsCheckword(uint16_t info, RdsOffset offset)
{
    return static_cast<uint16_t>((syndrome(static_cast<uint32_t>(info) << 10) ^ kOffsetWords[offset]) & 0x3FF);
}

// --- demodulator ---

RdsDemod::RdsDemod()
{
    // 256 -> 32 kHz: keep +-2.4 kHz clean of what folds in from 32 kHz
    // multiples (L-R audio around 25 kHz in the MPX lands there).
    dec8_.init(designLowpass(35, 16000.0 / kMpxRate, kaiserBeta(60)), 8);
    // 32 -> 16 kHz: also the RDS channel filter. The L-R sideband ends at
    // 53 kHz, only 4 kHz below the subcarrier.
    dec2_.init(designLowpass(73, 3200.0 / 32000.0, kaiserBeta(60)), 2);
    reset();
}

void RdsDemod::reset()
{
    ncoPhase_ = 0;
    dec8_.reset();
    dec2_.reset();
    psi_ = 0;
    nu_ = 0;
    power_ = 0;
    std::memset(x_, 0, sizeof(x_));
    std::memset(m_, 0, sizeof(m_));
    n_ = 0;
    period_ = kBasebandRate / kBitRate;
    next_ = 20;
    avgAbs_ = 0;
    prevBit_ = 0;
}

void RdsDemod::process(const float* mpx, int n, std::vector<uint8_t>& bits)
{
    mix_.resize(static_cast<size_t>(2 * n));
    for (int i = 0; i < n; i++) {
        const float v = mpx[i];
        mix_[static_cast<size_t>(2 * i)] = v * cosTable(ncoPhase_);
        mix_[static_cast<size_t>(2 * i + 1)] = -v * sinTable(ncoPhase_);
        ncoPhase_ += kInc57;
    }
    bb32_.resize(static_cast<size_t>(2 * (n / 8 + 2)));
    const int n32 = dec8_.process(mix_.data(), n, bb32_.data());
    bb16_.resize(static_cast<size_t>(2 * (n32 / 2 + 2)));
    const int n16 = dec2_.process(bb32_.data(), n32, bb16_.data());

    for (int i = 0; i < n16; i++) {
        const float re = bb16_[static_cast<size_t>(2 * i)];
        const float im = bb16_[static_cast<size_t>(2 * i + 1)];
        const float c = static_cast<float>(std::cos(psi_));
        const float s = static_cast<float>(std::sin(psi_));
        const float zr = re * c + im * s;
        const float zi = im * c - re * s;
        // Costas loop: BPSK lies on one axis; I*Q measures the angle off it
        // (independent of the data sign).
        power_ += 0.002f * (zr * zr + zi * zi - power_);
        float err = power_ > 0 ? zr * zi / power_ : 0.f;
        err = std::max(-1.f, std::min(1.f, err));
        nu_ += 6e-6 * err;
        nu_ = std::max(-0.01, std::min(0.01, nu_)); // +-25 Hz
        psi_ += nu_ + 0.005 * err;
        if (psi_ > M_PI) psi_ -= 2 * M_PI;
        if (psi_ < -M_PI) psi_ += 2 * M_PI;
        symbolSample(zr, bits);
    }
}

float RdsDemod::matchedAt(double t) const
{
    const long i = static_cast<long>(std::floor(t));
    const float f = static_cast<float>(t - i);
    return m_[i % kHist] * (1.f - f) + m_[(i + 1) % kHist] * f;
}

void RdsDemod::symbolSample(float x, std::vector<uint8_t>& bits)
{
    // One biphase symbol is a full cycle at the bit rate: positive half,
    // negative half (or the reverse). Correlate with that over ~13.5
    // samples: m = sum(first half) - sum(second half).
    x_[n_ % kHist] = x;
    float m = 0;
    if (n_ >= 13) {
        float early = 0, late = 0;
        for (int k = 0; k < 7; k++) late += x_[(n_ - k) % kHist];
        for (int k = 7; k < 14; k++) early += x_[(n_ - k) % kHist];
        m = early - late;
    }
    m_[n_ % kHist] = m;
    n_++;

    const double d = period_ / 4;
    while (next_ + d + 1 <= static_cast<double>(n_ - 1)) {
        const float mc = matchedAt(next_);
        const float me = std::fabs(matchedAt(next_ - d));
        const float ml = std::fabs(matchedAt(next_ + d));
        avgAbs_ += 0.02f * (std::fabs(mc) - avgAbs_);
        // |m| peaks at the symbol centre (it also reaches the same height
        // between two equal bits, but only half as often, so the average
        // gradient still points to the centre).
        float e = avgAbs_ > 0 ? (ml - me) / avgAbs_ : 0.f;
        e = std::max(-1.f, std::min(1.f, e));
        period_ += 0.0005 * e;
        const double nominal = kBasebandRate / kBitRate;
        period_ = std::max(nominal * 0.995, std::min(nominal * 1.005, period_));
        const int b = mc > 0 ? 1 : 0;
        bits.push_back(static_cast<uint8_t>(b ^ prevBit_)); // differential decoding
        prevBit_ = b;
        next_ += period_ + 0.17 * e;
    }
}

// --- block / group decoder ---

void RdsDecoder::reset()
{
    reg_ = 0;
    bitCount_ = 0;
    synced_ = false;
    expect_ = 0;
    bitsInBlock_ = 0;
    errHist_ = 0;
    seen_.clear();
    std::memset(valid_, 0, sizeof(valid_));
    pi_ = -1;
    piCandidate_ = -1;
    piCount_ = 0;
    std::memset(psPending_, 0, sizeof(psPending_));
    std::memset(psCount_, 0, sizeof(psCount_));
    std::memset(psConfirmed_, 0, sizeof(psConfirmed_));
    std::memset(psHave_, 0, sizeof(psHave_));
    ps_.clear();
    std::memset(rtBuf_, ' ', sizeof(rtBuf_));
    rtMask_ = 0;
    rtAb_ = -1;
    rtVersionB_ = false;
    rt_.clear();
    std::memset(rtPending_, 0, sizeof(rtPending_));
    std::memset(rtPendingCount_, 0, sizeof(rtPendingCount_));
    rtAbPending_ = -1;
    rtAbCount_ = 0;
    changed_ = false;
    groups = blocksOk = blocksCorrected = blocksBad = 0;
}

void RdsDecoder::pushBit(int bit)
{
    reg_ = ((reg_ << 1) | static_cast<uint32_t>(bit & 1)) & 0x3FFFFFF;
    bitCount_++;
    if (synced_) {
        if (++bitsInBlock_ < 26) return;
        bitsInBlock_ = 0;
        block(expect_, reg_);
        return;
    }
    if (bitCount_ < 26) return;
    // Searching: a block whose syndrome is an offset word is a candidate;
    // two candidates a whole number of blocks apart in the right order
    // (A, B, C/C', D) are sync.
    const uint32_t s = syndrome(reg_);
    int pos = -1;
    for (int t = 0; t < 5; t++) {
        if (s == kOffsetWords[t]) pos = t <= kRdsC ? t : (t == kRdsCPrime ? 2 : 3);
    }
    if (pos < 0) return;
    for (const Seen& prev : seen_) {
        const long dist = bitCount_ - prev.at;
        if (dist <= 0 || dist % 26 != 0 || dist / 26 > 6) continue;
        if ((prev.pos + dist / 26) % 4 != pos) continue;
        synced_ = true;
        errHist_ = 0;
        bitsInBlock_ = 0;
        seen_.clear();
        std::memset(valid_, 0, sizeof(valid_));
        if (pos < 3) {
            group_[pos] = static_cast<uint16_t>(reg_ >> 10);
            valid_[pos] = true;
            cPrime_ = s == kOffsetWords[kRdsCPrime];
        }
        expect_ = (pos + 1) % 4;
        return;
    }
    seen_.push_back({bitCount_, pos});
    if (seen_.size() > 12) seen_.erase(seen_.begin());
}

void RdsDecoder::block(int pos, uint32_t raw)
{
    // Allowed offsets at this position (C or C' in the third block).
    int offsets[2] = {pos == 3 ? kRdsD : pos, -1};
    if (pos == 2) {
        offsets[0] = kRdsC;
        offsets[1] = kRdsCPrime;
        // Version B groups (bit 11 of block B) carry C'; try that first.
        if (valid_[1] && (group_[1] & 0x0800)) std::swap(offsets[0], offsets[1]);
    }
    const uint32_t s = syndrome(raw);
    bool ok = false;
    int used = offsets[0];
    for (int o : offsets) {
        if (o >= 0 && s == kOffsetWords[o]) {
            ok = true;
            used = o;
            break;
        }
    }
    if (ok) {
        blocksOk++;
    } else {
        for (int o : offsets) {
            if (o < 0 || ok) continue;
            const uint32_t sx = s ^ kOffsetWords[o];
            for (const auto& e : errorPatterns()) {
                if (e.syndrome == sx) {
                    raw ^= e.pattern;
                    ok = true;
                    used = o;
                    break;
                }
            }
        }
        if (ok) blocksCorrected++;
        else blocksBad++;
    }

    errHist_ = ((errHist_ << 1) | (ok ? 0u : 1u)) & ((1ull << 50) - 1);
    if (__builtin_popcountll(errHist_) > 30) {
        // Lost: too many bad blocks among the last 50.
        synced_ = false;
        seen_.clear();
        return;
    }

    if (pos == 0) std::memset(valid_, 0, sizeof(valid_));
    group_[pos] = static_cast<uint16_t>(raw >> 10);
    valid_[pos] = ok;
    if (pos == 2) cPrime_ = used == kRdsCPrime;
    expect_ = (pos + 1) % 4;
    if (pos == 3) processGroup();
}

void RdsDecoder::processGroup()
{
    groups++;
    if (valid_[0]) piCandidate(group_[0]);
    else if (valid_[2] && cPrime_) piCandidate(group_[2]);
    if (!valid_[1]) return;
    const uint16_t b = group_[1];
    const int type = b >> 12;
    const bool versionB = (b & 0x0800) != 0;
    if (type == 0) {
        if (valid_[3]) {
            psChars((b & 3) * 2, static_cast<uint8_t>(group_[3] >> 8), static_cast<uint8_t>(group_[3] & 0xFF));
        }
    } else if (type == 2) {
        const int ab = (b >> 4) & 1;
        const int seg = b & 0xF;
        if (!versionB) {
            if (valid_[2] && valid_[3] && !cPrime_) {
                const uint8_t c[4] = {static_cast<uint8_t>(group_[2] >> 8), static_cast<uint8_t>(group_[2] & 0xFF),
                                      static_cast<uint8_t>(group_[3] >> 8), static_cast<uint8_t>(group_[3] & 0xFF)};
                rtChars(false, ab, seg, c, 4);
            }
        } else if (valid_[3]) {
            const uint8_t c[2] = {static_cast<uint8_t>(group_[3] >> 8), static_cast<uint8_t>(group_[3] & 0xFF)};
            rtChars(true, ab, seg, c, 2);
        }
    }
}

void RdsDecoder::piCandidate(uint16_t pi)
{
    // Confirmed by two receptions in a row.
    if (pi == piCandidate_) {
        piCount_++;
    } else {
        piCandidate_ = pi;
        piCount_ = 1;
    }
    if (piCount_ >= 2 && pi_ != pi) {
        pi_ = pi;
        changed_ = true;
    }
}

void RdsDecoder::psChars(int pos, uint8_t c0, uint8_t c1)
{
    const uint8_t c[2] = {c0, c1};
    for (int i = 0; i < 2; i++) {
        const int p = pos + i;
        if (psCount_[p] > 0 && psPending_[p] == c[i]) {
            if (psCount_[p] < 255) psCount_[p]++;
        } else {
            psPending_[p] = c[i];
            psCount_[p] = 1;
        }
        // A character counts once received twice in a row - a single
        // (mis)corrected block must not put garbage on the display.
        if (psCount_[p] >= 2) {
            psConfirmed_[p] = c[i];
            psHave_[p] = true;
        }
    }
    for (bool h : psHave_) {
        if (!h) return;
    }
    std::string s = rdsText(psConfirmed_, 8);
    if (!s.empty() && s != ps_) {
        ps_ = s;
        changed_ = true;
    }
}

void RdsDecoder::rtChars(bool versionB, int ab, int segment, const uint8_t* chars, int n)
{
    // A segment and the A/B flag only count once received twice in a row:
    // a single miscorrected block used to look like "new text", threw away
    // the half-received one - and on less than perfect reception the new
    // text never completed, leaving the old one on display for good.
    if (ab == rtAbPending_) {
        if (rtAbCount_ < 255) rtAbCount_++;
    } else {
        rtAbPending_ = ab;
        rtAbCount_ = 1;
    }
    uint8_t* pending = rtPending_[segment];
    if (rtPendingCount_[segment] > 0 && std::memcmp(pending, chars, static_cast<size_t>(n)) == 0) {
        if (rtPendingCount_[segment] < 255) rtPendingCount_[segment]++;
    } else {
        std::memcpy(pending, chars, static_cast<size_t>(n));
        rtPendingCount_[segment] = 1;
    }
    if (rtPendingCount_[segment] < 2) return;

    // The A/B flag toggles for a new text; some stations never toggle it
    // and just send different text, which shows up as a segment changing.
    const int off = segment * n;
    const bool abToggled = rtAb_ >= 0 && rtAbCount_ >= 2 && rtAbPending_ != rtAb_;
    const bool segmentChanged = (rtMask_ & (1u << segment)) && std::memcmp(rtBuf_ + off, chars, static_cast<size_t>(n)) != 0;
    if (abToggled || versionB != rtVersionB_ || segmentChanged) {
        std::memset(rtBuf_, ' ', sizeof(rtBuf_));
        rtMask_ = 0;
        // The old text is over - better nothing than stale text until the
        // new one is complete.
        if (!rt_.empty()) {
            rt_.clear();
            changed_ = true;
        }
    }
    if (rtAb_ < 0 || abToggled) rtAb_ = rtAbPending_;
    rtVersionB_ = versionB;
    std::memcpy(rtBuf_ + off, chars, static_cast<size_t>(n));
    rtMask_ |= 1u << segment;

    // Complete once every segment up to the end marker (0x0D) is in, or
    // all 16 segments are.
    int end = -1;
    for (int seg = 0; seg < 16 && end < 0; seg++) {
        if (!(rtMask_ & (1u << seg))) return;
        for (int i = 0; i < n; i++) {
            if (rtBuf_[seg * n + i] == 0x0D) {
                end = seg * n + i;
                break;
            }
        }
    }
    if (end < 0) end = 16 * n;
    const std::string s = rdsText(rtBuf_, end);
    if (!s.empty() && s != rt_) {
        rt_ = s;
        changed_ = true;
    }
}

} // namespace hrdab
