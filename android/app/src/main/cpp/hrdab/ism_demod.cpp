#include "ism_demod.h"

#include <algorithm>
#include <cmath>

namespace hrdab {

namespace {

constexpr double kRate = static_cast<double>(IsmDemod::kSampleRate) / IsmDemod::kDecimation;  // 256 kS/s
constexpr double kUsPerSample = 1e6 / kRate;
constexpr double kOnRatio = 10.0;     // pulse starts 10 dB above the noise floor
constexpr double kOffRatio = 4.0;     // ... and ends below 6 dB
constexpr double kOffOfPeak = 0.04;   // or 14 dB below the pulse's peak
constexpr int kBurstEndUs = 10000;    // a gap this long ends the burst
constexpr int kMinPulses = 8;         // fewer: a click, not data
constexpr int kMaxDurations = 2400;
constexpr int kFskMinUs = 2000;       // a pulse this long may be an FSK burst
constexpr double kFskMinSpreadHz = 8000;
constexpr int kReadSamples = 65536;   // at 1,024 MS/s: 64 ms

int toUs(int samples)
{
    return static_cast<int>(std::lround(samples * kUsPerSample));
}

} // namespace

IsmDemod::IsmDemod(IqReader& reader, IsmSink& sink) : reader_(reader), sink_(sink) {}

void IsmDemod::process(const float* iq, int n)
{
    for (int k = 0; k < n; k++) {
        const float i = iq[2 * k], q = iq[2 * k + 1];
        // Envelope smoothed over ~3 samples (12 us): single noise spikes
        // must not start a pulse, the shortest real pulses (~100 us) stay.
        const double raw = static_cast<double>(i) * i + static_cast<double>(q) * q;
        env_ += (raw - env_) * 0.35;
        const double p = env_;
        // First 4 ms: only measure the noise floor.
        if (warmup_ < 1024) {
            noise_ += (p - noise_) / ++warmup_;
            prevI_ = i;
            prevQ_ = q;
            continue;
        }
        if (!high_) {
            // Right after a pulse its fading tail must not start another
            // one: the bar starts at a tenth of that pulse and decays.
            recent_ *= 0.97;
            if (p > noise_ * kOnRatio && p > recent_ * 0.1) {
                // Pulse starts: the gap before it is done.
                if (inBurst_) durations_.push_back(run_);
                high_ = true;
                inBurst_ = true;
                run_ = 0;
                peak_ = p;
                pulseFreq_.clear();
            } else {
                // Noise floor follows the quiet parts only.
                noise_ += (p - noise_) * 0.0005;
                run_++;
                if (inBurst_ && toUs(run_) > kBurstEndUs) burstEnd();
            }
        }
        if (high_) {
            if (p > peak_) peak_ = p;
            if (p < noise_ * kOffRatio || p < peak_ * kOffOfPeak) {
                pulseEnd(run_);
                recent_ = peak_;
                high_ = false;
                run_ = 1;
            } else {
                run_++;
                sigSum_ += p;
                sigN_++;
                // Instantaneous frequency: angle of z[n] * conj(z[n-1]).
                const double re = static_cast<double>(i) * prevI_ + static_cast<double>(q) * prevQ_;
                const double im = static_cast<double>(q) * prevI_ - static_cast<double>(i) * prevQ_;
                const float f = static_cast<float>(std::atan2(im, re) * kRate / (2 * 3.14159265358979));
                pulseFreq_.push_back(f);
                freqSum_ += f;
            }
        }
        prevI_ = i;
        prevQ_ = q;
    }
}

void IsmDemod::pulseEnd(int samples)
{
    durations_.push_back(samples);
    if (toUs(samples) >= kFskMinUs && pulseFreq_.size() > longestFreq_.size()) longestFreq_ = pulseFreq_;
    if (static_cast<int>(durations_.size()) >= kMaxDurations) burstEnd();
}

void IsmDemod::burstEnd()
{
    // A burst ending inside a pulse keeps that pulse.
    const int pulses = static_cast<int>((durations_.size() + 1) / 2);
    const double level = sigN_ > 0 ? sigSum_ / sigN_ : 0;
    const float levelDb = static_cast<float>(10 * std::log10(std::max(level, 1e-12)));
    const float snrDb = static_cast<float>(10 * std::log10(std::max(level, 1e-12) / std::max(noise_, 1e-12)));
    const float offset = sigN_ > 0 ? static_cast<float>(freqSum_ / sigN_) : 0.f;

    if (pulses >= kMinPulses) {
        std::vector<int> us;
        us.reserve(durations_.size());
        for (int d : durations_) us.push_back(toUs(d));
        sink_.onIsmBurst("ook", us, offset, levelDb, snrDb);
    }
    // FSK: slice the longest carrier's frequency around its middle -
    // smoothed over 3 samples first, so single noisy samples don't split a
    // bit into slivers.
    if (longestFreq_.size() > 16) {
        std::vector<float> smooth(longestFreq_.size());
        for (size_t k = 0; k < longestFreq_.size(); k++) {
            const size_t a = k > 0 ? k - 1 : k, b = k + 1 < longestFreq_.size() ? k + 1 : k;
            smooth[k] = (longestFreq_[a] + longestFreq_[k] + longestFreq_[b]) / 3;
        }
        longestFreq_.swap(smooth);
        std::vector<float> sorted = longestFreq_;
        std::sort(sorted.begin(), sorted.end());
        const float lo = sorted[sorted.size() / 10], hi = sorted[sorted.size() * 9 / 10];
        if (hi - lo >= kFskMinSpreadHz) {
            const float mid = (lo + hi) / 2;
            std::vector<int> runs;
            bool state = true;  // first run reported as "high"
            bool cur = longestFreq_[0] > mid;
            int len = 0;
            for (float f : longestFreq_) {
                const bool b = f > mid;
                if (b == cur) {
                    len++;
                    continue;
                }
                runs.push_back(len);
                cur = b;
                len = 1;
                state = !state;
            }
            runs.push_back(len);
            // Noise flips every sample or two; data holds its level longer.
            std::vector<int> sortedRuns = runs;
            std::sort(sortedRuns.begin(), sortedRuns.end());
            const bool noise = sortedRuns[sortedRuns.size() / 2] < 3;
            if (!noise && runs.size() >= 2 * kMinPulses) {
                std::vector<int> us;
                us.reserve(runs.size());
                // Starting with a "low" run: report a zero-length high first,
                // so high/low stay in place (high = upper frequency).
                if (!(longestFreq_[0] > mid)) us.push_back(0);
                for (int r : runs) us.push_back(toUs(r));
                sink_.onIsmBurst("fsk", us, offset, levelDb, snrDb);
            }
            (void)state;
        }
    }
    inBurst_ = false;
    durations_.clear();
    longestFreq_.clear();
    sigSum_ = 0;
    sigN_ = 0;
    freqSum_ = 0;
}

void IsmDemod::run(const std::atomic<bool>& stop)
{
    // A fresh start (another frequency, after another mode).
    noise_ = env_ = recent_ = 0;
    warmup_ = 0;
    high_ = inBurst_ = false;
    run_ = 0;
    durations_.clear();
    longestFreq_.clear();
    sigSum_ = freqSum_ = 0;
    sigN_ = 0;
    std::vector<uint8_t> raw(static_cast<size_t>(kReadSamples) * 2);
    std::vector<float> dec(static_cast<size_t>(kReadSamples / kDecimation) * 2);
    double dcI = 127.5, dcQ = 127.5;
    while (!stop) {
        const int got = reader_.readIq(raw.data(), static_cast<int>(raw.size()));
        if (got <= 0 || stop) break;
        const int n = got / 2;
        // DC offset of the stick (slowly followed), level for the AGC.
        double sumI = 0, sumQ = 0, sq = 0;
        long clipped = 0;
        for (int k = 0; k < n; k++) {
            const uint8_t iv = raw[static_cast<size_t>(2 * k)], qv = raw[static_cast<size_t>(2 * k + 1)];
            sumI += iv;
            sumQ += qv;
            clipped += (iv == 0) + (iv == 255) + (qv == 0) + (qv == 255);
        }
        dcI += (sumI / n - dcI) * 0.2;
        dcQ += (sumQ / n - dcQ) * 0.2;
        // Average 4 samples -> 256 kS/s (a simple low-pass against aliasing).
        const int m = n / kDecimation;
        for (int k = 0; k < m; k++) {
            float si = 0, sq4 = 0;
            for (int j = 0; j < kDecimation; j++) {
                const size_t o = static_cast<size_t>(2 * (k * kDecimation + j));
                si += static_cast<float>((raw[o] - dcI) / 127.5);
                sq4 += static_cast<float>((raw[o + 1] - dcQ) / 127.5);
            }
            dec[static_cast<size_t>(2 * k)] = si / kDecimation;
            dec[static_cast<size_t>(2 * k + 1)] = sq4 / kDecimation;
            sq += static_cast<double>(si) * si / 16 + static_cast<double>(sq4) * sq4 / 16;
        }
        process(dec.data(), m);
        if (m > 0) sink_.onIsmLevel(static_cast<float>(std::sqrt(sq / m / 2)), static_cast<float>(clipped) / n / 2.f);
    }
}

} // namespace hrdab
