#pragma once

#include <cstdint>
#include <functional>
#include <string>

#include "byte_ring.h"

namespace hrdab {

// A tuner delivering 8-bit unsigned I/Q into a ByteRing, at 2.048 MS/s
// unless setSampleRate() chose another rate (narrowband mode only).
class SampleSource {
public:
    static constexpr uint32_t kDefaultRate = 2048000;

    virtual ~SampleSource() = default;

    virtual bool start(ByteRing& ring) = 0;
    virtual void stop() = 0;
    virtual bool setFrequency(uint32_t hz) = 0;
    // Gain steps, 0 = lowest. Index -> tenths of dB via gainTenthsDb().
    virtual int gainCount() const = 0;
    virtual bool setGainIndex(int index) = 0;
    virtual int gainTenthsDb(int index) const = 0;

    // Output sample rate. Only called while the source is stopped; a
    // hardware source overrides it to program the device and then calls
    // this base version to record the new rate.
    virtual bool setSampleRate(uint32_t hz)
    {
        rate_ = hz;
        return true;
    }
    uint32_t sampleRate() const { return rate_; }

    // Connection state changes worth showing to the user (TCP only).
    std::function<void(bool isError, const std::string& message)> onStatus;

private:
    uint32_t rate_ = kDefaultRate;
};

} // namespace hrdab
