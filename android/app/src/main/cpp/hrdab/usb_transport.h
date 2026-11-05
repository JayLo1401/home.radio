#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

namespace hrdab {

// How Rtl2832Source reaches the stick: control transfers for the registers
// and the tuner's I2C bus, and a bulk-in stream for the samples. Android
// hands out a usbfs fd (UsbfsTransport); the desktop builds go through
// libusb (desktop/libusb_transport).
class UsbTransport {
public:
    virtual ~UsbTransport() = default;

    // Vendor control transfer with bRequest 0, ~300 ms timeout.
    virtual bool control(uint8_t requestType, uint16_t value, uint16_t index, uint8_t* data, uint16_t len) = 0;

    // Keeps a set of bulk transfers in flight on `endpoint` and hands every
    // completed one to onData, until `running` turns false (then returns
    // once all transfers are back) or the device is gone (onError with a
    // message for the user, then returns). Blocks the calling thread.
    virtual void streamBulk(uint8_t endpoint, const std::atomic<bool>& running,
                            const std::function<void(const uint8_t*, size_t)>& onData,
                            const std::function<void(const std::string&)>& onError) = 0;
};

} // namespace hrdab
