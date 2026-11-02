#include "fm_tx_sim.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <random>

#include "common.h"
#include "rds.h"

namespace hrdab::test {

namespace {

using cd = std::complex<double>;

// Recursive oscillator (one complex multiply per sample).
struct Osc {
    cd p, step;
    int n = 0;
    Osc(double hz, double phase) : p(std::polar(1.0, phase)), step(std::polar(1.0, 2 * M_PI * hz / kSampleRate)) {}
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

double preEmphasis(double hz)
{
    const double w = 2 * M_PI * hz * 50e-6;
    return std::sqrt(1 + w * w);
}

constexpr double kBitRate = 1187.5;
constexpr int kPulseSpanBits = 2; // pulse table covers -2T .. +2.5T

// Biphase symbol as EN 50067 shapes it: a +1/-1 impulse pair T/2 apart
// through H(f) = cos(pi f T / 4) for f < 2/T, whose impulse response is
// h(t) ~ cos(4 pi t / T) / (1 - 64 t^2 / T^2). Sampled at the I/Q rate,
// normalised to a peak of 1.
const std::vector<float>& biphasePulse()
{
    static const std::vector<float> table = [] {
        const double t = 1.0 / kBitRate;
        auto h = [t](double x) {
            const double u = x / t;
            const double den = 1 - 64 * u * u;
            if (std::fabs(den) < 1e-9) return M_PI / 4; // limit at |t| = T/8
            return std::cos(4 * M_PI * u) / den;
        };
        const int len = static_cast<int>((2 * kPulseSpanBits + 0.5) * kSampleRate / kBitRate) + 1;
        std::vector<float> p(static_cast<size_t>(len));
        double peak = 0;
        for (int i = 0; i < len; i++) {
            const double x = static_cast<double>(i) / kSampleRate - kPulseSpanBits * t;
            const double v = h(x) - h(x - t / 2);
            p[static_cast<size_t>(i)] = static_cast<float>(v);
            peak = std::max(peak, std::fabs(v));
        }
        for (auto& v : p) v = static_cast<float>(v / peak);
        return p;
    }();
    return table;
}

struct StationState {
    const FmStation& st;
    Osc pilot, left, right, rdsClock, carrier;
    cd mod{1, 0};
    int modCount = 0;
    std::vector<int8_t> rdsSymbols; // differentially encoded, +-1
    double bitPhase = 0;
    size_t bitIndex = 0;
    double peL, peR;

    StationState(const FmStation& s, double seconds, unsigned seed)
        : st(s),
          pilot(19000, 0.3 + seed % 7),
          left(s.leftHz, 0.1),
          right(s.rightHz, 1.1),
          rdsClock(1187.5, 0),
          carrier(s.offsetHz, 0.7),
          peL(preEmphasis(s.leftHz)),
          peR(preEmphasis(s.rightHz))
    {
        if (s.rds) {
            const auto groups = rdsGroups(s);
            const int bitsPerCycle = static_cast<int>(groups.size()) * 104;
            const int repeat = static_cast<int>(seconds * 1187.5 / bitsPerCycle) + 2;
            const auto bits = rdsBits(groups, repeat);
            int prev = 0;
            for (uint8_t b : bits) {
                prev ^= b;
                rdsSymbols.push_back(prev ? 1 : -1);
            }
        }
    }

    cd sample()
    {
        const cd pp = pilot.next();
        const double s1 = pp.imag(), c1 = pp.real();
        const double s2 = 2 * s1 * c1;
        const double s3 = 3 * s1 - 4 * s1 * s1 * s1;
        const double l = st.toneAmp * peL * left.next().imag();
        const double r = st.toneAmp * peR * right.next().imag();
        double mpx = st.stereo ? 0.9 * ((l + r) / 2 + (l - r) / 2 * s2) + 0.09 * s1 : 0.9 * (l + r) / 2;
        if (st.rds) {
            double v;
            if (st.rdsShaped) {
                // Sum of the shaped symbols of the neighbouring bits.
                const auto& pulse = biphasePulse();
                v = 0;
                const double perBit = kSampleRate / kBitRate;
                for (int k = -kPulseSpanBits; k <= kPulseSpanBits; k++) {
                    const long bit = static_cast<long>(bitIndex) + k;
                    if (bit < 0 || bit >= static_cast<long>(rdsSymbols.size())) continue;
                    // Position of this sample within bit `bit`'s pulse.
                    const long idx = std::lround((bitPhase - k + kPulseSpanBits) * perBit);
                    if (idx >= 0 && idx < static_cast<long>(pulse.size())) v += rdsSymbols[static_cast<size_t>(bit)] * pulse[static_cast<size_t>(idx)];
                }
            } else {
                // One biphase symbol = one full cycle at the bit rate.
                v = rdsSymbols[bitIndex] * rdsClock.next().imag();
            }
            mpx += st.rdsLevel * v * s3;
            bitPhase += kBitRate / kSampleRate;
            if (bitPhase >= 1) {
                bitPhase -= 1;
                if (++bitIndex >= rdsSymbols.size()) bitIndex = 0;
            }
        }
        const double d = 2 * M_PI * 75000.0 * mpx / kSampleRate;
        const double d2 = d * d;
        const cd step(1 - d2 / 2 + d2 * d2 / 24 - d2 * d2 * d2 / 720, d - d * d2 / 6 + d * d2 * d2 / 120);
        mod *= step;
        if (++modCount == 4096) {
            modCount = 0;
            mod /= std::abs(mod);
        }
        return st.amplitude * carrier.next() * mod;
    }
};

} // namespace

std::vector<std::vector<uint16_t>> rdsGroups(const FmStation& st)
{
    std::string ps = st.ps;
    ps.resize(8, ' ');
    std::string rt = st.rt;
    if (!rt.empty()) {
        if (rt.size() < 64) rt += '\r';
        while (rt.size() % 4) rt += ' ';
        if (rt.size() > 64) rt.resize(64);
    }
    const int segments = static_cast<int>(rt.size() / 4);
    auto byte = [](const std::string& s, size_t i) { return static_cast<uint16_t>(static_cast<uint8_t>(s[i])); };
    auto group0A = [&](int seg) {
        return std::vector<uint16_t>{st.pi, static_cast<uint16_t>((0 << 12) | (10 << 5) | (1 << 3) | seg), 0xE120,
                                     static_cast<uint16_t>(byte(ps, 2 * seg) << 8 | byte(ps, 2 * seg + 1))};
    };
    std::vector<std::vector<uint16_t>> groups;
    if (segments == 0) {
        for (int seg = 0; seg < 4; seg++) groups.push_back(group0A(seg));
        return groups;
    }
    const int cycles = std::max(segments, 2);
    for (int k = 0; k < cycles; k++) {
        groups.push_back(group0A((2 * k) % 4));
        groups.push_back(group0A((2 * k + 1) % 4));
        const int seg = k % segments;
        groups.push_back({st.pi, static_cast<uint16_t>((2 << 12) | (10 << 5) | (0 << 4) | seg),
                          static_cast<uint16_t>(byte(rt, 4 * seg) << 8 | byte(rt, 4 * seg + 1)),
                          static_cast<uint16_t>(byte(rt, 4 * seg + 2) << 8 | byte(rt, 4 * seg + 3))});
    }
    return groups;
}

std::vector<uint8_t> rdsBits(const std::vector<std::vector<uint16_t>>& groups, int repeat)
{
    static const RdsOffset kOffsets[4] = {kRdsA, kRdsB, kRdsC, kRdsD};
    std::vector<uint8_t> bits;
    for (int r = 0; r < repeat; r++) {
        for (const auto& g : groups) {
            for (int b = 0; b < 4; b++) {
                const uint32_t word = static_cast<uint32_t>(g[static_cast<size_t>(b)]) << 10 |
                                      rdsCheckword(g[static_cast<size_t>(b)], kOffsets[b]);
                for (int i = 25; i >= 0; i--) bits.push_back(static_cast<uint8_t>((word >> i) & 1));
            }
        }
    }
    return bits;
}

std::vector<uint8_t> generateFm(const FmTxConfig& cfg, double seconds)
{
    const size_t n = static_cast<size_t>(seconds * kSampleRate);
    std::vector<StationState> stations;
    stations.reserve(cfg.stations.size());
    double carrierPower = 0;
    for (const auto& s : cfg.stations) {
        stations.emplace_back(s, seconds, cfg.seed + static_cast<unsigned>(stations.size()));
        carrierPower += s.amplitude * s.amplitude;
    }
    const double noisePower = carrierPower / std::pow(10.0, cfg.cnrDb / 10.0);
    const double scale = cfg.rms / std::sqrt((carrierPower + noisePower) / 2);
    const double sigma = std::sqrt(noisePower / 2) * scale;

    // Gaussian noise from a table, read from random positions (fast).
    std::mt19937 rng(cfg.seed);
    std::normal_distribution<float> normal(0.f, 1.f);
    std::vector<float> table(1 << 20);
    for (auto& v : table) v = normal(rng);
    size_t ni = 0;

    std::vector<uint8_t> out(2 * n);
    for (size_t i = 0; i < n; i++) {
        if ((i & 4095) == 0) ni = rng() % (table.size() - 3 * 4096);
        cd z(0, 0);
        for (auto& st : stations) z += st.sample();
        z *= scale;
        const double re = z.real() + sigma * table[ni++];
        const double im = z.imag() + sigma * table[ni++];
        out[2 * i] = static_cast<uint8_t>(std::max(0.0, std::min(255.0, std::round(127.5 + 127.5 * re))));
        out[2 * i + 1] = static_cast<uint8_t>(std::max(0.0, std::min(255.0, std::round(127.5 + 127.5 * im))));
    }
    return out;
}

} // namespace hrdab::test
