// FM broadcast (UKW, 87.5-108 MHz) receiver on a 1.024 MS/s I/Q stream
// (half the DAB rate - a station is only +-100 kHz wide, and over rtl_tcp
// the rate is the bandwidth): channel filter + decimation to 256 kS/s, discriminator,
// AFC, 19 kHz pilot PLL, stereo decoder with automatic mono fallback, 50 us
// de-emphasis, 48 kHz PCM out, and RDS. Also measures power spectra for the
// band scan (survey).
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "common.h"
#include "fft.h"
#include "fm_dsp.h"
#include "ofdm.h"
#include "rds.h"

namespace hrdab {

struct FmStatus {
    float levelDbfs = -100;  // channel power at the ADC, dB full scale
    float snrDb = 0;         // carrier-to-noise ratio in the channel
    float offsetHz = 0;      // carrier offset; positive = station above the tuned frequency
    float pilot = 0;         // 19 kHz pilot amplitude, fraction of 75 kHz deviation
    bool stereo = false;
};

class FmSink {
public:
    virtual ~FmSink() = default;
    // Input level about every 50 ms (as OfdmSink::onLevel). `settled`: the
    // station is playing for a while, only correct clear over/under drive.
    // Returns true if the tuner gain was changed.
    virtual bool onFmLevel(float rms, float clipRatio, bool settled) = 0;
    // 48 kHz interleaved stereo PCM.
    virtual void onFmAudio(const int16_t* pcm, int frames) = 0;
    // About every 500 ms while playing.
    virtual void onFmStatus(const FmStatus& status) = 0;
    // PI (-1 = unknown), PS and RT (empty = unknown) whenever one changes.
    virtual void onFmRds(int pi, const std::string& ps, const std::string& rt) = 0;
};

// A carrier found in a survey spectrum.
struct FmCarrier {
    uint32_t freqHz;
    float levelDbfs;   // power within +-60 kHz
    float marginDb;    // above the window's noise floor
};

// Stations on the 50 kHz raster in a survey spectrum (kSurveyBins bins of
// 1 kHz, bin kSurveyBins/2 = `centerHz`). Only the inner +-kSurveySpanHz/2
// are used (the stick's own filters roll off towards +-fs/2), clipped to
// [lowHz, highHz]. Of carriers closer than 100 kHz only the strongest is
// reported - the others are its modulation sidebands.
std::vector<FmCarrier> findFmCarriers(const std::vector<float>& powerDb, uint32_t centerHz, uint32_t lowHz,
                                      uint32_t highHz);

class FmDemod {
public:
    // I/Q rate for playback and survey alike: a switch between them would
    // restart the source (over rtl_tcp a reconnect), and seek alternates.
    static constexpr int kRate = 1024000;
    // While playing, the tuner sits this far below the station: fs/4 moves
    // it back to 0 Hz without multiplications, and keeps it clear of the DC
    // offset / LO leakage at the tuner's own centre.
    static constexpr int kIfShiftHz = kRate / 4;
    static constexpr int kAudioRate = 48000;
    static constexpr int kSurveyBins = kRate / 1000;  // 1 kHz bins
    // Part of a survey spectrum that is searched for carriers (centred).
    static constexpr int kSurveySpanHz = 800000;

    FmDemod(IqReader& reader, FmSink& sink);

    // Thread body; returns once `stop` is set.
    void run(const std::atomic<bool>& stop);

    // After a retune to a station (tuner at station - kIfShiftHz).
    void requestPlay();
    // After a retune for a spectrum survey (tuner at the window centre).
    void requestSurvey();
    // Waits for the survey requested last; power in dBFS per 1 kHz bin.
    bool waitSurvey(std::vector<float>& powerDb, int timeoutMs);

    struct Info {
        bool valid = false;  // a status has been measured since the last retune
        FmStatus status;
        bool rdsSync = false;
        int pi = -1;
        std::string ps, rt;
    };
    Info info();

private:
    enum class Mode { Idle, Play, Survey };

    void doReset();
    void levelStats();
    void processPlay();
    void processSurvey();
    void processMpx(int n);
    void finishStatus();

    IqReader& reader_;
    FmSink& sink_;
    Fft fft_;
    float lut_[256];

    std::atomic<bool> resetRequested_{false};
    std::atomic<int> pendingMode_{0};
    Mode mode_ = Mode::Idle;
    long skip_ = 0;              // samples still to discard after a retune
    long chunks_ = 0;            // since the last reset

    std::vector<uint8_t> raw_;
    std::vector<float> iq_, hb1_, ch_, mpx_, pair_, pair64_, pair48_;
    std::vector<int16_t> pcm_;

    // level / AGC
    double levelSumSq_ = 0;
    long levelClipped_ = 0;
    long levelCount_ = 0;
    int agcRounds_ = 0;

    // front end
    FirDecimator<2> hb1_f_, hb2_f_;
    uint32_t afcPhase_ = 0;
    double afcHz_ = 0;           // applied correction
    double dcHz_ = 0;            // residual discriminator DC
    float prevI_ = 0, prevQ_ = 0;

    // pilot PLL / stereo
    uint32_t pllPhase_ = 0;
    float pllFreq_ = 0;          // rad/sample relative to 19 kHz
    float pI_ = 0, pI2_ = 0, pQ_ = 0, pQ2_ = 0;
    int goodRun_ = 0, badRun_ = 0;
    bool pilotLocked_ = false;
    bool cnrOk_ = false;
    float cnrSmooth_ = 0;
    bool stereo_ = false;
    float stereoGain_ = 0;

    // audio
    FirDecimator<2> audioDec_;
    RationalResampler<2> audioRes_;
    float deemphL_ = 0, deemphR_ = 0, dcBlock_ = 0;

    // RDS
    RdsDemod rdsDemod_;
    RdsDecoder rds_;
    std::vector<uint8_t> bits_;

    // status (0.5 s)
    double m2_ = 0, m4_ = 0;
    long statCount_ = 0;

    // survey
    std::vector<double> surveyAcc_;
    int surveyFfts_ = 0;
    bool surveyLeveling_ = true;
    std::vector<cf32> fftBuf_;
    std::vector<float> window_;
    float windowPower_ = 0;

    std::mutex surveyMutex_;
    std::condition_variable surveyCv_;
    bool surveyReady_ = false;
    std::vector<float> surveyResult_;

    std::mutex infoMutex_;
    Info info_;
};

} // namespace hrdab
