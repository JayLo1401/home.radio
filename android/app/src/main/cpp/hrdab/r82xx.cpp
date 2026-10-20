#include "r82xx.h"

#include <cstring>
#include <thread>

#include "common.h"

namespace hrdab {

namespace {

// Register 0x05..0x1F power-on configuration for digital TV reception.
const uint8_t kInitRegs[27] = {
    0x83, 0x32, 0x75,             // 05 - 07
    0xc0, 0x40, 0xd6, 0x6c,       // 08 - 0b
    0xf5, 0x63, 0x75, 0x68,       // 0c - 0f
    0x6c, 0x83, 0x80, 0x00,       // 10 - 13
    0x0f, 0x00, 0xc0, 0x30,       // 14 - 17
    0x48, 0xcc, 0x60, 0x00,       // 18 - 1b
    0x54, 0xae, 0x4a, 0xc0,       // 1c - 1f
};

// RF tracking filter / mux settings by LO frequency (MHz lower bound).
struct MuxRange {
    uint16_t mhz;
    uint8_t openDrain, rfMuxPoly, tfBand;
};
const MuxRange kMux[] = {
    {0, 0x08, 0x02, 0xdf},   {50, 0x08, 0x02, 0xbe},  {55, 0x08, 0x02, 0x8b},
    {60, 0x08, 0x02, 0x7b},  {65, 0x08, 0x02, 0x69},  {70, 0x08, 0x02, 0x58},
    {75, 0x00, 0x02, 0x44},  {90, 0x00, 0x02, 0x34},  {110, 0x00, 0x02, 0x24},
    {140, 0x00, 0x02, 0x14}, {180, 0x00, 0x02, 0x13}, {250, 0x00, 0x02, 0x11},
    {280, 0x00, 0x02, 0x00}, {310, 0x00, 0x41, 0x00}, {588, 0x00, 0x40, 0x00},
};

// Gain contribution (0.1 dB) of each LNA / mixer gain code step.
const int kLnaSteps[16] = {0, 9, 13, 40, 38, 13, 31, 22, 26, 31, 26, 14, 19, 5, 35, 13};
const int kMixerSteps[16] = {0, 5, 10, 10, 19, 9, 10, 25, 17, 10, 8, 16, 13, 6, 3, -8};

uint8_t reverseBits(uint8_t b)
{
    b = static_cast<uint8_t>((b & 0xF0) >> 4 | (b & 0x0F) << 4);
    b = static_cast<uint8_t>((b & 0xCC) >> 2 | (b & 0x33) << 2);
    b = static_cast<uint8_t>((b & 0xAA) >> 1 | (b & 0x55) << 1);
    return b;
}

void sleepMs(int ms)
{
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

} // namespace

R82xx::R82xx(I2cBus& bus, uint8_t addr, uint32_t xtalHz, bool r828d)
    : bus_(bus), addr_(addr), xtal_(xtalHz), r828d_(r828d)
{
}

int R82xx::gainTenthsDb(int index)
{
    int total = 0;
    for (int i = 1; i <= index && i < kGainSteps; i++) {
        // Odd steps raise the LNA, even steps the mixer.
        total += (i & 1) ? kLnaSteps[(i + 1) / 2] : kMixerSteps[i / 2];
    }
    return total;
}

bool R82xx::writeRegs(uint8_t reg, const uint8_t* val, int len)
{
    // The RTL2832U I2C bridge carries at most 8 bytes per message.
    while (len > 0) {
        const int n = len > 7 ? 7 : len;
        uint8_t buf[8];
        buf[0] = reg;
        std::memcpy(buf + 1, val, static_cast<size_t>(n));
        if (!bus_.i2cWrite(addr_, buf, n + 1)) return false;
        std::memcpy(shadow_ + reg, val, static_cast<size_t>(n));
        reg = static_cast<uint8_t>(reg + n);
        val += n;
        len -= n;
    }
    return true;
}

bool R82xx::writeMask(uint8_t reg, uint8_t val, uint8_t mask)
{
    const uint8_t v = static_cast<uint8_t>((shadow_[reg] & ~mask) | (val & mask));
    return writeReg(reg, v);
}

bool R82xx::readStatus(uint8_t* out, int len)
{
    // Reads always start at register 0 and come back bit-reversed.
    const uint8_t start = 0;
    if (!bus_.i2cWrite(addr_, &start, 1)) return false;
    if (!bus_.i2cRead(addr_, out, len)) return false;
    for (int i = 0; i < len; i++) out[i] = reverseBits(out[i]);
    return true;
}

bool R82xx::setMux(uint32_t loHz)
{
    const uint32_t mhz = loHz / 1000000;
    const MuxRange* r = &kMux[0];
    for (const auto& m : kMux) {
        if (mhz >= m.mhz) r = &m;
    }
    return writeMask(0x17, r->openDrain, 0x08) && writeMask(0x1a, r->rfMuxPoly, 0xc3) &&
           writeReg(0x1b, r->tfBand) && writeMask(0x10, 0x00, 0x0b) && writeMask(0x08, 0x00, 0x3f) &&
           writeMask(0x09, 0x00, 0x3f);
}

bool R82xx::setPll(uint32_t loHz)
{
    const uint64_t vcoMin = 1770000000ull;
    const uint64_t vcoMax = 2 * vcoMin;
    if (!writeMask(0x10, 0x00, 0x10)) return false;      // reference divider 1
    if (!writeMask(0x1a, 0x00, 0x0c)) return false;      // PLL autotune 128 kHz
    if (!writeMask(0x12, 0x80, 0xe0)) return false;      // VCO current

    uint32_t mixDiv = 2;
    int divNum = 0;
    for (; mixDiv <= 64; mixDiv <<= 1) {
        const uint64_t vco = static_cast<uint64_t>(loHz) * mixDiv;
        if (vco >= vcoMin && vco < vcoMax) {
            for (uint32_t d = mixDiv; d > 2; d >>= 1) divNum++;
            break;
        }
    }
    if (mixDiv > 64) return false;

    uint8_t status[5];
    if (!readStatus(status, 5)) return false;
    const int powerRef = r828d_ ? 1 : 2;
    const int fineTune = (status[4] & 0x30) >> 4;
    if (fineTune > powerRef) divNum--;
    else if (fineTune < powerRef) divNum++;
    if (!writeMask(0x10, static_cast<uint8_t>(divNum << 5), 0xe0)) return false;

    const uint64_t vco = static_cast<uint64_t>(loHz) * mixDiv;
    const uint64_t ref2 = 2ull * xtal_;
    const uint64_t nint = vco / ref2;
    const uint64_t frac = vco - nint * ref2;
    if (nint < 13 || nint > static_cast<uint64_t>(128 / powerRef - 1)) return false;
    const uint64_t ni = (nint - 13) / 4;
    const uint64_t si = nint - 4 * ni - 13;
    if (!writeReg(0x14, static_cast<uint8_t>(ni + (si << 6)))) return false;
    if (!writeMask(0x12, frac == 0 ? 0x08 : 0x00, 0x08)) return false;
    uint64_t sdm = (frac * 65536 + ref2 / 2) / ref2;
    if (sdm > 0xFFFF) sdm = 0xFFFF;
    if (!writeReg(0x16, static_cast<uint8_t>(sdm >> 8)) || !writeReg(0x15, static_cast<uint8_t>(sdm & 0xFF))) {
        return false;
    }

    pllLocked_ = false;
    for (int i = 0; i < 2; i++) {
        sleepMs(1);
        if (!readStatus(status, 3)) return false;
        if (status[2] & 0x40) {
            pllLocked_ = true;
            break;
        }
        if (i == 0 && !writeMask(0x12, 0x60, 0xe0)) return false; // more VCO current
    }
    if (!pllLocked_) {
        HR_LOGW("R82xx: PLL not locked at %u Hz", loHz);
        return false;
    }
    return writeMask(0x1a, 0x08, 0x08); // PLL autotune 8 kHz
}

bool R82xx::calibrateFilter()
{
    filterCal_ = 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!writeMask(0x0b, 0x6b, 0x60)) return false;  // filter cap
        if (!writeMask(0x0f, 0x04, 0x04)) return false;  // calibration clock on
        if (!writeMask(0x10, 0x00, 0x03)) return false;  // xtal cap 0 pF for the PLL
        if (!setPll(56000000)) return false;
        if (!writeMask(0x0b, 0x10, 0x10)) return false;  // start
        sleepMs(1);
        if (!writeMask(0x0b, 0x00, 0x10)) return false;  // stop
        if (!writeMask(0x0f, 0x00, 0x04)) return false;  // calibration clock off
        uint8_t status[5];
        if (!readStatus(status, 5)) return false;
        filterCal_ = status[4] & 0x0f;
        if (filterCal_ != 0 && filterCal_ != 0x0f) break;
    }
    if (filterCal_ == 0x0f) filterCal_ = 0;
    return true;
}

bool R82xx::init()
{
    std::memset(shadow_, 0, sizeof(shadow_));
    if (!writeRegs(0x05, kInitRegs, sizeof(kInitRegs))) return false;

    // 6 MHz digital TV standard with a 3.57 MHz IF.
    if (!writeMask(0x0c, 0x00, 0x0f) || !writeMask(0x13, 49, 0x3f) || !writeMask(0x1d, 0x00, 0x38)) return false;
    if (!calibrateFilter()) return false;
    if (!writeMask(0x0a, static_cast<uint8_t>(0x10 | filterCal_), 0x1f) || !writeMask(0x0b, 0x6b, 0xef) ||
        !writeMask(0x07, 0x00, 0x80) || !writeMask(0x06, 0x10, 0x30) || !writeMask(0x1e, 0x60, 0x60) ||
        !writeMask(0x05, 0x00, 0x80) || !writeMask(0x1f, 0x00, 0x80) || !writeMask(0x0f, 0x00, 0x80) ||
        !writeMask(0x19, 0x60, 0x60)) {
        return false;
    }

    // System frequency / AGC thresholds for DVB-T style reception.
    if (!writeMask(0x1d, 0xe5, 0xc7) || !writeMask(0x1c, 0x24, 0xf8) || !writeReg(0x0d, 0x53) ||
        !writeReg(0x0e, 0x75) || !writeMask(0x05, 0x00, 0x60) || !writeMask(0x06, 0x00, 0x08) ||
        !writeMask(0x11, 0x38, 0x38) || !writeMask(0x17, 0x30, 0x30) || !writeMask(0x0a, 0x40, 0x60)) {
        return false;
    }
    if (!writeMask(0x1d, 0x00, 0x38) || !writeMask(0x1c, 0x00, 0x04) || !writeMask(0x06, 0x00, 0x40) ||
        !writeMask(0x1a, 0x30, 0x30)) {
        return false;
    }
    sleepMs(250);
    if (!writeMask(0x1d, 0x18, 0x38) || !writeMask(0x1c, 0x24, 0x04) || !writeMask(0x1e, 14, 0x1f) ||
        !writeMask(0x1a, 0x20, 0x30)) {
        return false;
    }
    input_ = 0;
    return true;
}

bool R82xx::setFrequency(uint32_t rfHz)
{
    const uint32_t lo = rfHz + kIfHz;
    if (!setMux(lo) || !setPll(lo)) return false;
    if (r828d_) {
        // R828D sticks wire the VHF antenna to the "cable 1" input.
        const int input = rfHz > 345000000u ? 0x00 : 0x60;
        if (input != input_) {
            if (!writeMask(0x05, static_cast<uint8_t>(input), 0x60)) return false;
            input_ = input;
        }
    }
    return true;
}

bool R82xx::setGainIndex(int index)
{
    if (index < 0) index = 0;
    if (index >= kGainSteps) index = kGainSteps - 1;
    const int lna = (index + 1) / 2;
    const int mixer = index / 2;
    return writeMask(0x05, 0x10, 0x10) &&                       // LNA AGC off
           writeMask(0x07, 0x00, 0x10) &&                       // mixer AGC off
           writeMask(0x0c, 0x08, 0x9f) &&                       // fixed VGA gain
           writeMask(0x05, static_cast<uint8_t>(lna), 0x0f) &&
           writeMask(0x07, static_cast<uint8_t>(mixer), 0x0f);
}

} // namespace hrdab
