#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include "common.h"

namespace hrdab {

// Phase reference symbol (EN 300 401 clause 14.3.2), indexed by FFT bin.
// Unused bins (DC and outside +-768) are 0.
const std::vector<cf32>& phaseReference();

// FFT bin index for carrier k (-768..768, k != 0).
inline int carrierToBin(int k) { return k < 0 ? k + kFftLen : k; }

// Frequency interleaving (clause 14.6.1): logical QPSK symbol n is carried on
// carrier frequencyMap()[n].
const std::array<int, kCarriers>& frequencyMap();

// Puncturing vector PI_n (clause 11.1.2), n = 1..24, as 32 keep(1)/drop(0)
// flags, first transmitted bit first.
const std::array<uint8_t, 32>& puncturingVector(int n);
// The 24-bit tail vector PI_X.
const std::array<uint8_t, 24>& puncturingTail();

// Energy dispersal PRBS (clause 10.2): x^9 + x^5 + 1, all-ones start.
// XORs the sequence into `bits` (one bit per byte).
void energyDispersal(uint8_t* bits, int count);

// CRC-16 CCITT (x^16+x^12+x^5+1, init 0xFFFF) as used by FIBs, DAB+ AUs,
// X-PAD and MOT data groups. The transmitted CRC is the ones' complement.
uint16_t crc16Ccitt(const uint8_t* data, int len);
inline bool crc16Ok(const uint8_t* data, int lenWithCrc)
{
    if (lenWithCrc < 2) return false;
    const uint16_t stored = static_cast<uint16_t>((data[lenWithCrc - 2] << 8) | data[lenWithCrc - 1]);
    return static_cast<uint16_t>(~crc16Ccitt(data, lenWithCrc - 2)) == stored;
}

// DAB+ superframe fire code (TS 102 563 clause 5.2), init 0, not inverted.
uint16_t fireCode(const uint8_t* data, int len);

// Equal error protection parameters (clause 11.3.2).
struct EepProfile {
    int l1 = 0, l2 = 0; // number of 128-bit blocks using pi1 / pi2
    int pi1 = 0, pi2 = 0;
    int bitrateKbps = 0;
};
// optionB: false = EEP-A, true = EEP-B; level 0..3 = protection level 1..4.
bool eepProfile(bool optionB, int level, int sizeCu, EepProfile& out);

} // namespace hrdab
