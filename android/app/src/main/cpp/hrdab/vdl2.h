// VDL Mode 2 on several channels at once (the European ones lie within
// 250 kHz around 136.85 MHz): the data link most airliners use today instead
// of classic ACARS on 131 MHz. Written from the public standard (ICAO Doc
// 9776 / ETSI EN 301 841), no third-party code; the transmission details
// below were checked against bursts recorded off the air.
//
// Per channel: mixed down, CIC-decimated to 105 kS/s (10 samples per
// symbol), low-pass filtered. D8PSK at 10 500 symbols/s carries its data in
// the phase turn from one symbol to the next. A burst is found by
// correlating those turns (as unit phasors) with the 16-symbol training
// sequence, which also gives the symbol timing (to a fraction of a sample)
// and the frequency offset; then the symbols are detected coherently (a
// carrier loop follows phase and offset, ~2 dB better than comparing each
// symbol with the noisy one before it). The tuning error of the stick is
// learned from the bursts and corrected for all channels.
//
// A burst after the training sequence, all of it scrambled (LFSR
// x^15 + x^14 + 1 as used here: feedback bit 0 ^ bit 14, seed 0x6959, from
// the first header bit on), 3 bits per symbol, first bit first:
//   header: 3 reserved bits (0), 17 bits transmission length (data bits,
//           LSB first), 5 bits header FEC (corrects one wrong bit);
//   data:   the length's bits, padded to whole octets (octets LSB first),
//           in Reed-Solomon blocks of up to 249 octets, the blocks
//           interleaved octet by octet;
//   FEC:    RS(255,249) over GF(256) (x^8+x^7+x^2+x+1, roots alpha^120..125),
//           the block padded with zeros after its data; full blocks send all
//           6 check octets, the last one 0/2/4/6 by its length (the rest of
//           its 6 are left out - erasures for the decoder), interleaved too.
// The data are HDLC frames (flags, bit stuffing, FCS) - AVLC; those carrying
// ACARS (info field FF FF 01) go out as ACARS messages (SOH .. ETX/ETB +
// BCS, like AcarsDecoder's).
#pragma once

#include <atomic>
#include <cstdint>
#include <vector>

#include "acars_multi.h"  // AcarsSink
#include "ofdm.h"         // IqReader

namespace hrdab {

class Vdl2MultiDemod {
public:
    static constexpr uint32_t kSampleRate = 1050000;
    static constexpr int kDecimation = 10;   // -> 105 kS/s
    static constexpr int kSps = 10;          // samples per symbol there

    // What happened so far (for tests and diagnostics).
    struct Stats {
        long syncs = 0;        // training sequences found
        long headers = 0;      // ... with a plausible header
        long bursts = 0;       // ... received to their end
        long rsFailed = 0;     // ... with a block RS could not correct
        long rsCorrected = 0;  // octets RS corrected
        long frames = 0;       // HDLC frames with a good FCS
        long acars = 0;        // ... carrying ACARS
    };

    Vdl2MultiDemod(IqReader& reader, AcarsSink& sink);

    // Before run(): tuner frequency and the channels (within +-400 kHz).
    void configure(uint32_t centerHz, const std::vector<uint32_t>& channelsHz);

    // Thread body; returns once `stop` is set.
    void run(const std::atomic<bool>& stop);

    // Feeds raw 8-bit I/Q (for tests).
    void process(const uint8_t* iq, int samples);

    // Each channel's strongest level (dBFS) since the last call.
    std::vector<float> channelLevelsDb();

    Stats stats() const { return stats_; }
    // The stick's tuning error as measured on the bursts: how far (Hz) the
    // signals lie above where they should.
    float tuningErrorHz() const { return afcHz_; }

    // The frames (FCS checked, without it) in a burst's bits: descrambled,
    // from the header on, one bit per byte. Public for tests.
    // `soft`: per symbol (3 bits each) how sure its decision is, 0..255;
    // lets RS erase the least sure octets when there are too many errors.
    static std::vector<std::vector<uint8_t>> framesFromBits(const std::vector<uint8_t>& bits,
                                                            const std::vector<uint8_t>* soft = nullptr,
                                                            Stats* stats = nullptr);
    // Checks the header (first 25 bits) and corrects a single wrong length
    // bit; false if it's no header.
    static bool checkHeader(uint8_t* bits);
    // Total bits (header, data, FEC) of a burst whose header says
    // `dataBits`; 0 if implausible.
    static size_t burstBits(uint32_t dataBits);
    // An AVLC frame's ACARS message as SOH .. ETX/ETB + BCS; empty if none.
    static std::vector<uint8_t> acarsFromFrame(const std::vector<uint8_t>& frame);
    // Reed-Solomon (VDL2 code) over a whole 255-octet block in place: data
    // octets 0..248 (zeros after the data), check octets 249..254, of which
    // only the first `fecOctets` were received, `erased` (positions) are
    // known to be unreliable. Errors may only lie in the first `dataOctets`
    // and the received check octets. Returns the number of octets corrected,
    // -1 if not correctable. Public for tests.
    static int rsDecode(uint8_t* block, int dataOctets, int fecOctets, const int* erased = nullptr,
                        int erasedCount = 0);
    // The check octets for a block (as the transmitter computes them).
    static void rsEncode(const uint8_t* data249, uint8_t* fec6);

private:
    static constexpr int kRing = 256;  // > 16 symbols of samples
    static constexpr int kFirTaps = 51;

    struct Channel {
        uint32_t freqHz = 0;
        double offsetHz = 0;  // from the tuner frequency
        uint32_t phase = 0, inc = 0;
        // CIC order 3; wrapping arithmetic, the output fits in 32 bits.
        uint32_t i1 = 0, q1 = 0, i2 = 0, q2 = 0, i3 = 0, q3 = 0;
        uint32_t ci1 = 0, cq1 = 0, ci2 = 0, cq2 = 0, ci3 = 0, cq3 = 0;
        int count = 0;
        // FIR delay line, stored twice (no wrapping in the loop).
        float hi[2 * kFirTaps] = {}, hq[2 * kFirTaps] = {};
        int hpos = 0;
        // Last samples (filtered) and their phase turns over one symbol
        // (unit phasors; only kept up to date while something is on air).
        float zi[kRing] = {}, zq[kRing] = {};
        float di[kRing] = {}, dq[kRing] = {};
        int pos = 0;
        bool dLive = false;
        float powerFast = 0, noise = 0, burstPower = 0;
        int warm = 0;  // samples seen (noise floor settling)
        float peak = 0;
        // Burst
        enum class State { Search, Peak, Burst } state = State::Search;
        float bestMetric = 0, bestI = 0, bestQ = 0;
        float lastMetric = 0, bestBefore = 0, bestAfter = 0;  // its neighbours
        float frac = 0;  // symbol timing between two samples
        int bestAgo = 0, peakLeft = 0;
        int symbolIn = 0;  // samples to the next symbol
        float rot = 0;     // phase turn per symbol from the offset
        // Carrier loop: phase, its turn per symbol, last symbol's phase index.
        float theta = 0, freq = 0;
        int lastA = 0;
        int weak = 0;
        uint16_t lfsr = 0;
        size_t needBits = 0;  // from the header
        std::vector<uint8_t> bits;
        std::vector<uint8_t> soft;  // per symbol
        float lastMargin = 1;
    };

    void filtered(Channel& c, float i, float q);
    void phaseTurn(Channel& c, int at);
    void symbol(Channel& c, int at, float p);
    void endBurst(Channel& c, bool complete);
    uint32_t ncoIncrement(const Channel& c) const;

    IqReader& reader_;
    AcarsSink& sink_;
    std::vector<Channel> channels_;
    float fir_[kFirTaps] = {};
    std::vector<int16_t> cos_, sin_;
    std::vector<int16_t> x_, y_;  // input as signed values
    // Training sequence as phase turns (unit phasors), conjugated.
    float syncI_[16] = {}, syncQ_[16] = {};
    int syncPhase_[16] = {};  // the same as phase turn indices
    Stats stats_;
    float afcHz_ = 0;  // tuning correction, from the bursts received
};

} // namespace hrdab
