#include "fft.h"

#include <cmath>
#include <utility>

namespace hrdab {

Fft::Fft(int size) : n_(size), bitrev_(size), twiddle_(size / 2)
{
    int bits = 0;
    while ((1 << bits) < size) bits++;
    for (int i = 0; i < size; i++) {
        int r = 0;
        for (int b = 0; b < bits; b++) {
            if (i & (1 << b)) r |= 1 << (bits - 1 - b);
        }
        bitrev_[i] = r;
    }
    for (int k = 0; k < size / 2; k++) {
        const double a = -2.0 * M_PI * k / size;
        twiddle_[k] = cf32(static_cast<float>(std::cos(a)), static_cast<float>(std::sin(a)));
    }
}

void Fft::run(cf32* data, bool inverse) const
{
    for (int i = 0; i < n_; i++) {
        const int j = bitrev_[i];
        if (j > i) std::swap(data[i], data[j]);
    }
    for (int len = 2; len <= n_; len <<= 1) {
        const int half = len >> 1;
        const int step = n_ / len;
        for (int start = 0; start < n_; start += len) {
            for (int k = 0; k < half; k++) {
                cf32 w = twiddle_[k * step];
                if (inverse) w = std::conj(w);
                // Manual complex multiply: std::complex operator* carries
                // NaN/Inf handling that is measurably slower on ARM.
                const cf32 b = data[start + k + half];
                const cf32 t(b.real() * w.real() - b.imag() * w.imag(),
                             b.real() * w.imag() + b.imag() * w.real());
                const cf32 a = data[start + k];
                data[start + k] = a + t;
                data[start + k + half] = a - t;
            }
        }
    }
}

} // namespace hrdab
