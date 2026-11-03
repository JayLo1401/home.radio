#include "nb_tx_sim.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <random>

namespace hrdab::test {

namespace {

using cd = std::complex<double>;

// Recursive oscillator (one complex multiply per sample).
struct Osc {
    cd p, step;
    int n = 0;
    Osc(double hz, double rate, double phase) : p(std::polar(1.0, phase)), step(std::polar(1.0, 2 * M_PI * hz / rate)) {}
    cd next()
    {
        const cd v = p;
        p *= step;
        if (++n == 4096) {
            n = 0;
            p /= std::abs(p);
        }
        return v;
    }
};

constexpr double kA1 = 0.55, kA2 = 0.45;   // tone amplitudes, peak sum 1
constexpr double kSyllableHz = 3.0;

struct StationState {
    const NbStation& st;
    double rate;
    Osc carrier, t1, t2, syl;
    double amp = 1;
    double fmPhase = 0;

    StationState(const NbStation& s, double r, double noiseIn8k, unsigned seed)
        : st(s), rate(r), carrier(s.offsetHz, r, 0.3 + seed), t1(s.tone1Hz, r, 0.1 * seed), t2(s.tone2Hz, r, 1.7),
          syl(kSyllableHz, r, 0.5 * seed)
    {
        // Average power while keyed: envelope e = 0.75 + 0.25 sin, E[e^2].
        const double e2 = 0.75 * 0.75 + 0.25 * 0.25 / 2;
        const double tones = kA1 * kA1 + kA2 * kA2;
        double unit;  // power for amp = 1
        switch (s.mode) {
            case NbTxMode::Am: unit = 1 + s.depth * s.depth * e2 * tones / 2; break;
            case NbTxMode::Fm:
            case NbTxMode::Wfm: unit = 1; break;
            default: unit = e2 * tones; break;
        }
        const double want = noiseIn8k * std::pow(10.0, s.snrDb / 10);
        amp = std::sqrt(want / unit);
    }

    cd sample(double t)
    {
        const cd c = carrier.next();
        const cd a = t1.next(), b = t2.next();
        const double env = 0.75 + 0.25 * syl.next().imag();
        if (t < st.onS || t >= st.offS) return 0;
        // 5 ms key ramps, as a real transmitter's.
        const double ramp = std::min(1.0, std::min(t - st.onS, st.offS - t) / 0.005);
        cd base;
        switch (st.mode) {
            case NbTxMode::Am: {
                const double m = env * (kA1 * a.imag() + kA2 * b.imag());
                base = cd(1 + st.depth * m, 0);
                break;
            }
            case NbTxMode::Fm:
            case NbTxMode::Wfm: {
                const double m = st.mode == NbTxMode::Wfm ? a.imag() : env * (kA1 * a.imag() + kA2 * b.imag());
                fmPhase += 2 * M_PI * st.deviationHz * m / rate;
                if (fmPhase > M_PI) fmPhase -= 2 * M_PI;
                if (fmPhase < -M_PI) fmPhase += 2 * M_PI;
                base = std::polar(1.0, fmPhase);
                break;
            }
            case NbTxMode::Usb: base = env * (kA1 * a + kA2 * b); break;
            case NbTxMode::Lsb: base = env * (kA1 * std::conj(a) + kA2 * std::conj(b)); break;
        }
        return amp * ramp * base * c;
    }
};

} // namespace

std::vector<uint8_t> generateNb(const NbTxConfig& cfg, double seconds)
{
    const double rate = cfg.sampleRate;
    const size_t n = static_cast<size_t>(seconds * rate);
    // Noise: unit complex variance per sample over the full rate.
    const double noiseIn8k = 8000.0 / rate;
    std::vector<StationState> stations;
    stations.reserve(cfg.stations.size());
    double total = 1.0;
    for (const auto& s : cfg.stations) {
        stations.emplace_back(s, rate, noiseIn8k, static_cast<unsigned>(stations.size() + 1));
        total += noiseIn8k * std::pow(10.0, s.snrDb / 10);
    }
    const double scale = cfg.rms / std::sqrt(total / 2);
    const double sigma = std::sqrt(0.5) * scale;

    std::mt19937 rng(cfg.seed);
    std::normal_distribution<float> normal(0.f, 1.f);
    std::vector<float> table(1 << 20);
    for (auto& v : table) v = normal(rng);
    size_t ni = 0;

    // Impulses use their own generator, so a config with and one without
    // them get identical stations and noise.
    std::mt19937 irng(cfg.seed + 99);
    std::uniform_real_distribution<double> uni(0.0, 1.0);
    const size_t impulseLen = std::max<size_t>(2, static_cast<size_t>(std::lround(cfg.impulseUs * 1e-6 * rate)));
    auto nextImpulse = [&](size_t from) {
        if (cfg.impulseRateHz <= 0) return n;
        return from + static_cast<size_t>(rate / cfg.impulseRateHz * (0.5 + uni(irng)));
    };
    size_t impulseAt = nextImpulse(0), impulseLeft = 0;
    cd impulse(0, 0);

    std::vector<uint8_t> out(2 * n);
    for (size_t i = 0; i < n; i++) {
        if ((i & 4095) == 0) ni = rng() % (table.size() - 3 * 4096);
        const double t = i / rate;
        cd z(0, 0);
        for (auto& st : stations) z += st.sample(t);
        z *= scale;
        if (i == impulseAt) {
            impulse = std::polar(cfg.impulseAmp, 2 * M_PI * uni(irng));
            impulseLeft = impulseLen;
            impulseAt = nextImpulse(i);
        }
        if (impulseLeft > 0) {
            z += impulse;
            impulseLeft--;
        }
        const double re = z.real() + sigma * table[ni++];
        const double im = z.imag() + sigma * table[ni++];
        out[2 * i] = static_cast<uint8_t>(std::max(0.0, std::min(255.0, std::round(127.5 + 127.5 * re))));
        out[2 * i + 1] = static_cast<uint8_t>(std::max(0.0, std::min(255.0, std::round(127.5 + 127.5 * im))));
    }
    return out;
}

} // namespace hrdab::test
