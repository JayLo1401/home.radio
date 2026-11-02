#include "fm_demod.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

namespace hrdab {

namespace {

constexpr int kChunk = 16384;                   // input samples per read (8 ms)
constexpr int kMpxRate = kSampleRate / 8;        // 256 kHz
constexpr int kMpxChunk = kChunk / 8;
constexpr double kDeviationHz = 75000.0;         // full modulation
constexpr int kLevelChunks = 6;                  // ~50 ms per AGC report
constexpr int kStatusSamples = kMpxRate / 2;     // 0.5 s
constexpr long kRetuneSkip = kSampleRate * 15 / 100;  // old data still in flight after a retune
constexpr long kGainSkip = kSampleRate * 13 / 100;    // same after a gain change
constexpr int kSurveyFfts = 64;
constexpr int kMaxAgcRounds = 4;
constexpr double kMaxAfcHz = 25000.0;           // beyond that it is the neighbour, not drift
constexpr int kPcmBlock = 1536;                 // frames per onFmAudio (32 ms)
constexpr uint32_t kInc19 = 19u << 24;          // 19/256 of a cycle per 256 kHz sample
constexpr float kPhaseScale = 683565275.6f;     // 2^32 / (2 pi)

// 1 - exp(-2 pi fc / fs)
float onePole(double fc, double fs)
{
    return static_cast<float>(1.0 - std::exp(-2.0 * M_PI * fc / fs));
}

} // namespace

FmDemod::FmDemod(IqReader& reader, FmSink& sink)
    : reader_(reader), sink_(sink), fft_(kSurveyBins), raw_(2 * kChunk)
{
    for (int i = 0; i < 256; i++) lut_[i] = (static_cast<float>(i) - 127.5f) / 127.5f;

    // Channel filter as three half-band decimators (2.048 -> 1.024 -> 0.512
    // -> 0.256 MS/s). Only the last one is sharp: it passes +-100 kHz (the
    // FM signal incl. RDS) and must stop by 156 kHz, which aliases to the
    // passband edge. Half-bands skip every other tap.
    hb1_f_.init(designLowpass(11, 0.25, kaiserBeta(60)), 2);
    hb2_f_.init(designLowpass(19, 0.25, kaiserBeta(60)), 2);
    hb3_f_.init(designLowpass(35, 0.25, kaiserBeta(60)), 2);
    // Audio, done on (L+R, L-R) pairs: 256 -> 64 kHz, then 64 -> 48 kHz with
    // the 15 kHz audio low-pass that also removes the 19 kHz pilot.
    audioDec_.init(designLowpass(33, 30000.0 / kMpxRate, kaiserBeta(60)), 4);
    audioRes_.init(designLowpass(177, 17000.0 / 192000.0, kaiserBeta(60)), 3, 4);

    iq_.resize(2 * kChunk);
    hb1_.resize(2 * (kChunk / 2 + 4));
    hb2_.resize(2 * (kChunk / 4 + 4));
    ch_.resize(2 * (kMpxChunk + 4));
    mpx_.resize(kMpxChunk + 4);
    pair_.resize(2 * (kMpxChunk + 4));
    pair64_.resize(2 * (kMpxChunk / 4 + 4));
    pair48_.resize(2 * (kMpxChunk / 4 + 4));
    pcm_.reserve(2 * (kPcmBlock + 512));

    fftBuf_.resize(kSurveyBins);
    window_.resize(kSurveyBins);
    windowPower_ = 0;
    for (int i = 0; i < kSurveyBins; i++) {
        window_[static_cast<size_t>(i)] = static_cast<float>(0.5 - 0.5 * std::cos(2 * M_PI * (i + 0.5) / kSurveyBins));
        windowPower_ += window_[static_cast<size_t>(i)] * window_[static_cast<size_t>(i)];
    }
    surveyAcc_.assign(kSurveyBins, 0.0);
}

void FmDemod::requestPlay()
{
    pendingMode_ = static_cast<int>(Mode::Play);
    resetRequested_ = true;
}

void FmDemod::requestSurvey()
{
    {
        std::lock_guard<std::mutex> lock(surveyMutex_);
        surveyReady_ = false;
    }
    pendingMode_ = static_cast<int>(Mode::Survey);
    resetRequested_ = true;
}

bool FmDemod::waitSurvey(std::vector<float>& powerDb, int timeoutMs)
{
    std::unique_lock<std::mutex> lock(surveyMutex_);
    if (!surveyCv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this] { return surveyReady_; })) return false;
    powerDb = surveyResult_;
    return true;
}

FmDemod::Info FmDemod::info()
{
    std::lock_guard<std::mutex> lock(infoMutex_);
    return info_;
}

void FmDemod::doReset()
{
    mode_ = static_cast<Mode>(pendingMode_.load());
    skip_ = kRetuneSkip;
    chunks_ = 0;
    levelSumSq_ = 0;
    levelClipped_ = 0;
    levelCount_ = 0;
    agcRounds_ = 0;

    hb1_f_.reset();
    hb2_f_.reset();
    hb3_f_.reset();
    // A new station has its own offset; the stick's share of it (crystal
    // ppm) is small next to the AFC's range, so starting from 0 is fine.
    afcHz_ = 0;
    afcPhase_ = 0;
    dcHz_ = 0;
    prevI_ = prevQ_ = 0;

    pllPhase_ = 0;
    pllFreq_ = 0;
    pI_ = pI2_ = pQ_ = pQ2_ = 0;
    goodRun_ = badRun_ = 0;
    pilotLocked_ = false;
    cnrOk_ = false;
    cnrSmooth_ = 0;
    stereo_ = false;
    stereoGain_ = 0;

    audioDec_.reset();
    audioRes_.reset();
    deemphL_ = deemphR_ = dcBlock_ = 0;
    pcm_.clear();

    rdsDemod_.reset();
    rds_.reset();

    m2_ = m4_ = 0;
    statCount_ = 0;

    std::fill(surveyAcc_.begin(), surveyAcc_.end(), 0.0);
    surveyFfts_ = 0;
    surveyLeveling_ = true;

    std::lock_guard<std::mutex> lock(infoMutex_);
    info_ = Info();
}

void FmDemod::run(const std::atomic<bool>& stop)
{
    while (!stop.load()) {
        if (resetRequested_.exchange(false)) doReset();
        const int got = reader_.readIq(raw_.data(), 2 * kChunk);
        // Short read: interrupted by a retune (handled above next round) or
        // aborted for stop.
        if (got < 2 * kChunk) continue;
        if (resetRequested_.load()) continue;
        if (skip_ > 0) {
            skip_ -= kChunk;
            continue;
        }
        if (mode_ == Mode::Idle) continue;
        chunks_++;
        levelStats();
        if (mode_ == Mode::Play) processPlay();
        else if (mode_ == Mode::Survey) processSurvey();
    }
}

void FmDemod::levelStats()
{
    // A survey keeps its gain while it collects spectra.
    if (mode_ == Mode::Survey && !surveyLeveling_) return;
    // Integer arithmetic: (2b - 255)^2 = (255 * v)^2 for v = lut_[b].
    uint64_t sum = 0;
    long clipped = 0;
    for (int i = 0; i < 2 * kChunk; i++) {
        const int b = raw_[static_cast<size_t>(i)];
        clipped += (b == 0) | (b == 255);
        const int v = 2 * b - 255;
        sum += static_cast<uint32_t>(v * v);
    }
    levelSumSq_ += static_cast<double>(sum) / (255.0 * 255.0);
    levelClipped_ += clipped;
    levelCount_ += kChunk;
    if (levelCount_ < static_cast<long>(kLevelChunks) * kChunk) return;
    const float rms = static_cast<float>(std::sqrt(levelSumSq_ / levelCount_ / 2.0));
    const float clip = static_cast<float>(levelClipped_) / levelCount_ / 2.f;
    levelSumSq_ = 0;
    levelClipped_ = 0;
    levelCount_ = 0;

    // FM does not care about amplitude, so playback never pauses for a gain
    // step; it only settles down after the first second.
    const bool settled = mode_ == Mode::Play && chunks_ > kSampleRate / kChunk;
    const bool changed = sink_.onFmLevel(rms, clip, settled);
    if (mode_ == Mode::Survey && surveyLeveling_) {
        if (changed && agcRounds_ < kMaxAgcRounds) {
            // Samples taken with the old gain are still in flight.
            agcRounds_++;
            skip_ = kGainSkip;
        } else {
            surveyLeveling_ = false;
        }
    }
}

// --- survey ---

void FmDemod::processSurvey()
{
    if (surveyLeveling_ || surveyFfts_ >= kSurveyFfts) return;
    for (int block = 0; block < kChunk / kSurveyBins && surveyFfts_ < kSurveyFfts; block++) {
        const uint8_t* r = &raw_[static_cast<size_t>(2 * block * kSurveyBins)];
        for (int i = 0; i < kSurveyBins; i++) {
            const float w = window_[static_cast<size_t>(i)];
            fftBuf_[static_cast<size_t>(i)] = cf32(lut_[r[2 * i]] * w, lut_[r[2 * i + 1]] * w);
        }
        fft_.forward(fftBuf_.data());
        for (int k = 0; k < kSurveyBins; k++) surveyAcc_[static_cast<size_t>(k)] += std::norm(fftBuf_[static_cast<size_t>(k)]);
        surveyFfts_++;
    }
    if (surveyFfts_ < kSurveyFfts) return;

    // Normalised so the bins sum to the mean power (Parseval with window),
    // and reordered so bin kSurveyBins/2 is the tuned frequency.
    std::vector<float> db(kSurveyBins);
    const double norm = 1.0 / (static_cast<double>(kSurveyFfts) * kSurveyBins * windowPower_);
    for (int k = 0; k < kSurveyBins; k++) {
        const double p = surveyAcc_[static_cast<size_t>(k)] * norm;
        db[static_cast<size_t>((k + kSurveyBins / 2) % kSurveyBins)] = static_cast<float>(10.0 * std::log10(p + 1e-20));
    }
    {
        std::lock_guard<std::mutex> lock(surveyMutex_);
        surveyResult_ = std::move(db);
        surveyReady_ = true;
    }
    surveyCv_.notify_all();
    mode_ = Mode::Idle;
}

std::vector<FmCarrier> findFmCarriers(const std::vector<float>& powerDb, uint32_t centerHz, uint32_t lowHz,
                                      uint32_t highHz)
{
    std::vector<FmCarrier> out;
    const int n = static_cast<int>(powerDb.size());
    if (n < 64) return out;
    const int binHz = kSampleRate / n;
    const int mid = n / 2;
    const int usable = 800000 / binHz;
    const int half = 60000 / binHz;
    std::vector<double> lin(static_cast<size_t>(n));
    for (int i = 0; i < n; i++) lin[static_cast<size_t>(i)] = std::pow(10.0, powerDb[static_cast<size_t>(i)] / 10.0);
    // The tuner's own DC offset sits in the centre bins.
    double around = 0;
    for (int k = 3; k <= 6; k++) around += lin[static_cast<size_t>(mid - k)] + lin[static_cast<size_t>(mid + k)];
    for (int k = -2; k <= 2; k++) lin[static_cast<size_t>(mid + k)] = around / 8;

    std::vector<double> sorted(lin.begin() + (mid - usable), lin.begin() + (mid + usable));
    std::nth_element(sorted.begin(), sorted.begin() + static_cast<long>(sorted.size() / 5), sorted.end());
    const double floorBin = std::max(sorted[sorted.size() / 5], 1e-20);

    auto band = [&](long offsetHz) {
        const int c = mid + static_cast<int>(offsetHz / binHz);
        double s = 0;
        for (int i = std::max(0, c - half); i <= std::min(n - 1, c + half); i++) s += lin[static_cast<size_t>(i)];
        return s;
    };

    const long center = static_cast<long>(centerHz);
    long first = (center - 800000 + 49999) / 50000 * 50000;
    for (long f = first; f < center + 800000; f += 50000) {
        if (f < static_cast<long>(lowHz) || f > static_cast<long>(highHz)) continue;
        const double p = band(f - center);
        const double margin = 10.0 * std::log10(p / (floorBin * (2 * half + 1)));
        // Generous on purpose (6 dB, peak only against the direct 50 kHz
        // neighbours): the probe afterwards sorts out noise and splatter,
        // while a survey too strict lost real, weaker stations - a scan found
        // fewer than tuning through by hand (seen in Graz).
        if (margin < 6.0) continue;
        bool isMax = true;
        for (long g = f - 50000; g <= f + 50000 && isMax; g += 50000) {
            if (g == f) continue;
            const double q = band(g - center);
            if (q > p || (q == p && g < f)) isMax = false;
        }
        if (!isMax) continue;
        out.push_back({static_cast<uint32_t>(f), static_cast<float>(10.0 * std::log10(p)), static_cast<float>(margin)});
    }
    return out;
}

// --- playback ---

void FmDemod::processPlay()
{
    // 8-bit I/Q -> float, shifted by -fs/4 (station to 0 Hz): multiply by
    // (-j)^n, i.e. swap/negate only.
    const uint8_t* r = raw_.data();
    float* o = iq_.data();
    for (int i = 0; i < kChunk; i += 4, r += 8, o += 8) {
        o[0] = lut_[r[0]];
        o[1] = lut_[r[1]];
        o[2] = lut_[r[3]];
        o[3] = -lut_[r[2]];
        o[4] = -lut_[r[4]];
        o[5] = -lut_[r[5]];
        o[6] = -lut_[r[7]];
        o[7] = lut_[r[6]];
    }
    const int n1 = hb1_f_.process(iq_.data(), kChunk, hb1_.data());
    const int n2 = hb2_f_.process(hb1_.data(), n1, hb2_.data());

    // AFC at 512 kHz, ahead of the sharp channel filter so a station that is
    // off by a few kHz still gets centred in it.
    const uint32_t afcInc = static_cast<uint32_t>(static_cast<int32_t>(std::lround(-afcHz_ / (kMpxRate * 2) * 4294967296.0)));
    for (int i = 0; i < n2; i++) {
        const float c = cosTable(afcPhase_), s = sinTable(afcPhase_);
        const float re = hb2_[static_cast<size_t>(2 * i)], im = hb2_[static_cast<size_t>(2 * i + 1)];
        hb2_[static_cast<size_t>(2 * i)] = re * c - im * s;
        hb2_[static_cast<size_t>(2 * i + 1)] = re * s + im * c;
        afcPhase_ += afcInc;
    }
    const int n = hb3_f_.process(hb2_.data(), n2, ch_.data());

    // Discriminator: phase step between samples = instantaneous frequency.
    constexpr float kToHz = static_cast<float>(kMpxRate / (2.0 * M_PI));
    const float dc = static_cast<float>(dcHz_);
    const float scale = static_cast<float>(1.0 / kDeviationHz);
    double sumHz = 0, cm2 = 0, cm4 = 0;
    float pi = prevI_, pq = prevQ_;
    for (int i = 0; i < n; i++) {
        const float zi = ch_[static_cast<size_t>(2 * i)], zq = ch_[static_cast<size_t>(2 * i + 1)];
        const float p = zi * zi + zq * zq;
        cm2 += p;
        cm4 += static_cast<double>(p) * p;
        const float dr = zi * pi + zq * pq;
        const float di = zq * pi - zi * pq;
        const float hz = fastAtan2(di, dr) * kToHz;
        sumHz += hz;
        mpx_[static_cast<size_t>(i)] = (hz - dc) * scale;
        pi = zi;
        pq = zq;
    }
    prevI_ = pi;
    prevQ_ = pq;
    m2_ += cm2;
    m4_ += cm4;
    statCount_ += n;

    // Carrier offset = AFC + residual discriminator DC. The residual is
    // tracked slowly (audio has no DC, but bass moves the short-term mean)
    // and removed from the MPX; the AFC only steps when it grows large.
    if (n > 0) {
        const double alpha = chunks_ < 60 ? 0.2 : 0.02;
        dcHz_ += alpha * (sumHz / n - dcHz_);
        if (std::fabs(dcHz_) > 2000.0) {
            afcHz_ = std::max(-kMaxAfcHz, std::min(kMaxAfcHz, afcHz_ + dcHz_));
            dcHz_ = 0;
        }
        // Per-chunk CNR for the stereo decision (the 0.5 s figure is for display).
        const double a2 = cm2 / n, a4 = cm4 / n;
        const double s = std::sqrt(std::max(0.0, 2 * a2 * a2 - a4));
        const double noise = a2 - s;
        const float cnr = s <= 0 ? -10.f : noise <= 0 ? 60.f : static_cast<float>(10.0 * std::log10(s / noise));
        cnrSmooth_ += (chunks_ < 10 ? 0.5f : 0.1f) * (std::max(-10.f, std::min(60.f, cnr)) - cnrSmooth_);
        if (cnrSmooth_ > 14.f) cnrOk_ = true;
        else if (cnrSmooth_ < 10.f) cnrOk_ = false;
    }

    processMpx(n);
    // The first status after a retune comes after half the time: scan and
    // seek wait for it on every candidate.
    if (statCount_ >= (chunks_ * kMpxChunk > kStatusSamples ? kStatusSamples : kStatusSamples / 2)) finishStatus();
}

void FmDemod::processMpx(int n)
{
    // Pilot PLL (19 kHz): mpx*cos -> sin(err) * A/2, mpx*sin -> cos(err) * A/2,
    // each through two one-pole low-passes; the phase detector is their atan2.
    static const float kLp = onePole(400.0, kMpxRate);
    constexpr float kKp = 2.8e-4f, kKi = 3.9e-8f;
    constexpr float kMaxFreq = static_cast<float>(2 * M_PI * 50.0 / kMpxRate);
    // The discriminator takes the phase *difference* between samples, whose
    // response falls off like sinc(f/fs): 3.6% less at 38 kHz than for the
    // audio band, which alone would limit the separation to 35 dB.
    static const float kSubcarrierGain = [] {
        const double x = M_PI * 38000.0 / kMpxRate;
        return static_cast<float>(4.0 * x / std::sin(x));
    }();
    const float* mpx = mpx_.data();
    float* pair = pair_.data();
    for (int i = 0; i < n; i++) {
        const float m = mpx[i];
        const float c = cosTable(pllPhase_), s = sinTable(pllPhase_);
        pI_ += kLp * (m * c - pI_);
        pI2_ += kLp * (pI_ - pI2_);
        pQ_ += kLp * (m * s - pQ_);
        pQ2_ += kLp * (pQ_ - pQ2_);
        const float err = fastAtan2(pI2_, pQ2_);
        pllFreq_ = std::max(-kMaxFreq, std::min(kMaxFreq, pllFreq_ + kKi * err));
        pllPhase_ += kInc19 + static_cast<uint32_t>(static_cast<int32_t>((pllFreq_ + kKp * err) * kPhaseScale));
        // Stereo: the 38 kHz subcarrier is sin(2 * pilot phase) = 2 sin cos;
        // demodulated with twice that, the low-pass leaves (L-R)/2.
        pair[2 * i] = m;
        pair[2 * i + 1] = m * kSubcarrierGain * s * c;
    }

    // Stereo decision once per chunk, with hysteresis both ways.
    const float amp = 2.f * std::sqrt(pI2_ * pI2_ + pQ2_ * pQ2_);
    const float inPhase = amp > 0 ? 2.f * pQ2_ / amp : 0.f;
    const float pilot = 2.f * pQ2_;
    const bool good = pilot > 0.04f && inPhase > 0.9f;
    const bool bad = pilot < 0.025f || inPhase < 0.7f;
    if (good) {
        goodRun_++;
        badRun_ = 0;
    } else if (bad) {
        badRun_++;
        goodRun_ = 0;
    }
    if (goodRun_ >= 25) pilotLocked_ = true;    // 200 ms
    if (badRun_ >= 25) pilotLocked_ = false;
    stereo_ = pilotLocked_ && cnrOk_;

    // Audio: (L+R, L-R) -> 64 kHz -> 48 kHz.
    const int n64 = audioDec_.process(pair_.data(), n, pair64_.data());
    const int n48 = audioRes_.process(pair64_.data(), n64, pair48_.data());
    static const float kDeemph = static_cast<float>(1.0 - std::exp(-1.0 / (kAudioRate * 50e-6)));
    static const float kDcBlock = onePole(5.0, kAudioRate);
    const float target = stereo_ ? 1.f : 0.f;
    for (int i = 0; i < n48; i++) {
        // ~50 ms cross-fade between mono and stereo.
        stereoGain_ += std::max(-1.f / 2400, std::min(1.f / 2400, target - stereoGain_));
        float sum = pair48_[static_cast<size_t>(2 * i)];
        dcBlock_ += kDcBlock * (sum - dcBlock_);
        sum -= dcBlock_;
        const float diff = pair48_[static_cast<size_t>(2 * i + 1)] * stereoGain_;
        deemphL_ += kDeemph * (sum + diff - deemphL_);
        deemphR_ += kDeemph * (sum - diff - deemphR_);
        const float l = std::max(-1.f, std::min(1.f, deemphL_)) * 32767.f;
        const float r = std::max(-1.f, std::min(1.f, deemphR_)) * 32767.f;
        pcm_.push_back(static_cast<int16_t>(std::lrintf(l)));
        pcm_.push_back(static_cast<int16_t>(std::lrintf(r)));
    }
    if (static_cast<int>(pcm_.size()) >= 2 * kPcmBlock) {
        sink_.onFmAudio(pcm_.data(), static_cast<int>(pcm_.size() / 2));
        pcm_.clear();
    }

    // RDS
    bits_.clear();
    rdsDemod_.process(mpx_.data(), n, bits_);
    for (uint8_t b : bits_) rds_.pushBit(b);
    if (rds_.takeChanged()) {
        {
            std::lock_guard<std::mutex> lock(infoMutex_);
            info_.pi = rds_.pi();
            info_.ps = rds_.ps();
            info_.rt = rds_.rt();
        }
        sink_.onFmRds(rds_.pi(), rds_.ps(), rds_.rt());
    }
}

void FmDemod::finishStatus()
{
    FmStatus st;
    const double a2 = m2_ / statCount_, a4 = m4_ / statCount_;
    st.levelDbfs = static_cast<float>(10.0 * std::log10(a2 + 1e-20));
    // M2M4 estimator: for a constant-envelope carrier S plus Gaussian noise
    // N, E|z|^2 = S + N and E|z|^4 = S^2 + 4SN + 2N^2.
    const double s = std::sqrt(std::max(0.0, 2 * a2 * a2 - a4));
    const double noise = a2 - s;
    float cnr = s <= 0 ? -10.f : noise <= 0 ? 60.f : static_cast<float>(10.0 * std::log10(s / noise));
    st.snrDb = std::max(-10.f, std::min(60.f, cnr));
    st.offsetHz = static_cast<float>(afcHz_ + dcHz_);
    st.pilot = std::max(0.f, 2.f * pQ2_);
    st.stereo = stereo_;
    m2_ = m4_ = 0;
    statCount_ = 0;
    {
        std::lock_guard<std::mutex> lock(infoMutex_);
        info_.valid = true;
        info_.status = st;
        info_.rdsSync = rds_.synced();
    }
    sink_.onFmStatus(st);
}

} // namespace hrdab
