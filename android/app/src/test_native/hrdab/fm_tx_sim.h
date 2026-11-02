// Test-only FM broadcast transmitter: stereo MPX (distinct left/right tones
// with 50 us pre-emphasis, 19 kHz pilot, 38 kHz DSB-SC), RDS groups 0A and
// 2A on 57 kHz, frequency modulated with 75 kHz deviation at a given
// baseband offset, several stations summed, plus white noise, as 2.048 MS/s
// 8-bit I/Q.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace hrdab::test {

struct FmStation {
    double offsetHz = 0;          // carrier frequency relative to the tuner
    double amplitude = 1.0;       // relative carrier amplitude
    bool stereo = true;           // pilot + L-R subcarrier
    double leftHz = 1000, rightHz = 2500;
    double toneAmp = 0.45;        // per channel, before pre-emphasis
    bool rds = true;
    double rdsLevel = 0.045;      // fraction of full deviation
    bool rdsShaped = true;        // EN 50067 pulse shaping; false: one sine cycle per bit
    uint16_t pi = 0xA3E1;
    std::string ps = "\xD7" "3 TEST";  // RDS G0 bytes (0xD7 = O umlaut)
    std::string rt;                   // RDS G0 bytes, up to 64
};

struct FmTxConfig {
    std::vector<FmStation> stations;
    double cnrDb = 25;            // total carrier power to noise over the full 2.048 MHz
    double rms = 0.22;            // per component, of full scale before quantisation
    unsigned seed = 4321;
};

// RDS groups (four 16-bit info words each) as the simulator sends them:
// 0A for the PS and 2A for the RadioText, interleaved 0A,0A,2A.
std::vector<std::vector<uint16_t>> rdsGroups(const FmStation& st);
// The groups as a (not yet differentially encoded) bit stream with check words.
std::vector<uint8_t> rdsBits(const std::vector<std::vector<uint16_t>>& groups, int repeat);

std::vector<uint8_t> generateFm(const FmTxConfig& cfg, double seconds);

} // namespace hrdab::test
