#include "rtl2832.h"

#include <cstring>

#include "common.h"
#include "hf.h"

namespace hrdab {

namespace {

constexpr uint32_t kRtlXtal = 28800000;
constexpr uint32_t kR828dXtal = 16000000;
constexpr uint8_t kEndpointIn = 0x81;

// USB block registers
constexpr uint16_t kUsbSysctl = 0x2000;
constexpr uint16_t kUsbEpaCtl = 0x2148;
constexpr uint16_t kUsbEpaMaxpkt = 0x2158;
// SYS block registers
constexpr uint16_t kDemodCtl = 0x3000;
constexpr uint16_t kDemodCtl1 = 0x300b;

// Default decimation low-pass of the RTL2832U DDC: 8 x int8 then 8 x int12.
const int kFirCoeffs[16] = {-54, -36, -41, -40, -32, -14, 14, 53, 101, 156, 215, 273, 327, 372, 404, 421};

} // namespace

Rtl2832Source::Rtl2832Source(std::unique_ptr<UsbTransport> usb) : usb_(std::move(usb)) {}

Rtl2832Source::~Rtl2832Source()
{
    stop();
}

bool Rtl2832Source::control(uint8_t requestType, uint16_t value, uint16_t index, uint8_t* data, uint16_t len)
{
    return usb_->control(requestType, value, index, data, len);
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

std::string Rtl2832Source::usbString(int descriptorOffset)
{
    uint8_t dev[18] = {0};
    if (usb_->getDescriptor(0x0100, 0, dev, sizeof(dev)) < static_cast<int>(sizeof(dev))) return {};
    const uint8_t index = dev[descriptorOffset];
    if (index == 0) return {};
    // First language of string descriptor 0, else US English.
    uint8_t langs[4] = {0};
    const uint16_t lang = usb_->getDescriptor(0x0300, 0, langs, sizeof(langs)) >= 4
                              ? static_cast<uint16_t>(langs[2] | (langs[3] << 8))
                              : 0x0409;
    uint8_t buf[255] = {0};
    const int n = usb_->getDescriptor(static_cast<uint16_t>(0x0300 | index), lang, buf, sizeof(buf));
    if (n < 2) return {};
    // UTF-16LE after the 2-byte header; anything outside ASCII as '?'.
    std::string out;
    const int len = buf[0] < n ? buf[0] : n;
    for (int i = 2; i + 1 < len; i += 2) {
        const unsigned c = buf[i] | (buf[i + 1] << 8);
        out += c >= 0x20 && c < 0x7f ? static_cast<char>(c) : '?';
    }
    return out;
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
    const uint32_t v = rtlIfWord(hz, kRtlXtal);
    return demodWrite(1, 0x19, static_cast<uint16_t>((v >> 16) & 0x3f), 1) &&
           demodWrite(1, 0x1a, static_cast<uint16_t>((v >> 8) & 0xff), 1) &&
           demodWrite(1, 0x1b, static_cast<uint16_t>(v & 0xff), 1);
}

// Direct sampling: the Q-ADC (where the V3-style boards have their HF input)
// takes the I path, real input at the IF set by setIfFrequency, no spectrum
// inversion; the RTL2832U's digital AGC makes up for the missing tuner gain.
// Off: back to the tuner's low IF. The tuner itself keeps running.
bool Rtl2832Source::setDirectSampling(bool on)
{
    if (on) {
        if (!demodWrite(1, 0xb1, 0x1a, 1) || !demodWrite(1, 0x15, 0x00, 1) || !demodWrite(0, 0x08, 0x4d, 1) ||
            !demodWrite(0, 0x06, 0x90, 1) || !demodWrite(0, 0x19, 0x25, 1)) {
            return false;
        }
    } else if (!demodWrite(0, 0x06, 0x80, 1) || !demodWrite(0, 0x19, 0x05, 1) || !demodWrite(1, 0x15, 0x01, 1) ||
               !setIfFrequency(R82xx::kIfHz)) {
        return false;
    }
    directSampling_ = on;
    HR_LOGI("RTL2832: direct sampling %s", on ? "on (Q branch)" : "off");
    return true;
}

bool Rtl2832Source::programSampleRate(uint32_t rate)
{
    // Resampler ratio xtal / rate in 6.22 fixed point (lowest two bits must
    // be zero). For 0.96, 1.44 and 2.048 MS/s it is exact (30, 20, 14.0625).
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
    const std::string manufacturer = usbString(14);
    const std::string product = usbString(15);
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
    // The Blog V4's R828D runs from the stick's 28.8 MHz reference, other
    // R828D sticks (DVB-T2) from their own 16 MHz crystal.
    blogV4_ = r828d_ && manufacturer == "RTLSDRBlog" && product == "Blog V4";
    tuner_ = std::make_unique<R82xx>(static_cast<I2cBus&>(*this), addr, r828d_ && !blogV4_ ? kR828dXtal : kRtlXtal,
                                     r828d_, blogV4_);
    const bool tunerOk = tuner_->init();
    i2cRepeater(false);
    if (!tunerOk) {
        HR_LOGE("RTL2832: tuner init failed");
        return false;
    }
    if (!programSampleRate(sampleRate())) return false;
    HR_LOGI("RTL2832 ready, tuner %s (\"%s\" / \"%s\")", tunerName(), manufacturer.c_str(), product.c_str());
    return true;
}

bool Rtl2832Source::setSampleRate(uint32_t hz)
{
    if (hz <= 900000 || hz > 3200000) return false;
    std::lock_guard<std::mutex> lock(ctrlMutex_);
    if (!programSampleRate(hz)) return false;
    HR_LOGI("RTL2832: sample rate %u S/s", hz);
    return SampleSource::setSampleRate(hz);
}

const char* Rtl2832Source::tunerName() const
{
    return blogV4_ ? "R828D (RTL-SDR Blog V4)" : (r828d_ ? "R828D" : "R820T");
}

bool Rtl2832Source::setFrequency(uint32_t hz)
{
    std::lock_guard<std::mutex> lock(ctrlMutex_);
    if (!tuner_) return false;
    const HfTuning t = planHf(hz, !r828d_, externalUpconverterHz().load());
    if (t.directSampling != directSampling_ && !setDirectSampling(t.directSampling)) return false;
    if (t.directSampling) return setIfFrequency(t.rfHz);
    if (!i2cRepeater(true)) return false;
    const bool ok = tuner_->setFrequency(t.rfHz);
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
    raiseThreadPriority(-19);
    usb_->streamBulk(
        kEndpointIn, streaming_, [this](const uint8_t* data, size_t len) { ring_->write(data, len); },
        [this](const std::string& message) {
            if (onStatus) onStatus(true, message);
        });
}

} // namespace hrdab
