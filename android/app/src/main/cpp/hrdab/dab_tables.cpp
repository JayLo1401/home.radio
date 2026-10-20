#include "dab_tables.h"

#include <cmath>

namespace hrdab {

namespace {

// Time-frequency-phase parameter h (EN 300 401 table 44).
const uint8_t kH[4][32] = {
    {0, 2, 0, 0, 0, 0, 1, 1, 2, 0, 0, 0, 2, 2, 1, 1, 0, 2, 0, 0, 0, 0, 1, 1, 2, 0, 0, 0, 2, 2, 1, 1},
    {0, 3, 2, 3, 0, 1, 3, 0, 2, 1, 2, 3, 2, 3, 3, 0, 0, 3, 2, 3, 0, 1, 3, 0, 2, 1, 2, 3, 2, 3, 3, 0},
    {0, 0, 0, 2, 0, 2, 1, 3, 2, 2, 0, 2, 2, 0, 1, 3, 0, 0, 0, 2, 0, 2, 1, 3, 2, 2, 0, 2, 2, 0, 1, 3},
    {0, 1, 2, 1, 0, 3, 3, 2, 2, 3, 2, 1, 2, 1, 3, 2, 0, 1, 2, 1, 0, 3, 3, 2, 2, 3, 2, 1, 2, 1, 3, 2},
};

// Mode I (i, n) per block of 32 carriers (EN 300 401 table 43), from
// k = -768 upwards; the k' of each block is its first carrier.
struct PrsBlock {
    uint8_t i, n;
};
const PrsBlock kPrsBlocks[48] = {
    {0, 1}, {1, 2}, {2, 0}, {3, 1}, {0, 3}, {1, 2}, {2, 2}, {3, 3},
    {0, 2}, {1, 1}, {2, 2}, {3, 3}, {0, 1}, {1, 2}, {2, 3}, {3, 3},
    {0, 2}, {1, 2}, {2, 2}, {3, 1}, {0, 1}, {1, 3}, {2, 1}, {3, 2},
    {0, 3}, {3, 1}, {2, 1}, {1, 1}, {0, 2}, {3, 2}, {2, 1}, {1, 0},
    {0, 2}, {3, 2}, {2, 3}, {1, 3}, {0, 0}, {3, 2}, {2, 1}, {1, 3},
    {0, 3}, {3, 3}, {2, 3}, {1, 0}, {0, 3}, {3, 0}, {2, 1}, {1, 1},
};

std::vector<cf32> buildPhaseReference()
{
    std::vector<cf32> ref(kFftLen, cf32(0, 0));
    for (int b = 0; b < 48; b++) {
        // Negative carriers: blocks 0..23 start at -768 + 32b. Positive
        // carriers: blocks 24..47 start at 1 + 32(b-24) (carrier 0 unused).
        const int kStart = b < 24 ? -768 + 32 * b : 1 + 32 * (b - 24);
        for (int j = 0; j < 32; j++) {
            const int k = kStart + j;
            const int phase = (kH[kPrsBlocks[b].i][j] + kPrsBlocks[b].n) & 3;
            static const cf32 kQuadrant[4] = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}};
            ref[carrierToBin(k)] = kQuadrant[phase];
        }
    }
    return ref;
}

std::array<int, kCarriers> buildFrequencyMap()
{
    std::array<int, kCarriers> map{};
    int pi = 0;
    int n = 0;
    for (int i = 0; i < kFftLen; i++) {
        if (i > 0) pi = (13 * pi + 511) % kFftLen;
        if (pi >= 256 && pi <= 1792 && pi != 1024) map[n++] = pi - 1024;
    }
    return map;
}

std::array<std::array<uint8_t, 32>, 25> buildPuncturingVectors()
{
    // Each PI_n keeps the first bit of all eight 4-bit groups, plus n more
    // bits; the extra bits are handed out to the groups in the order below,
    // filling each group from the left. This reproduces table 29 exactly.
    static const int kGroupOrder[8] = {0, 4, 2, 6, 1, 5, 3, 7};
    std::array<std::array<uint8_t, 32>, 25> pv{};
    for (int n = 1; n <= 24; n++) {
        int ones[8];
        for (int g = 0; g < 8; g++) ones[g] = 1;
        for (int m = 0; m < n; m++) ones[kGroupOrder[m % 8]]++;
        for (int g = 0; g < 8; g++) {
            for (int b = 0; b < 4; b++) pv[n][g * 4 + b] = b < ones[g] ? 1 : 0;
        }
    }
    return pv;
}

} // namespace

const std::vector<cf32>& phaseReference()
{
    static const std::vector<cf32> ref = buildPhaseReference();
    return ref;
}

const std::array<int, kCarriers>& frequencyMap()
{
    static const std::array<int, kCarriers> map = buildFrequencyMap();
    return map;
}

const std::array<uint8_t, 32>& puncturingVector(int n)
{
    static const auto vectors = buildPuncturingVectors();
    return vectors[n < 1 ? 1 : (n > 24 ? 24 : n)];
}

const std::array<uint8_t, 24>& puncturingTail()
{
    static const std::array<uint8_t, 24> tail = {1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0,
                                                 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0};
    return tail;
}

void energyDispersal(uint8_t* bits, int count)
{
    uint16_t reg = 0x1FF;
    for (int i = 0; i < count; i++) {
        const uint8_t out = static_cast<uint8_t>(((reg >> 8) ^ (reg >> 4)) & 1);
        reg = static_cast<uint16_t>(((reg << 1) | out) & 0x1FF);
        bits[i] ^= out;
    }
}

uint16_t crc16Ccitt(const uint8_t* data, int len)
{
    uint16_t crc = 0xFFFF;
    for (int i = 0; i < len; i++) {
        crc ^= static_cast<uint16_t>(data[i] << 8);
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021) : static_cast<uint16_t>(crc << 1);
        }
    }
    return crc;
}

uint16_t fireCode(const uint8_t* data, int len)
{
    uint16_t crc = 0;
    for (int i = 0; i < len; i++) {
        crc ^= static_cast<uint16_t>(data[i] << 8);
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x782F) : static_cast<uint16_t>(crc << 1);
        }
    }
    return crc;
}

bool eepProfile(bool optionB, int level, int sizeCu, EepProfile& out)
{
    if (level < 0 || level > 3 || sizeCu <= 0) return false;
    if (!optionB) {
        static const int kCuPerN[4] = {12, 8, 6, 4};
        if (sizeCu % kCuPerN[level]) return false;
        const int n = sizeCu / kCuPerN[level];
        out.bitrateKbps = 8 * n;
        switch (level) {
            case 0: out = {6 * n - 3, 3, 24, 23, 8 * n}; break;
            case 1:
                if (n == 1) out = {5, 1, 13, 12, 8};
                else out = {2 * n - 3, 4 * n + 3, 14, 13, 8 * n};
                break;
            case 2: out = {6 * n - 3, 3, 8, 7, 8 * n}; break;
            default: out = {4 * n - 3, 2 * n + 3, 3, 2, 8 * n}; break;
        }
    } else {
        static const int kCuPerN[4] = {27, 21, 18, 15};
        static const int kPi1[4] = {10, 6, 4, 2};
        if (sizeCu % kCuPerN[level]) return false;
        const int n = sizeCu / kCuPerN[level];
        out = {24 * n - 3, 3, kPi1[level], kPi1[level] - 1, 32 * n};
    }
    return out.l1 >= 0;
}

} // namespace hrdab
