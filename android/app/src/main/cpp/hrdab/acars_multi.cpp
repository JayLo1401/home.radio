#include "acars_multi.h"

#include <algorithm>
#include <cmath>

namespace hrdab {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kTableBits = 10;
constexpr int kFirTaps = 41;
constexpr double kCutoffHz = 5000;     // AM channel +-5 kHz
constexpr int kPcmBlock = 960;         // 20 ms at 48 kHz
constexpr int kReadSamples = 65536;

} // namespace

AcarsMultiDemod::AcarsMultiDemod(IqReader& reader, AcarsSink& sink) : reader_(reader), sink_(sink)
{
    const int n = 1 << kTableBits;
    cos_.resize(static_cast<size_t>(n));
    sin_.resize(static_cast<size_t>(n));
    for (int k = 0; k < n; k++) {
        cos_[static_cast<size_t>(k)] = static_cast<int16_t>(std::lround(32767 * std::cos(2 * kPi * k / n)));
        sin_[static_cast<size_t>(k)] = static_cast<int16_t>(std::lround(32767 * std::sin(2 * kPi * k / n)));
    }
    // Windowed-sinc low-pass at 48 kHz, unity gain.
    fir_.resize(kFirTaps);
    double sum = 0;
    for (int k = 0; k < kFirTaps; k++) {
        const double m = k - (kFirTaps - 1) / 2.0;
        const double x = 2 * kCutoffHz / kAudioRate;
        const double sinc = m == 0 ? x : std::sin(kPi * x * m) / (kPi * m);
        const double w = 0.54 - 0.46 * std::cos(2 * kPi * k / (kFirTaps - 1));
        fir_[static_cast<size_t>(k)] = static_cast<float>(sinc * w);
        sum += sinc * w;
    }
    for (float& f : fir_) f = static_cast<float>(f / sum);
}

void AcarsMultiDemod::configure(uint32_t centerHz, const std::vector<uint32_t>& channelsHz)
{
    channels_.clear();
    for (uint32_t f : channelsHz) {
        Channel c;
        c.freqHz = f;
        // Mix down by the channel's offset: exp(-j 2pi off t).
        const double off = static_cast<double>(f) - static_cast<double>(centerHz);
        c.inc = static_cast<uint32_t>(static_cast<int64_t>(std::llround(-off / kSampleRate * 4294967296.0)));
        c.hi.assign(kFirTaps, 0.f);
        c.hq.assign(kFirTaps, 0.f);
        c.decoder = std::make_unique<AcarsDecoder>(kAudioRate);
        channels_.push_back(std::move(c));
    }
}

void AcarsMultiDemod::output(Channel& c, float i, float q)
{
    c.hi[static_cast<size_t>(c.hpos)] = i;
    c.hq[static_cast<size_t>(c.hpos)] = q;
    float fi = 0, fq = 0;
    int p = c.hpos;
    for (int k = 0; k < kFirTaps; k++) {
        fi += fir_[static_cast<size_t>(k)] * c.hi[static_cast<size_t>(p)];
        fq += fir_[static_cast<size_t>(k)] * c.hq[static_cast<size_t>(p)];
        p = p == 0 ? kFirTaps - 1 : p - 1;
    }
    c.hpos = (c.hpos + 1) % kFirTaps;
    // AM relative to the carrier: no AGC needed, the depth is what counts.
    const float mag = std::sqrt(fi * fi + fq * fq);
    c.carrier += (mag - c.carrier) * 0.002f;
    if (c.carrier > c.peak) c.peak = c.carrier;
    const float a = c.carrier > 1e-9f ? (mag - c.carrier) / c.carrier : 0.f;
    c.pcm.push_back(static_cast<int16_t>(std::max(-32000.f, std::min(32000.f, a * 12000.f))));
    if (static_cast<int>(c.pcm.size()) >= kPcmBlock) {
        const uint32_t freq = c.freqHz;
        c.decoder->process(c.pcm.data(), static_cast<int>(c.pcm.size()),
                           [this, freq](const std::vector<uint8_t>& frame) { sink_.onAcarsFrame(freq, frame); });
        c.pcm.clear();
    }
}

void AcarsMultiDemod::process(const uint8_t* iq, int samples)
{
    constexpr int shift = 32 - kTableBits;
    const double norm = 1.0 / (128.0 * 32767.0 * kDecimation * kDecimation);
    for (auto& c : channels_) {
        for (int k = 0; k < samples; k++) {
            const int x = iq[2 * k] - 128, y = iq[2 * k + 1] - 128;
            const size_t t = c.phase >> shift;
            const int co = cos_[t], si = sin_[t];
            c.phase += c.inc;
            // (x + jy) * (cos + j sin)
            const int64_t mi = static_cast<int64_t>(x) * co - static_cast<int64_t>(y) * si;
            const int64_t mq = static_cast<int64_t>(x) * si + static_cast<int64_t>(y) * co;
            c.i1 += mi;
            c.q1 += mq;
            c.i2 += c.i1;
            c.q2 += c.q1;
            if (++c.count < kDecimation) continue;
            c.count = 0;
            // Combs at the low rate.
            const int64_t di1 = c.i2 - c.ci1, dq1 = c.q2 - c.cq1;
            c.ci1 = c.i2;
            c.cq1 = c.q2;
            const int64_t di2 = di1 - c.ci2, dq2 = dq1 - c.cq2;
            c.ci2 = di1;
            c.cq2 = dq1;
            output(c, static_cast<float>(di2 * norm), static_cast<float>(dq2 * norm));
        }
    }
}

std::vector<float> AcarsMultiDemod::channelLevelsDb()
{
    std::vector<float> out;
    for (auto& c : channels_) {
        out.push_back(20.f * std::log10(std::max(c.peak, 1e-7f)));
        c.peak = 0;
    }
    return out;
}

void AcarsMultiDemod::run(const std::atomic<bool>& stop)
{
    std::vector<uint8_t> raw(static_cast<size_t>(kReadSamples) * 2);
    while (!stop) {
        const int got = reader_.readIq(raw.data(), static_cast<int>(raw.size()));
        if (got <= 0 || stop) break;
        const int n = got / 2;
        process(raw.data(), n);
        double sq = 0;
        long clipped = 0;
        for (int k = 0; k < n; k++) {
            const uint8_t iv = raw[static_cast<size_t>(2 * k)], qv = raw[static_cast<size_t>(2 * k + 1)];
            const double di = (iv - 127.5) / 127.5, dq = (qv - 127.5) / 127.5;
            sq += di * di + dq * dq;
            clipped += (iv == 0) + (iv == 255) + (qv == 0) + (qv == 255);
        }
        if (n > 0) sink_.onAcarsLevel(static_cast<float>(std::sqrt(sq / n / 2)), static_cast<float>(clipped) / n / 2.f);
    }
}

} // namespace hrdab
