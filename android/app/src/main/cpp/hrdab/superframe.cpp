#include "superframe.h"

#include <cstdio>
#include <cstring>

#include "dab_tables.h"

namespace hrdab {

namespace {

constexpr int kFramesPerSuperframe = 5;

class BitWriter {
public:
    void put(unsigned value, int bits)
    {
        for (int i = bits - 1; i >= 0; i--) {
            if (bitPos_ == 0) bytes_.push_back(0);
            if ((value >> i) & 1u) bytes_.back() |= static_cast<uint8_t>(0x80 >> bitPos_);
            bitPos_ = (bitPos_ + 1) & 7;
        }
    }
    std::vector<uint8_t> bytes() const { return bytes_; }

private:
    std::vector<uint8_t> bytes_;
    int bitPos_ = 0;
};

int sampleRateIndex(int hz)
{
    switch (hz) {
        case 48000: return 3;
        case 32000: return 5;
        case 24000: return 6;
        case 16000: return 8;
        default: return 3;
    }
}

} // namespace

std::vector<uint8_t> AudioParams::audioSpecificConfig() const
{
    // ISO 14496-3 AudioSpecificConfig. With SBR the explicit hierarchical
    // signalling is used (AOT 5 or 29 first, core AAC-LC after it), so the
    // decoder knows the output rate and PS/SBR presence up front.
    const int outRate = outputSampleRate();
    const int coreRate = sbr ? outRate / 2 : outRate;
    const int channelConfig = stereo ? 2 : 1;
    BitWriter w;
    if (sbr) {
        w.put(ps ? 29 : 5, 5);
        w.put(static_cast<unsigned>(sampleRateIndex(coreRate)), 4);
        w.put(static_cast<unsigned>(channelConfig), 4);
        w.put(static_cast<unsigned>(sampleRateIndex(outRate)), 4);
        w.put(2, 5); // AAC LC
    } else {
        w.put(2, 5);
        w.put(static_cast<unsigned>(sampleRateIndex(coreRate)), 4);
        w.put(static_cast<unsigned>(channelConfig), 4);
    }
    // GASpecificConfig: frameLengthFlag = 1 (960), dependsOnCoreCoder = 0,
    // extensionFlag = 0.
    w.put(1, 1);
    w.put(0, 1);
    w.put(0, 1);
    return w.bytes();
}

std::string AudioParams::describe(int bitrateKbps) const
{
    const char* codec = ps ? "HE-AAC v2" : (sbr ? "HE-AAC" : "AAC-LC");
    const char* mode = ps ? "Parametric Stereo" : (stereo ? "Stereo" : "Mono");
    char buf[96];
    std::snprintf(buf, sizeof(buf), "%s, %d kHz %s @ %d kbit/s", codec, outputSampleRate() / 1000, mode,
                  bitrateKbps);
    return buf;
}

void SuperframeDecoder::reset()
{
    buffer_.clear();
    framesInBuffer_ = 0;
    synced_ = false;
    syncFailures_ = 0;
    // After a reset (service change, retune) the listener may be a fresh
    // audio output, so the parameters must be announced again even if the
    // stream turns out unchanged - e.g. when the same station is re-selected.
    haveParams_ = false;
}

void SuperframeDecoder::processFrame(const std::vector<uint8_t>& frame)
{
    const int len = static_cast<int>(frame.size());
    if (len != frameLen_) {
        reset();
        frameLen_ = len;
    }
    if (frameLen_ <= 0 || frameLen_ % 24 != 0) return;
    buffer_.insert(buffer_.end(), frame.begin(), frame.end());
    framesInBuffer_++;
    if (framesInBuffer_ < kFramesPerSuperframe) return;

    if (tryDecode(synced_)) {
        synced_ = true;
        syncFailures_ = 0;
        buffer_.clear();
        framesInBuffer_ = 0;
        return;
    }
    if (synced_ && ++syncFailures_ < 3) {
        // Probably just a damaged super frame: keep the alignment and let the
        // AAC side know it lost this one's audio.
        if (haveParams_) {
            const int aus = params_.sbr ? (params_.dac48k ? 3 : 2) : (params_.dac48k ? 6 : 4);
            for (int i = 0; i < aus; i++) listener_.onAccessUnit(nullptr, 0, false);
            auErrors_ += aus;
        }
        buffer_.clear();
        framesInBuffer_ = 0;
        return;
    }
    // Not (or no longer) aligned: slide by one logical frame and retry.
    synced_ = false;
    buffer_.erase(buffer_.begin(), buffer_.begin() + frameLen_);
    framesInBuffer_--;
}

bool SuperframeDecoder::tryDecode(bool synced)
{
    const int s = frameLen_ / 24; // RS codewords per super frame
    const int total = 120 * s;
    if (static_cast<int>(buffer_.size()) < total) return false;

    // Cheap pre-check while searching: the fire code is usually already
    // intact before RS correction.
    const bool rawFireOk = fireCode(buffer_.data() + 2, 9) == ((buffer_[0] << 8) | buffer_[1]);

    work_.assign(buffer_.begin(), buffer_.begin() + total);
    bool uncorrectable = false;
    int corrected = 0;
    if (synced || rawFireOk) {
        uint8_t cw[ReedSolomon::kN];
        for (int j = 0; j < s; j++) {
            for (int k = 0; k < ReedSolomon::kN; k++) cw[k] = work_[static_cast<size_t>(j + k * s)];
            const int r = rs_.decode(cw);
            if (r < 0) {
                uncorrectable = true;
                continue;
            }
            if (r > 0) {
                corrected += r;
                for (int k = 0; k < ReedSolomon::kN; k++) work_[static_cast<size_t>(j + k * s)] = cw[k];
            }
        }
    } else {
        return false;
    }

    if (fireCode(work_.data() + 2, 9) != ((work_[0] << 8) | work_[1])) return false;

    AudioParams p;
    p.dac48k = work_[2] & 0x40;
    p.sbr = work_[2] & 0x20;
    p.stereo = work_[2] & 0x10;
    p.ps = work_[2] & 0x08;
    p.mpegSurround = work_[2] & 0x07;
    const int numAus = p.sbr ? (p.dac48k ? 3 : 2) : (p.dac48k ? 6 : 4);
    int starts[7];
    starts[0] = p.sbr ? (p.dac48k ? 6 : 5) : (p.dac48k ? 11 : 8);
    for (int i = 1; i < numAus; i++) {
        const int bit = (i - 1) * 12;
        const int byte = 3 + bit / 8;
        int v;
        if (bit % 8 == 0) v = (work_[byte] << 4) | (work_[byte + 1] >> 4);
        else v = ((work_[byte] & 0x0F) << 8) | work_[byte + 1];
        starts[i] = v;
    }
    starts[numAus] = 110 * s;
    for (int i = 0; i < numAus; i++) {
        if (starts[i + 1] <= starts[i] + 2) return false; // not a valid layout
    }

    listener_.onSuperframeStats(uncorrectable, corrected);
    if (!haveParams_ || p != params_) {
        params_ = p;
        haveParams_ = true;
        listener_.onAudioParams(p);
    }
    for (int i = 0; i < numAus; i++) {
        const uint8_t* au = work_.data() + starts[i];
        const int len = starts[i + 1] - starts[i];
        const bool ok = crc16Ok(au, len);
        if (!ok) auErrors_++;
        listener_.onAccessUnit(au, len - 2, ok);
    }
    return true;
}

} // namespace hrdab
