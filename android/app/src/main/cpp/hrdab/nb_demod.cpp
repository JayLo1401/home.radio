#include "nb_demod.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace hrdab {

namespace {

constexpr int kChunksPerSecond = 125;           // 8 ms per read at every rate
constexpr int kChannelPerChunk = NbDemod::kChannelRate / kChunksPerSecond;  // 128
constexpr int kReportChunks = 25;               // 0.2 s per report
constexpr int kLevelChunks = 6;                 // ~50 ms per AGC report
constexpr double kRetuneSkipS = 0.15;           // old data still in flight after a retune
constexpr double kGainSkipS = 0.13;             // same after a gain change
constexpr int kStageGuardHz = 7000;             // every decimation stage keeps 0..7 kHz alias-free
constexpr int kDcGuardHz = 2500;                // no channel this close to the tuner's own DC
constexpr int kMaxLoShiftHz = 12500;
constexpr int kClsFft = 512;                    // 31.25 Hz bins at 16 kS/s
constexpr int kClsFfts = 8;                     // 256 ms per classification
constexpr int kClsVotes = 3;                    // same verdict this often in a row to switch
constexpr double kFmNormHz = 3000.0;            // NFM deviation that gives full-scale audio
constexpr int kSquelchBlock = 320;              // 20 ms at 16 kS/s
constexpr int kSquelchHangBlocks = 15;          // 0.3 s
constexpr float kSquelchHystDb = 3.f;
constexpr int kPcmBlock = 1536;                 // frames per onNbAudio (32 ms)
constexpr float kAgcTarget = 0.5f;              // audio peak level (full scale 1)
constexpr float kPhaseScale = 4294967296.f;
constexpr double kWfmDeviationHz = 75000.0;     // full modulation, gives kAgcTarget peaks
constexpr int kWfmGuardHz = 120000;             // WFM stages keep 0..120 kHz alias-free
constexpr int kWfmPassHz = 100000;              // ...and flat to 100 kHz

struct RatePlan {
    uint32_t rate;
    int factors[3];  // product = rate / 16000
    int wfm[2];      // product = rate / 240000 or rate / 256000
};

// Decimation to 16 kS/s in three stages; the first is the one that costs,
// so it gets the largest factor its wide transition band allows. WFM: two
// stages, the last always by 2 (a half-band, see buildRate).
const RatePlan kPlans[] = {
    {960000, {5, 4, 3}, {2, 2}},  {1024000, {8, 4, 2}, {2, 2}}, {1440000, {6, 5, 3}, {3, 2}},
    {1920000, {8, 5, 3}, {4, 2}}, {2048000, {8, 4, 4}, {4, 2}}, {2400000, {10, 5, 3}, {5, 2}},
};

const RatePlan* planFor(uint32_t rate)
{
    for (const auto& p : kPlans) {
        if (p.rate == rate) return &p;
    }
    return nullptr;
}

// Kaiser low-pass for 60 dB stop-band: taps from the transition width.
std::vector<float> lowpass(double passHz, double stopHz, double rate)
{
    const double transition = (stopHz - passHz) / rate;
    const int taps = (static_cast<int>(std::ceil(3.62 / transition)) + 1) | 1;
    return designLowpass(taps, (passHz + stopHz) / 2 / rate, kaiserBeta(60));
}

// Equivalent noise bandwidth of a unity-DC-gain FIR at `rate`.
float enbw(const std::vector<float>& h, double rate)
{
    double s = 0;
    for (float v : h) s += static_cast<double>(v) * v;
    return static_cast<float>(rate * s);
}

float onePole(double fc, double fs)
{
    return static_cast<float>(1.0 - std::exp(-2.0 * M_PI * fc / fs));
}

float linToDb(double p)
{
    return static_cast<float>(10.0 * std::log10(std::max(p, 1e-20)));
}

NbMode bandDefault(uint32_t freqHz)
{
    // Airband is AM by regulation; CB here is mostly FM.
    return freqHz >= 108000000u && freqHz <= 137000000u ? NbMode::Am : NbMode::Fm;
}

} // namespace

const char* nbModeName(NbMode mode)
{
    switch (mode) {
        case NbMode::Am: return "am";
        case NbMode::Fm: return "fm";
        case NbMode::Usb: return "usb";
        case NbMode::Lsb: return "lsb";
        case NbMode::Wfm: return "wfm";
        default: return "auto";
    }
}

const char* nbAgcName(NbAgc agc)
{
    switch (agc) {
        case NbAgc::Fast: return "fast";
        case NbAgc::Slow: return "slow";
        default: return "auto";
    }
}

int NbDemod::effectiveBandwidth(NbMode mode, int requestedHz)
{
    if (mode == NbMode::Usb || mode == NbMode::Lsb) {
        return requestedHz <= 0 ? 2700 : std::max(1000, std::min(3500, requestedHz));
    }
    if (mode == NbMode::Wfm) {
        return requestedHz <= 0 ? 100000 : std::max(50000, std::min(kWfmMaxBwHz, requestedHz));
    }
    // +-6.25 kHz at most: the 16 kS/s channel is only alias-free to ~7 kHz.
    if (requestedHz <= 0) return mode == NbMode::Am ? 9500 : 10500;
    return std::max(3000, std::min(12500, requestedHz));
}

void NbDemod::setFilters(const NbFilters& filters)
{
    std::lock_guard<std::mutex> lock(cfgMutex_);
    pendingFilters_ = filters;
    filtersVersion_++;
}

void NbDemod::rebuildDemod(NbMode mode)
{
    // Channel filter: -6 dB at half the width, transition 20 % of the width
    // (at most 1.5 kHz, i.e. the old fixed filters for the defaults).
    const int bw = effectiveBandwidth(mode, filters_.bandwidthHz);
    bandwidthHz_ = bw;
    const bool ssb = mode == NbMode::Usb || mode == NbMode::Lsb;
    if (mode == NbMode::Wfm) {
        // At 240/256 kS/s; transition 20 % of the width, at least 15 kHz
        // (taps), so 200 kHz stops right at 120 kHz, the stages' guard.
        const double half = bw / 2.0, tr = std::max(15000.0, std::min(40000.0, 0.2 * bw));
        const auto h = lowpass(half - tr / 2, half + tr / 2, wfmRate_);
        wfmFilt_.init(h, 1);
        enbwWfm_ = enbw(h, wfmRate_);
        // No audio filters or AGC (they are not used); reported as fast.
        agcInUse_ = filters_.agc == NbAgc::Auto ? NbAgc::Fast : filters_.agc;
        return;
    }
    if (ssb) {
        // Audio passband 300 Hz .. 300 + bw, shifted to 0 Hz for the low-pass.
        const double half = bw / 2.0, tr = std::min(350.0, 0.2 * bw);
        const auto h = lowpass(half - tr / 2, half + tr / 2, kChannelRate);
        ssbFilt_.init(h, 1);
        enbwSsb_ = enbw(h, kChannelRate);
        ssbCentreHz_ = 300 + half;
    } else {
        const double half = bw / 2.0, tr = std::min(1500.0, 0.2 * bw);
        const auto h = lowpass(half - tr / 2, half + tr / 2, kChannelRate);
        if (mode == NbMode::Am) {
            amFilt_.init(h, 1);
            enbwAm_ = enbw(h, kChannelRate);
        } else {
            fmFilt_.init(h, 1);
            enbwFm_ = enbw(h, kChannelRate);
        }
    }

    // Audio band. Voice filter: 300-3000 Hz; for NFM a 6th-order
    // Butterworth at 350 Hz against CTCSS tones (67-254 Hz), otherwise 4th
    // order at 300 Hz. Off: NFM keeps a 100 Hz hum/DC high-pass, AM/SSB only
    // a DC block; the low-pass then only removes what is above any voice
    // (and the discriminator's rising noise).
    const bool fm = mode == NbMode::Fm;
    if (filters_.voiceFilter) {
        if (fm) {
            const double q[3] = {0.5176, 0.7071, 1.9319};
            for (int i = 0; i < 3; i++) hp_[i].highpass(350, q[i], kChannelRate);
            hpCount_ = 3;
        } else {
            hp_[0].highpass(300, 0.5412, kChannelRate);
            hp_[1].highpass(300, 1.3066, kChannelRate);
            hpCount_ = 2;
        }
        audioLp_.init(lowpass(2900, 3500, kChannelRate), 1);
    } else {
        hp_[0].highpass(fm ? 100 : 20, 0.7071, kChannelRate);
        hpCount_ = 1;
        audioLp_.init(lowpass(6000, 7000, kChannelRate), 1);
    }

    // AGC: fast suits AM/NFM (carrier-normalised already, only evens out
    // modulation); slow suits SSB, whose level comes and goes with the voice.
    agcInUse_ = filters_.agc == NbAgc::Auto ? (ssb ? NbAgc::Slow : NbAgc::Fast) : filters_.agc;
    const bool slow = agcInUse_ == NbAgc::Slow;
    agcHoldSamples_ = kChannelRate * (slow ? 10 : 2) / 10;
    agcDecay_ = static_cast<float>(std::pow(10.0, -(slow ? 6.0 : 20.0) / 20.0 / kChannelRate));
}

void NbDemod::blankImpulses()
{
    // Classic blanker: a sample whose power exceeds kThreshold times the
    // running average is an impulse; it is zeroed together with a few
    // samples before (the stick's own filters spread the impulse's rising
    // edge) and after it. The average only learns from samples kept, so a
    // burst cannot raise its own threshold - but a run longer than any
    // impulse (a station keying up) is accepted as the new level at once.
    // Gaussian noise crosses 10x its mean power with p = 4.5e-5: a few
    // dozen microsecond-gaps per second, far below audibility.
    constexpr float kThreshold = 10.f;
    const double rate = cfg_.sampleRate;
    // Short holds: every blanked sample also removes the wanted carrier for
    // that moment, which is itself a (small) click.
    const int pre = std::max(1, static_cast<int>(rate * 1e-6));
    const int post = std::max(2, static_cast<int>(rate * 4e-6));
    const int maxRun = static_cast<int>(rate * 50e-6);
    const float alpha = static_cast<float>(1.0 / (rate * 0.005));
    float* d = iq_.data();
    const int n = chunk_;
    float avg = nbAvg_;
    if (avg <= 0) {
        double s = 0;
        for (int i = 0; i < 2 * n; i++) s += static_cast<double>(d[i]) * d[i];
        avg = static_cast<float>(s / n);
        if (avg <= 0) return;
    }
    int postLeft = nbPostLeft_;
    int run = nbOverRun_;
    for (int i = 0; i < n; i++) {
        const float p = d[2 * i] * d[2 * i] + d[2 * i + 1] * d[2 * i + 1];
        if (p > kThreshold * avg) {
            if (++run > maxRun) {
                avg = p;  // not an impulse: a new, stronger signal
                run = 0;
                continue;
            }
            for (int j = std::max(0, i - pre); j <= i; j++) d[2 * j] = d[2 * j + 1] = 0.f;
            postLeft = post;
        } else {
            run = 0;
            if (postLeft > 0) {
                postLeft--;
                d[2 * i] = d[2 * i + 1] = 0.f;
            } else {
                avg += alpha * (p - avg);
            }
        }
    }
    nbAvg_ = avg;
    nbPostLeft_ = postLeft;
    nbOverRun_ = run;
}

void NbDemod::Biquad::highpass(double hz, double q, double rate)
{
    // RBJ cookbook high-pass.
    const double w0 = 2 * M_PI * hz / rate;
    const double alpha = std::sin(w0) / (2 * q);
    const double c = std::cos(w0);
    const double a0 = 1 + alpha;
    b0 = static_cast<float>((1 + c) / 2 / a0);
    b1 = static_cast<float>(-(1 + c) / a0);
    b2 = b0;
    a1 = static_cast<float>(-2 * c / a0);
    a2 = static_cast<float>((1 - alpha) / a0);
    reset();
}

bool NbDemod::supportedRate(uint32_t rate)
{
    return planFor(rate) != nullptr;
}

bool NbDemod::canListen(uint32_t rate, uint32_t loHz, uint32_t freqHz, NbMode mode)
{
    const long off = std::labs(static_cast<long>(freqHz) - static_cast<long>(loHz));
    // WFM: the DC spike may sit inside the channel (it is far narrower than
    // the window shift could avoid); convert() removes the stick's offset.
    const long margin = mode == NbMode::Wfm ? kWfmMaxBwHz / 2 : 6000;
    return off >= kDcGuardHz && off <= usableHalfSpan(rate) - margin;
}

bool NbDemod::canMonitor(uint32_t rate, uint32_t loHz, uint32_t freqHz)
{
    const long off = std::labs(static_cast<long>(freqHz) - static_cast<long>(loHz));
    return off <= usableHalfSpan(rate) - kActivityBwHz / 2;
}

uint32_t NbDemod::placeLo(uint32_t rate, uint32_t centerHz, const std::vector<uint32_t>& freqsHz)
{
    const long half = usableHalfSpan(rate);
    long bestShift = 0;
    long bestDist = -1;
    // 0, +250, -250, +500, ...: on a tie the smallest shift wins.
    for (int k = 0; k <= 2 * kMaxLoShiftHz / 250; k++) {
        const long shift = (k % 2 ? 1 : -1) * ((k + 1) / 2) * 250L;
        const long lo = static_cast<long>(centerHz) + shift;
        long dist = 1L << 30;
        for (uint32_t f : freqsHz) {
            const long d = std::labs(static_cast<long>(f) - lo);
            if (d <= half) dist = std::min(dist, d);
        }
        if (dist > bestDist) {
            bestDist = dist;
            bestShift = shift;
        }
        if (bestDist >= kMaxLoShiftHz) break;
    }
    return static_cast<uint32_t>(static_cast<long>(centerHz) + bestShift);
}

NbDemod::NbDemod(IqReader& reader, NbSink& sink)
    : reader_(reader), sink_(sink), monFft_(kMonitorFft), clsFft_(kClsFft)
{
    for (int i = 0; i < 256; i++) lut_[i] = (static_cast<float>(i) - 127.5f) / 127.5f;
    auto hann = [](int n, std::vector<float>& w, double& power) {
        w.resize(static_cast<size_t>(n));
        power = 0;
        for (int i = 0; i < n; i++) {
            w[static_cast<size_t>(i)] = static_cast<float>(0.5 - 0.5 * std::cos(2 * M_PI * (i + 0.5) / n));
            power += w[static_cast<size_t>(i)] * w[static_cast<size_t>(i)];
        }
    };
    hann(kMonitorFft, monWindow_, monWinPower_);
    hann(kClsFft, clsWindow_, clsWinPower_);
    monAcc_.assign(kMonitorFft, 0.0);
    monBuf_.resize(kMonitorFft);
    clsBuf_.resize(kClsFft);
    clsAcc_.assign(kClsFft, 0.0);

    // Fixed +-5.25 kHz analysis filter for auto mode (and the squelch noise
    // reference before the first rebuildDemod). The demodulators' own
    // filters follow the user's bandwidth, see rebuildDemod().
    const auto wide = lowpass(4500, 6000, kChannelRate);
    wideFilt_.init(wide, 1);
    enbwWide_ = enbw(wide, kChannelRate);
    enbwAm_ = enbwFm_ = enbwSsb_ = enbwWide_;
    sqBlockLen_ = kSquelchBlock;
    // x3 to 48 kHz; passes up to 7 kHz (voice filter off), images from 9 kHz.
    interp_.init(lowpass(7000, 9000, kAudioRate), 3, 1);

    const int maxChunk = kChannelPerChunk + 8;
    a_.resize(2 * maxChunk);
    m_.resize(2 * maxChunk);
    tmp_.resize(2 * maxChunk);
    aud16_.resize(maxChunk);
    audLp_.resize(maxChunk);
    aud48_.resize(3 * maxChunk + 8);
    pcm_.reserve(kPcmBlock + 3 * maxChunk);
}

void NbDemod::configure(const NbConfig& cfg)
{
    std::lock_guard<std::mutex> lock(cfgMutex_);
    pending_ = cfg;
    cfgVersion_++;
}

void NbDemod::buildRate(uint32_t rate)
{
    const RatePlan* plan = planFor(rate);
    if (!plan) return;
    builtRate_ = rate;
    chunk_ = static_cast<int>(rate / kChunksPerSecond);
    double in = rate;
    for (int s = 0; s < 3; s++) {
        factors_[s] = plan->factors[s];
        const double out = in / factors_[s];
        // Only 0..7 kHz has to stay free of aliases: whatever folds into the
        // rest of the band is removed by the following stages.
        stage_[s].init(lowpass(kStageGuardHz, out - kStageGuardHz, in), factors_[s]);
        in = out;
    }
    raw_.resize(2 * static_cast<size_t>(chunk_));
    iq_.resize(2 * static_cast<size_t>(chunk_));
    b1_.resize(2 * static_cast<size_t>(chunk_ / factors_[0] + 8));
    b2_.resize(2 * static_cast<size_t>(chunk_ / factors_[0] / factors_[1] + 8));
    c16_.resize(2 * static_cast<size_t>(kChannelPerChunk + 8));

    // WFM: the first stage only has to keep 0..120 kHz free of aliases (the
    // channel filter's widest stop edge); the last, always by 2, is flat to
    // 100 kHz and lets 120..140 kHz fold onto 100..120 kHz, where the channel
    // filter's own transition takes it down further. Both come out as
    // half-bands wherever the first factor is 2.
    in = rate;
    for (int s = 0; s < 2; s++) {
        wfmFactors_[s] = plan->wfm[s];
        const double out = in / wfmFactors_[s];
        const double pass = s == 1 ? kWfmPassHz : kWfmGuardHz;
        wfmStage_[s].init(lowpass(pass, out - pass, in), wfmFactors_[s]);
        in = out;
    }
    wfmRate_ = static_cast<int>(in);
    const int wfmChunk = chunk_ / wfmFactors_[0] / wfmFactors_[1];
    w1_.resize(2 * static_cast<size_t>(chunk_ / wfmFactors_[0] + 8));
    w2_.resize(2 * static_cast<size_t>(wfmChunk + 8));
    wfmCh_.resize(2 * static_cast<size_t>(wfmChunk + 8));
    // Discriminator output to 48 kHz (240 kHz: 1/5, 256 kHz: 3/16) with the
    // 15 kHz audio low-pass, which also takes out a 19 kHz stereo pilot.
    int g = kAudioRate, r = wfmRate_;
    while (r) {
        const int t = g % r;
        g = r;
        r = t;
    }
    const int up = kAudioRate / g, down = wfmRate_ / g;
    wfmAudio_.init(lowpass(15000, 19000, static_cast<double>(up) * wfmRate_), up, down);
    wfmAud_.resize(static_cast<size_t>(wfmChunk * up / down + 16));
    // Noise reference until the first rebuildDemod (default width).
    enbwWfm_ = enbw(lowpass(40000, 60000, wfmRate_), wfmRate_);
}

void NbDemod::applyConfig()
{
    NbConfig c;
    {
        std::lock_guard<std::mutex> lock(cfgMutex_);
        c = pending_;
        appliedVersion_ = cfgVersion_.load();
    }
    if (!supportedRate(c.sampleRate)) {
        HR_LOGW("NB: unsupported sample rate %u", c.sampleRate);
        return;
    }
    const bool window = builtRate_ == 0 || c.sampleRate != cfg_.sampleRate || c.loHz != cfg_.loHz ||
                        c.retune != cfg_.retune;
    const bool listen = window || c.freqHz != cfg_.freqHz || c.mode != cfg_.mode;
    cfg_ = c;
    if (c.sampleRate != builtRate_) buildRate(c.sampleRate);
    if (window) resetWindow();
    if (listen) resetListen();
    HR_LOGI("NB: %u S/s, tuner %u Hz, %zu channels, listen %u Hz %s%s", c.sampleRate, c.loHz, c.channelsHz.size(),
            c.freqHz, nbModeName(c.mode), listening_ ? "" : " (outside the window)");
}

void NbDemod::resetWindow()
{
    skip_ = static_cast<long>(cfg_.sampleRate * kRetuneSkipS);
    chunks_ = 0;
    reportChunks_ = 0;
    dcInit_ = false;
    dcI_ = dcQ_ = 0;
    levelSumSq_ = 0;
    levelClipped_ = levelCount_ = 0;
    gainHold_ = 0;
    std::fill(monAcc_.begin(), monAcc_.end(), 0.0);
    monCount_ = 0;
    // The noise floor is measured anew: the squelch stays shut for the first
    // 0.2 s rather than judging by another window's floor.
    floorBin_ = 0;
    n0_ = 0;
    nbAvg_ = 0;
    nbPostLeft_ = 0;
    nbOverRun_ = 0;
}

void NbDemod::resetListen()
{
    listening_ = canListen(cfg_.sampleRate, cfg_.loHz, cfg_.freqHz, cfg_.mode);
    const double offset = static_cast<double>(cfg_.freqHz) - static_cast<double>(cfg_.loHz);
    inc_ = static_cast<uint32_t>(static_cast<int64_t>(std::llround(-offset / cfg_.sampleRate * 4294967296.0)));
    phase_ = 0;
    for (auto& s : stage_) s.reset();
    wideFilt_.reset();
    amFilt_.reset();
    fmFilt_.reset();
    ssbFilt_.reset();
    for (auto& s : wfmStage_) s.reset();
    wfmFilt_.reset();
    wfmAudio_.reset();
    wfmDeemph_ = wfmDc_ = 0;
    sqBlockLen_ = cfg_.mode == NbMode::Wfm ? wfmRate_ / 50 : kSquelchBlock;
    ssbPhase_ = 0;
    prevI_ = prevQ_ = 0;
    amMean_ = 0;
    amInit_ = false;
    lastMode_ = NbMode::Auto;
    audioLp_.reset();
    interp_.reset();
    agcEnv_ = 0;
    agcHold_ = 0;
    sqBlockPow_ = 0;
    sqBlockN_ = 0;
    sqLevel_ = 0;
    sqLevelInit_ = false;
    sqOpen_ = false;
    sqHang_ = 0;
    gate_ = 0;
    statPow_ = 0;
    statN_ = 0;
    clsFill_ = 0;
    std::fill(clsAcc_.begin(), clsAcc_.end(), 0.0);
    clsFfts_ = 0;
    envSum_ = env2Sum_ = 0;
    envN_ = 0;
    candidate_ = NbMode::Auto;
    candidateVotes_ = 0;
    confirmed_ = NbMode::Auto;
    // An explicit choice counts as "confirmed" for a later switch to auto -
    // except WFM, which auto never uses.
    if (cfg_.mode != NbMode::Auto && cfg_.mode != NbMode::Wfm) fallback_ = cfg_.mode;
}

NbMode NbDemod::activeMode() const
{
    if (cfg_.mode != NbMode::Auto) return cfg_.mode;
    if (confirmed_ != NbMode::Auto) return confirmed_;
    if (fallback_ != NbMode::Auto) return fallback_;
    return bandDefault(cfg_.freqHz);
}

float NbDemod::channelNoise(NbMode mode) const
{
    const float bw = mode == NbMode::Am                                ? enbwAm_
                     : (mode == NbMode::Usb || mode == NbMode::Lsb) ? enbwSsb_
                     : mode == NbMode::Wfm                          ? enbwWfm_
                                                                    : enbwFm_;
    return static_cast<float>(n0_ * bw);
}

void NbDemod::run(const std::atomic<bool>& stop)
{
    while (!stop.load()) {
        if (cfgVersion_.load() != appliedVersion_) applyConfig();
        if (chunk_ == 0) {
            // Not configured (cannot happen through Receiver): keep the ring drained.
            uint8_t sink[4096];
            reader_.readIq(sink, sizeof(sink));
            continue;
        }
        const int got = reader_.readIq(raw_.data(), 2 * chunk_);
        // Short read: interrupted by a retune or aborted for stop.
        if (got < 2 * chunk_) continue;
        if (cfgVersion_.load() != appliedVersion_) continue;
        if (skip_ > 0) {
            skip_ -= chunk_;
            continue;
        }
        processChunk();
    }
}

void NbDemod::processChunk()
{
    chunks_++;
    if (filtersVersion_.load() != appliedFiltersVersion_) {
        std::lock_guard<std::mutex> lock(cfgMutex_);
        filters_ = pendingFilters_;
        appliedFiltersVersion_ = filtersVersion_.load();
        lastMode_ = NbMode::Auto;  // demod16 rebuilds its filters
        HR_LOGI("NB filters: bandwidth %d Hz, blanker %d, voice filter %d, AGC %s", filters_.bandwidthHz,
                filters_.noiseBlanker, filters_.voiceFilter, nbAgcName(filters_.agc));
    }
    convert();
    // Not for WFM: its wide channel would lose too much to every gap.
    if (filters_.noiseBlanker && cfg_.mode != NbMode::Wfm) blankImpulses();
    const bool hold = gainHold_ > 0;
    if (hold) gainHold_ -= chunk_;
    if (!hold) monitorFft();
    if (listening_) {
        channelChain(hold);
    } else {
        // Keep the audio output running (silence) so it never underruns.
        pcm_.insert(pcm_.end(), static_cast<size_t>(3 * kChannelPerChunk), 0);
        if (static_cast<int>(pcm_.size()) >= kPcmBlock) {
            sink_.onNbAudio(pcm_.data(), static_cast<int>(pcm_.size()));
            pcm_.clear();
        }
    }
    if (++reportChunks_ >= kReportChunks) {
        report();
        reportChunks_ = 0;
    }
}

void NbDemod::convert()
{
    const uint8_t* r = raw_.data();
    const int n = chunk_;
    uint32_t sumI = 0, sumQ = 0;
    uint64_t sq = 0;
    long clipped = 0;
    for (int i = 0; i < n; i++) {
        const int bi = r[2 * i], bq = r[2 * i + 1];
        sumI += static_cast<uint32_t>(bi);
        sumQ += static_cast<uint32_t>(bq);
        clipped += (bi == 0) + (bi == 255) + (bq == 0) + (bq == 255);
        const int vi = 2 * bi - 255, vq = 2 * bq - 255;
        sq += static_cast<uint32_t>(vi * vi + vq * vq);
    }
    // DC offset of the stick, removed before anything else (it would sit
    // right between two channels, see placeLo, but leaks into the FFT).
    const float mi = (static_cast<float>(sumI) / n - 127.5f) / 127.5f;
    const float mq = (static_cast<float>(sumQ) / n - 127.5f) / 127.5f;
    if (!dcInit_) {
        dcI_ = mi;
        dcQ_ = mq;
        dcInit_ = true;
    } else {
        dcI_ += 0.1f * (mi - dcI_);
        dcQ_ += 0.1f * (mq - dcQ_);
    }
    const float di = dcI_, dq = dcQ_;
    float* o = iq_.data();
    for (int i = 0; i < n; i++) {
        o[2 * i] = lut_[r[2 * i]] - di;
        o[2 * i + 1] = lut_[r[2 * i + 1]] - dq;
    }

    levelSumSq_ += static_cast<double>(sq) / (255.0 * 255.0);
    levelClipped_ += clipped;
    levelCount_ += n;
    if (levelCount_ < static_cast<long>(kLevelChunks) * n) return;
    const float rms = static_cast<float>(std::sqrt(levelSumSq_ / levelCount_ / 2.0));
    const float clip = static_cast<float>(levelClipped_) / levelCount_ / 2.f;
    levelSumSq_ = 0;
    levelClipped_ = 0;
    levelCount_ = 0;
    const bool settled = chunks_ > kChunksPerSecond;
    if (sink_.onNbLevel(rms, clip, settled)) {
        // Samples with the old gain are still in flight: keep them out of
        // the level measurements (audio just carries on, the AGC copes).
        gainHold_ = static_cast<long>(cfg_.sampleRate * kGainSkipS);
        std::fill(monAcc_.begin(), monAcc_.end(), 0.0);
        monCount_ = 0;
        clsFill_ = 0;
        std::fill(clsAcc_.begin(), clsAcc_.end(), 0.0);
        clsFfts_ = 0;
        envSum_ = env2Sum_ = 0;
        envN_ = 0;
    }
}

void NbDemod::monitorFft()
{
    // One FFT per chunk (2048 of its samples) - plenty for 5 Hz reports.
    const float* x = iq_.data();
    for (int i = 0; i < kMonitorFft; i++) {
        const float w = monWindow_[static_cast<size_t>(i)];
        monBuf_[static_cast<size_t>(i)] = cf32(x[2 * i] * w, x[2 * i + 1] * w);
    }
    monFft_.forward(monBuf_.data());
    for (int k = 0; k < kMonitorFft; k++) monAcc_[static_cast<size_t>(k)] += std::norm(monBuf_[static_cast<size_t>(k)]);
    monCount_++;
}

void NbDemod::channelChain(bool hold)
{
    // Listened channel to 0 Hz.
    float* d = iq_.data();
    uint32_t ph = phase_;
    const uint32_t inc = inc_;
    for (int i = 0; i < chunk_; i++) {
        const float c = cosTable(ph), s = sinTable(ph);
        const float re = d[2 * i], im = d[2 * i + 1];
        d[2 * i] = re * c - im * s;
        d[2 * i + 1] = re * s + im * c;
        ph += inc;
    }
    phase_ = ph;
    if (cfg_.mode == NbMode::Wfm) {
        wfmChain(hold);
        return;
    }
    const int n1 = stage_[0].process(iq_.data(), chunk_, b1_.data());
    const int n2 = stage_[1].process(b1_.data(), n1, b2_.data());
    const int n3 = stage_[2].process(b2_.data(), n2, c16_.data());
    demod16(n3, hold);
}

void NbDemod::demod16(int n, bool hold)
{
    const float* z = c16_.data();
    wideFilt_.process(z, n, a_.data());
    if (cfg_.mode == NbMode::Auto && !hold) classifyAccumulate(a_.data(), n);

    const NbMode mode = activeMode();
    if (mode != lastMode_) {
        // New demodulator (auto switched, channel/mode or filters changed):
        // its filters follow mode and user settings; the AGC starts afresh
        // (its level means something else now) and the AM carrier average
        // settles anew.
        rebuildDemod(mode);
        agcEnv_ = 0;
        agcHold_ = 0;
        amInit_ = false;
        prevI_ = prevQ_ = 0;
        lastMode_ = mode;
    }

    const float* m = m_.data();
    const bool ssb = mode == NbMode::Usb || mode == NbMode::Lsb;
    const double ssbHz = mode == NbMode::Usb ? ssbCentreHz_ : -ssbCentreHz_;
    const uint32_t ssbInc = static_cast<uint32_t>(static_cast<int64_t>(std::llround(ssbHz / kChannelRate * 4294967296.0)));
    if (mode == NbMode::Am) {
        amFilt_.process(z, n, m_.data());
    } else if (mode == NbMode::Fm) {
        fmFilt_.process(z, n, m_.data());
    } else if (ssb) {
        // Product detector: the sideband's centre to 0 Hz, +-1.35 kHz
        // low-pass, back up, real part.
        uint32_t ph = ssbPhase_;
        for (int i = 0; i < n; i++) {
            const float c = cosTable(ph), s = sinTable(ph);
            const float re = z[2 * i], im = z[2 * i + 1];
            tmp_[static_cast<size_t>(2 * i)] = re * c + im * s;
            tmp_[static_cast<size_t>(2 * i + 1)] = im * c - re * s;
            ph += ssbInc;
        }
        ssbFilt_.process(tmp_.data(), n, m_.data());
    }
    levelAndSquelch(m, n, hold);

    float* aud = aud16_.data();
    switch (mode) {
        case NbMode::Fm: {
            constexpr float kToNorm = static_cast<float>(kChannelRate / (2.0 * M_PI) / kFmNormHz);
            float pi = prevI_, pq = prevQ_;
            for (int i = 0; i < n; i++) {
                const float zi = m[2 * i], zq = m[2 * i + 1];
                aud[i] = fastAtan2(zq * pi - zi * pq, zi * pi + zq * pq) * kToNorm;
                pi = zi;
                pq = zq;
            }
            prevI_ = pi;
            prevQ_ = pq;
            break;
        }
        case NbMode::Am: {
            // Envelope relative to the carrier: modulation depth, whatever
            // the signal strength. The carrier average also removes DC.
            static const float kCarrierLp = onePole(8.0, kChannelRate);
            for (int i = 0; i < n; i++) {
                const float env = std::sqrt(m[2 * i] * m[2 * i] + m[2 * i + 1] * m[2 * i + 1]);
                if (!amInit_) {
                    amMean_ = env;
                    amInit_ = true;
                }
                amMean_ += kCarrierLp * (env - amMean_);
                // Clamped to what a real AM signal can do (-100..+200 %): the
                // filters' start-up or a fading carrier would otherwise give
                // huge peaks that hold the audio AGC down for seconds.
                aud[i] = std::max(-1.f, std::min(2.f, (env - amMean_) / std::max(amMean_, 1e-6f)));
            }
            break;
        }
        default: {
            uint32_t ph = ssbPhase_;
            for (int i = 0; i < n; i++) {
                const float c = cosTable(ph), s = sinTable(ph);
                aud[i] = m[2 * i] * c - m[2 * i + 1] * s;
                ph += ssbInc;
            }
            break;
        }
    }
    if (ssb) ssbPhase_ += ssbInc * static_cast<uint32_t>(n);
    audioOut(n);
}

void NbDemod::wfmChain(bool hold)
{
    if (lastMode_ != NbMode::Wfm) {
        rebuildDemod(NbMode::Wfm);
        prevI_ = prevQ_ = 0;
        lastMode_ = NbMode::Wfm;
    }
    const int n1 = wfmStage_[0].process(iq_.data(), chunk_, w1_.data());
    const int n2 = wfmStage_[1].process(w1_.data(), n1, w2_.data());
    wfmFilt_.process(w2_.data(), n2, wfmCh_.data());
    const float* m = wfmCh_.data();
    levelAndSquelch(m, n2, hold);

    // Discriminator; full deviation gives the other modes' AGC peak level,
    // so switching modes does not jump in loudness. No AGC: the deviation
    // is the level.
    const float toNorm = static_cast<float>(kAgcTarget * wfmRate_ / (2.0 * M_PI) / kWfmDeviationHz);
    float* disc = w2_.data();  // free again
    float pi = prevI_, pq = prevQ_;
    for (int i = 0; i < n2; i++) {
        const float zi = m[2 * i], zq = m[2 * i + 1];
        disc[i] = fastAtan2(zq * pi - zi * pq, zi * pi + zq * pq) * toNorm;
        pi = zi;
        pq = zq;
    }
    prevI_ = pi;
    prevQ_ = pq;

    // 15 kHz low-pass and 48 kHz in one; then, as the UKW receiver, a DC
    // block (carrier offset) and the 50 us de-emphasis.
    const int n48 = wfmAudio_.process(disc, n2, wfmAud_.data());
    static const float kDeemph = static_cast<float>(1.0 - std::exp(-1.0 / (kAudioRate * 50e-6)));
    static const float kDcBlock = onePole(5.0, kAudioRate);
    float dc = wfmDc_, de = wfmDeemph_;
    float* a = wfmAud_.data();
    for (int i = 0; i < n48; i++) {
        dc += kDcBlock * (a[i] - dc);
        de += kDeemph * (a[i] - dc - de);
        a[i] = std::max(-0.98f, std::min(0.98f, de));
    }
    wfmDc_ = dc;
    wfmDeemph_ = de;
    gateOut(a, n48);
}

void NbDemod::levelAndSquelch(const float* m, int n, bool hold)
{
    double pow = 0;
    for (int i = 0; i < n; i++) {
        const float re = m[2 * i], im = m[2 * i + 1];
        const float p = re * re + im * im;
        pow += p;
        sqBlockPow_ += p;
        if (++sqBlockN_ == sqBlockLen_) {
            // Also during a gain change: one step (~1.6 dB) stays within the
            // hysteresis, and freezing would stretch the hang time.
            squelchBlock();
            sqBlockPow_ = 0;
            sqBlockN_ = 0;
        }
    }
    if (!hold) {
        statPow_ += pow;
        statN_ += n;
    }
}

void NbDemod::squelchBlock()
{
    const float sq = squelchDb_.load();
    if (sq <= 0.f) {
        sqOpen_ = true;
        return;
    }
    const double noise = channelNoise(activeMode());
    if (noise <= 0) {
        sqOpen_ = false;  // floor not measured yet
        return;
    }
    const double level = sqBlockPow_ / sqBlockLen_;
    if (!sqLevelInit_) {
        sqLevel_ = level;
        sqLevelInit_ = true;
    } else {
        sqLevel_ += 0.5 * (level - sqLevel_);
    }
    const double snr = 10.0 * std::log10(std::max(sqLevel_, 1e-20) / noise);
    if (snr >= sq) {
        sqOpen_ = true;
        sqHang_ = kSquelchHangBlocks;
    } else if (sqOpen_) {
        if (snr >= sq - kSquelchHystDb) {
            sqHang_ = kSquelchHangBlocks;
        } else if (--sqHang_ <= 0) {
            sqOpen_ = false;
        }
    }
}

void NbDemod::audioOut(int n)
{
    const NbMode mode = lastMode_;
    float* aud = aud16_.data();
    for (int i = 0; i < n; i++) {
        float x = aud[i];
        for (int k = 0; k < hpCount_; k++) x = hp_[k].process(x);
        aud[i] = x;
    }
    const int nl = audioLp_.process(aud, n, audLp_.data());

    // AGC: instant attack on peaks, then hold and decay (fast: 0.2 s,
    // 20 dB/s; slow: 1 s, 6 dB/s). Its floor caps the gain, so a weak
    // signal's noise is not pumped up: AM and NFM are already normalised
    // (depth, deviation), SSB is scaled to its channel noise.
    const float kDecay = agcDecay_;
    const int kHold = agcHoldSamples_;
    float maxGain = 4.f;
    if (mode == NbMode::Usb || mode == NbMode::Lsb) {
        const double noiseAmp = std::sqrt(std::max(n0_ * enbwSsb_ / 2.0, 0.0));
        maxGain = noiseAmp > 0 ? static_cast<float>(kAgcTarget / (10.0 * noiseAmp)) : 1e5f;
    }
    const float floorEnv = kAgcTarget / maxGain;
    float env = agcEnv_;
    int holdLeft = agcHold_;
    for (int i = 0; i < nl; i++) {
        const float x = audLp_[static_cast<size_t>(i)];
        const float a = std::fabs(x);
        if (a > env) {
            env = a;
            holdLeft = kHold;
        } else if (holdLeft > 0) {
            holdLeft--;
        } else {
            env *= kDecay;
        }
        const float y = x * (kAgcTarget / std::max(env, floorEnv));
        audLp_[static_cast<size_t>(i)] = std::max(-0.98f, std::min(0.98f, y));
    }
    agcEnv_ = env;
    agcHold_ = holdLeft;

    const int n48 = interp_.process(audLp_.data(), nl, aud48_.data());
    gateOut(aud48_.data(), n48);
}

void NbDemod::gateOut(const float* a48, int n48)
{
    // Squelch gate: 5 ms fade in, 10 ms fade out - no clicks.
    const float target = sqOpen_ ? 1.f : 0.f;
    float g = gate_;
    for (int i = 0; i < n48; i++) {
        if (g < target) g = std::min(target, g + 1.f / 240);
        else if (g > target) g = std::max(target, g - 1.f / 480);
        const float v = a48[i] * g * 32767.f;
        pcm_.push_back(static_cast<int16_t>(std::lrintf(std::max(-32767.f, std::min(32767.f, v)))));
    }
    gate_ = g;
    if (static_cast<int>(pcm_.size()) >= kPcmBlock) {
        sink_.onNbAudio(pcm_.data(), static_cast<int>(pcm_.size()));
        pcm_.clear();
    }
}

// --- auto mode ---

void NbDemod::classifyAccumulate(const float* a, int n)
{
    for (int i = 0; i < n; i++) {
        const float re = a[2 * i], im = a[2 * i + 1];
        const float p = re * re + im * im;
        envSum_ += std::sqrt(p);
        env2Sum_ += p;
        envN_++;
        const float w = clsWindow_[static_cast<size_t>(clsFill_)];
        clsBuf_[static_cast<size_t>(clsFill_)] = cf32(re * w, im * w);
        if (++clsFill_ < kClsFft) continue;
        clsFill_ = 0;
        clsFft_.forward(clsBuf_.data());
        for (int k = 0; k < kClsFft; k++) clsAcc_[static_cast<size_t>(k)] += std::norm(clsBuf_[static_cast<size_t>(k)]);
        if (++clsFfts_ >= kClsFfts) {
            classify();
            std::fill(clsAcc_.begin(), clsAcc_.end(), 0.0);
            clsFfts_ = 0;
            envSum_ = env2Sum_ = 0;
            envN_ = 0;
        }
    }
}

void NbDemod::classify()
{
    // Features of the last 256 ms in the +-5.25 kHz channel:
    //  - carrier fraction: power of the strongest line within +-1 kHz of the
    //    channel centre, relative to the signal power (AM ~0.9; NFM with
    //    modulation well below; SSB has no carrier),
    //  - sideband asymmetry: 200-3200 Hz above vs below the centre (SSB >10 dB,
    //    AM/NFM symmetric),
    //  - envelope variation (std/mean of |z|): NFM constant, AM follows the
    //    modulation.
    // Noise is subtracted using the window's measured floor; without a floor
    // or below ~5 dB SNR there is no verdict.
    if (n0_ <= 0 || envN_ == 0) return;
    constexpr double binHz = static_cast<double>(kChannelRate) / kClsFft;
    const double norm = 1.0 / (static_cast<double>(clsFfts_) * kClsFft * clsWinPower_);
    auto bin = [&](int k) { return clsAcc_[static_cast<size_t>((k + kClsFft) % kClsFft)] * norm; };
    const double nBin = n0_ * binHz;
    const int edge = static_cast<int>(5000 / binHz);
    double total = 0;
    for (int k = -edge; k <= edge; k++) total += bin(k);
    const double noise = nBin * (2 * edge + 1);
    const double sig = total - noise;
    if (sig < 3 * noise) return;

    const int search = static_cast<int>(1000 / binHz);
    int peak = 0;
    for (int k = -search; k <= search; k++) {
        if (bin(k) > bin(peak)) peak = k;
    }
    const double carrier = std::max(0.0, bin(peak - 1) + bin(peak) + bin(peak + 1) - 3 * nBin);
    const double cf = carrier / sig;

    const int lo = static_cast<int>(std::lround(200 / binHz)), hi = static_cast<int>(std::lround(3200 / binHz));
    double up = 0, down = 0;
    for (int k = lo; k <= hi; k++) {
        if (cf <= 0.15 || std::abs(k - peak) > 2) up += bin(k) - nBin;
        if (cf <= 0.15 || std::abs(-k - peak) > 2) down += bin(-k) - nBin;
    }
    const double eps = 0.003 * sig;
    const double asym = 10.0 * std::log10(std::max(up, 0.0) + eps) - 10.0 * std::log10(std::max(down, 0.0) + eps);

    const double mean = envSum_ / envN_;
    const double var = env2Sum_ / envN_ - mean * mean;
    // Noise adds ~N/2 to the envelope variance (N = noise power in the filter).
    const double varSig = var - n0_ * enbwWide_ / 2;
    const double cv = mean > 0 ? std::sqrt(std::max(0.0, varSig)) / mean : 0;

    NbMode verdict = NbMode::Auto;
    if (asym > 10) verdict = NbMode::Usb;
    else if (asym < -10) verdict = NbMode::Lsb;
    else if (std::fabs(asym) < 6) {
        if (cf >= 0.3 && cv >= 0.1) verdict = NbMode::Am;
        else if (cv < 0.07 && cf < 0.8) verdict = NbMode::Fm;
        // else: e.g. an unmodulated carrier - AM and NFM look the same.
    }
    if (verdict == NbMode::Auto) return;
    if (verdict == candidate_) {
        candidateVotes_++;
    } else {
        candidate_ = verdict;
        candidateVotes_ = 1;
    }
    if (candidateVotes_ >= kClsVotes && confirmed_ != verdict) {
        HR_LOGI("NB auto: %s (carrier %.2f, asym %.1f dB, env cv %.3f, snr %.1f dB)", nbModeName(verdict), cf, asym, cv,
                10 * std::log10(sig / noise));
        confirmed_ = verdict;
        fallback_ = verdict;
    }
}

// --- reports ---

void NbDemod::report()
{
    NbReport rep;
    rep.freqHz = cfg_.freqHz;
    rep.centerHz = cfg_.loHz;
    const int half = usableHalfSpan(cfg_.sampleRate);
    rep.spanHz = static_cast<uint32_t>(2 * half);
    rep.channelsHz = cfg_.channelsHz;

    const double binHz = static_cast<double>(cfg_.sampleRate) / kMonitorFft;
    const double actBins = kActivityBwHz / binHz;
    if (monCount_ > 0) {
        // Normalised so the bins sum to the mean power (Parseval with window).
        const double norm = 1.0 / (static_cast<double>(monCount_) * kMonitorFft * monWinPower_);
        std::vector<double> p(kMonitorFft);
        for (int k = 0; k < kMonitorFft; k++) p[static_cast<size_t>(k)] = monAcc_[static_cast<size_t>(k)] * norm;
        auto offsetOf = [&](int k) { return (k < kMonitorFft / 2 ? k : k - kMonitorFft) * binHz; };

        // Noise floor: 30th percentile of the usable bins (away from DC),
        // corrected for the averaged bins' spread. Robust as long as fewer
        // than ~2/3 of the window is occupied.
        std::vector<double> usable;
        usable.reserve(kMonitorFft);
        for (int k = 0; k < kMonitorFft; k++) {
            const double f = offsetOf(k);
            if (std::fabs(f) <= half && (k > 2 && k < kMonitorFft - 2)) usable.push_back(p[static_cast<size_t>(k)]);
        }
        const size_t q = usable.size() * 3 / 10;
        std::nth_element(usable.begin(), usable.begin() + static_cast<long>(q), usable.end());
        const double spread = 0.524 / std::sqrt(static_cast<double>(monCount_));
        floorBin_ = usable[q] / std::max(0.3, 1.0 - spread);
        n0_ = floorBin_ / binHz;

        rep.channelNoiseDbfs = linToDb(floorBin_ * actBins);
        rep.channelDbfs.resize(cfg_.channelsHz.size());
        for (size_t c = 0; c < cfg_.channelsHz.size(); c++) {
            const uint32_t f = cfg_.channelsHz[c];
            if (!canMonitor(cfg_.sampleRate, cfg_.loHz, f)) {
                rep.channelDbfs[c] = NAN;
                continue;
            }
            const double off = static_cast<double>(f) - static_cast<double>(cfg_.loHz);
            const int k0 = static_cast<int>(std::ceil((off - kActivityBwHz / 2) / binHz));
            const int k1 = static_cast<int>(std::floor((off + kActivityBwHz / 2) / binHz));
            double sum = 0;
            int cnt = 0;
            for (int k = k0; k <= k1; k++) {
                sum += p[static_cast<size_t>((k + kMonitorFft) % kMonitorFft)];
                cnt++;
            }
            rep.channelDbfs[c] = cnt > 0 ? linToDb(sum / cnt * actBins) : NAN;
        }

        std::vector<double> acc(kSpectrumBins, 0.0);
        std::vector<int> cnt(kSpectrumBins, 0);
        for (int k = 0; k < kMonitorFft; k++) {
            const double f = offsetOf(k);
            if (f < -half || f >= half) continue;
            const int j = static_cast<int>((f + half) * kSpectrumBins / (2.0 * half));
            if (j < 0 || j >= kSpectrumBins) continue;
            acc[static_cast<size_t>(j)] += p[static_cast<size_t>(k)];
            cnt[static_cast<size_t>(j)]++;
        }
        rep.spectrumDbfs.resize(kSpectrumBins);
        for (int j = 0; j < kSpectrumBins; j++) {
            const int c = cnt[static_cast<size_t>(j)];
            rep.spectrumDbfs[static_cast<size_t>(j)] = c ? linToDb(acc[static_cast<size_t>(j)] / c) : linToDb(floorBin_);
        }
        std::fill(monAcc_.begin(), monAcc_.end(), 0.0);
        monCount_ = 0;
    }

    const NbMode mode = activeMode();
    const double noise = channelNoise(mode);
    rep.noiseDbfs = linToDb(noise);
    if (listening_ && statN_ > 0) {
        rep.levelDbfs = linToDb(statPow_ / statN_);
        rep.snrDb = noise > 0 ? rep.levelDbfs - rep.noiseDbfs : 0.f;
    } else {
        rep.levelDbfs = rep.noiseDbfs;
        rep.snrDb = 0;
    }
    statPow_ = 0;
    statN_ = 0;
    rep.squelchOpen = listening_ && sqOpen_;
    rep.mode = cfg_.mode != NbMode::Auto ? cfg_.mode : confirmed_;
    rep.bandwidthHz = lastMode_ != NbMode::Auto ? bandwidthHz_ : effectiveBandwidth(mode, filters_.bandwidthHz);
    rep.noiseBlanker = filters_.noiseBlanker;
    rep.voiceFilter = filters_.voiceFilter;
    rep.agc = lastMode_ != NbMode::Auto
                  ? agcInUse_
                  : (filters_.agc != NbAgc::Auto ? filters_.agc
                                                 : (mode == NbMode::Usb || mode == NbMode::Lsb ? NbAgc::Slow : NbAgc::Fast));
    sink_.onNbReport(rep);
}

} // namespace hrdab
