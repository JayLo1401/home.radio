#include "fm_dsp.h"

#include <algorithm>

namespace hrdab {

namespace {

double besselI0(double x)
{
    // Power series; converges quickly for the beta values used here (< 12).
    double sum = 1, term = 1;
    for (int k = 1; k < 40; k++) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
        if (term < 1e-12 * sum) break;
    }
    return sum;
}

struct SineTable {
    float v[4096];
    SineTable()
    {
        for (int i = 0; i < 4096; i++) v[i] = static_cast<float>(std::sin(2.0 * M_PI * (i + 0.5) / 4096.0));
    }
};

const SineTable& sineTable()
{
    static const SineTable t;
    return t;
}

} // namespace

double kaiserBeta(double a)
{
    if (a > 50) return 0.1102 * (a - 8.7);
    if (a >= 21) return 0.5842 * std::pow(a - 21, 0.4) + 0.07886 * (a - 21);
    return 0;
}

std::vector<float> designLowpass(int taps, double cutoff, double beta)
{
    std::vector<double> h(static_cast<size_t>(taps));
    const double mid = (taps - 1) / 2.0;
    const double i0b = besselI0(beta);
    double sum = 0;
    for (int n = 0; n < taps; n++) {
        const double t = n - mid;
        const double sinc = t == 0 ? 2 * cutoff : std::sin(2 * M_PI * cutoff * t) / (M_PI * t);
        const double r = mid > 0 ? t / mid : 0;
        const double w = besselI0(beta * std::sqrt(std::max(0.0, 1 - r * r))) / i0b;
        h[static_cast<size_t>(n)] = sinc * w;
        sum += h[static_cast<size_t>(n)];
    }
    std::vector<float> out(static_cast<size_t>(taps));
    for (int n = 0; n < taps; n++) {
        double v = h[static_cast<size_t>(n)] / sum;
        // Keep the exact zeros of a half-band design exact, so they are skipped.
        if (std::fabs(v) < 1e-9) v = 0;
        out[static_cast<size_t>(n)] = static_cast<float>(v);
    }
    return out;
}

float sinTable(uint32_t phase)
{
    return sineTable().v[phase >> 20];
}

} // namespace hrdab
