// Shortwave (HF) on RTL2832U sticks: which way a frequency reaches the ADC.
//
// The R820T/R828D tuners do not go below ~24 MHz. Three ways around that,
// all chosen per tuned frequency (switching on retune, no hysteresis):
//  - direct sampling: the antenna feeds the RTL2832U's Q-ADC directly (RTL-SDR
//    Blog V3, NooElec NESDR SMArt v5 and other boards with an HF input on the
//    Q branch); the tuner is bypassed and the RTL2832U's DDC tunes. Only for
//    R820T-class tuners - an R828D stick is either a Blog V4 (own path below)
//    or a DVB-T2 stick without such an input;
//  - RTL-SDR Blog V4 (R828D, USB strings "RTLSDRBlog" / "Blog V4"): an
//    on-board mixer moves HF up by its 28.8 MHz reference; the tuner is set
//    28.8 MHz higher and switched to its HF input, a triplexer feeds the
//    three tuner inputs (HF, VHF, UHF), and the tuner's open-drain output
//    switches notch filters for the broadcast bands (see blogV4*() below);
//  - an external upconverter (Ham It Up 125 MHz, SpyVerter 120 MHz, ...)
//    configured by the user: everything below kExternalUpconverterBelowHz is
//    tuned that much higher. It takes precedence over the two above.
#pragma once

#include <atomic>
#include <cstdint>

namespace hrdab {

// Below this the R820T cannot tune; direct sampling takes over.
constexpr uint32_t kDirectSamplingBelowHz = 24000000;
// The Blog V4 upconverts below its reference frequency.
constexpr uint32_t kBlogV4UpconvertBelowHz = 28800000;
constexpr uint32_t kBlogV4UpconverterHz = 28800000;
// The Blog V4 tuner inputs: HF up to the upconverter limit, VHF below
// 250 MHz, UHF above.
constexpr uint32_t kBlogV4UhfFromHz = 250000000;
// An external upconverter covers the whole shortwave range.
constexpr uint32_t kExternalUpconverterBelowHz = 30000000;

// The user's external upconverter (0 = none), process-wide: set from the
// app's settings, read by the sources on every retune.
inline std::atomic<uint32_t>& externalUpconverterHz()
{
    static std::atomic<uint32_t> hz{0};
    return hz;
}

struct HfTuning {
    // RTL2832U direct sampling (Q branch); the DDC tunes to rfHz.
    bool directSampling = false;
    // Frequency for the tuner (or the DDC with direct sampling). A Blog V4
    // tuner adds its own upconverter offset, see blogV4TunerHz().
    uint32_t rfHz = 0;
};

// How to receive `hz`. directSamplingCapable: the stick has an R820T-class
// tuner (an R828D stick never uses direct sampling).
inline HfTuning planHf(uint32_t hz, bool directSamplingCapable, uint32_t externalUpconverter)
{
    HfTuning t;
    t.rfHz = hz;
    if (externalUpconverter != 0 && hz < kExternalUpconverterBelowHz) {
        t.rfHz = hz + externalUpconverter;
    } else if (directSamplingCapable && hz < kDirectSamplingBelowHz) {
        t.directSampling = true;
    }
    return t;
}

// RTL2832U DDC frequency word (22 bits, two's complement) that mixes hz at
// the input down to 0 Hz, the ADC clocked at xtalHz. Above half the clock
// (direct sampling 14.4-28.8 MHz) it wraps to the alias at hz - xtalHz,
// which keeps the spectrum the right way round.
inline uint32_t rtlIfWord(uint32_t hz, uint32_t xtalHz)
{
    const int64_t v = -(static_cast<int64_t>(hz) * (int64_t(1) << 22)) / xtalHz;
    return static_cast<uint32_t>(v) & 0x3fffff;
}

// --- RTL-SDR Blog V4 ---

enum class BlogV4Band { Hf, Vhf, Uhf };

inline BlogV4Band blogV4Band(uint32_t rfHz)
{
    if (rfHz < kBlogV4UpconvertBelowHz) return BlogV4Band::Hf;
    return rfHz < kBlogV4UhfFromHz ? BlogV4Band::Vhf : BlogV4Band::Uhf;
}

// What the tuner itself has to receive: HF comes out of the upconverter
// 28.8 MHz higher.
inline uint32_t blogV4TunerHz(uint32_t rfHz)
{
    return rfHz < kBlogV4UpconvertBelowHz ? rfHz + kBlogV4UpconverterHz : rfHz;
}

// Notch filters for the strong broadcast bands (MW, FM, DAB/VHF TV): on,
// except while tuned into one of those bands.
inline bool blogV4NotchOn(uint32_t rfHz)
{
    const bool inBroadcastBand = rfHz <= 2200000 || (rfHz >= 85000000 && rfHz <= 112000000) ||
                                 (rfHz >= 172000000 && rfHz <= 242000000);
    return !inBroadcastBand;
}

} // namespace hrdab
