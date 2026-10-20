#include "viterbi.h"

#include <climits>

namespace hrdab {

namespace {

// Encoder word w: bit 6 = newest input bit, bit 0 = input 6 bits ago.
const uint8_t kPolys[4] = {0x5B, 0x79, 0x65, 0x5B}; // 133, 171, 145, 133 octal

inline int parity(unsigned v)
{
    return __builtin_parity(v);
}

} // namespace

Viterbi::Viterbi()
{
    for (int w = 0; w < 128; w++) {
        uint8_t o = 0;
        for (int j = 0; j < 4; j++) o |= static_cast<uint8_t>(parity(w & kPolys[j]) << (3 - j));
        outputs_[w] = o;
    }
}

void Viterbi::encode(const uint8_t* bits, int count, uint8_t* out)
{
    unsigned state = 0; // last 6 input bits, newest in bit 5
    for (int i = 0; i < count + 6; i++) {
        const unsigned b = i < count ? (bits[i] & 1u) : 0u;
        const unsigned w = (b << 6) | state;
        for (int j = 0; j < 4; j++) *out++ = static_cast<uint8_t>(parity(w & kPolys[j]));
        state = w >> 1;
    }
}

void Viterbi::decode(const int8_t* soft, int bits, uint8_t* out)
{
    const int steps = bits + 6;
    decisions_.resize(static_cast<size_t>(steps));

    int32_t metric[64];
    int32_t next[64];
    for (int s = 0; s < 64; s++) metric[s] = INT32_MIN / 2;
    metric[0] = 0;

    for (int t = 0; t < steps; t++) {
        const int8_t* sv = soft + 4 * t;
        // Branch metric for each of the 16 possible 4-bit code words:
        // correlation of expected bits (as +-1) with the soft values.
        int32_t bm[16];
        for (int c = 0; c < 16; c++) {
            int32_t m = 0;
            for (int j = 0; j < 4; j++) m += ((c >> (3 - j)) & 1) ? sv[j] : -sv[j];
            bm[c] = m;
        }
        uint64_t dec = 0;
        for (int ns = 0; ns < 64; ns++) {
            // ns = (b << 5) | (s >> 1); predecessors s = ((ns & 31) << 1) | x
            const int b = ns >> 5;
            const int s0 = (ns & 31) << 1;
            const int s1 = s0 | 1;
            const int32_t m0 = metric[s0] + bm[outputs_[(b << 6) | s0]];
            const int32_t m1 = metric[s1] + bm[outputs_[(b << 6) | s1]];
            if (m1 > m0) {
                next[ns] = m1;
                dec |= 1ull << ns;
            } else {
                next[ns] = m0;
            }
        }
        decisions_[static_cast<size_t>(t)] = dec;
        for (int s = 0; s < 64; s++) metric[s] = next[s];
        // Keep the metrics bounded on long blocks.
        if ((t & 255) == 255) {
            int32_t best = metric[0];
            for (int s = 1; s < 64; s++) best = metric[s] > best ? metric[s] : best;
            for (int s = 0; s < 64; s++) metric[s] -= best;
        }
    }

    // The tail drives the encoder back to state 0.
    int state = 0;
    for (int t = steps - 1; t >= 0; t--) {
        const int b = state >> 5;
        const int x = static_cast<int>((decisions_[static_cast<size_t>(t)] >> state) & 1u);
        if (t < bits) out[t] = static_cast<uint8_t>(b);
        state = ((state & 31) << 1) | x;
    }
}

int depuncture(const int8_t* in, const uint8_t* pattern, int patternLen, int outCount, int8_t* out)
{
    int used = 0;
    for (int i = 0; i < outCount; i++) {
        if (pattern[i % patternLen]) {
            out[i] = in[used++];
        } else {
            out[i] = 0;
        }
    }
    return used;
}

} // namespace hrdab
