#pragma once

#include <vector>

#include "common.h"

namespace hrdab {

// In-place iterative radix-2 FFT for one fixed power-of-two size.
class Fft {
public:
    explicit Fft(int size);

    int size() const { return n_; }

    // X[k] = sum x[n] e^{-j2pi kn/N}
    void forward(cf32* data) const { run(data, false); }
    // x[n] = sum X[k] e^{+j2pi kn/N} (not scaled by 1/N)
    void inverse(cf32* data) const { run(data, true); }

private:
    void run(cf32* data, bool inverse) const;

    int n_;
    std::vector<int> bitrev_;
    std::vector<cf32> twiddle_; // e^{-j2pi k/N}, k < N/2
};

} // namespace hrdab
