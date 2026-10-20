#include "tx_sim.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "dab_tables.h"
#include "reed_solomon.h"
#include "viterbi.h"

namespace hrdab::test {

namespace {

const int kInterleaveDelay[16] = {0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15};
const int kSubfieldLen[8] = {4, 6, 8, 12, 16, 24, 32, 48};

void appendCrc(std::vector<uint8_t>& v)
{
    const uint16_t crc = static_cast<uint16_t>(~crc16Ccitt(v.data(), static_cast<int>(v.size())));
    v.push_back(static_cast<uint8_t>(crc >> 8));
    v.push_back(static_cast<uint8_t>(crc & 0xff));
}

void bytesToBits(const uint8_t* bytes, int count, uint8_t* bits)
{
    for (int i = 0; i < count; i++) {
        for (int b = 0; b < 8; b++) bits[i * 8 + b] = (bytes[i] >> (7 - b)) & 1;
    }
}

// Convolutional encoding + puncturing of one block.
void encodeBlock(const uint8_t* info, int infoBits, const std::vector<std::pair<int, int>>& segments,
                 std::vector<uint8_t>& out)
{
    std::vector<uint8_t> mother(static_cast<size_t>(4 * (infoBits + 6)));
    Viterbi::encode(info, infoBits, mother.data());
    size_t pos = 0;
    for (const auto& seg : segments) { // (count of 128-bit blocks, PI index)
        const auto& pv = puncturingVector(seg.second);
        for (int i = 0; i < seg.first * 128; i++, pos++) {
            if (pv[static_cast<size_t>(i % 32)]) out.push_back(mother[pos]);
        }
    }
    const auto& tail = puncturingTail();
    for (int i = 0; i < 24; i++, pos++) {
        if (tail[static_cast<size_t>(i)]) out.push_back(mother[pos]);
    }
}

void putLabel(std::vector<uint8_t>& fig, const std::string& label)
{
    for (int i = 0; i < 16; i++) fig.push_back(i < static_cast<int>(label.size()) ? static_cast<uint8_t>(label[static_cast<size_t>(i)]) : ' ');
    fig.push_back(0xFF); // short label mask: first 8 characters
    fig.push_back(0x00);
}

} // namespace

TxSim::TxSim(const TxConfig& cfg) : cfg_(cfg), fft_(kFftLen), rng_(cfg.seed)
{
    interleaveHist_.assign(16, {});

    // Dynamic label: one data group per 16-character segment.
    const std::string& text = cfg_.dls;
    const int segments = static_cast<int>((text.size() + 15) / 16);
    for (int s = 0; s < segments; s++) {
        const std::string part = text.substr(static_cast<size_t>(s * 16), 16);
        std::vector<uint8_t> g;
        const bool first = s == 0;
        const bool last = s == segments - 1;
        g.push_back(static_cast<uint8_t>((first ? 0x40 : 0) | (last ? 0x20 : 0) | (part.size() - 1)));
        g.push_back(static_cast<uint8_t>(first ? 0x00 : (s << 4)));
        g.insert(g.end(), part.begin(), part.end());
        appendCrc(g);
        padQueue_.push_back({2, 3, g, 0});
    }

    if (!cfg_.slide.empty()) {
        const uint16_t tid = 0x1234;
        auto dataGroup = [&](int type, int segNum, bool last, const std::vector<uint8_t>& seg) {
            std::vector<uint8_t> g;
            g.push_back(static_cast<uint8_t>(0x40 | 0x20 | 0x10 | type)); // CRC, segment, user access
            g.push_back(0x00);
            g.push_back(static_cast<uint8_t>((last ? 0x80 : 0) | (segNum >> 8)));
            g.push_back(static_cast<uint8_t>(segNum & 0xff));
            g.push_back(0x12); // transport id present, length 2
            g.push_back(static_cast<uint8_t>(tid >> 8));
            g.push_back(static_cast<uint8_t>(tid & 0xff));
            g.push_back(static_cast<uint8_t>(seg.size() >> 8));
            g.push_back(static_cast<uint8_t>(seg.size() & 0xff));
            g.insert(g.end(), seg.begin(), seg.end());
            appendCrc(g);
            padQueue_.push_back({12, 13, g, 0});
        };
        // MOT header: core + ContentName "logo.jpg".
        const uint32_t bodySize = static_cast<uint32_t>(cfg_.slide.size());
        const uint32_t headerSize = 7 + 2 + 9;
        std::vector<uint8_t> h(7);
        h[0] = static_cast<uint8_t>(bodySize >> 20);
        h[1] = static_cast<uint8_t>(bodySize >> 12);
        h[2] = static_cast<uint8_t>(bodySize >> 4);
        h[3] = static_cast<uint8_t>(((bodySize & 0x0F) << 4) | (headerSize >> 9));
        h[4] = static_cast<uint8_t>(headerSize >> 1);
        h[5] = static_cast<uint8_t>(((headerSize & 1) << 7) | (2 << 1) | 0); // content type 2 (image)
        h[6] = 0x01;                                                         // subtype 1 (JPEG)
        const char* name = "logo.jpg";
        h.push_back(0xCC);
        h.push_back(0x09);
        h.push_back(0x00);
        h.insert(h.end(), name, name + 8);
        dataGroup(3, 0, true, h);
        const size_t segLen = 120;
        const int bodySegs = static_cast<int>((cfg_.slide.size() + segLen - 1) / segLen);
        for (int s = 0; s < bodySegs; s++) {
            const size_t from = static_cast<size_t>(s) * segLen;
            std::vector<uint8_t> seg(cfg_.slide.begin() + static_cast<long>(from),
                                     cfg_.slide.begin() + static_cast<long>(std::min(cfg_.slide.size(), from + segLen)));
            dataGroup(4, s, s == bodySegs - 1, seg);
        }
    }
}

int TxSim::auPerSuperframe() const
{
    return cfg_.sbr ? (cfg_.dac48k ? 3 : 2) : (cfg_.dac48k ? 6 : 4);
}

std::vector<uint8_t> TxSim::buildFib(int fibIndex)
{
    std::vector<uint8_t> fib;
    const int cif = cifCount_ + fibIndex / 3;
    switch (fibIndex % 4) {
        case 0: {
            // FIG 0/0
            fib.push_back(0x05);
            fib.push_back(0x00);
            fib.push_back(static_cast<uint8_t>(cfg_.eid >> 8));
            fib.push_back(static_cast<uint8_t>(cfg_.eid & 0xff));
            const int c = cif % 5000;
            fib.push_back(static_cast<uint8_t>((c / 250) & 0x1F));
            fib.push_back(static_cast<uint8_t>(c % 250));
            // FIG 0/1, long form EEP-A
            const int sizeCu = cfg_.bitrateKbps / 8 * (std::array<int, 4>{12, 8, 6, 4}[static_cast<size_t>(cfg_.level)]);
            fib.push_back(0x05);
            fib.push_back(0x01);
            fib.push_back(static_cast<uint8_t>((cfg_.subchId << 2) | (cfg_.startCu >> 8)));
            fib.push_back(static_cast<uint8_t>(cfg_.startCu & 0xff));
            fib.push_back(static_cast<uint8_t>(0x80 | (cfg_.level << 2) | (sizeCu >> 8)));
            fib.push_back(static_cast<uint8_t>(sizeCu & 0xff));
            // FIG 0/2, two programme services
            fib.push_back(0x0B);
            fib.push_back(0x02);
            for (int s = 0; s < 2; s++) {
                const uint16_t sid = s == 0 ? cfg_.sid : cfg_.sid2;
                fib.push_back(static_cast<uint8_t>(sid >> 8));
                fib.push_back(static_cast<uint8_t>(sid & 0xff));
                fib.push_back(0x01);
                fib.push_back(63);
                fib.push_back(static_cast<uint8_t>(((s == 0 ? cfg_.subchId : 40) << 2) | 0x02));
            }
            break;
        }
        case 1:
            fib.push_back(0x35); // FIG 1, length 21
            fib.push_back(0x00);
            fib.push_back(static_cast<uint8_t>(cfg_.eid >> 8));
            fib.push_back(static_cast<uint8_t>(cfg_.eid & 0xff));
            putLabel(fib, cfg_.ensembleLabel);
            break;
        default: {
            const bool second = fibIndex % 4 == 3;
            const uint16_t sid = second ? cfg_.sid2 : cfg_.sid;
            fib.push_back(0x35);
            fib.push_back(0x01);
            fib.push_back(static_cast<uint8_t>(sid >> 8));
            fib.push_back(static_cast<uint8_t>(sid & 0xff));
            putLabel(fib, second ? cfg_.serviceLabel2 : cfg_.serviceLabel);
            break;
        }
    }
    if (fib.size() < 30) fib.push_back(0xFF);
    while (fib.size() < 30) fib.push_back(0x00);
    appendCrc(fib);
    return fib;
}

void TxSim::encodeFic(std::vector<uint8_t>& frameBits)
{
    for (int block = 0; block < 4; block++) {
        std::vector<uint8_t> fibs;
        for (int f = 0; f < 3; f++) {
            const auto fib = buildFib(block * 3 + f);
            fibs.insert(fibs.end(), fib.begin(), fib.end());
        }
        std::vector<uint8_t> bits(768);
        bytesToBits(fibs.data(), 96, bits.data());
        energyDispersal(bits.data(), 768);
        std::vector<uint8_t> coded;
        encodeBlock(bits.data(), 768, {{21, 16}, {3, 15}}, coded);
        frameBits.insert(frameBits.end(), coded.begin(), coded.end());
    }
}

std::vector<uint8_t> TxSim::makePad(int count)
{
    // Returns `count` PAD bytes: X-PAD (byte-reversed) + 2 F-PAD bytes.
    const int xlen = count - 2;
    std::vector<uint8_t> x; // natural order
    bool ci = false;
    if (xlen >= 6 && !padQueue_.empty()) {
        PadStream& st = padQueue_.front();
        const size_t remaining = st.bytes.size() - st.pos;
        padRound_++;
        if (st.pos > 0 && padRound_ % 3 == 0 && remaining >= static_cast<size_t>(xlen)) {
            // Continuation without contents indicator: X-PAD is pure data.
            x.assign(st.bytes.begin() + static_cast<long>(st.pos), st.bytes.begin() + static_cast<long>(st.pos) + xlen);
            st.pos += static_cast<size_t>(xlen);
        } else {
            ci = true;
            const bool start = st.pos == 0;
            const bool dgli = start && st.startApp == 12;
            const int ciBytes = (dgli ? 2 : 1) + 1; // + end marker
            const int room = xlen - ciBytes - (dgli ? 4 : 0);
            int lenIdx = -1;
            for (int i = 7; i >= 0; i--) {
                if (kSubfieldLen[i] <= room) {
                    lenIdx = i;
                    break;
                }
            }
            if (lenIdx >= 0) {
                if (dgli) x.push_back(0x01); // length index 0 (4 bytes), app 1
                x.push_back(static_cast<uint8_t>((lenIdx << 5) | (start ? st.startApp : st.contApp)));
                x.push_back(0x00); // end marker
                if (dgli) {
                    std::vector<uint8_t> d = {static_cast<uint8_t>(st.bytes.size() >> 8),
                                              static_cast<uint8_t>(st.bytes.size() & 0xff)};
                    appendCrc(d);
                    x.insert(x.end(), d.begin(), d.end());
                }
                const size_t take = std::min(remaining, static_cast<size_t>(kSubfieldLen[lenIdx]));
                x.insert(x.end(), st.bytes.begin() + static_cast<long>(st.pos),
                         st.bytes.begin() + static_cast<long>(st.pos + take));
                for (size_t i = take; i < static_cast<size_t>(kSubfieldLen[lenIdx]); i++) x.push_back(0);
                st.pos += take;
            } else {
                ci = false;
            }
        }
        if (st.pos >= st.bytes.size()) {
            PadStream done = st;
            done.pos = 0;
            padQueue_.erase(padQueue_.begin());
            padQueue_.push_back(done);
        }
    }
    const bool haveXpad = !x.empty();
    x.resize(static_cast<size_t>(xlen), 0);
    std::vector<uint8_t> pad(x.rbegin(), x.rend());
    pad.push_back(haveXpad ? 0x20 : 0x00);   // F-PAD type 0, X-PAD variable size
    pad.push_back(ci ? 0x02 : 0x00);         // CI flag
    return pad;
}

void TxSim::buildSuperframe()
{
    const int s = cfg_.bitrateKbps / 8;
    const int numAus = auPerSuperframe();
    const int au0 = cfg_.sbr ? (cfg_.dac48k ? 6 : 5) : (cfg_.dac48k ? 11 : 8);
    const int dataLen = 110 * s;
    const int capacity = dataLen - au0;

    std::vector<std::vector<uint8_t>> frames;
    if (auProvider_) {
        frames = auProvider_(numAus, capacity - numAus * (2 + 40));
    } else {
        std::uniform_int_distribution<int> byte(0, 255);
        for (int i = 0; i < numAus; i++) {
            std::vector<uint8_t> f(static_cast<size_t>(capacity / numAus - 2 - 60));
            for (auto& b : f) b = static_cast<uint8_t>(byte(rng_));
            frames.push_back(f);
        }
    }
    int used = 0;
    for (const auto& f : frames) used += static_cast<int>(f.size()) + 2;
    int extra = capacity - used; // goes into the PAD data stream elements

    std::vector<uint8_t> sf(static_cast<size_t>(120 * s), 0);
    sf[2] = static_cast<uint8_t>((cfg_.dac48k ? 0x40 : 0) | (cfg_.sbr ? 0x20 : 0) | (cfg_.stereo ? 0x10 : 0) |
                                 (cfg_.ps ? 0x08 : 0));
    int pos = au0;
    std::vector<int> starts;
    for (int i = 0; i < numAus; i++) {
        starts.push_back(pos);
        int dse = extra / (numAus - i);
        extra -= dse;
        std::vector<uint8_t> au;
        // data_stream_element: id 4, tag 0, no alignment, count (+ escape)
        const int padCount = dse >= 2 + 255 + 1 ? dse - 3 : dse - 2;
        au.push_back(0x80);
        if (padCount >= 255) {
            au.push_back(255);
            au.push_back(static_cast<uint8_t>(padCount - 255));
        } else {
            au.push_back(static_cast<uint8_t>(padCount));
        }
        const auto pad = makePad(padCount);
        au.insert(au.end(), pad.begin(), pad.end());
        au.insert(au.end(), frames[static_cast<size_t>(i)].begin(), frames[static_cast<size_t>(i)].end());
        sentAus_.push_back(au);
        appendCrc(au);
        std::memcpy(&sf[static_cast<size_t>(pos)], au.data(), au.size());
        pos += static_cast<int>(au.size());
    }
    for (int i = 1; i < numAus; i++) {
        const int bit = (i - 1) * 12;
        const int byte = 3 + bit / 8;
        if (bit % 8 == 0) {
            sf[static_cast<size_t>(byte)] = static_cast<uint8_t>(starts[static_cast<size_t>(i)] >> 4);
            sf[static_cast<size_t>(byte + 1)] |= static_cast<uint8_t>((starts[static_cast<size_t>(i)] & 0x0F) << 4);
        } else {
            sf[static_cast<size_t>(byte)] |= static_cast<uint8_t>(starts[static_cast<size_t>(i)] >> 8);
            sf[static_cast<size_t>(byte + 1)] = static_cast<uint8_t>(starts[static_cast<size_t>(i)] & 0xff);
        }
    }
    const uint16_t fc = fireCode(sf.data() + 2, 9);
    sf[0] = static_cast<uint8_t>(fc >> 8);
    sf[1] = static_cast<uint8_t>(fc & 0xff);

    ReedSolomon rs;
    uint8_t cw[ReedSolomon::kN];
    for (int j = 0; j < s; j++) {
        for (int k = 0; k < ReedSolomon::kK; k++) cw[k] = sf[static_cast<size_t>(j + k * s)];
        rs.encode(cw);
        for (int k = ReedSolomon::kK; k < ReedSolomon::kN; k++) sf[static_cast<size_t>(j + k * s)] = cw[k];
    }
    const int frameLen = 24 * s;
    for (int f = 0; f < 5; f++) {
        logicalFrames_.emplace_back(sf.begin() + f * frameLen, sf.begin() + (f + 1) * frameLen);
    }
}

std::vector<uint8_t> TxSim::nextLogicalFrame()
{
    if (logicalFrames_.empty()) buildSuperframe();
    auto f = logicalFrames_.front();
    logicalFrames_.erase(logicalFrames_.begin());
    return f;
}

void TxSim::encodeMscCif(std::vector<uint8_t>& cifBits)
{
    const int n = cfg_.bitrateKbps / 8;
    EepProfile prof;
    const int sizeCu = n * std::array<int, 4>{12, 8, 6, 4}[static_cast<size_t>(cfg_.level)];
    eepProfile(false, cfg_.level, sizeCu, prof);

    const auto lf = nextLogicalFrame();
    std::vector<uint8_t> bits(lf.size() * 8);
    bytesToBits(lf.data(), static_cast<int>(lf.size()), bits.data());
    energyDispersal(bits.data(), static_cast<int>(bits.size()));
    std::vector<uint8_t> coded;
    encodeBlock(bits.data(), static_cast<int>(bits.size()), {{prof.l1, prof.pi1}, {prof.l2, prof.pi2}}, coded);

    // history: [0] = this CIF's logical frame, [k] = k frames ago
    interleaveHist_.insert(interleaveHist_.begin(), coded);
    interleaveHist_.resize(16);

    std::uniform_int_distribution<int> bit(0, 1);
    cifBits.resize(kCifBits);
    for (auto& b : cifBits) b = static_cast<uint8_t>(bit(rng_));
    const int len = sizeCu * kCuBits;
    for (int i = 0; i < len; i++) {
        // Bit i is delayed by kInterleaveDelay[i % 16] CIFs.
        const int age = kInterleaveDelay[i & 15];
        const auto& src = interleaveHist_[static_cast<size_t>(age)];
        cifBits[static_cast<size_t>(cfg_.startCu * kCuBits + i)] = src.empty() ? 0 : src[static_cast<size_t>(i)];
    }
}

void TxSim::modulateFrame(const std::vector<uint8_t>& bits, std::vector<cf32>& out)
{
    out.assign(kNullLen, cf32(0, 0));
    std::vector<cf32> z = phaseReference();
    std::vector<cf32> t(kFftLen);
    const auto& map = frequencyMap();
    const float r = static_cast<float>(1.0 / std::sqrt(2.0));
    for (int l = 0; l < kSymbolsPerFrame; l++) {
        if (l > 0) {
            const uint8_t* p = bits.data() + (l - 1) * kBitsPerSymbol;
            for (int n = 0; n < kCarriers; n++) {
                const cf32 q((1 - 2 * p[n]) * r, (1 - 2 * p[n + kCarriers]) * r);
                cf32& c = z[static_cast<size_t>(carrierToBin(map[static_cast<size_t>(n)]))];
                c *= q;
            }
        }
        t = z;
        fft_.inverse(t.data());
        out.insert(out.end(), t.end() - kGuardLen, t.end());
        out.insert(out.end(), t.begin(), t.end());
    }
}

void TxSim::channel(const std::vector<cf32>& in, std::vector<uint8_t>& out)
{
    if (gain_ == 0 && in.size() > static_cast<size_t>(kFrameLen / 2)) {
        double p = 0;
        for (size_t i = kNullLen; i < in.size(); i++) p += std::norm(in[i]);
        p /= static_cast<double>(in.size() - kNullLen);
        gain_ = cfg_.rms * std::sqrt(2.0) / std::sqrt(p); // rms per I/Q component = cfg_.rms
    }
    const float g = static_cast<float>(gain_ == 0 ? 1.0 : gain_);
    // single echo + gain
    const size_t d = static_cast<size_t>(cfg_.echoDelay);
    for (size_t i = 0; i < in.size(); i++) {
        rawTail_.push_back(in[i]);
        cf32 v = in[i];
        if (cfg_.echoGain > 0 && rawTail_.size() > d) v += static_cast<float>(cfg_.echoGain) * rawTail_[rawTail_.size() - 1 - d];
        history_.push_back(v * g);
    }
    if (rawTail_.size() > 4 * d + 16) rawTail_.erase(rawTail_.begin(), rawTail_.end() - static_cast<long>(d + 1));
    // Resample (receiver clock fast by clockPpm) with a windowed sinc.
    const double step = 1.0 / (1.0 + cfg_.clockPpm * 1e-6);
    const double sigPower = 2.0 * cfg_.rms * cfg_.rms;
    const double noiseSigma = std::sqrt(sigPower / std::pow(10.0, cfg_.snrDb / 10.0) / 2.0);
    std::normal_distribution<double> noise(0.0, noiseSigma);
    const double w = 2.0 * M_PI * cfg_.freqOffsetHz / kSampleRate;
    const int taps = 12;
    while (resamplePos_ + taps + 1 < static_cast<double>(history_.size())) {
        const long base = static_cast<long>(std::floor(resamplePos_));
        const double frac = resamplePos_ - base;
        cf32 acc(0, 0);
        for (int k = -taps + 1; k <= taps; k++) {
            const long idx = base + k;
            if (idx < 0) continue;
            const double x = k - frac;
            const double sinc = std::fabs(x) < 1e-9 ? 1.0 : std::sin(M_PI * x) / (M_PI * x);
            const double win = 0.5 + 0.5 * std::cos(M_PI * x / (taps + 1));
            acc += history_[static_cast<size_t>(idx)] * static_cast<float>(sinc * win);
        }
        acc *= cf32(static_cast<float>(std::cos(phase_)), static_cast<float>(std::sin(phase_)));
        phase_ = std::fmod(phase_ + w, 2.0 * M_PI);
        const double i = acc.real() + noise(rng_);
        const double q = acc.imag() + noise(rng_);
        out.push_back(static_cast<uint8_t>(std::clamp(std::lrint(127.5 + 127.5 * i), 0L, 255L)));
        out.push_back(static_cast<uint8_t>(std::clamp(std::lrint(127.5 + 127.5 * q), 0L, 255L)));
        resamplePos_ += step;
    }
    // Keep only the context the next call still needs.
    const long keep = static_cast<long>(std::floor(resamplePos_)) - taps - 2;
    if (keep > 0) {
        history_.erase(history_.begin(), history_.begin() + keep);
        resamplePos_ -= static_cast<double>(keep);
    }
}

std::vector<uint8_t> TxSim::generate(int frames)
{
    std::vector<uint8_t> out;
    out.reserve(static_cast<size_t>(frames) * kFrameLen * 2 + 200000);
    // Start somewhere in the middle of nowhere: pure noise first.
    std::vector<cf32> silence(77777, cf32(0, 0));
    channel(silence, out);
    std::vector<uint8_t> bits;
    std::vector<uint8_t> cif;
    std::vector<cf32> samples;
    for (int f = 0; f < frames; f++) {
        bits.clear();
        encodeFic(bits);
        for (int c = 0; c < kCifsPerFrame; c++) {
            encodeMscCif(cif);
            bits.insert(bits.end(), cif.begin(), cif.end());
        }
        cifCount_ += 4;
        frameBits.push_back(bits);
        modulateFrame(bits, samples);
        channel(samples, out);
    }
    return out;
}

} // namespace hrdab::test
