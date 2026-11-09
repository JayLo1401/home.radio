#include "ofdm.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "dab_tables.h"

namespace hrdab {

namespace {

constexpr int kChunkSamples = 16384;
constexpr size_t kKeepBehind = 8192;   // history kept for negative timing steps
constexpr int kWindowOffset = kGuardLen / 2; // FFT window starts mid-guard
constexpr int kMaxCoarseShift = 45;   // carriers = kHz, ~ +-200 ppm in Band III
// The most a tuner can plausibly be off in total (same ~200 ppm). A "lock"
// further out is on noise or a neighbour, never the wanted ensemble.
constexpr double kMaxOffsetHz = kMaxCoarseShift * 1000.0 + 1000.0;
constexpr int kNullBlock = 64;
constexpr int kNullWindowBlocks = 40; // 2560 of the 2656 null samples
// Carrier distance for the phase slope estimate: 4 x slope x lag stays
// below pi up to ~390 ppm of sample clock offset.
constexpr int kSlopeLag = 256;

inline int wrapTiming(int m)
{
    int e = m - kWindowOffset;
    if (e >= kFftLen / 2) e -= kFftLen;
    if (e < -kFftLen / 2) e += kFftLen;
    return e;
}

inline cf32 mulConj(cf32 a, cf32 b)
{
    return cf32(a.real() * b.real() + a.imag() * b.imag(), a.imag() * b.real() - a.real() * b.imag());
}

// Natural carrier order: index j = 0..1535 <-> carrier k = -768..-1, 1..768.
inline int naturalCarrier(int j)
{
    return j < kCarriers / 2 ? j - kCarriers / 2 : j - kCarriers / 2 + 1;
}

inline int naturalIndex(int k)
{
    return k < 0 ? k + kCarriers / 2 : k + kCarriers / 2 - 1;
}

// d^4 scaled back to |d|: the QPSK data drops out (4 x 90 degrees), the
// phase error is multiplied by 4, and strong carriers don't dominate the way
// they would with |d|^4.
inline cf32 quartic(cf32 d)
{
    const float m = std::norm(d);
    if (m <= 0.f) return cf32(0, 0);
    const cf32 d2 = d * d;
    return d2 * d2 / (m * std::sqrt(m));
}

inline int8_t clampSoft(float v)
{
    if (v > 127.f) return 127;
    if (v < -127.f) return -127;
    return static_cast<int8_t>(std::lrintf(v));
}

} // namespace

OfdmDemod::OfdmDemod(IqReader& reader, OfdmSink& sink)
    : reader_(reader),
      sink_(sink),
      fft_(kFftLen),
      lut_(256),
      raw_(2 * kChunkSamples),
      prs_(phaseReference()),
      cur_(kFftLen),
      prev_(kFftLen),
      work_(kFftLen),
      soft_(kFrameSoftBits),
      diff_(static_cast<size_t>(kDataSymbols) * kCarriers),
      phaseFix_(kCarriers, cf32(1, 0)),
      carrierSum_(kCarriers)
{
    for (int i = 0; i < 256; i++) lut_[static_cast<size_t>(i)] = (static_cast<float>(i) - 127.5f) / 127.5f;
    stash_.reserve(4 * kFrameLen);
}

void OfdmDemod::requestReset(uint32_t tunedHz)
{
    pendingTunedHz_ = tunedHz;
    resetRequested_ = true;
}

void OfdmDemod::doReset()
{
    stash_.clear();
    head_ = 0;
    locked_ = false;
    misses_ = 0;
    searchFailures_ = 0;
    const uint32_t hz = pendingTunedHz_.load();
    if (tunedHz_ != 0 && hz != 0) freqOffsetHz_ *= static_cast<double>(hz) / tunedHz_;
    if (hz != 0) tunedHz_ = hz;
    // Never carry an implausible offset over to the next channel.
    if (std::abs(freqOffsetHz_) > kMaxOffsetHz) freqOffsetHz_ = 0;
    snrAcc_ = 0;
    snrCount_ = 0;
    // USB transfers already in flight and the tuner PLL settling still carry
    // the old channel for a while; neither sync nor the AGC should see that.
    skipSamples_ = kSampleRate / 5;
    levelSumSq_ = 0;
    levelClipped_ = 0;
    levelCount_ = 0;
    if (reportedSync_) {
        reportedSync_ = false;
        sink_.onSync(false);
    }
    sink_.onReset();
}

void OfdmDemod::run(const std::atomic<bool>& stop)
{
    while (!stop.load()) {
        if (resetRequested_.exchange(false)) doReset();
        // false only means ensure() bailed out - for a pending reset, or for
        // a ring interrupt that tune() raised while this thread was busy and
        // that only reached read() after doReset(). Neither is an exit; only
        // stop is (stopLocked() sets it before aborting the ring).
        if (locked_) demodulateFrame();
        else acquire();
    }
}

bool OfdmDemod::ensure(size_t count)
{
    while (stash_.size() - head_ < count) {
        if (head_ > static_cast<size_t>(2 * kFrameLen)) {
            const size_t drop = head_ - kKeepBehind;
            stash_.erase(stash_.begin(), stash_.begin() + static_cast<long>(drop));
            head_ -= drop;
        }
        const int got = reader_.readIq(raw_.data(), 2 * kChunkSamples);
        if (got < 2 * kChunkSamples) return false;
        if (resetRequested_.load()) return false;
        if (skipSamples_ > 0) {
            skipSamples_ -= kChunkSamples;
            continue;
        }

        const size_t base = stash_.size();
        stash_.resize(base + kChunkSamples);
        const double step = -2.0 * M_PI * freqOffsetHz_ / kSampleRate;
        for (int blk = 0; blk < kChunkSamples; blk += 4096) {
            cf32 rot(static_cast<float>(std::cos(ncoPhase_)), static_cast<float>(std::sin(ncoPhase_)));
            const cf32 inc(static_cast<float>(std::cos(step)), static_cast<float>(std::sin(step)));
            for (int i = blk; i < blk + 4096; i++) {
                const uint8_t ri = raw_[static_cast<size_t>(2 * i)];
                const uint8_t rq = raw_[static_cast<size_t>(2 * i + 1)];
                if (ri == 0 || ri == 255 || rq == 0 || rq == 255) levelClipped_++;
                const cf32 x(lut_[ri], lut_[rq]);
                levelSumSq_ += static_cast<double>(x.real() * x.real() + x.imag() * x.imag());
                stash_[base + static_cast<size_t>(i)] =
                    cf32(x.real() * rot.real() - x.imag() * rot.imag(), x.real() * rot.imag() + x.imag() * rot.real());
                rot = cf32(rot.real() * inc.real() - rot.imag() * inc.imag(),
                           rot.real() * inc.imag() + rot.imag() * inc.real());
            }
            ncoPhase_ = std::fmod(ncoPhase_ + step * 4096, 2.0 * M_PI);
        }
        levelCount_ += kChunkSamples;
        if (levelCount_ >= kSampleRate / 10) {
            sink_.onLevel(static_cast<float>(std::sqrt(levelSumSq_ / levelCount_ / 2.0)),
                          static_cast<float>(levelClipped_) / levelCount_);
            levelSumSq_ = 0;
            levelClipped_ = 0;
            levelCount_ = 0;
        }
    }
    return true;
}

void OfdmDemod::consume(long n)
{
    if (n < 0 && static_cast<size_t>(-n) > head_) n = -static_cast<long>(head_);
    head_ = static_cast<size_t>(static_cast<long>(head_) + n);
    absPos_ += n;
}

void OfdmDemod::remix(size_t from, double hz)
{
    const double step = -2.0 * M_PI * hz / kSampleRate;
    double phase = 0;
    for (size_t i = from; i < stash_.size(); i += 4096) {
        cf32 rot(static_cast<float>(std::cos(phase)), static_cast<float>(std::sin(phase)));
        const cf32 inc(static_cast<float>(std::cos(step)), static_cast<float>(std::sin(step)));
        const size_t end = std::min(stash_.size(), i + 4096);
        for (size_t j = i; j < end; j++) {
            stash_[j] *= rot;
            rot *= inc;
        }
        phase = std::fmod(phase + step * 4096, 2.0 * M_PI);
    }
}

void OfdmDemod::spectrumAt(size_t pos, cf32* out)
{
    std::memcpy(out, &stash_[pos], sizeof(cf32) * kFftLen);
    fft_.forward(out);
}

bool OfdmDemod::impulse(const cf32* spectrum, int& peak, float& quality)
{
    for (int b = 0; b < kFftLen; b++) work_[static_cast<size_t>(b)] = mulConj(spectrum[b], prs_[static_cast<size_t>(b)]);
    fft_.inverse(work_.data());
    float best = 0;
    double sum = 0;
    peak = 0;
    for (int n = 0; n < kFftLen; n++) {
        const float p = std::norm(work_[static_cast<size_t>(n)]);
        sum += p;
        if (p > best) {
            best = p;
            peak = n;
        }
    }
    const double mean = sum / kFftLen;
    quality = mean > 0 ? static_cast<float>(best / mean) : 0.f;
    return true;
}

float OfdmDemod::cyclicPrefixOffsetHz(size_t frameStart, int timingShift)
{
    // While acquiring the timing is only known to ~+-100 samples, so only
    // the middle of each guard interval is used.
    const int margin = locked_ ? 64 : 140;
    cf32 acc(0, 0);
    for (int l = 0; l < kSymbolsPerFrame; l++) {
        const long s = static_cast<long>(frameStart) + kNullLen + static_cast<long>(l) * kSymbolLen + timingShift;
        for (int n = margin; n < kGuardLen - margin; n++) {
            const size_t i = static_cast<size_t>(s + n);
            acc += mulConj(stash_[i + kFftLen], stash_[i]);
        }
    }
    return static_cast<float>(std::atan2(acc.imag(), acc.real()) / (2.0 * M_PI) * 1000.0);
}

int OfdmDemod::coarseOffset(const cf32* spectrum, float& quality)
{
    // Differential correlation across neighbouring carriers: independent of
    // the (still unknown) timing, which only adds a linear phase slope.
    std::vector<cf32>& refDiff = refDiff_;
    if (refDiff.empty()) {
        refDiff.assign(kCarriers + 1, cf32(0, 0));
        for (int k = -768; k < 768; k++) {
            if (k == -1 || k == 0) continue;
            refDiff[static_cast<size_t>(k + 768)] =
                mulConj(prs_[static_cast<size_t>(carrierToBin(k + 1))], prs_[static_cast<size_t>(carrierToBin(k))]);
        }
    }
    int bestShift = 0;
    quality = 0;
    for (int s = -kMaxCoarseShift; s <= kMaxCoarseShift; s++) {
        cf32 acc(0, 0);
        double norm = 0;
        for (int k = -768; k < 768; k++) {
            if (k == -1 || k == 0) continue;
            const cf32 a = spectrum[(k + s + 1 + kFftLen) % kFftLen];
            const cf32 b = spectrum[(k + s + kFftLen) % kFftLen];
            const cf32 d = mulConj(a, b);
            acc += mulConj(d, refDiff[static_cast<size_t>(k + 768)]);
            norm += std::abs(d);
        }
        const float q = norm > 0 ? static_cast<float>(std::abs(acc) / norm) : 0.f;
        if (q > quality) {
            quality = q;
            bestShift = s;
        }
    }
    return bestShift;
}

bool OfdmDemod::acquire()
{
    const size_t span = kFrameLen + kNullLen;
    if (!ensure(span)) return false;

    // 1. Null symbol: the quietest ~2560 samples of a frame-long window.
    const int blocks = static_cast<int>(span / kNullBlock);
    std::vector<float> energy(static_cast<size_t>(blocks));
    double total = 0;
    for (int b = 0; b < blocks; b++) {
        float e = 0;
        const cf32* p = &stash_[head_ + static_cast<size_t>(b * kNullBlock)];
        for (int i = 0; i < kNullBlock; i++) e += std::norm(p[i]);
        energy[static_cast<size_t>(b)] = e;
        total += e;
    }
    double window = 0;
    for (int b = 0; b < kNullWindowBlocks; b++) window += energy[static_cast<size_t>(b)];
    double minWindow = window;
    int minStart = 0;
    for (int b = kNullWindowBlocks; b < blocks; b++) {
        window += energy[static_cast<size_t>(b)] - energy[static_cast<size_t>(b - kNullWindowBlocks)];
        if (window < minWindow) {
            minWindow = window;
            minStart = b - kNullWindowBlocks + 1;
        }
    }
    const double meanBlock = total / blocks;
    const double ratio = meanBlock > 0 ? (minWindow / kNullWindowBlocks) / meanBlock : 1.0;
    auto fail = [this](long skip) {
        consume(skip);
        if (++searchFailures_ >= 10 && reportedSync_) {
            reportedSync_ = false;
            sink_.onSync(false);
        }
        return true;
    };
    if (ratio > 0.4) return fail(kFrameLen);
#ifdef HRDAB_STDERR_LOG
    HR_LOGI("null candidate @%ld ratio %.3f", absPos_ + minStart * kNullBlock, ratio);
#endif

    // The quiet window can lie anywhere in a longer quiet stretch (signal
    // fade-in, noise before the first frame), so take the null's *end*: the
    // first block after it whose energy rises half-way (in dB) back to the
    // signal level. The PRS follows right there; the impulse response below
    // only resolves timing modulo 2048 samples, so this must be close.
    const double nullBlock = std::max(minWindow / kNullWindowBlocks, 1e-12);
    const double threshold = std::sqrt(nullBlock * meanBlock);
    int edge = -1;
    for (int b = minStart; b < blocks; b++) {
        if (energy[static_cast<size_t>(b)] > threshold) {
            edge = b;
            break;
        }
    }
    if (edge < 0 || edge * kNullBlock < kNullLen) return fail(kFrameLen / 2);
    // Frame start = PRS start - null length; the edge block may already be
    // part-way into the PRS, so start a little early (the impulse corrects).
    consume(edge * kNullBlock - kNullLen - kNullBlock / 2);
    if (!ensure(kFrameLen + 2 * kSymbolLen)) return false;

    // Steps 2 and 3 correct the carrier offset before it's known whether
    // this attempt locks at all. A failed attempt must take its correction
    // back: on an empty channel each one is noise, and kept they added up
    // over a scan (to ~190 kHz, seen on a real device) until even real
    // ensembles were out of the +-45 kHz coarse search range.
    const double offsetBefore = freqOffsetHz_;
    auto failRestoring = [&](long skip) {
        const double applied = freqOffsetHz_ - offsetBefore;
        if (applied != 0) {
            freqOffsetHz_ = offsetBefore;
            remix(head_, -applied);
        }
        return fail(skip);
    };

    // 2. Fractional carrier offset from the cyclic prefixes.
    const float frac = cyclicPrefixOffsetHz(head_, 0);
    freqOffsetHz_ += frac;
    remix(head_, frac);

    // 3. Integer carrier offset from the phase reference symbol.
    spectrumAt(head_ + kNullLen + kWindowOffset, cur_.data());
    float coarseQuality = 0;
    const int shift = coarseOffset(cur_.data(), coarseQuality);
    if (coarseQuality < 0.12f) return failRestoring(kFrameLen / 2);
    if (std::abs(freqOffsetHz_ + shift * 1000.0) > kMaxOffsetHz) return failRestoring(kFrameLen / 2);
    if (shift != 0) {
        freqOffsetHz_ += shift * 1000.0;
        remix(head_, shift * 1000.0);
        spectrumAt(head_ + kNullLen + kWindowOffset, cur_.data());
    }

    // 4. Fine timing from the channel impulse response.
    int peak = 0;
    float quality = 0;
    impulse(cur_.data(), peak, quality);
    if (quality < 15.f) return failRestoring(kFrameLen / 2);
    consume(wrapTiming(peak));

    locked_ = true;
    misses_ = 0;
    searchFailures_ = 0;
    dbgFrames_ = 0;
    HR_LOGI("OFDM sync: carrier offset %.0f Hz (coarse %d, q %.2f), null ratio %.2f, impulse quality %.1f",
            freqOffsetHz_, shift, coarseQuality, ratio, quality);
    if (!reportedSync_) {
        reportedSync_ = true;
        sink_.onSync(true);
    }
    return true;
}

bool OfdmDemod::demodulateFrame()
{
    if (!ensure(kFrameLen + kSymbolLen)) return false;
    const size_t base = head_;

    int peak = 0;
    float quality = 0;
    spectrumAt(base + kNullLen + kWindowOffset, cur_.data());
    impulse(cur_.data(), peak, quality);
    const int e = wrapTiming(peak);
    // Guard against locking 2048 samples off (the impulse cannot tell): the
    // null symbol has to be clearly quieter than the PRS that follows it.
    double quiet = 0, loud = 0;
    for (int i = 128; i < kNullLen - 128; i += 4) quiet += std::norm(stash_[base + static_cast<size_t>(i)]);
    for (int i = 0; i < kSymbolLen; i += 4) loud += std::norm(stash_[base + kNullLen + static_cast<size_t>(i)]);
    quiet /= (kNullLen - 256) / 4;
    loud /= kSymbolLen / 4;
    if (quality < 8.f || std::abs(e) > 200 || quiet > 0.5 * loud) {
        ++misses_;
        // Still locked, the frame timeline goes on (one frame consumed): the
        // decoders can take it as an erasure. Once the lock is given up, the
        // re-acquisition skips an unknown number of frames - a real gap.
        sink_.onFrameLost(misses_ < 3);
        if (misses_ >= 3) {
            locked_ = false;
            HR_LOGW("OFDM sync lost (impulse quality %.1f, timing step %d)", quality, e);
            if (reportedSync_) {
                reportedSync_ = false;
                sink_.onSync(false);
            }
        }
        consume(kFrameLen);
        return true;
    }
    misses_ = 0;
    lastTimingStep_ = static_cast<float>(e);

    const int offset = kWindowOffset + e;
    if (e != 0) spectrumAt(base + kNullLen + static_cast<size_t>(offset), cur_.data());
    std::swap(cur_, prev_);

    // Carrier tracking (first-order loop on the cyclic prefix phase).
    const float residual = cyclicPrefixOffsetHz(base, e);
    freqOffsetHz_ += std::max(-200.f, std::min(200.f, 0.3f * residual));

    // Pass 1: differential products of all data symbols, in natural carrier
    // order (k = -768..-1, 1..768).
    double signalPower = 0;
    for (int l = 1; l < kSymbolsPerFrame; l++) {
        const size_t pos = base + kNullLen + static_cast<size_t>(l) * kSymbolLen + static_cast<size_t>(offset);
        for (int i = 0; i < kFftLen; i += 8) signalPower += std::norm(stash_[pos + static_cast<size_t>(i)]);
        spectrumAt(pos, cur_.data());
        cf32* d = &diff_[static_cast<size_t>(l - 1) * kCarriers];
        for (int j = 0; j < kCarriers; j++) {
            const size_t b = static_cast<size_t>(carrierToBin(naturalCarrier(j)));
            d[j] = mulConj(cur_[b], prev_[b]);
        }
        std::swap(cur_, prev_);
    }

    // Pass 2: phase slope of the differential products across the carriers.
    // The sample clock is off by the crystal's ppm (the same crystal as the
    // LO on these sticks), so each symbol's FFT window drifts against the
    // signal by ppm * 2552 samples - a phase step between symbols that grows
    // linearly with the carrier index, ~17 degrees at the band edges for
    // 50 ppm: most of the QPSK margin. It is the same for every symbol pair,
    // so the 4th power (removes the pi/4-DQPSK data) is summed per carrier
    // over the whole frame first, then compared between carriers kSlopeLag
    // apart. Smoothed over frames; the clock drifts only slowly.
    {
        for (int j = 0; j < kCarriers; j++) carrierSum_[static_cast<size_t>(j)] = cf32(0, 0);
        for (int l = 0; l < kDataSymbols; l++) {
            const cf32* d = &diff_[static_cast<size_t>(l) * kCarriers];
            for (int j = 0; j < kCarriers; j++) carrierSum_[static_cast<size_t>(j)] += quartic(d[j]);
        }
        cf32 acc(0, 0), common(0, 0);
        for (int j = 0; j + kSlopeLag < kCarriers; j++) {
            // only pairs on the same side of the DC carrier: exactly kSlopeLag apart
            if (j < kCarriers / 2 && j + kSlopeLag >= kCarriers / 2) continue;
            acc += mulConj(carrierSum_[static_cast<size_t>(j + kSlopeLag)], carrierSum_[static_cast<size_t>(j)]);
        }
        const float accMag = std::abs(acc);
        if (accMag > 0) {
            // weighted by reliability: a frame of noise adds little
            double total = 0;
            for (int j = 0; j < kCarriers; j++) total += std::norm(carrierSum_[static_cast<size_t>(j)]);
            const float weight = total > 0 ? std::min(1.f, static_cast<float>(accMag / total)) : 0.f;
            slopeState_ = slopeState_ * (1.f - 0.3f * weight) + (acc / accMag) * (0.3f * weight);
        }
        const double slope = std::atan2(slopeState_.imag(), slopeState_.real()) / (4.0 * kSlopeLag); // rad per carrier
        for (int j = 0; j < kCarriers; j++) {
            const double ph = -slope * naturalCarrier(j);
            phaseFix_[static_cast<size_t>(j)] = cf32(static_cast<float>(std::cos(ph)), static_cast<float>(std::sin(ph)));
            const double c = 4.0 * ph;
            common += carrierSum_[static_cast<size_t>(j)] * cf32(static_cast<float>(std::cos(c)), static_cast<float>(std::sin(c)));
        }
        // Diagnostics only: sample clock offset, and the common phase error
        // per symbol that is left (pi/4-DQPSK: d^4 sits at 180 degrees).
        // The common phase is not corrected: the cyclic prefix loop keeps the
        // carrier within ~1 Hz (< 1 degree per symbol), and a 4th-power
        // estimate would risk a 90 degree slip on weak frames.
        // A fast stick clock (+ppm) makes the windows lag: negative slope.
        slopePpm_ = static_cast<float>(-slope * kFftLen / (2.0 * M_PI) / kSymbolLen * 1e6);
        commonDeg_ = static_cast<float>(std::atan2(-common.imag(), -common.real()) / 4.0 * 180.0 / M_PI);
    }

    // Pass 3: corrected decisions, frequency de-interleaved. The soft value
    // comes from the phase alone: each differential product is normalised
    // to |re| + |im| = 1, so 48 at the ideal +-45 degrees, 96 at most.
    // Weighting by amplitude (|d|, as before, or a full channel-state LLR)
    // let carriers with a large amplitude but an unreliable phase outvote
    // the rest - on a real capture of 8D in Graz (multipath notch of 10-16
    // dB, 14 dB SNR) that lost 21 of 279 AUs of the 112 kbit/s service with
    // 1526 RS byte corrections; phase only: 0 AUs, 18 corrections.
    const auto& map = frequencyMap();
    constexpr float kSoftScale = 96.f;
    for (int l = 0; l < kDataSymbols; l++) {
        const cf32* d = &diff_[static_cast<size_t>(l) * kCarriers];
        for (int j = 0; j < kCarriers; j++) {
            const cf32 v = d[j] * phaseFix_[static_cast<size_t>(j)];
            const float a = std::fabs(v.real()) + std::fabs(v.imag());
            work_[static_cast<size_t>(j)] = a > 0 ? v * (kSoftScale / a) : cf32(0, 0);
        }
        int8_t* out = soft_.data() + l * kBitsPerSymbol;
        for (int n = 0; n < kCarriers; n++) {
            const cf32 v = work_[static_cast<size_t>(naturalIndex(map[static_cast<size_t>(n)]))];
            // QPSK: bit 0 -> +1. Soft convention here: > 0 means bit 1.
            out[n] = clampSoft(-v.real());
            out[n + kCarriers] = clampSoft(-v.imag());
        }
    }

    double nullPower = 0;
    for (int i = 64; i < kNullLen - 64; i++) nullPower += std::norm(stash_[base + static_cast<size_t>(i)]);
    nullPower /= (kNullLen - 128);
    signalPower /= (kDataSymbols * (kFftLen / 8));
#ifdef HRDAB_STDERR_LOG
    if (misses_ == 0 && snrCount_ < 4 && dbgFrames_++ < 4) {
        HR_LOGI("frame @%ld (mod frame %ld): e=%d q=%.1f", absPos_, absPos_ % kFrameLen, e, quality);
        HR_LOGI("       e=%d q=%.1f residual=%.1f Hz offset=%.1f Pn=%.5f Ps=%.5f", e, quality, residual,
                freqOffsetHz_, nullPower, signalPower);
    }
#endif
    if (nullPower > 0) {
        const double snr = std::max(1e-3, (signalPower - nullPower) / nullPower);
        snrAcc_ += 10.0 * std::log10(snr);
        if (++snrCount_ >= 10) {
            sink_.onSnr(static_cast<float>(snrAcc_ / snrCount_));
            snrAcc_ = 0;
            snrCount_ = 0;
        }
    }

    sink_.onFrame(soft_.data());
    consume(kFrameLen + e);
    return true;
}

} // namespace hrdab
