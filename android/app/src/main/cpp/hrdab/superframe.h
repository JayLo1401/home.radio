#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "reed_solomon.h"

namespace hrdab {

struct AudioParams {
    bool dac48k = false;   // dac_rate: 48 kHz vs 32 kHz output
    bool sbr = false;
    bool stereo = false;   // aac_channel_mode
    bool ps = false;
    int mpegSurround = 0;

    bool operator==(const AudioParams& o) const
    {
        return dac48k == o.dac48k && sbr == o.sbr && stereo == o.stereo && ps == o.ps &&
               mpegSurround == o.mpegSurround;
    }
    bool operator!=(const AudioParams& o) const { return !(*this == o); }

    int outputSampleRate() const { return dac48k ? 48000 : 32000; }
    int outputChannels() const { return (stereo || ps) ? 2 : 1; }
    // MPEG-4 AudioSpecificConfig for a raw AAC decoder (960-sample frames).
    std::vector<uint8_t> audioSpecificConfig() const;
    std::string describe(int bitrateKbps) const;
};

class SuperframeListener {
public:
    virtual ~SuperframeListener() = default;
    virtual void onAudioParams(const AudioParams& params) = 0;
    // One access unit without its CRC; ok == false when the CRC failed (the
    // payload is then unusable but keeps the audio timeline intact).
    virtual void onAccessUnit(const uint8_t* data, int len, bool ok) = 0;
    virtual void onSuperframeStats(bool rsUncorrectable, int rsCorrected) = 0;
};

// DAB+ audio super frame handling (ETSI TS 102 563): fire-code
// synchronisation over 5 logical frames, RS(120,110) correction and
// splitting into AAC access units.
class SuperframeDecoder {
public:
    explicit SuperframeDecoder(SuperframeListener& listener) : listener_(listener) {}

    void reset();
    // frame: one logical frame (CIF) of sub-channel data, bitrate*3 bytes.
    void processFrame(const std::vector<uint8_t>& frame);

    int auCrcErrors() const { return auErrors_; }

private:
    bool tryDecode(bool synced);

    SuperframeListener& listener_;
    ReedSolomon rs_;
    std::vector<uint8_t> buffer_; // up to 5 frames
    std::vector<uint8_t> work_;
    int frameLen_ = 0;
    int framesInBuffer_ = 0;
    bool synced_ = false;
    int syncFailures_ = 0;
    AudioParams params_;
    bool haveParams_ = false;
    int auErrors_ = 0;
};

} // namespace hrdab
