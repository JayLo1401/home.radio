#pragma once

#include <memory>
#include <string>

#include "usb_transport.h"

struct libusb_context;
struct libusb_device_handle;

namespace hrdab {

// UsbTransport over libusb-1.0 for the desktop builds. Windows needs the
// stick bound to WinUSB (Zadig) instead of the DVB-T driver; on Linux the
// kernel's dvb_usb_rtl28xxu driver is detached automatically, provided the
// user may open the device (udev rule, e.g. the rtl-sdr package's).
class LibusbTransport : public UsbTransport {
public:
    ~LibusbTransport() override;

    // Opens and claims the first RTL2832U stick (same VID/PIDs as Android's
    // DabRtlSdrPlugin). On failure `error` is a German message for the UI.
    static std::unique_ptr<LibusbTransport> openFirst(std::string& error);

    // [{"deviceName","vendorId","productId","productName","manufacturerName","hasPermission"}]
    // for RtlSdrUsbService.listDevices.
    static std::string listDevicesJson();

    bool control(uint8_t requestType, uint16_t value, uint16_t index, uint8_t* data, uint16_t len) override;
    void streamBulk(uint8_t endpoint, const std::atomic<bool>& running,
                    const std::function<void(const uint8_t*, size_t)>& onData,
                    const std::function<void(const std::string&)>& onError) override;

private:
    LibusbTransport(libusb_context* ctx, libusb_device_handle* handle) : ctx_(ctx), handle_(handle) {}

    libusb_context* ctx_;
    libusb_device_handle* handle_;
};

} // namespace hrdab
