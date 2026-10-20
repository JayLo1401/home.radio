#include "rtl2832.h"

#include <cerrno>
#include <cstring>
#include <linux/usbdevice_fs.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <unistd.h>

#include "common.h"

namespace hrdab {

namespace {

constexpr uint32_t kRtlXtal = 28800000;
constexpr uint32_t kR828dXtal = 16000000;
constexpr uint8_t kEndpointIn = 0x81;
constexpr int kUrbCount = 32;
constexpr int kUrbBytes = 16384; // safe on every usbfs, even without scatter-gather

// USB block registers
constexpr uint16_t kUsbSysctl = 0x2000;
constexpr uint16_t kUsbEpaCtl = 0x2148;
constexpr uint16_t kUsbEpaMaxpkt = 0x2158;
// SYS block registers
constexpr uint16_t kDemodCtl = 0x3000;
constexpr uint16_t kDemodCtl1 = 0x300b;

// Default decimation low-pass of the RTL2832U DDC: 8 x int8 then 8 x int12.
const int kFirCoeffs[16] = {-54, -36, -41, -40, -32, -14, 14, 53, 101, 156, 215, 273, 327, 372, 404, 421};

struct Urb {
    std::vector<uint8_t> buffer;
    usbdevfs_urb urb; // last: ends in a (here unused) flexible array
};

} // namespace

Rtl2832Source::Rtl2832Source(int fd) : fd_(fd) {}

Rtl2832Source::~Rtl2832Source()
{
    stop();
}

bool Rtl2832Source::control(uint8_t requestType, uint16_t value, uint16_t index, uint8_t* data, uint16_t len)
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

bool Rtl2832Source::writeReg(int block, uint16_t addr, uint16_t value, int len)
{
    uint8_t data[2];
    if (len == 1) {
        data[0] = static_cast<uint8_t>(value & 0xff);
    } else {
        data[0] = static_cast<uint8_t>(value >> 8);
        data[1] = static_cast<uint8_t>(value & 0xff);
    }
    return control(0x40, addr, static_cast<uint16_t>((block << 8) | 0x10), data, static_cast<uint16_t>(len));
}

bool Rtl2832Source::readDemodDummy()
{
    uint8_t b = 0;
    return control(0xC0, static_cast<uint16_t>((0x01 << 8) | 0x20), 0x0a, &b, 1);
}

bool Rtl2832Source::demodWrite(int page, uint16_t addr, uint16_t value, int len)
{
    uint8_t data[2];
    if (len == 1) {
        data[0] = static_cast<uint8_t>(value & 0xff);
    } else {
        data[0] = static_cast<uint8_t>(value >> 8);
        data[1] = static_cast<uint8_t>(value & 0xff);
    }
    if (!control(0x40, static_cast<uint16_t>((addr << 8) | 0x20), static_cast<uint16_t>(0x10 | page), data,
                 static_cast<uint16_t>(len))) {
        return false;
    }
    return readDemodDummy();
}

bool Rtl2832Source::i2cWrite(uint8_t addr, const uint8_t* data, int len)
{
    uint8_t buf[16];
    std::memcpy(buf, data, static_cast<size_t>(len));
    return control(0x40, addr, static_cast<uint16_t>((kI2c << 8) | 0x10), buf, static_cast<uint16_t>(len));
}

bool Rtl2832Source::i2cRead(uint8_t addr, uint8_t* data, int len)
{
    return control(0xC0, addr, static_cast<uint16_t>(kI2c << 8), data, static_cast<uint16_t>(len));
}

bool Rtl2832Source::i2cRepeater(bool on)
{
    return demodWrite(1, 0x01, on ? 0x18 : 0x10, 1);
}

uint8_t Rtl2832Source::probe(uint8_t addr)
{
    const uint8_t reg = 0;
    uint8_t v = 0;
    if (!i2cWrite(addr, &reg, 1) || !i2cRead(addr, &v, 1)) return 0;
    return v;
}

bool Rtl2832Source::initBaseband()
{
    // USB endpoint + demodulator power-up.
    if (!writeReg(kUsb, kUsbSysctl, 0x09, 1) || !writeReg(kUsb, kUsbEpaMaxpkt, 0x0002, 2) ||
        !writeReg(kUsb, kUsbEpaCtl, 0x1002, 2) || !writeReg(kSys, kDemodCtl1, 0x22, 1) ||
        !writeReg(kSys, kDemodCtl, 0xe8, 1)) {
        return false;
    }
    // Soft reset, no spectrum inversion / adjacent channel rejection yet.
    if (!demodWrite(1, 0x01, 0x14, 1) || !demodWrite(1, 0x01, 0x10, 1) || !demodWrite(1, 0x15, 0x00, 1) ||
        !demodWrite(1, 0x16, 0x0000, 2)) {
        return false;
    }
    for (int i = 0; i < 6; i++) {
        if (!demodWrite(1, static_cast<uint16_t>(0x16 + i), 0x00, 1)) return false;
    }

    uint8_t fir[20];
    for (int i = 0; i < 8; i++) fir[i] = static_cast<uint8_t>(kFirCoeffs[i]);
    for (int i = 0; i < 4; i++) {
        const int a = kFirCoeffs[8 + 2 * i];
        const int b = kFirCoeffs[8 + 2 * i + 1];
        fir[8 + 3 * i] = static_cast<uint8_t>(a >> 4);
        fir[8 + 3 * i + 1] = static_cast<uint8_t>(((a << 4) & 0xf0) | ((b >> 8) & 0x0f));
        fir[8 + 3 * i + 2] = static_cast<uint8_t>(b & 0xff);
    }
    for (int i = 0; i < 20; i++) {
        if (!demodWrite(1, static_cast<uint16_t>(0x1c + i), fir[i], 1)) return false;
    }

    return demodWrite(0, 0x19, 0x05, 1) &&   // SDR mode, digital AGC off
           demodWrite(1, 0x93, 0xf0, 1) &&   // FSM state holding
           demodWrite(1, 0x94, 0x0f, 1) &&
           demodWrite(1, 0x11, 0x00, 1) &&   // DAGC off
           demodWrite(1, 0x04, 0x00, 1) &&   // RF/IF AGC loop off
           demodWrite(0, 0x61, 0x60, 1) &&   // PID filter off
           demodWrite(0, 0x06, 0x80, 1) &&   // default ADC I/Q datapath
           demodWrite(1, 0xb1, 0x1b, 1) &&   // zero-IF, DC cancel, IQ compensation
           demodWrite(0, 0x0d, 0x83, 1);     // no 4.096 MHz clock output
}

bool Rtl2832Source::setIfFrequency(uint32_t hz)
{
    const int64_t v = -(static_cast<int64_t>(hz) * (1ll << 22)) / kRtlXtal;
    return demodWrite(1, 0x19, static_cast<uint16_t>((v >> 16) & 0x3f), 1) &&
           demodWrite(1, 0x1a, static_cast<uint16_t>((v >> 8) & 0xff), 1) &&
           demodWrite(1, 0x1b, static_cast<uint16_t>(v & 0xff), 1);
}

bool Rtl2832Source::setSampleRate(uint32_t rate)
{
    const uint32_t ratio = static_cast<uint32_t>((static_cast<uint64_t>(kRtlXtal) << 22) / rate) & 0x0ffffffc;
    return demodWrite(1, 0x9f, static_cast<uint16_t>(ratio >> 16), 2) &&
           demodWrite(1, 0xa1, static_cast<uint16_t>(ratio & 0xffff), 2) &&
           demodWrite(1, 0x3f, 0x00, 1) && demodWrite(1, 0x3e, 0x00, 1) && // no sample clock correction
           demodWrite(1, 0x01, 0x14, 1) && demodWrite(1, 0x01, 0x10, 1);
}

bool Rtl2832Source::open()
{
    std::lock_guard<std::mutex> lock(ctrlMutex_);
    if (!writeReg(kUsb, kUsbSysctl, 0x09, 1)) {
        HR_LOGE("RTL2832: device does not answer");
        return false;
    }
    if (!initBaseband()) return false;

    if (!i2cRepeater(true)) return false;
    uint8_t addr = 0;
    if (probe(R82xx::kAddrR820T) == 0x69) {
        addr = R82xx::kAddrR820T;
        r828d_ = false;
    } else if (probe(R82xx::kAddrR828D) == 0x69) {
        addr = R82xx::kAddrR828D;
        r828d_ = true;
    } else {
        i2cRepeater(false);
        HR_LOGE("RTL2832: no supported tuner (R820T/R820T2/R828D) found");
        return false;
    }
    // Low-IF tuner: real ADC input, DDC at the IF, inverted spectrum.
    if (!demodWrite(1, 0xb1, 0x1a, 1) || !demodWrite(0, 0x08, 0x4d, 1) || !setIfFrequency(R82xx::kIfHz) ||
        !demodWrite(1, 0x15, 0x01, 1)) {
        i2cRepeater(false);
        return false;
    }
    tuner_ = std::make_unique<R82xx>(static_cast<I2cBus&>(*this), addr, r828d_ ? kR828dXtal : kRtlXtal, r828d_);
    const bool tunerOk = tuner_->init();
    i2cRepeater(false);
    if (!tunerOk) {
        HR_LOGE("RTL2832: tuner init failed");
        return false;
    }
    if (!setSampleRate(kSampleRate)) return false;
    HR_LOGI("RTL2832 ready, tuner %s", tunerName());
    return true;
}

const char* Rtl2832Source::tunerName() const
{
    return r828d_ ? "R828D" : "R820T";
}

bool Rtl2832Source::setFrequency(uint32_t hz)
{
    std::lock_guard<std::mutex> lock(ctrlMutex_);
    if (!tuner_ || !i2cRepeater(true)) return false;
    const bool ok = tuner_->setFrequency(hz);
    i2cRepeater(false);
    return ok;
}

bool Rtl2832Source::setGainIndex(int index)
{
    std::lock_guard<std::mutex> lock(ctrlMutex_);
    if (!tuner_ || !i2cRepeater(true)) return false;
    const bool ok = tuner_->setGainIndex(index);
    i2cRepeater(false);
    return ok;
}

bool Rtl2832Source::start(ByteRing& ring)
{
    if (streaming_) return true;
    {
        std::lock_guard<std::mutex> lock(ctrlMutex_);
        // Flush the endpoint FIFO.
        if (!writeReg(kUsb, kUsbEpaCtl, 0x1002, 2) || !writeReg(kUsb, kUsbEpaCtl, 0x0000, 2)) return false;
    }
    ring_ = &ring;
    streaming_ = true;
    thread_ = std::thread(&Rtl2832Source::streamLoop, this);
    return true;
}

void Rtl2832Source::stop()
{
    if (!thread_.joinable()) return;
    streaming_ = false;
    thread_.join();
}

void Rtl2832Source::streamLoop()
{
    setpriority(PRIO_PROCESS, 0, -19);

    std::vector<Urb> urbs(kUrbCount);
    int inFlight = 0;
    for (auto& u : urbs) {
        u.buffer.resize(kUrbBytes);
        std::memset(&u.urb, 0, sizeof(u.urb));
        u.urb.type = USBDEVFS_URB_TYPE_BULK;
        u.urb.endpoint = kEndpointIn;
        u.urb.buffer = u.buffer.data();
        u.urb.buffer_length = kUrbBytes;
        u.urb.usercontext = &u;
        if (ioctl(fd_, USBDEVFS_SUBMITURB, &u.urb) == 0) inFlight++;
    }
    if (inFlight == 0) {
        HR_LOGE("RTL2832: could not submit any USB transfer: %s", strerror(errno));
        if (onStatus) onStatus(true, "USB-Übertragung konnte nicht gestartet werden");
        return;
    }

    bool discarded = false;
    while (inFlight > 0) {
        if (!streaming_ && !discarded) {
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
            if (errno == ENODEV && onStatus) onStatus(true, "USB-Stick getrennt");
            break; // device gone - nothing more will complete
        }
        auto* u = static_cast<Urb*>(static_cast<usbdevfs_urb*>(reaped)->usercontext);
        inFlight--;
        if (u->urb.status == 0 && u->urb.actual_length > 0 && streaming_) {
            ring_->write(u->buffer.data(), static_cast<size_t>(u->urb.actual_length));
        }
        if (streaming_) {
            u->urb.actual_length = 0;
            u->urb.status = 0;
            if (ioctl(fd_, USBDEVFS_SUBMITURB, &u->urb) == 0) inFlight++;
            else HR_LOGW("RTL2832: resubmit failed: %s", strerror(errno));
        }
    }
}

} // namespace hrdab
