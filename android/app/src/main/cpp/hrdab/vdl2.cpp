#include "vdl2.h"

#include <algorithm>
#include <cmath>

namespace hrdab {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kNcoBits = 12;
constexpr int kNcoAmp = 4095;  // 255 * 4095 * 2 * 10^3 (CIC gain) < 2^31
// The signal (raised cosine, alpha 0.6) covers +-8.4 kHz, most of its power
// within +-5 kHz. The filter (-6 dB at 7.5 kHz) passes that and as little
// noise as it can: tried on recorded bursts, wider or narrower decoded fewer.
constexpr double kCutoffHz = 7500;
constexpr int kReadSamples = 65536;
constexpr int kSyncLen = 16;
// |sum d * conj(sync)| / 16 with d unit phasors; 1 = perfect. Real bursts
// reach 0.9 and more; 16 random phasors pass 0.75 with p ~ 1e-4.
constexpr float kSyncThreshold = 0.75f;
// Correlation only where the power stands out of the noise floor.
constexpr float kGate = 4.f;
constexpr int kWarm = 2000;
constexpr int kHeaderBits = 25;
constexpr uint16_t kLfsrSeed = 0x6959;
constexpr int kBlockData = 249;
constexpr int kMaxBlocks = 16;  // ~4 kB, ~1 s on air: larger is a misread header
constexpr int kMinDataBits = 13 * 8;
constexpr float kAfcMaxHz = 8000;
// Carrier loop gains (per symbol): phase, frequency.
constexpr float kLoopA = 0.15f;
constexpr float kLoopB = 0.005f;

// D8PSK: phase turn index (k * 45 degrees) -> 3 bits (first bit sent = MSB).
constexpr uint8_t kGray[8] = {0, 1, 3, 2, 6, 7, 5, 4};
// Training sequence, 3 bits per symbol as transmitted.
constexpr uint8_t kSyncBits[kSyncLen] = {0, 2, 3, 6, 0, 1, 5, 6, 1, 4, 3, 7, 5, 7, 4, 2};

// Check octets of the last (or only) block, by its data length.
int lastBlockFec(int octets)
{
    return octets <= 2 ? 0 : octets <= 30 ? 2 : octets <= 67 ? 4 : 6;
}

bool fcsOk(const uint8_t* b, size_t n)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < n; i++) {
        crc ^= b[i];
        for (int k = 0; k < 8; k++) crc = (crc & 1) ? static_cast<uint16_t>((crc >> 1) ^ 0x8408) : static_cast<uint16_t>(crc >> 1);
    }
    return crc == 0xF0B8;
}

// HDLC frames (flags, bit stuffing, LSB first) in bits[0..n); only those with
// a good FCS, without it.
std::vector<std::vector<uint8_t>> hdlcFrames(const uint8_t* bits, size_t n)
{
    std::vector<std::vector<uint8_t>> out;
    std::vector<uint8_t> bytes;
    uint32_t acc = 0;
    int nbits = 0, ones = 0;
    bool inFrame = false;
    // A zero is held back until it's clear it doesn't open a flag.
    bool zero = false;
    auto put = [&](int bit) {
        acc |= static_cast<uint32_t>(bit) << nbits;
        if (++nbits == 8) {
            bytes.push_back(static_cast<uint8_t>(acc));
            acc = 0;
            nbits = 0;
            if (bytes.size() > 8400) inFrame = false;  // too long: lost
        }
    };
    for (size_t i = 0; i < n; i++) {
        if (bits[i]) {
            if (++ones > 6) inFrame = false;  // abort / idle
            continue;
        }
        if (ones == 6) {  // flag
            if (inFrame && nbits == 0 && bytes.size() >= 13 && fcsOk(bytes.data(), bytes.size())) {
                bytes.resize(bytes.size() - 2);
                out.push_back(bytes);
            }
            inFrame = true;
            bytes.clear();
            acc = 0;
            nbits = 0;
            ones = 0;
            zero = false;
            continue;
        }
        if (inFrame && ones <= 6) {
            if (zero) put(0);
            for (int k = 0; k < ones; k++) put(1);
        }
        zero = ones != 5;  // after five ones: a stuffed zero
        ones = 0;
    }
    return out;
}

// --- Reed-Solomon over GF(256), field polynomial x^8+x^7+x^2+x+1, code
// generator roots alpha^120 .. alpha^125; block[0] is the highest power.

struct Gf {
    uint8_t exp[512];
    int log[256];
    Gf()
    {
        int x = 1;
        for (int i = 0; i < 255; i++) {
            exp[i] = static_cast<uint8_t>(x);
            log[x] = i;
            x <<= 1;
            if (x & 0x100) x ^= 0x187;
        }
        for (int i = 255; i < 512; i++) exp[i] = exp[i - 255];
        log[0] = -1;
    }
    uint8_t mul(uint8_t a, uint8_t b) const { return a && b ? exp[log[a] + log[b]] : 0; }
    uint8_t div(uint8_t a, uint8_t b) const { return a ? exp[(log[a] - log[b] + 255) % 255] : 0; }
    uint8_t pow(int e) const { return exp[((e % 255) + 255) % 255]; }
};

const Gf& gf()
{
    static const Gf g;
    return g;
}

constexpr int kFcr = 120;
constexpr int kRoots = 6;
constexpr int kN = 255;

} // namespace

void Vdl2MultiDemod::rsEncode(const uint8_t* data, uint8_t* fec)
{
    const Gf& g = gf();
    // Generator polynomial, highest power first.
    uint8_t gen[kRoots + 1] = {1};
    for (int i = 0; i < kRoots; i++) {
        const uint8_t root = g.pow(kFcr + i);
        for (int j = i + 1; j > 0; j--) gen[j] = static_cast<uint8_t>(gen[j] ^ g.mul(gen[j - 1], root));
    }
    uint8_t r[kRoots] = {};
    for (int i = 0; i < kBlockData; i++) {
        const uint8_t f = static_cast<uint8_t>(data[i] ^ r[0]);
        for (int j = 0; j < kRoots - 1; j++) r[j] = static_cast<uint8_t>(r[j + 1] ^ g.mul(f, gen[j + 1]));
        r[kRoots - 1] = g.mul(f, gen[kRoots]);
    }
    for (int j = 0; j < kRoots; j++) fec[j] = r[j];
}

int Vdl2MultiDemod::rsDecode(uint8_t* block, int dataOctets, int fecOctets, const int* erased, int erasedCount)
{
    const Gf& g = gf();
    if (fecOctets <= 0) return 0;
    // Syndromes S_i = c(alpha^(fcr+i)).
    uint8_t s[kRoots];
    bool clean = true;
    for (int i = 0; i < kRoots; i++) {
        const uint8_t root = g.pow(kFcr + i);
        uint8_t acc = 0;
        for (int j = 0; j < kN; j++) acc = static_cast<uint8_t>(g.mul(acc, root) ^ block[j]);
        s[i] = acc;
        if (acc) clean = false;
    }
    if (clean) return 0;  // only the left-out check octets "wrong"; not data
    // Erasures: the check octets not sent, and those the caller names.
    int pos[kRoots];
    int erasures = 0;
    for (int j = kBlockData + fecOctets; j < kN; j++) pos[erasures++] = j;
    for (int e = 0; e < erasedCount && erasures < kRoots; e++) pos[erasures++] = erased[e];
    // Erasure locator (position j is x^(254-j)).
    uint8_t lambda[kRoots + 1] = {1};
    for (int e = 0; e < erasures; e++) {
        const uint8_t x = g.pow(kN - 1 - pos[e]);
        for (int i = e + 1; i > 0; i--) lambda[i] = static_cast<uint8_t>(lambda[i] ^ g.mul(lambda[i - 1], x));
    }
    // Berlekamp-Massey, started from the erasures.
    uint8_t b[kRoots + 1];
    std::copy(lambda, lambda + kRoots + 1, b);
    int l = erasures;
    for (int r = erasures; r < kRoots; r++) {
        uint8_t delta = 0;
        for (int i = 0; i <= r; i++) delta ^= g.mul(lambda[i], s[r - i]);
        // b <- x * b
        for (int i = kRoots; i > 0; i--) b[i] = b[i - 1];
        b[0] = 0;
        if (delta == 0) continue;
        uint8_t t[kRoots + 1];
        for (int i = 0; i <= kRoots; i++) t[i] = static_cast<uint8_t>(lambda[i] ^ g.mul(delta, b[i]));
        if (2 * l <= r + erasures) {
            l = r + 1 + erasures - l;
            for (int i = 0; i <= kRoots; i++) b[i] = g.div(lambda[i], delta);
        }
        std::copy(t, t + kRoots + 1, lambda);
    }
    int deg = 0;
    for (int i = 0; i <= kRoots; i++)
        if (lambda[i]) deg = i;
    if (deg != l || 2 * l - erasures > kRoots) return -1;
    // Error evaluator omega = S(x) lambda(x) mod x^6.
    uint8_t omega[kRoots] = {};
    for (int i = 0; i < kRoots; i++)
        for (int j = 0; j <= i; j++) omega[i] ^= g.mul(s[i - j], lambda[j]);
    // Chien search over the positions that may hold errors; Forney.
    int found = 0, corrected = 0;
    for (int j = 0; j < kN && found < deg; j++) {
        if (j >= dataOctets && j < kBlockData) continue;
        const int power = kN - 1 - j;
        const uint8_t xinv = g.pow(-power);
        uint8_t v = 0;
        for (int i = deg; i >= 0; i--) v = static_cast<uint8_t>(g.mul(v, xinv) ^ lambda[i]);
        if (v != 0) continue;
        found++;
        uint8_t om = 0;
        for (int i = kRoots - 1; i >= 0; i--) om = static_cast<uint8_t>(g.mul(om, xinv) ^ omega[i]);
        uint8_t der = 0;
        for (int i = 1; i <= deg; i += 2) der ^= g.mul(lambda[i], g.pow(-power * (i - 1)));
        if (der == 0) return -1;
        const uint8_t e = g.mul(g.div(om, der), g.pow(power * (1 - kFcr)));
        if (e && j < kBlockData + fecOctets) {
            block[j] ^= e;
            corrected++;
        }
    }
    return found == deg ? corrected : -1;
}

Vdl2MultiDemod::Vdl2MultiDemod(IqReader& reader, AcarsSink& sink) : reader_(reader), sink_(sink)
{
    const int n = 1 << kNcoBits;
    cos_.resize(static_cast<size_t>(n));
    sin_.resize(static_cast<size_t>(n));
    for (int k = 0; k < n; k++) {
        cos_[static_cast<size_t>(k)] = static_cast<int16_t>(std::lround(kNcoAmp * std::cos(2 * kPi * k / n)));
        sin_[static_cast<size_t>(k)] = static_cast<int16_t>(std::lround(kNcoAmp * std::sin(2 * kPi * k / n)));
    }
    const double rate = static_cast<double>(kSampleRate) / kDecimation;
    double sum = 0;
    double taps[kFirTaps];
    for (int k = 0; k < kFirTaps; k++) {
        const double m = k - (kFirTaps - 1) / 2.0;
        const double x = 2 * kCutoffHz / rate;
        const double sinc = m == 0 ? x : std::sin(kPi * x * m) / (kPi * m);
        const double w = 0.54 - 0.46 * std::cos(2 * kPi * k / (kFirTaps - 1));
        taps[k] = sinc * w;
        sum += taps[k];
    }
    for (int k = 0; k < kFirTaps; k++) fir_[k] = static_cast<float>(taps[k] / sum);
    for (int k = 0; k < kSyncLen; k++) {
        int p = 0;
        while (kGray[p] != kSyncBits[k]) p++;
        syncPhase_[k] = p;
        syncI_[k] = static_cast<float>(std::cos(p * kPi / 4));
        syncQ_[k] = static_cast<float>(-std::sin(p * kPi / 4));
    }
}

void Vdl2MultiDemod::configure(uint32_t centerHz, const std::vector<uint32_t>& channelsHz)
{
    channels_.clear();
    for (uint32_t f : channelsHz) {
        Channel c;
        c.freqHz = f;
        c.offsetHz = static_cast<double>(f) - static_cast<double>(centerHz);
        channels_.push_back(std::move(c));
    }
    afcHz_ = 0;
    for (auto& c : channels_) c.inc = ncoIncrement(c);
    stats_ = Stats();
}

uint32_t Vdl2MultiDemod::ncoIncrement(const Channel& c) const
{
    const double hz = c.offsetHz + afcHz_;
    return static_cast<uint32_t>(static_cast<int64_t>(std::llround(-hz / kSampleRate * 4294967296.0)));
}

void Vdl2MultiDemod::process(const uint8_t* iq, int samples)
{
    if (static_cast<int>(x_.size()) < samples) {
        x_.resize(static_cast<size_t>(samples));
        y_.resize(static_cast<size_t>(samples));
    }
    int16_t* xs = x_.data();
    int16_t* ys = y_.data();
    // Doubled around 127.5 (the stick's zero): no DC offset.
    for (int k = 0; k < samples; k++) {
        xs[k] = static_cast<int16_t>(2 * iq[2 * k] - 255);
        ys[k] = static_cast<int16_t>(2 * iq[2 * k + 1] - 255);
    }
    constexpr int shift = 32 - kNcoBits;
    constexpr float norm = 1.f / (255.f * kNcoAmp * kDecimation * kDecimation * kDecimation);
    const int16_t* co = cos_.data();
    const int16_t* si = sin_.data();
    for (auto& c : channels_) {
        // A new tuning correction (see endBurst), not in the middle of a burst.
        if (c.state != Channel::State::Burst) c.inc = ncoIncrement(c);
        uint32_t phase = c.phase;
        const uint32_t inc = c.inc;
        uint32_t i1 = c.i1, q1 = c.q1, i2 = c.i2, q2 = c.q2, i3 = c.i3, q3 = c.q3;
        int count = c.count;
        for (int k = 0; k < samples; k++) {
            const uint32_t t = phase >> shift;
            phase += inc;
            const int32_t x = xs[k], y = ys[k];
            const int32_t mi = x * co[t] - y * si[t];
            const int32_t mq = x * si[t] + y * co[t];
            i1 += static_cast<uint32_t>(mi);
            q1 += static_cast<uint32_t>(mq);
            i2 += i1;
            q2 += q1;
            i3 += i2;
            q3 += q2;
            if (++count < kDecimation) continue;
            count = 0;
            const uint32_t a1 = i3 - c.ci1, b1 = q3 - c.cq1;
            c.ci1 = i3;
            c.cq1 = q3;
            const uint32_t a2 = a1 - c.ci2, b2 = b1 - c.cq2;
            c.ci2 = a1;
            c.cq2 = b1;
            const uint32_t a3 = a2 - c.ci3, b3 = b2 - c.cq3;
            c.ci3 = a2;
            c.cq3 = b2;
            // Low-pass at 105 kS/s (symmetric taps).
            const int h = c.hpos;
            c.hi[h] = c.hi[h + kFirTaps] = static_cast<float>(static_cast<int32_t>(a3)) * norm;
            c.hq[h] = c.hq[h + kFirTaps] = static_cast<float>(static_cast<int32_t>(b3)) * norm;
            c.hpos = h + 1 == kFirTaps ? 0 : h + 1;
            const float* wi = c.hi + h + 1;  // oldest .. newest
            const float* wq = c.hq + h + 1;
            constexpr int mid = (kFirTaps - 1) / 2;
            float fi = fir_[mid] * wi[mid], fq = fir_[mid] * wq[mid];
            for (int j = 0; j < mid; j++) {
                fi += fir_[j] * (wi[j] + wi[kFirTaps - 1 - j]);
                fq += fir_[j] * (wq[j] + wq[kFirTaps - 1 - j]);
            }
            filtered(c, fi, fq);
        }
        c.phase = phase;
        c.i1 = i1;
        c.q1 = q1;
        c.i2 = i2;
        c.q2 = q2;
        c.i3 = i3;
        c.q3 = q3;
        c.count = count;
    }
}

// Phase turn over one symbol at ring position `at`, as a unit phasor.
void Vdl2MultiDemod::phaseTurn(Channel& c, int at)
{
    const int old = (at - kSps) & (kRing - 1);
    const float re = c.zi[at] * c.zi[old] + c.zq[at] * c.zq[old];
    const float im = c.zq[at] * c.zi[old] - c.zi[at] * c.zq[old];
    const float m = re * re + im * im;
    const float s = m > 0 ? 1.f / std::sqrt(m) : 0.f;
    c.di[at] = re * s;
    c.dq[at] = im * s;
}

void Vdl2MultiDemod::filtered(Channel& c, float i, float q)
{
    const int at = c.pos;
    c.zi[at] = i;
    c.zq[at] = q;
    c.pos = (at + 1) & (kRing - 1);
    const float p = i * i + q * q;
    if (p > c.peak) c.peak = p;
    c.powerFast += (p - c.powerFast) * 0.05f;  // ~2 symbols

    if (c.state == Channel::State::Burst) {
        if (--c.symbolIn > 0) return;
        c.symbolIn = kSps;
        symbol(c, at, p);
        return;
    }
    if (c.warm < kWarm) {
        // First the plain mean, as the starting floor.
        c.warm++;
        c.noise += (p - c.noise) / static_cast<float>(c.warm);
        return;
    }
    if (c.state == Channel::State::Search) {
        // Noise floor: follows quiet stretches quickly, bursts only slowly.
        c.noise += (c.powerFast - c.noise) * (c.powerFast < c.noise ? 0.002f : 0.0001f);
        if (c.powerFast < kGate * c.noise) {
            c.dLive = false;
            return;
        }
    }
    if (c.dLive) {
        phaseTurn(c, at);
    } else {
        // Something came up: the phase turns of the last samples too, the
        // training sequence began before the power rose this far.
        for (int k = 0; k < kRing; k++) phaseTurn(c, k);
        c.dLive = true;
    }
    float ci = 0, cq = 0;
    for (int k = 0; k < kSyncLen; k++) {
        const int idx = (at - kSps * (kSyncLen - 1 - k)) & (kRing - 1);
        const float di = c.di[idx], dq = c.dq[idx];
        ci += di * syncI_[k] - dq * syncQ_[k];
        cq += di * syncQ_[k] + dq * syncI_[k];
    }
    const float metric = (ci * ci + cq * cq) * (1.f / (kSyncLen * kSyncLen));
    const float before = c.lastMetric;
    c.lastMetric = metric;
    if (c.state == Channel::State::Search) {
        if (metric < kSyncThreshold * kSyncThreshold) return;
        c.state = Channel::State::Peak;
        c.bestMetric = metric;
        c.bestBefore = before;
        c.bestAfter = -1;
        c.bestI = ci;
        c.bestQ = cq;
        c.bestAgo = 0;
        c.peakLeft = kSps / 2;
        return;
    }
    // Peak: the best timing within half a symbol.
    if (metric > c.bestMetric) {
        c.bestMetric = metric;
        c.bestBefore = before;
        c.bestAfter = -1;
        c.bestI = ci;
        c.bestQ = cq;
        c.bestAgo = 0;
    } else {
        if (c.bestAgo == 0) c.bestAfter = metric;
        c.bestAgo++;
    }
    if (--c.peakLeft > 0) return;
    stats_.syncs++;
    c.state = Channel::State::Burst;
    c.rot = std::atan2(c.bestQ, c.bestI);
    // Carrier phase at the training's last symbol, from all 17 of its
    // samples (each rotated back by its known phase and the offset).
    {
        const int last = at - c.bestAgo;
        float si = 0, sq = 0;
        int a = 0;
        for (int k = 0; k <= kSyncLen; k++) {
            if (k > 0) a += syncPhase_[k - 1];
            const int idx = (last - kSps * (kSyncLen - k)) & (kRing - 1);
            const float ph = -(a * static_cast<float>(kPi / 4) + (k - kSyncLen) * c.rot);
            const float co = std::cos(ph), sn = std::sin(ph);
            si += c.zi[idx] * co - c.zq[idx] * sn;
            sq += c.zi[idx] * sn + c.zq[idx] * co;
        }
        c.theta = std::atan2(sq, si);
        c.freq = c.rot;
        c.lastA = a & 7;
    }
    // Between the samples: the peak of a parabola through the best and its
    // neighbours; the symbols are interpolated between two samples, the
    // later one is where they're taken.
    float mu = 0;
    if (c.bestAfter >= 0) {
        const float den = c.bestBefore - 2 * c.bestMetric + c.bestAfter;
        if (den < 0) mu = std::max(-0.5f, std::min(0.5f, 0.5f * (c.bestBefore - c.bestAfter) / den));
    }
    c.frac = mu < 0 ? 1 + mu : mu;
    c.symbolIn = kSps - c.bestAgo + (mu < 0 ? 0 : 1);  // the first symbol after the training
    c.burstPower = c.powerFast;
    c.weak = 0;
    c.lfsr = kLfsrSeed;
    c.needBits = 0;
    c.bits.clear();
    c.soft.clear();
    c.lastMargin = 1;
}

void Vdl2MultiDemod::symbol(Channel& c, int at, float p)
{
    constexpr float step = static_cast<float>(kPi / 4);
    constexpr float pi = static_cast<float>(kPi);
    // Coherent: the carrier phase predicted, the symbol's phase decided,
    // the loop (2nd order) corrected by the decision's error.
    c.theta += c.freq;
    if (c.theta > pi) c.theta -= 2 * pi;
    if (c.theta < -pi) c.theta += 2 * pi;
    const int prev = (at - 1) & (kRing - 1);
    const float zi = c.zi[prev] + c.frac * (c.zi[at] - c.zi[prev]);
    const float zq = c.zq[prev] + c.frac * (c.zq[at] - c.zq[prev]);
    float ang = std::atan2(zq, zi) - c.theta;
    if (ang < -pi) ang += 2 * pi;
    if (ang > pi) ang -= 2 * pi;
    const int a = static_cast<int>(std::lround(ang / step));
    const float err = ang - a * step;
    c.theta += kLoopA * err;
    c.freq += kLoopB * err;
    const int k = (a - c.lastA) & 7;
    c.lastA = a;
    // How sure: the distance to the decision boundary, of this symbol's
    // phase and the last one's (the turn between them is the data).
    const float margin = std::max(0.f, 1.f - std::fabs(err) / (step / 2));
    const auto sure = static_cast<uint8_t>(std::lround(255 * std::min(margin, c.lastMargin)));
    c.lastMargin = margin;
    c.soft.push_back(sure);
    // Descrambled as they come.
    const uint8_t v = kGray[k & 7];
    for (int b = 2; b >= 0; b--) {
        const uint16_t out = (c.lfsr ^ (c.lfsr >> 14)) & 1;
        c.lfsr = static_cast<uint16_t>((c.lfsr >> 1) | (out << 14));
        c.bits.push_back(static_cast<uint8_t>(((v >> b) & 1) ^ out));
    }
    if (c.needBits == 0 && c.bits.size() >= kHeaderBits) {
        size_t need = 0;
        if (checkHeader(c.bits.data())) {
            uint32_t len = 0;
            for (int b = 0; b < 17; b++) len |= static_cast<uint32_t>(c.bits[static_cast<size_t>(3 + b)]) << b;
            need = burstBits(len);
        }
        if (need == 0) {  // no header: a false sync
            c.state = Channel::State::Search;
            c.dLive = false;
            return;
        }
        stats_.headers++;
        c.needBits = need;
        c.bits.reserve(need + 3);
    }
    if (c.needBits && c.bits.size() >= c.needBits) {
        endBurst(c, true);
        return;
    }
    // The carrier gone before its time: near the noise, or far below the
    // level the burst started with.
    c.weak = p < std::max(3.f * c.noise, 0.03f * c.burstPower) ? c.weak + 1 : 0;
    if (c.weak >= 4) endBurst(c, false);
}

size_t Vdl2MultiDemod::burstBits(uint32_t dataBits)
{
    if (dataBits < kMinDataBits) return 0;
    const int octets = static_cast<int>((dataBits + 7) / 8);
    const int blocks = (octets + kBlockData - 1) / kBlockData;
    if (blocks > kMaxBlocks) return 0;
    const int fec = 6 * (blocks - 1) + lastBlockFec(octets - kBlockData * (blocks - 1));
    return kHeaderBits + 8 * static_cast<size_t>(octets + fec);
}

void Vdl2MultiDemod::endBurst(Channel& c, bool complete)
{
    c.state = Channel::State::Search;
    c.dLive = false;
    if (!complete) return;
    stats_.bursts++;
    const auto frames = framesFromBits(c.bits, &c.soft, &stats_);
    if (!frames.empty()) {
        // The stick's tuning error (cheap ones are off by kHz here, more
        // than the filter allows): the carrier loop's offset at the end of a
        // burst that was received right, averaged over bursts (an
        // aircraft's own error is a few 100 Hz), corrects the mixers of all
        // channels.
        const float residualHz = c.freq / static_cast<float>(2 * kPi) * (kSampleRate / kDecimation / kSps);
        afcHz_ = std::max(-kAfcMaxHz, std::min(kAfcMaxHz, afcHz_ + 0.2f * residualHz));
    }
    for (const auto& frame : frames) {
        stats_.frames++;
        const auto msg = acarsFromFrame(frame);
        if (msg.empty()) continue;
        stats_.acars++;
        sink_.onAcarsFrame(c.freqHz, msg);
    }
}

bool Vdl2MultiDemod::checkHeader(uint8_t* bits)
{
    // The header's 5 check bits (a Hamming code, read off received bursts):
    // which of them each transmission length bit (0..11) flips. The columns
    // of length bits 12..16 never showed up (bursts of 512+ octets) - such
    // headers pass unchecked, as does a wrong check bit itself.
    static constexpr uint8_t kColumn[12] = {10, 11, 12, 14, 15, 17, 19, 21, 22, 24, 25, 26};
    if (bits[0] | bits[1] | bits[2]) return false;  // reserved: 0
    for (int b = 12; b < 17; b++)
        if (bits[3 + b]) return true;
    uint8_t syndrome = 0;
    for (int b = 0; b < 5; b++) syndrome = static_cast<uint8_t>(syndrome | (bits[20 + b] << (4 - b)));
    for (int b = 0; b < 12; b++)
        if (bits[3 + b]) syndrome ^= kColumn[b];
    if ((syndrome & (syndrome - 1)) == 0) return true;  // none, or a check bit
    for (int b = 0; b < 12; b++) {
        if (syndrome == kColumn[b]) {
            bits[3 + b] ^= 1;  // one wrong length bit
            return true;
        }
    }
    return false;
}

std::vector<std::vector<uint8_t>> Vdl2MultiDemod::framesFromBits(const std::vector<uint8_t>& bits,
                                                                 const std::vector<uint8_t>* soft, Stats* stats)
{
    if (bits.size() < kHeaderBits) return {};
    uint32_t len = 0;
    for (int b = 0; b < 17; b++) len |= static_cast<uint32_t>(bits[static_cast<size_t>(3 + b)] & 1) << b;
    const size_t total = burstBits(len);
    if (total == 0) return {};
    const int octets = static_cast<int>((len + 7) / 8);
    const int blocks = (octets + kBlockData - 1) / kBlockData;
    const int lastLen = octets - kBlockData * (blocks - 1);
    const int lastFec = lastBlockFec(lastLen);
    // The received octets (missing ones at the end stay 0).
    std::vector<uint8_t> rx((total - kHeaderBits) / 8, 0);
    for (size_t k = 0; k < rx.size(); k++) {
        uint8_t v = 0;
        for (int j = 0; j < 8; j++) {
            const size_t at = kHeaderBits + 8 * k + static_cast<size_t>(j);
            if (at < bits.size() && bits[at]) v = static_cast<uint8_t>(v | (1 << j));
        }
        rx[k] = v;
    }
    // Deinterleaved into the RS blocks: octet by octet across the blocks,
    // the last block (shorter) dropping out once it's full; the same for the
    // check octets after all data.
    std::vector<uint8_t> block(static_cast<size_t>(blocks) * kN, 0);
    std::vector<int> where(block.size(), -1);  // octet's index in rx
    int idx = 0;
    for (int col = 0; col < kBlockData; col++)
        for (int b = 0; b < blocks; b++)
            if (col < (b == blocks - 1 ? lastLen : kBlockData)) where[static_cast<size_t>(b * kN + col)] = idx++;
    for (int col = 0; col < kRoots; col++)
        for (int b = 0; b < blocks; b++)
            if (col < (b == blocks - 1 ? lastFec : kRoots)) where[static_cast<size_t>(b * kN + kBlockData + col)] = idx++;
    for (size_t j = 0; j < block.size(); j++)
        if (where[j] >= 0) block[j] = rx[static_cast<size_t>(where[j])];
    std::vector<uint8_t> data;
    data.reserve(static_cast<size_t>(octets) * 8);
    for (int b = 0; b < blocks; b++) {
        uint8_t* blk = block.data() + static_cast<size_t>(b) * kN;
        const int n = b == blocks - 1 ? lastLen : kBlockData;
        const int fec = b == blocks - 1 ? lastFec : kRoots;
        int fixed = rsDecode(blk, n, fec);
        if (fixed < 0 && soft && fec > 0) {
            // Too many errors: the least sure octets erased (an erasure
            // costs RS half an error), more and more of them, but always
            // one check octet left to confirm; a wrong guess still has to
            // get past the frames' FCS.
            std::vector<std::pair<int, int>> sure;  // (sureness, position)
            for (int j = 0; j < kN; j++) {
                const int at = where[static_cast<size_t>(b * kN + j)];
                if (at < 0) continue;
                const size_t from = (kHeaderBits + 8 * static_cast<size_t>(at)) / 3,
                             to = (kHeaderBits + 8 * static_cast<size_t>(at) + 7) / 3;
                int least = 0;  // missing: not sure at all
                if (to < soft->size()) {
                    least = 255;
                    for (size_t q = from; q <= to; q++) least = std::min<int>(least, (*soft)[q]);
                }
                sure.emplace_back(least, j);
            }
            std::sort(sure.begin(), sure.end());
            uint8_t copy[kN];
            int erased[kRoots];
            for (int e = 1; e < fec && e <= static_cast<int>(sure.size()) && fixed < 0; e++) {
                for (int q = 0; q < e; q++) erased[q] = sure[static_cast<size_t>(q)].second;
                std::copy(blk, blk + kN, copy);
                fixed = rsDecode(copy, n, fec, erased, e);
                if (fixed >= 0) std::copy(copy, copy + kN, blk);
            }
        }
        if (stats) {
            if (fixed < 0) stats->rsFailed++;
            else stats->rsCorrected += fixed;
        }
        // Uncorrectable: the frames in it fail their FCS, others still pass.
        for (int k = 0; k < n; k++)
            for (int j = 0; j < 8; j++) data.push_back((blk[k] >> j) & 1);
    }
    return hdlcFrames(data.data(), std::min<size_t>(len, data.size()));
}

std::vector<uint8_t> Vdl2MultiDemod::acarsFromFrame(const std::vector<uint8_t>& frame)
{
    // Destination (4) source (4) control (1) info: ACARS starts FF FF 01,
    // then mode, registration (7), ack, label (2), block id, STX, text,
    // ETX/ETB, BCS (2).
    constexpr size_t kInfo = 9;
    if (frame.size() < kInfo + 3 + 13) return {};
    if (frame[kInfo] != 0xFF || frame[kInfo + 1] != 0xFF || frame[kInfo + 2] != 0x01) return {};
    const size_t from = kInfo + 3;
    size_t end = 0;
    for (size_t i = from + 12; i < frame.size(); i++) {
        const uint8_t ch = frame[i] & 0x7F;
        if (ch == 0x03 || ch == 0x17) {
            end = i;
            break;
        }
    }
    if (end == 0) return {};
    std::vector<uint8_t> out{0x01};
    out.insert(out.end(), frame.begin() + static_cast<std::ptrdiff_t>(from),
               frame.begin() + static_cast<std::ptrdiff_t>(end + 1));
    for (size_t i = end + 1; i < end + 3; i++) out.push_back(i < frame.size() ? frame[i] : 0);
    return out;
}

std::vector<float> Vdl2MultiDemod::channelLevelsDb()
{
    std::vector<float> out;
    for (auto& c : channels_) {
        out.push_back(10.f * std::log10(std::max(c.peak, 1e-14f)));
        c.peak = 0;
    }
    return out;
}

void Vdl2MultiDemod::run(const std::atomic<bool>& stop)
{
    std::vector<uint8_t> raw(static_cast<size_t>(kReadSamples) * 2);
    while (!stop) {
        const int got = reader_.readIq(raw.data(), static_cast<int>(raw.size()));
        if (got <= 0 || stop) break;
        const int n = got / 2;
        process(raw.data(), n);
        double sq = 0;
        long clipped = 0;
        for (int k = 0; k < n; k++) {
            const uint8_t iv = raw[static_cast<size_t>(2 * k)], qv = raw[static_cast<size_t>(2 * k + 1)];
            const double di = (iv - 127.5) / 127.5, dq = (qv - 127.5) / 127.5;
            sq += di * di + dq * dq;
            clipped += (iv == 0) + (iv == 255) + (qv == 0) + (qv == 255);
        }
        if (n > 0) sink_.onAcarsLevel(static_cast<float>(std::sqrt(sq / n / 2)), static_cast<float>(clipped) / n / 2.f);
    }
}

} // namespace hrdab
