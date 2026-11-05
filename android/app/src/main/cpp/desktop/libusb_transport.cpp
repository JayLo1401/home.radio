#include "libusb_transport.h"

#include <libusb.h>

#include <cstdio>
#include <vector>

#include "common.h"
#include "json.h"

namespace hrdab {

namespace {

// Known RTL2832U dongle VID/PIDs (same list as DabRtlSdrPlugin.kt).
bool isRtlSdr(uint16_t vid, uint16_t pid)
{
    return vid == 0x0bda && (pid == 0x2832 || pid == 0x2838);
}

// 16 x 64 KiB = 16 ms each at 2.048 MS/s: short enough to keep the squelch
// snappy, plenty in flight for WinUSB.
constexpr int kTransferCount = 16;
constexpr int kTransferBytes = 65536;

std::string usbString(libusb_device_handle* h, uint8_t index)
{
    if (!h || index == 0) return std::string();
    unsigned char buf[256];
    const int n = libusb_get_string_descriptor_ascii(h, index, buf, sizeof(buf));
    return n > 0 ? std::string(reinterpret_cast<char*>(buf), static_cast<size_t>(n)) : std::string();
}

struct Stream {
    std::vector<libusb_transfer*> transfers;
    std::vector<std::vector<uint8_t>> buffers;
    const std::atomic<bool>* running = nullptr;
    const std::function<void(const uint8_t*, size_t)>* onData = nullptr;
    int inFlight = 0;
    bool deviceGone = false;
};

void LIBUSB_CALL onTransfer(libusb_transfer* t)
{
    auto* s = static_cast<Stream*>(t->user_data);
    if (t->status == LIBUSB_TRANSFER_COMPLETED && t->actual_length > 0 && *s->running) {
        (*s->onData)(t->buffer, static_cast<size_t>(t->actual_length));
    }
    if (t->status == LIBUSB_TRANSFER_NO_DEVICE) s->deviceGone = true;
    if (*s->running && !s->deviceGone && libusb_submit_transfer(t) == 0) return;
    s->inFlight--;
}

} // namespace

LibusbTransport::~LibusbTransport()
{
    if (handle_) {
        libusb_release_interface(handle_, 0);
        libusb_close(handle_);
    }
    if (ctx_) libusb_exit(ctx_);
}

std::unique_ptr<LibusbTransport> LibusbTransport::openFirst(std::string& error)
{
    libusb_context* ctx = nullptr;
    if (libusb_init(&ctx) != 0) {
        error = "USB-Zugriff (libusb) nicht verfügbar";
        return nullptr;
    }
    libusb_device** list = nullptr;
    const ssize_t n = libusb_get_device_list(ctx, &list);
    libusb_device_handle* handle = nullptr;
    int openError = 0;
    bool found = false;
    for (ssize_t i = 0; i < n && !handle; i++) {
        libusb_device_descriptor d{};
        if (libusb_get_device_descriptor(list[i], &d) != 0 || !isRtlSdr(d.idVendor, d.idProduct)) continue;
        found = true;
        openError = libusb_open(list[i], &handle);
        if (openError != 0) handle = nullptr;
    }
    if (list) libusb_free_device_list(list, 1);
    if (!handle) {
        libusb_exit(ctx);
        if (!found) {
            error = "Kein RTL-SDR-Stick gefunden";
        } else if (openError == LIBUSB_ERROR_ACCESS) {
#ifdef _WIN32
            error = "Kein Zugriff auf den RTL-SDR-Stick - mit Zadig den WinUSB-Treiber installieren";
#else
            error = "Kein Zugriff auf den RTL-SDR-Stick - udev-Regel fehlt (Paket rtl-sdr)";
#endif
        } else {
#ifdef _WIN32
            error = "RTL-SDR-Stick braucht den WinUSB-Treiber (mit Zadig installieren)";
#else
            error = std::string("RTL-SDR-Stick lässt sich nicht öffnen: ") + libusb_error_name(openError);
#endif
        }
        HR_LOGW("libusb: %s", error.c_str());
        return nullptr;
    }
    // Linux: hand the stick over from the DVB-T kernel driver and back.
    libusb_set_auto_detach_kernel_driver(handle, 1);
    const int r = libusb_claim_interface(handle, 0);
    if (r != 0) {
        error = r == LIBUSB_ERROR_BUSY ? "RTL-SDR-Stick wird von einem anderen Programm verwendet"
                                       : std::string("RTL-SDR-Stick: Schnittstelle belegt (") + libusb_error_name(r) + ")";
        HR_LOGW("libusb: %s", error.c_str());
        libusb_close(handle);
        libusb_exit(ctx);
        return nullptr;
    }
    return std::unique_ptr<LibusbTransport>(new LibusbTransport(ctx, handle));
}

std::string LibusbTransport::listDevicesJson()
{
    JsonWriter w;
    w.beginArray();
    libusb_context* ctx = nullptr;
    if (libusb_init(&ctx) == 0) {
        libusb_device** list = nullptr;
        const ssize_t n = libusb_get_device_list(ctx, &list);
        for (ssize_t i = 0; i < n; i++) {
            libusb_device_descriptor d{};
            if (libusb_get_device_descriptor(list[i], &d) != 0 || !isRtlSdr(d.idVendor, d.idProduct)) continue;
            libusb_device_handle* h = nullptr;
            const bool canOpen = libusb_open(list[i], &h) == 0;
            const std::string product = usbString(h, d.iProduct);
            const std::string manufacturer = usbString(h, d.iManufacturer);
            if (h) libusb_close(h);
            char name[64];
            std::snprintf(name, sizeof(name), "usb:%03u:%03u", libusb_get_bus_number(list[i]),
                          libusb_get_device_address(list[i]));
            w.beginObject()
                .str("deviceName", name)
                .num("vendorId", d.idVendor)
                .num("productId", d.idProduct)
                .strOrNull("productName", product.empty() ? nullptr : &product)
                .strOrNull("manufacturerName", manufacturer.empty() ? nullptr : &manufacturer)
                // "Permission" on the desktop = the stick can be opened
                // (WinUSB driver on Windows, udev rule on Linux).
                .boolean("hasPermission", canOpen)
                .endObject();
        }
        if (list) libusb_free_device_list(list, 1);
        libusb_exit(ctx);
    }
    w.endArray();
    return w.text();
}

bool LibusbTransport::control(uint8_t requestType, uint16_t value, uint16_t index, uint8_t* data, uint16_t len)
{
    const int r = libusb_control_transfer(handle_, requestType, 0, value, index, data, len, 300);
    if (r < 0) {
        HR_LOGW("RTL2832 control 0x%02x val=0x%04x idx=0x%04x failed: %s", requestType, value, index,
                libusb_error_name(r));
        return false;
    }
    return true;
}

void LibusbTransport::streamBulk(uint8_t endpoint, const std::atomic<bool>& running,
                                 const std::function<void(const uint8_t*, size_t)>& onData,
                                 const std::function<void(const std::string&)>& onError)
{
    Stream s;
    s.running = &running;
    s.onData = &onData;
    s.buffers.resize(kTransferCount);
    for (int i = 0; i < kTransferCount; i++) {
        libusb_transfer* t = libusb_alloc_transfer(0);
        if (!t) break;
        s.buffers[static_cast<size_t>(i)].resize(kTransferBytes);
        libusb_fill_bulk_transfer(t, handle_, endpoint, s.buffers[static_cast<size_t>(i)].data(), kTransferBytes,
                                  onTransfer, &s, 0);
        s.transfers.push_back(t);
        if (libusb_submit_transfer(t) == 0) s.inFlight++;
    }
    if (s.inFlight == 0) {
        HR_LOGE("RTL2832: could not submit any USB transfer");
        onError("USB-Übertragung konnte nicht gestartet werden");
    }

    bool cancelled = false;
    while (s.inFlight > 0) {
        if ((!running || s.deviceGone) && !cancelled) {
            for (auto* t : s.transfers) libusb_cancel_transfer(t);
            cancelled = true;
        }
        timeval tv{0, 100000};
        const int r = libusb_handle_events_timeout_completed(ctx_, &tv, nullptr);
        if (r != 0 && r != LIBUSB_ERROR_INTERRUPTED && r != LIBUSB_ERROR_TIMEOUT) {
            HR_LOGE("RTL2832: libusb event handling failed: %s", libusb_error_name(r));
            s.deviceGone = true;
            break; // transfers cannot complete any more; leak rather than free in-flight ones
        }
    }
    if (s.deviceGone) {
        HR_LOGE("RTL2832: device gone");
        onError("USB-Stick getrennt");
    }
    if (s.inFlight == 0) {
        for (auto* t : s.transfers) libusb_free_transfer(t);
    }
}

} // namespace hrdab
