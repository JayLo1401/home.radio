#pragma once

#include <cstdint>

namespace hrdab {

class I2cBus {
public:
    virtual ~I2cBus() = default;
    virtual bool i2cWrite(uint8_t addr, const uint8_t* data, int len) = 0;
    virtual bool i2cRead(uint8_t addr, uint8_t* data, int len) = 0;
};

// Rafael Micro R820T / R820T2 / R828D silicon tuner, configured for a
// 3.57 MHz low IF (the RTL2832U's DDC then mixes it down to zero). With
// blogV4 (an R828D on an RTL-SDR Blog V4) it also drives that board's HF
// upconverter, input triplexer and notch filters (see hf.h).
class R82xx {
public:
    static constexpr uint8_t kAddrR820T = 0x34;
    static constexpr uint8_t kAddrR828D = 0x74;
    static constexpr uint32_t kIfHz = 3570000;

    R82xx(I2cBus& bus, uint8_t addr, uint32_t xtalHz, bool r828d, bool blogV4 = false);

    bool init();
    // rfHz at the antenna; a Blog V4 tunes HF 28.8 MHz higher on its own.
    bool setFrequency(uint32_t rfHz);
    bool setGainIndex(int index); // 0 .. kGainSteps-1, manual LNA/mixer gain

    static constexpr int kGainSteps = 31;
    static int gainTenthsDb(int index);

private:
    bool writeRegs(uint8_t reg, const uint8_t* val, int len);
    bool writeReg(uint8_t reg, uint8_t val) { return writeRegs(reg, &val, 1); }
    bool writeMask(uint8_t reg, uint8_t val, uint8_t mask);
    bool readStatus(uint8_t* out, int len);
    bool setPll(uint32_t loHz);
    bool setMux(uint32_t loHz, uint32_t rfHz);
    bool selectBlogV4Input(uint32_t rfHz);
    bool calibrateFilter();

    I2cBus& bus_;
    uint8_t addr_;
    uint32_t xtal_;
    bool r828d_;
    bool blogV4_;
    uint8_t shadow_[32] = {0};
    bool pllLocked_ = false;
    uint8_t filterCal_ = 0;
    int input_ = -1; // R828D input selection last written, -1 = unknown
};

} // namespace hrdab
