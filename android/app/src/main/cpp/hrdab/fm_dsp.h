// Small DSP building blocks for the FM (UKW) receiver: FIR design, a
// decimating FIR and a rational resampler over interleaved channels, a sine
// table and a fast atan2. Everything runs on float; the filters skip zero
// taps, so half-band designs cost half.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace hrdab {

// Kaiser-windowed sinc low-pass with unity DC gain. `cutoff` is the -6 dB
// point in cycles/sample (0..0.5), i.e. the middle of the transition band.
// A cutoff of exactly 0.25 gives a half-band filter (every other tap zero).
std::vector<float> designLowpass(int taps, double cutoff, double kaiserBeta);

// Kaiser beta for a wanted stop-band attenuation in dB.
double kaiserBeta(double attenuationDb);

// sin(2*pi*phase/2^32) from a 4096-entry table (phase error < 0.0008 rad,
// which keeps the stereo crosstalk of the 38 kHz reference below -55 dB).
float sinTable(uint32_t phase);
inline float cosTable(uint32_t phase) { return sinTable(phase + 0x40000000u); }

// atan2 with a maximum error of ~1e-5 rad - libm's is several times slower
// and the discriminator calls this 256000 times a second.
inline float fastAtan2(float y, float x)
{
    const float ax = std::fabs(x), ay = std::fabs(y);
    const float mx = ax > ay ? ax : ay;
    if (mx == 0.f) return 0.f;
    const float mn = ax > ay ? ay : ax;
    const float a = mn / mx;
    const float s = a * a;
    // Polynomial for atan on [0,1], |error| <= 1e-5 (Abramowitz/Stegun 4.4.49).
    float r = a * (0.9998660f + s * (-0.3302995f + s * (0.1801410f + s * (-0.0851330f + s * 0.0208351f))));
    if (ay > ax) r = 1.57079637f - r;
    if (x < 0.f) r = 3.14159274f - r;
    return y < 0.f ? -r : r;
}

// Decimating FIR over C interleaved float channels (C = 2: one complex
// stream, or two real streams filtered with the same taps).
template <int C>
class FirDecimator {
public:
    void init(const std::vector<float>& taps, int factor)
    {
        len_ = static_cast<int>(taps.size());
        factor_ = factor;
        idx_.clear();
        coef_.clear();
        for (int i = 0; i < len_; i++) {
            if (taps[static_cast<size_t>(i)] == 0.f) continue;
            idx_.push_back(i);
            coef_.push_back(taps[static_cast<size_t>(i)]);
        }
        reset();
    }

    void reset()
    {
        buf_.assign(static_cast<size_t>((len_ - 1) * C), 0.f);
        next_ = len_ - 1;
    }

    // Consumes `n` frames, writes the outputs to `out`; returns their count.
    int process(const float* in, int n, float* out)
    {
        const size_t histFrames = buf_.size() / C;
        buf_.resize((histFrames + static_cast<size_t>(n)) * C);
        std::memcpy(&buf_[histFrames * C], in, sizeof(float) * static_cast<size_t>(n) * C);
        const int total = static_cast<int>(histFrames) + n;
        const int taps = static_cast<int>(idx_.size());
        int produced = 0;
        while (next_ < total) {
            const float* base = &buf_[static_cast<size_t>(next_ - len_ + 1) * C];
            float acc[C] = {};
            for (int k = 0; k < taps; k++) {
                const float* p = base + idx_[static_cast<size_t>(k)] * C;
                const float c = coef_[static_cast<size_t>(k)];
                for (int ch = 0; ch < C; ch++) acc[ch] += c * p[ch];
            }
            for (int ch = 0; ch < C; ch++) out[produced * C + ch] = acc[ch];
            produced++;
            next_ += factor_;
        }
        const int keep = len_ - 1;
        const int shift = total - keep;
        std::memmove(buf_.data(), &buf_[static_cast<size_t>(shift) * C], sizeof(float) * static_cast<size_t>(keep) * C);
        buf_.resize(static_cast<size_t>(keep) * C);
        next_ -= shift;
        return produced;
    }

private:
    std::vector<int> idx_;
    std::vector<float> coef_;
    std::vector<float> buf_;
    int len_ = 1;
    int factor_ = 1;
    int next_ = 0;
};

// Polyphase resampler by up/down, C interleaved channels. The taps are
// designed at up * input rate; the DC gain of the output is that of the taps.
template <int C>
class RationalResampler {
public:
    void init(const std::vector<float>& taps, int up, int down)
    {
        up_ = up;
        down_ = down;
        perPhase_ = (static_cast<int>(taps.size()) + up - 1) / up;
        // phases_[p][m] = up * taps[p + m*up], so a full-scale input stays
        // full scale after zero-stuffing.
        phases_.assign(static_cast<size_t>(up * perPhase_), 0.f);
        for (int p = 0; p < up; p++) {
            for (int m = 0; m < perPhase_; m++) {
                const size_t i = static_cast<size_t>(p + m * up);
                phases_[static_cast<size_t>(p * perPhase_ + m)] = i < taps.size() ? up * taps[i] : 0.f;
            }
        }
        reset();
    }

    void reset()
    {
        buf_.assign(static_cast<size_t>((perPhase_ - 1) * C), 0.f);
        t_ = static_cast<long>(perPhase_ - 1) * up_;
    }

    int process(const float* in, int n, float* out)
    {
        const size_t histFrames = buf_.size() / C;
        buf_.resize((histFrames + static_cast<size_t>(n)) * C);
        std::memcpy(&buf_[histFrames * C], in, sizeof(float) * static_cast<size_t>(n) * C);
        const long total = static_cast<long>(histFrames) + n;
        int produced = 0;
        while (t_ / up_ < total) {
            const long base = t_ / up_;
            const int phase = static_cast<int>(t_ % up_);
            const float* h = &phases_[static_cast<size_t>(phase * perPhase_)];
            float acc[C] = {};
            for (int m = 0; m < perPhase_; m++) {
                const float* p = &buf_[static_cast<size_t>(base - m) * C];
                for (int ch = 0; ch < C; ch++) acc[ch] += h[m] * p[ch];
            }
            for (int ch = 0; ch < C; ch++) out[produced * C + ch] = acc[ch];
            produced++;
            t_ += down_;
        }
        const long keep = perPhase_ - 1;
        const long shift = total - keep;
        std::memmove(buf_.data(), &buf_[static_cast<size_t>(shift) * C], sizeof(float) * static_cast<size_t>(keep) * C);
        buf_.resize(static_cast<size_t>(keep) * C);
        t_ -= shift * up_;
        return produced;
    }

private:
    std::vector<float> phases_;
    std::vector<float> buf_;
    int up_ = 1, down_ = 1, perPhase_ = 1;
    long t_ = 0;
};

} // namespace hrdab
