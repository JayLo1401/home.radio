#pragma once

#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "r82xx.h"
#include "sample_source.h"

namespace hrdab {

// RTL2832U USB demodulator in SDR mode with an R820T/R828D tuner, driven
// directly through Linux usbfs ioctls on the file descriptor Android's
// UsbManager hands out. The caller must already have claimed interface 0.
class Rtl2832Source : public SampleSource, private I2cBus {
public:
    explicit Rtl2832Source(int fd);
    ~Rtl2832Source() override;

    bool open();
    const char* tunerName() const;

    bool start(ByteRing& ring) override;
    void stop() override;
    bool setFrequency(uint32_t hz) override;
    int gainCount() const override { return R82xx::kGainSteps; }
    bool setGainIndex(int index) override;
    int gainTenthsDb(int index) const override { return R82xx::gainTenthsDb(index); }

private:
    enum Block { kDemod = 0, kUsb = 1, kSys = 2, kTuner = 3, kRom = 4, kIr = 5, kI2c = 6 };

    bool control(uint8_t requestType, uint16_t value, uint16_t index, uint8_t* data, uint16_t len);
    bool writeReg(int block, uint16_t addr, uint16_t value, int len);
    bool demodWrite(int page, uint16_t addr, uint16_t value, int len);
    bool readDemodDummy();
    bool i2cRepeater(bool on);
    bool initBaseband();
    bool setSampleRate(uint32_t rate);
    bool setIfFrequency(uint32_t hz);
    uint8_t probe(uint8_t addr);

    bool i2cWrite(uint8_t addr, const uint8_t* data, int len) override;
    bool i2cRead(uint8_t addr, uint8_t* data, int len) override;

    void streamLoop();

    int fd_;
    std::mutex ctrlMutex_; // tuner/register access vs. AGC from another thread
    std::unique_ptr<R82xx> tuner_;
    bool r828d_ = false;

    std::thread thread_;
    std::atomic<bool> streaming_{false};
    ByteRing* ring_ = nullptr;
};

} // namespace hrdab
