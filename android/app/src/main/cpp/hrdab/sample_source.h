#pragma once

#include <cstdint>
#include <functional>
#include <string>

#include "byte_ring.h"

namespace hrdab {

// A tuner delivering 8-bit unsigned I/Q at 2.048 MS/s into a ByteRing.
class SampleSource {
public:
    virtual ~SampleSource() = default;

    virtual bool start(ByteRing& ring) = 0;
    virtual void stop() = 0;
    virtual bool setFrequency(uint32_t hz) = 0;
    // Gain steps, 0 = lowest. Index -> tenths of dB via gainTenthsDb().
    virtual int gainCount() const = 0;
    virtual bool setGainIndex(int index) = 0;
    virtual int gainTenthsDb(int index) const = 0;

    // Connection state changes worth showing to the user (TCP only).
    std::function<void(bool isError, const std::string& message)> onStatus;
};

} // namespace hrdab
