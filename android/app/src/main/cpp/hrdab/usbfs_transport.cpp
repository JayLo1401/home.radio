#include "usbfs_transport.h"

#include <cerrno>
#include <cstring>
#include <linux/usbdevice_fs.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <vector>

#include "common.h"

namespace hrdab {

namespace {

constexpr int kUrbCount = 32;
constexpr int kUrbBytes = 16384; // safe on every usbfs, even without scatter-gather

struct Urb {
    std::vector<uint8_t> buffer;
    usbdevfs_urb urb; // last: ends in a (here unused) flexible array
};

} // namespace

bool UsbfsTransport::control(uint8_t requestType, uint16_t value, uint16_t index, uint8_t* data, uint16_t len)
{
    usbdevfs_ctrltransfer ct{};
    ct.bRequestType = requestType;
    ct.bRequest = 0;
    ct.wValue = value;
    ct.wIndex = index;
    ct.wLength = len;
    ct.timeout = 300;
    ct.data = data;
    const int r = ioctl(fd_, USBDEVFS_CONTROL, &ct);
    if (r < 0) {
        HR_LOGW("RTL2832 control 0x%02x val=0x%04x idx=0x%04x failed: %s", requestType, value, index,
                strerror(errno));
        return false;
    }
    return true;
}

void UsbfsTransport::streamBulk(uint8_t endpoint, const std::atomic<bool>& running,
                                const std::function<void(const uint8_t*, size_t)>& onData,
                                const std::function<void(const std::string&)>& onError)
{
    std::vector<Urb> urbs(kUrbCount);
    int inFlight = 0;
    for (auto& u : urbs) {
        u.buffer.resize(kUrbBytes);
        std::memset(&u.urb, 0, sizeof(u.urb));
        u.urb.type = USBDEVFS_URB_TYPE_BULK;
        u.urb.endpoint = endpoint;
        u.urb.buffer = u.buffer.data();
        u.urb.buffer_length = kUrbBytes;
        u.urb.usercontext = &u;
        if (ioctl(fd_, USBDEVFS_SUBMITURB, &u.urb) == 0) inFlight++;
    }
    if (inFlight == 0) {
        HR_LOGE("RTL2832: could not submit any USB transfer: %s", strerror(errno));
        onError("USB-Übertragung konnte nicht gestartet werden");
        return;
    }

    bool discarded = false;
    while (inFlight > 0) {
        if (!running && !discarded) {
            for (auto& u : urbs) ioctl(fd_, USBDEVFS_DISCARDURB, &u.urb);
            discarded = true;
        }
        void* reaped = nullptr;
        // Non-blocking reap + short sleep while stopping, blocking otherwise:
        // a blocking reap only returns once some transfer completes.
        const int r = discarded ? ioctl(fd_, USBDEVFS_REAPURBNDELAY, &reaped)
                                : ioctl(fd_, USBDEVFS_REAPURB, &reaped);
        if (r < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) {
                usleep(1000);
                continue;
            }
            HR_LOGE("RTL2832: reap failed: %s", strerror(errno));
            if (errno == ENODEV) onError("USB-Stick getrennt");
            break; // device gone - nothing more will complete
        }
        auto* u = static_cast<Urb*>(static_cast<usbdevfs_urb*>(reaped)->usercontext);
        inFlight--;
        if (u->urb.status == 0 && u->urb.actual_length > 0 && running) {
            onData(u->buffer.data(), static_cast<size_t>(u->urb.actual_length));
        }
        if (running) {
            u->urb.actual_length = 0;
            u->urb.status = 0;
            if (ioctl(fd_, USBDEVFS_SUBMITURB, &u->urb) == 0) inFlight++;
            else HR_LOGW("RTL2832: resubmit failed: %s", strerror(errno));
        }
    }
}

} // namespace hrdab
