// Mode S / ADS-B receiver on 1090 MHz: 2 MS/s I/Q in, verified Mode S
// frames out.
//
// Classic dump1090-style detection at 2 samples per microsecond: the 8 us
// preamble pattern, then 56 or 112 PPM bits (first half of the bit period
// stronger = 1). CRC-24: extended squitter (DF17/18) must check out (one
// flipped bit is repaired), DF11 may carry an interrogator id, and the
// replies with the address overlaid on the parity (DF0/4/5/16/20/21) are
// only taken for aircraft already heard - otherwise every noise burst
// would read as some "address".
#pragma once

#include <atomic>
#include <cstdint>
#include <unordered_map>
#include <vector>

#include "ofdm.h"  // IqReader

namespace hrdab {

class AdsbSink {
public:
    virtual ~AdsbSink() = default;
    // A verified frame (7 or 14 bytes), the aircraft address (from the frame
    // or the parity) and its level in dBFS.
    virtual void onAdsbFrame(const uint8_t* bytes, int length, uint32_t icao, float signalDbfs) = 0;
    // Input level per read (~33 ms), like the other modes' AGC reports.
    virtual void onAdsbLevel(float rms, float clipRatio) = 0;
};

class AdsbDemod {
public:
    static constexpr uint32_t kSampleRate = 2000000;
    static constexpr uint32_t kFrequencyHz = 1090000000;

    AdsbDemod(IqReader& reader, AdsbSink& sink);

    // Thread body; returns once `stop` is set.
    void run(const std::atomic<bool>& stop);

    // Mode S CRC-24 remainder over the whole frame (0 for a good DF17).
    static uint32_t crc(const uint8_t* msg, int bits);

    // Decodes one buffer of magnitudes (for tests); frames go to the sink.
    void detect(const uint16_t* mag, int n);
    static uint16_t magnitude(uint8_t i, uint8_t q);

private:
    bool accept(uint8_t* msg, int bits, uint32_t& icao);

    IqReader& reader_;
    AdsbSink& sink_;
    std::vector<uint16_t> magLut_;
    std::vector<uint32_t> syndrome112_;  // CRC of a single flipped bit
    std::unordered_map<uint32_t, long long> known_;  // address -> last heard (samples)
    long long sampleCount_ = 0;
};

} // namespace hrdab
