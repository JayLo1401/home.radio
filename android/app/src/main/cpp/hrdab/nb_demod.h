// Narrowband listening receiver ("NB"): CB radio (26.5-27.5 MHz) and
// airband (118-137 MHz), next to DAB and FM on the same stick.
//
// The tuner sits in the middle of a window of 0.96-2.4 MS/s. Within it:
//  - an activity monitor: 2048-point FFTs of the whole window, averaged
//    over 0.2 s, give the power of every monitored channel, the noise floor
//    and a 256-bin spectrum (for a waterfall);
//  - the listened channel is mixed to 0 Hz and decimated in three stages to
//    16 kS/s complex, where it is filtered and demodulated as AM (envelope),
//    NFM (discriminator, CTCSS high-pass), USB or LSB (product detector),
//    then levelled by an audio AGC, gated by a level squelch and
//    interpolated to 48 kHz mono PCM;
//  - in "auto" mode the listened channel's signal is classified from its
//    spectrum (carrier, sideband symmetry) and envelope (constant or not).
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "common.h"
#include "fft.h"
#include "fm_dsp.h"
#include "ofdm.h"

namespace hrdab {

enum class NbMode { Auto = 0, Am = 1, Fm = 2, Usb = 3, Lsb = 4 };

// "auto", "am", "fm", "usb", "lsb"
const char* nbModeName(NbMode mode);

enum class NbAgc { Auto = 0, Fast = 1, Slow = 2 };

// "auto", "fast", "slow"
const char* nbAgcName(NbAgc agc);

// User-selectable signal filters; they persist across channel/mode changes.
struct NbFilters {
    // Channel filter width: two-sided for AM/NFM (3000-12500), the audio
    // passband width from 300 Hz up for USB/LSB (1000-3500). 0 = mode default
    // (AM 9500, NFM 10500, SSB 2700).
    int bandwidthHz = 0;
    // Impulse blanker on the wideband I/Q (ignition, electric fences).
    bool noiseBlanker = false;
    // Audio 300-3000 Hz (NFM: CTCSS high-pass at 350 Hz); off: NFM 100 Hz
    // high-pass, AM/SSB only a DC block, low-pass at ~6.5 kHz.
    bool voiceFilter = true;
    // Auto: fast for AM/NFM, slow for SSB.
    NbAgc agc = NbAgc::Auto;
};

// Everything the app shows, every 0.2 s. Levels in dBFS (power at the ADC);
// the receiver refers them to the tuner input.
struct NbReport {
    uint32_t freqHz = 0;          // listened channel
    float levelDbfs = -150;       // its power in the demodulator's channel filter
    float noiseDbfs = -150;       // noise floor in the same bandwidth
    float snrDb = 0;
    bool squelchOpen = false;
    NbMode mode = NbMode::Auto;   // in use; for auto the detected one, Auto while unknown
    // Filters in effect: bandwidth after defaults/clamping for the mode in
    // use, AGC resolved to Fast/Slow.
    int bandwidthHz = 0;
    bool noiseBlanker = false;
    bool voiceFilter = true;
    NbAgc agc = NbAgc::Fast;

    // Activity monitor; empty spectrum = no monitor data this time (e.g.
    // right after a gain change).
    uint32_t centerHz = 0;        // tuner frequency (window centre)
    uint32_t spanHz = 0;          // usable span the spectrum covers
    std::vector<float> spectrumDbfs;   // NbDemod::kSpectrumBins, power per FFT bin
    std::vector<uint32_t> channelsHz;
    std::vector<float> channelDbfs;    // power in kActivityBwHz; NaN = outside the window
    float channelNoiseDbfs = -150;     // noise floor in kActivityBwHz
};

class NbSink {
public:
    virtual ~NbSink() = default;
    // Input level about every 50 ms (as FmSink::onFmLevel); true if the
    // tuner gain was changed.
    virtual bool onNbLevel(float rms, float clipRatio, bool settled) = 0;
    // 48 kHz mono PCM, continuously (silence while the squelch is closed).
    virtual void onNbAudio(const int16_t* pcm, int frames) = 0;
    virtual void onNbReport(const NbReport& report) = 0;
};

struct NbConfig {
    uint32_t sampleRate = kSampleRate;
    uint32_t loHz = 0;            // tuner frequency
    std::vector<uint32_t> channelsHz;
    uint32_t freqHz = 0;          // listened channel
    NbMode mode = NbMode::Auto;
    int retune = 0;               // bumped whenever the tuner was retuned
};

class NbDemod {
public:
    static constexpr int kChannelRate = 16000;
    static constexpr int kAudioRate = 48000;
    static constexpr int kMonitorFft = 2048;
    static constexpr int kSpectrumBins = 256;
    static constexpr int kActivityBwHz = 8000;

    // 960000, 1024000, 1440000, 1920000, 2048000, 2400000 S/s.
    static bool supportedRate(uint32_t rate);
    // Half of the usable span: the stick's own filters roll off beyond.
    static int usableHalfSpan(uint32_t rate) { return static_cast<int>(rate * 0.85 / 2); }
    // Whether a channel at freqHz can be demodulated with the tuner at loHz
    // (inside the usable span, not on the DC spike).
    static bool canListen(uint32_t rate, uint32_t loHz, uint32_t freqHz);
    // Whether a monitored channel's power can be measured.
    static bool canMonitor(uint32_t rate, uint32_t loHz, uint32_t freqHz);
    // Tuner frequency for a window around centerHz: shifted by up to
    // +-12.5 kHz so that none of `freqsHz` sits near 0 Hz, where the stick's
    // DC offset / LO leakage is.
    static uint32_t placeLo(uint32_t rate, uint32_t centerHz, const std::vector<uint32_t>& freqsHz);

    NbDemod(IqReader& reader, NbSink& sink);

    // Thread body; returns once `stop` is set.
    void run(const std::atomic<bool>& stop);

    // Takes effect on the next chunk. A new rate/loHz/retune restarts the
    // whole window (skipping samples still in flight); a new freqHz/mode
    // only the channel chain.
    void configure(const NbConfig& cfg);
    // dB above the noise floor; <= 0 turns the squelch off (always open).
    void setSquelch(float db) { squelchDb_ = db; }
    // Takes effect on the next chunk.
    void setFilters(const NbFilters& filters);

    // Effective channel width for a mode under `filters` (see NbFilters).
    static int effectiveBandwidth(NbMode mode, int requestedHz);

private:
    struct Biquad {
        float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
        float z1 = 0, z2 = 0;
        void highpass(double hz, double q, double rate);
        float process(float x)
        {
            const float y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }
        void reset() { z1 = z2 = 0; }
    };

    void applyConfig();
    void rebuildDemod(NbMode mode);
    void blankImpulses();
    void buildRate(uint32_t rate);
    void resetWindow();
    void resetListen();
    NbMode activeMode() const;
    void processChunk();
    void convert();
    void monitorFft();
    void channelChain(bool hold);
    void demod16(int n, bool hold);
    void squelchBlock();
    void audioOut(int n);
    void classifyAccumulate(const float* a, int n);
    void classify();
    void report();
    float channelNoise(NbMode mode) const;

    IqReader& reader_;
    NbSink& sink_;
    float lut_[256];
    Fft monFft_;
    Fft clsFft_;
    std::vector<float> monWindow_, clsWindow_;
    double monWinPower_ = 0, clsWinPower_ = 0;

    std::mutex cfgMutex_;
    NbConfig pending_;
    std::atomic<int> cfgVersion_{0};
    int appliedVersion_ = -1;
    NbConfig cfg_;               // thread copy
    std::atomic<float> squelchDb_{10.f};
    NbFilters pendingFilters_;           // cfgMutex_
    std::atomic<int> filtersVersion_{0};
    int appliedFiltersVersion_ = 0;
    NbFilters filters_;                  // thread copy

    // noise blanker
    float nbAvg_ = 0;            // average sample power, 0 = not yet known
    int nbPostLeft_ = 0;
    int nbOverRun_ = 0;

    // rate dependent
    uint32_t builtRate_ = 0;
    int chunk_ = 0;              // input samples per read (8 ms)
    int factors_[3] = {1, 1, 1};
    FirDecimator<2> stage_[3];
    std::vector<uint8_t> raw_;
    std::vector<float> iq_, b1_, b2_, c16_;

    // window state
    long skip_ = 0;
    long chunks_ = 0;
    int reportChunks_ = 0;
    bool dcInit_ = false;
    float dcI_ = 0, dcQ_ = 0;
    double levelSumSq_ = 0;
    long levelClipped_ = 0, levelCount_ = 0;
    long gainHold_ = 0;          // samples after a gain change
    std::vector<double> monAcc_;
    int monCount_ = 0;
    std::vector<cf32> monBuf_;
    double floorBin_ = 0;        // noise power per monitor FFT bin, 0 = unknown
    double n0_ = 0;              // noise density per Hz (floorBin_ / bin width)

    // listened channel
    bool listening_ = false;
    uint32_t phase_ = 0, inc_ = 0;
    FirDecimator<2> wideFilt_, amFilt_, fmFilt_, ssbFilt_;
    float enbwWide_ = 0, enbwAm_ = 0, enbwFm_ = 0, enbwSsb_ = 0;
    double ssbCentreHz_ = 1650;
    int bandwidthHz_ = 0;        // in effect for lastMode_
    NbAgc agcInUse_ = NbAgc::Fast;
    int agcHoldSamples_ = 0;
    float agcDecay_ = 1;
    std::vector<float> a_, m_, tmp_, aud16_, audLp_, aud48_;
    uint32_t ssbPhase_ = 0;
    float prevI_ = 0, prevQ_ = 0;
    float amMean_ = 0;
    bool amInit_ = false;
    NbMode lastMode_ = NbMode::Auto;  // demodulator of the previous chunk
    Biquad hp_[3];
    int hpCount_ = 0;
    FirDecimator<1> audioLp_;
    RationalResampler<1> interp_;
    float agcEnv_ = 0;
    int agcHold_ = 0;
    std::vector<int16_t> pcm_;

    // squelch
    double sqBlockPow_ = 0;
    int sqBlockN_ = 0;
    double sqLevel_ = 0;
    bool sqLevelInit_ = false;
    bool sqOpen_ = false;
    int sqHang_ = 0;
    float gate_ = 0;

    // status
    double statPow_ = 0;
    long statN_ = 0;

    // auto mode
    std::vector<cf32> clsBuf_;
    int clsFill_ = 0;
    std::vector<double> clsAcc_;
    int clsFfts_ = 0;
    double envSum_ = 0, env2Sum_ = 0;
    long envN_ = 0;
    NbMode candidate_ = NbMode::Auto;
    int candidateVotes_ = 0;
    NbMode confirmed_ = NbMode::Auto;   // for the current channel
    NbMode fallback_ = NbMode::Auto;    // last confirmed on any channel
};

} // namespace hrdab
