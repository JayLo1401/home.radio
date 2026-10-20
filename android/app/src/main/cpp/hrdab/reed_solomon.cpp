#include "reed_solomon.h"

#include <cstring>

namespace hrdab {

// Polynomial convention: codeword byte j is the coefficient of x^(119-j),
// i.e. the 135 leading zeros of the full-length code are simply implied.

ReedSolomon::ReedSolomon()
{
    int x = 1;
    for (int i = 0; i < 255; i++) {
        exp_[i] = static_cast<uint8_t>(x);
        log_[x] = static_cast<uint8_t>(i);
        x <<= 1;
        if (x & 0x100) x ^= 0x11D;
    }
    for (int i = 255; i < 512; i++) exp_[i] = exp_[i - 255];
    log_[0] = 0;

    // g(x) = prod (x + alpha^i), i = 0..9; gen_[i] = coefficient of x^i.
    std::memset(gen_, 0, sizeof(gen_));
    gen_[0] = 1;
    for (int i = 0; i < kParity; i++) {
        const uint8_t root = exp_[i];
        for (int j = i + 1; j > 0; j--) gen_[j] = static_cast<uint8_t>(gen_[j - 1] ^ mul(gen_[j], root));
        gen_[0] = mul(gen_[0], root);
    }
}

void ReedSolomon::encode(uint8_t* cw) const
{
    uint8_t rem[kParity] = {0}; // rem[0] = highest degree
    for (int i = 0; i < kK; i++) {
        const uint8_t fb = cw[i] ^ rem[0];
        std::memmove(rem, rem + 1, kParity - 1);
        rem[kParity - 1] = 0;
        if (fb) {
            for (int j = 0; j < kParity; j++) rem[j] ^= mul(fb, gen_[kParity - 1 - j]);
        }
    }
    std::memcpy(cw + kK, rem, kParity);
}

int ReedSolomon::decode(uint8_t* cw) const
{
    uint8_t synd[kParity];
    bool clean = true;
    for (int i = 0; i < kParity; i++) {
        // Horner evaluation at alpha^i.
        uint8_t s = 0;
        const uint8_t a = exp_[i];
        for (int j = 0; j < kN; j++) s = static_cast<uint8_t>(mul(s, a) ^ cw[j]);
        synd[i] = s;
        if (s) clean = false;
    }
    if (clean) return 0;

    // Berlekamp-Massey.
    uint8_t lambda[kParity + 1] = {1};
    uint8_t prev[kParity + 1] = {1};
    int l = 0;
    int m = 1;
    uint8_t b = 1;
    for (int n = 0; n < kParity; n++) {
        uint8_t d = synd[n];
        for (int i = 1; i <= l; i++) d ^= mul(lambda[i], synd[n - i]);
        if (d == 0) {
            m++;
            continue;
        }
        const uint8_t coef = mul(d, inv(b));
        uint8_t t[kParity + 1];
        std::memcpy(t, lambda, sizeof(t));
        for (int i = 0; i + m <= kParity; i++) lambda[i + m] ^= mul(coef, prev[i]);
        if (2 * l <= n) {
            l = n + 1 - l;
            std::memcpy(prev, t, sizeof(prev));
            b = d;
            m = 1;
        } else {
            m++;
        }
    }
    if (l == 0 || l > kParity / 2) return -1;

    // Chien search over the 120 real positions: degree p is in error when
    // lambda(alpha^-p) == 0.
    int positions[kParity / 2];
    int found = 0;
    for (int p = 0; p < kN; p++) {
        const uint8_t xinv = exp_[(255 - p) % 255];
        uint8_t v = 0;
        for (int i = l; i >= 0; i--) v = static_cast<uint8_t>(mul(v, xinv) ^ lambda[i]);
        if (v == 0) {
            if (found == kParity / 2) return -1;
            positions[found++] = p;
        }
    }
    if (found != l) return -1;

    // Forney (first consecutive root alpha^0): e = X * omega(X^-1) / lambda'(X^-1).
    uint8_t omega[kParity] = {0};
    for (int i = 0; i < kParity; i++) {
        uint8_t v = 0;
        for (int j = 0; j <= i && j <= l; j++) v ^= mul(lambda[j], synd[i - j]);
        omega[i] = v;
    }
    for (int k = 0; k < found; k++) {
        const int p = positions[k];
        const uint8_t x = exp_[p];
        const uint8_t xinv = exp_[(255 - p) % 255];
        uint8_t num = 0;
        for (int i = kParity - 1; i >= 0; i--) num = static_cast<uint8_t>(mul(num, xinv) ^ omega[i]);
        uint8_t den = 0;
        // lambda'(x) = sum over odd i of lambda_i x^(i-1)
        uint8_t xpow = 1;
        const uint8_t xinv2 = mul(xinv, xinv);
        for (int i = 1; i <= l; i += 2) {
            den ^= mul(lambda[i], xpow);
            xpow = mul(xpow, xinv2);
        }
        if (den == 0) return -1;
        const uint8_t e = mul(mul(x, num), inv(den));
        cw[kN - 1 - p] ^= e;
    }
    return found;
}

} // namespace hrdab
