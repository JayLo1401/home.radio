#pragma once

#include "usb_transport.h"

namespace hrdab {

// UsbTransport straight on Linux usbfs ioctls, on the file descriptor
// Android's UsbManager hands out. The caller must already have claimed
// interface 0. Android only (the desktop builds use libusb).
class UsbfsTransport : public UsbTransport {
public:
    explicit UsbfsTransport(int fd) : fd_(fd) {}

    bool control(uint8_t requestType, uint16_t value, uint16_t index, uint8_t* data, uint16_t len) override;
    void streamBulk(uint8_t endpoint, const std::atomic<bool>& running,
                    const std::function<void(const uint8_t*, size_t)>& onData,
                    const std::function<void(const std::string&)>& onError) override;

private:
    int fd_;
};

} // namespace hrdab
