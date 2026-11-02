// Test-only narrowband transmitters (CB/airband style): AM, NFM, USB and
// LSB stations carrying two "voice-like" tones with a slow syllabic
// envelope, keyed on and off, at given offsets from the tuner, plus white
// noise, as 8-bit I/Q at any sample rate.
#pragma once

#include <cstdint>
#include <vector>

namespace hrdab::test {

enum class NbTxMode { Am, Fm, Usb, Lsb };

struct NbStation {
    double offsetHz = 0;          // carrier / suppressed carrier relative to the tuner
    NbTxMode mode = NbTxMode::Am;
    double snrDb = 30;            // average power while keyed vs. noise in 8 kHz
    double tone1Hz = 700, tone2Hz = 1500;
    double onS = 0, offS = 1e9;   // keyed between these times
    double depth = 0.8;           // AM peak modulation depth
    double deviationHz = 2500;    // NFM peak deviation
};

struct NbTxConfig {
    uint32_t sampleRate = 2048000;
    std::vector<NbStation> stations;
    double rms = 0.22;            // per component, of full scale while all are keyed
    unsigned seed = 1234;
    // Impulse noise (ignition-like): bursts of impulseUs at impulseAmp of
    // full scale (random phase, clipped by the 8-bit quantiser), about
    // impulseRateHz per second with jittered spacing. 0 = none.
    double impulseRateHz = 0;
    double impulseUs = 3;
    double impulseAmp = 1.2;
};

std::vector<uint8_t> generateNb(const NbTxConfig& cfg, double seconds);

} // namespace hrdab::test
