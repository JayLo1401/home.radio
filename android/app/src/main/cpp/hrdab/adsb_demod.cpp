#include "adsb_demod.h"

#include <cmath>
#include <cstring>

namespace hrdab {

namespace {

constexpr int kPreamble = 16;                  // samples (8 us)
constexpr int kLongBits = 112, kShortBits = 56;
constexpr int kFrameSamples = kPreamble + 2 * kLongBits;
constexpr int kReadSamples = 65536;            // ~33 ms
constexpr long long kKnownForSamples = 60LL * AdsbDemod::kSampleRate;
constexpr double kMagScale = 65535.0 / 181.0;  // |I/Q| of 8-bit samples up to ~180

int bitAt(const uint8_t* msg, int i)
{
    return (msg[i / 8] >> (7 - i % 8)) & 1;
}

} // namespace

uint16_t AdsbDemod::magnitude(uint8_t i, uint8_t q)
{
    const double di = i - 127.5, dq = q - 127.5;
    return static_cast<uint16_t>(std::lround(std::sqrt(di * di + dq * dq) * kMagScale));
}

uint32_t AdsbDemod::crc(const uint8_t* msg, int bits)
{
    uint32_t rem = 0;
    for (int i = 0; i < bits; i++) {
        rem = (rem << 1) | static_cast<uint32_t>(bitAt(msg, i));
        if (rem & 0x1000000u) rem ^= 0x1FFF409u;
    }
    return rem & 0xFFFFFFu;
}

AdsbDemod::AdsbDemod(IqReader& reader, AdsbSink& sink) : reader_(reader), sink_(sink)
{
    magLut_.resize(65536);
    for (int i = 0; i < 256; i++) {
        for (int q = 0; q < 256; q++) magLut_[static_cast<size_t>(i * 256 + q)] = magnitude(static_cast<uint8_t>(i), static_cast<uint8_t>(q));
    }
    syndrome112_.resize(kLongBits);
    for (int b = 0; b < kLongBits; b++) {
        uint8_t msg[14] = {};
        msg[b / 8] = static_cast<uint8_t>(0x80 >> (b % 8));
        syndrome112_[static_cast<size_t>(b)] = crc(msg, kLongBits);
    }
}

bool AdsbDemod::accept(uint8_t* msg, int bits, uint32_t& icao)
{
    const int df = msg[0] >> 3;
    const uint32_t rem = crc(msg, bits);
    const auto address = [&] { return (static_cast<uint32_t>(msg[1]) << 16) | (msg[2] << 8) | msg[3]; };
    if (df == 17 || df == 18) {
        if (rem != 0) {
            // One flipped bit (not in the DF field): repair it.
            int fix = -1;
            for (int b = 5; b < kLongBits; b++) {
                if (syndrome112_[static_cast<size_t>(b)] == rem) {
                    fix = b;
                    break;
                }
            }
            if (fix < 0) return false;
            msg[fix / 8] ^= static_cast<uint8_t>(0x80 >> (fix % 8));
        }
        icao = address();
        known_[icao] = sampleCount_;
        return true;
    }
    if (df == 11) {
        // Parity is CRC xor interrogator id (only the lowest 7 bits).
        if ((rem & ~0x7Fu) != 0) return false;
        icao = address();
        known_[icao] = sampleCount_;
        return true;
    }
    if (df == 0 || df == 4 || df == 5 || df == 16 || df == 20 || df == 21) {
        // Address overlaid on the parity: only for aircraft already heard.
        const auto it = known_.find(rem);
        if (it == known_.end() || sampleCount_ - it->second > kKnownForSamples) return false;
        icao = rem;
        return true;
    }
    return false;
}

void AdsbDemod::detect(const uint16_t* m0, int n)
{
    for (int j = 0; j + kFrameSamples < n; j++) {
        const uint16_t* m = m0 + j;
        // Pulses at 0, 1, 3.5 and 4.5 us (samples 0, 2, 7, 9).
        if (!(m[0] > m[1] && m[1] < m[2] && m[2] > m[3] && m[3] < m[0] && m[4] < m[0] && m[5] < m[0] &&
              m[6] < m[0] && m[7] > m[8] && m[8] < m[9] && m[9] > m[6])) {
            continue;
        }
        const int high = (m[0] + m[2] + m[7] + m[9]) / 6;
        if (m[4] >= high || m[5] >= high) continue;
        if (m[11] >= high || m[12] >= high || m[13] >= high || m[14] >= high) continue;

        uint8_t msg[14] = {};
        long long level = 0;
        int errors = 0;
        for (int b = 0; b < kLongBits; b++) {
            const int a = m[kPreamble + 2 * b], c = m[kPreamble + 2 * b + 1];
            if (a == c) errors++;
            if (a > c) msg[b / 8] |= static_cast<uint8_t>(0x80 >> (b % 8));
            level += a > c ? a : c;
            if (b == 7 && errors > 2) break;
        }
        const int df = msg[0] >> 3;
        const int bits = df >= 16 ? kLongBits : kShortBits;
        uint32_t icao = 0;
        if (!accept(msg, bits, icao)) continue;
        const double avg = static_cast<double>(level) / kLongBits / 65535.0;
        const float db = static_cast<float>(20.0 * std::log10(avg > 1e-6 ? avg : 1e-6));
        sink_.onAdsbFrame(msg, bits / 8, icao, db);
        j += kPreamble + 2 * bits - 1;
    }
}

void AdsbDemod::run(const std::atomic<bool>& stop)
{
    std::vector<uint8_t> raw(static_cast<size_t>(kReadSamples) * 2);
    // Magnitudes with the previous read's tail in front, so a frame across
    // two reads is still found.
    std::vector<uint16_t> mag(static_cast<size_t>(kReadSamples + kFrameSamples), 0);
    while (!stop) {
        const int got = reader_.readIq(raw.data(), static_cast<int>(raw.size()));
        if (got <= 0 || stop) break;
        const int n = got / 2;
        std::memmove(mag.data(), mag.data() + kReadSamples, sizeof(uint16_t) * kFrameSamples);
        double sq = 0;
        long clipped = 0;
        for (int i = 0; i < n; i++) {
            const uint8_t iv = raw[static_cast<size_t>(2 * i)], qv = raw[static_cast<size_t>(2 * i + 1)];
            mag[static_cast<size_t>(kFrameSamples + i)] = magLut_[static_cast<size_t>(iv * 256 + qv)];
            const double di = (iv - 127.5) / 127.5, dq = (qv - 127.5) / 127.5;
            sq += di * di + dq * dq;
            clipped += (iv == 0) + (iv == 255) + (qv == 0) + (qv == 255);
        }
        if (n < kReadSamples) std::fill(mag.begin() + kFrameSamples + n, mag.end(), 0);
        detect(mag.data(), kFrameSamples + n);
        sampleCount_ += n;
        if (n > 0) sink_.onAdsbLevel(static_cast<float>(std::sqrt(sq / n / 2)), static_cast<float>(clipped) / n / 2.f);
        // Forget aircraft not heard for a while.
        if (known_.size() > 2000) known_.clear();
    }
}

} // namespace hrdab
