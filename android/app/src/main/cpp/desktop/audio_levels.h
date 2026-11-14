#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace hrdab {

// Spectrum bars for the equalizer in the Now Playing banner, computed from
// the PCM that actually goes to the speaker. Same analysis as
// AudioLevelMeter.kt on Android:
//  - the output is mixed to mono into a ring of the last kSize samples
//  - every kHopMs (25 times a second) those get a Hann window and a
//    1024-point FFT, and the power is summed into kBands octave-wide bands
//    (log-spaced from 60 Hz up to 14 kHz, or a bit below Nyquist)
//  - each band in dB (re a full-scale sine, slightly tilted up towards the
//    treble, where music has less energy) is mapped to 0..1, rises fast and
//    falls slowly, and is sent as one byte (0..255)
//
// Threads: push() is called from the audio device callback, take() from the
// player's own thread - both under the player's levels mutex. analyze() runs
// on the player's thread only, outside that mutex.
class AudioLevels {
public:
    static constexpr int kBands = 8;
    static constexpr int kSize = 1024;
    static constexpr int kHopMs = 40;

    AudioLevels()
    {
        constexpr double pi = 3.14159265358979323846;
        for (int i = 0; i < kSize; i++) window_[i] = static_cast<float>(0.5 - 0.5 * std::cos(2 * pi * i / kSize));
        for (int i = 0; i < kSize / 2; i++) {
            cos_[i] = static_cast<float>(std::cos(2 * pi * i / kSize));
            sin_[i] = static_cast<float>(-std::sin(2 * pi * i / kSize));
        }
        int bits = 0;
        while ((1 << bits) < kSize) bits++;
        for (int i = 0; i < kSize; i++) {
            int r = 0;
            for (int b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b);
            rev_[i] = r;
        }
    }

    // --- device callback side (under the levels mutex) ---

    // Appends interleaved PCM, mixed to mono.
    void push(const int16_t* pcm, size_t frames, int channels, int rate)
    {
        if (channels <= 0) return;
        if (rate != rate_) {
            rate_ = rate;
            pending_ = 0;
        }
        for (size_t f = 0; f < frames; f++) {
            int sum = 0;
            for (int c = 0; c < channels; c++) sum += pcm[f * channels + c];
            ring_[pos_] = static_cast<float>(sum) / (32768.0f * channels);
            pos_ = (pos_ + 1) % kSize;
        }
        pending_ += frames;
    }

    // A new analysis is due: copies the last kSize samples (oldest first)
    // into `out` and returns the sample rate, else returns 0.
    int take(float* out)
    {
        const size_t hop = static_cast<size_t>(rate_) * kHopMs / 1000;
        if (rate_ <= 0 || pending_ < hop) return 0;
        pending_ = std::min(pending_ - hop, hop); // never queue up a backlog
        for (int i = 0; i < kSize; i++) out[i] = ring_[(pos_ + i) % kSize];
        return rate_;
    }

    // --- player thread side ---

    // Band levels (0..255) of one window from take(). Returns false when
    // there is nothing worth sending: silence that has already been sent
    // (repeated once a second only, so the app knows the player is alive).
    bool analyze(const float* samples, int rate, uint8_t* out)
    {
        if (rate != bandsRate_) setupBands(rate);
        for (int i = 0; i < kSize; i++) {
            re_[rev_[i]] = samples[i] * window_[i];
            im_[rev_[i]] = 0;
        }
        fft();
        // Full-scale sine through the Hann window: sum of |X|^2 over the
        // positive half = N^2 * 3/32.
        constexpr float ref = kSize * static_cast<float>(kSize) * 3.0f / 32.0f;
        bool any = false;
        for (int b = 0; b < kBands; b++) {
            float power = 0;
            for (int k = binLo_[b]; k < binHi_[b]; k++) power += re_[k] * re_[k] + im_[k] * im_[k];
            const float db = 10.0f * std::log10(power / ref + 1e-12f) + kTiltDb * b;
            const float target = std::clamp((db - kFloorDb) / (kTopDb - kFloorDb), 0.0f, 1.0f);
            float& v = smooth_[b];
            if (target > v) v += (target - v) * kAttack;
            else v = std::max(target, v - kFall);
            out[b] = static_cast<uint8_t>(std::lround(v * 255));
            if (out[b] != 0) any = true;
        }
        // Silence: send the first all-zero set (bars down), then a heartbeat.
        if (!any) {
            if (silentFrames_++ % (1000 / kHopMs) != 0) return false;
        } else {
            silentFrames_ = 0;
        }
        return true;
    }

private:
    static constexpr float kFloorDb = -50;
    static constexpr float kTopDb = -8;
    static constexpr float kTiltDb = 2;  // per band, towards the treble
    static constexpr float kAttack = 0.7f;
    static constexpr float kFall = 0.06f; // per hop: full scale in ~0.7 s

    void setupBands(int rate)
    {
        bandsRate_ = rate;
        const double lo = 60.0;
        const double hi = std::min(14000.0, 0.45 * rate);
        for (int b = 0; b < kBands; b++) {
            const double f0 = lo * std::pow(hi / lo, static_cast<double>(b) / kBands);
            const double f1 = lo * std::pow(hi / lo, static_cast<double>(b + 1) / kBands);
            int k0 = std::max(1, static_cast<int>(std::lround(f0 * kSize / rate)));
            int k1 = static_cast<int>(std::lround(f1 * kSize / rate));
            k0 = std::min(k0, kSize / 2 - 1);
            binLo_[b] = k0;
            binHi_[b] = std::clamp(k1, k0 + 1, kSize / 2);
        }
    }

    // In-place radix-2 FFT of re_/im_ (already in bit-reversed order).
    void fft()
    {
        for (int len = 2; len <= kSize; len <<= 1) {
            const int half = len >> 1;
            const int step = kSize / len;
            for (int i = 0; i < kSize; i += len) {
                for (int j = 0; j < half; j++) {
                    const float wr = cos_[j * step];
                    const float wi = sin_[j * step];
                    const int a = i + j;
                    const int b = a + half;
                    const float tr = re_[b] * wr - im_[b] * wi;
                    const float ti = re_[b] * wi + im_[b] * wr;
                    re_[b] = re_[a] - tr;
                    im_[b] = im_[a] - ti;
                    re_[a] += tr;
                    im_[a] += ti;
                }
            }
        }
    }

    // Device callback side.
    std::array<float, kSize> ring_{};
    int pos_ = 0;
    size_t pending_ = 0;
    int rate_ = 0;

    // Player thread side.
    std::array<float, kSize> window_{};
    std::array<float, kSize / 2> cos_{};
    std::array<float, kSize / 2> sin_{};
    std::array<int, kSize> rev_{};
    std::array<float, kSize> re_{};
    std::array<float, kSize> im_{};
    std::array<int, kBands> binLo_{};
    std::array<int, kBands> binHi_{};
    std::array<float, kBands> smooth_{};
    int bandsRate_ = 0;
    unsigned silentFrames_ = 0;
};

} // namespace hrdab
