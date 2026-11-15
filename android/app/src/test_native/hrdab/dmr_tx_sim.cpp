#include "dmr_tx_sim.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstring>
#include <random>

#include "dmr_fec.h"

namespace hrdab::test {

using namespace hrdab::dmr;

namespace {

constexpr int kSymbolsPerBurst = 144;  // 12 CACH (or guard) + 132 burst
const uint64_t kVoiceSync[3] = {0x755FD7DF75F7ull, 0x7F7D5DD57DFDull, 0x5D577F7757FFull};  // BS, MS, direct slot 1
const uint64_t kVoiceSyncTs2 = 0x7DFFD5F55D5Full;
constexpr uint64_t kComplement = 0xAAAAAAAAAAAAull;  // voice <-> data sync

using Bits = std::vector<uint8_t>;

Bits syncBits(DmrTxKind kind, int slot, bool voice)
{
    uint64_t s = kind == DmrTxKind::Repeater ? kVoiceSync[0]
                 : kind == DmrTxKind::Radio  ? kVoiceSync[1]
                 : slot == 0                 ? kVoiceSync[2]
                                             : kVoiceSyncTs2;
    if (!voice) s ^= kComplement;
    Bits b(48);
    for (int i = 0; i < 48; i++) b[static_cast<size_t>(i)] = static_cast<uint8_t>((s >> (47 - i)) & 1);
    return b;
}

uint32_t golay23Parity(uint32_t data12)
{
    uint32_t v = data12 << 11;
    for (int b = 22; b >= 11; b--) {
        if ((v >> b) & 1) v ^= 0xC75u << (b - 11);
    }
    return v & 0x7FF;
}

// Full LC (72 bits): PF, R, FLCO, FID, service options, two 24-bit fields.
Bits voiceLc(const DmrTxCall& c)
{
    Bits lc(72, 0);
    intToBits(c.group ? 0 : 3, 6, &lc[2]);
    intToBits(0, 8, &lc[8]);
    intToBits(c.privacy ? 0x40 : 0, 8, &lc[16]);
    intToBits(c.dst, 24, &lc[24]);
    intToBits(c.src, 24, &lc[48]);
    return lc;
}

// Talker alias (7-bit): header (49 data bits) + blocks of 56.
std::vector<Bits> aliasLcs(const std::string& alias)
{
    std::vector<uint8_t> data;
    for (char ch : alias) {
        for (int b = 6; b >= 0; b--) data.push_back(static_cast<uint8_t>((ch >> b) & 1));
    }
    data.resize(49 + 3 * 56, 0);
    const int len = static_cast<int>(alias.size());
    const int blocks = len <= 7 ? 0 : (len - 7 + 7) / 8;
    std::vector<Bits> out;
    Bits h(72, 0);
    intToBits(4, 6, &h[2]);
    intToBits(0, 2, &h[16]);
    intToBits(static_cast<uint32_t>(len), 5, &h[18]);
    std::copy(data.begin(), data.begin() + 49, h.begin() + 23);
    out.push_back(h);
    for (int k = 0; k < blocks; k++) {
        Bits b(72, 0);
        intToBits(static_cast<uint32_t>(5 + k), 6, &b[2]);
        std::copy(data.begin() + 49 + 56 * k, data.begin() + 49 + 56 * (k + 1), b.begin() + 16);
        out.push_back(b);
    }
    return out;
}

Bits dataBurst(DmrTxKind kind, int slot, int cc, int dataType, const uint8_t* info96)
{
    uint8_t info[196];
    bptc19696Encode(info96, info);
    Bits st(20);
    intToBits(golay2087Encode((cc << 4) | dataType), 20, st.data());
    const Bits sync = syncBits(kind, slot, false);
    Bits b(264);
    std::copy(info, info + 98, b.begin());
    std::copy(st.begin(), st.begin() + 10, b.begin() + 98);
    std::copy(sync.begin(), sync.end(), b.begin() + 108);
    std::copy(st.begin() + 10, st.end(), b.begin() + 156);
    std::copy(info + 98, info + 196, b.begin() + 166);
    return b;
}

Bits lcBurst(DmrTxKind kind, int slot, int cc, int dataType, const Bits& lc72)
{
    uint8_t bytes[12];
    for (int i = 0; i < 9; i++) bytes[i] = static_cast<uint8_t>(bitsToInt(&lc72[static_cast<size_t>(8 * i)], 8));
    rs129Parity(bytes, bytes + 9);
    const uint32_t mask = dataType == 1 ? kMaskVoiceLcHeader : kMaskTerminatorLc;
    bytes[9] ^= static_cast<uint8_t>(mask >> 16);
    bytes[10] ^= static_cast<uint8_t>(mask >> 8);
    bytes[11] ^= static_cast<uint8_t>(mask);
    uint8_t info96[96];
    for (int i = 0; i < 12; i++) intToBits(bytes[i], 8, info96 + 8 * i);
    return dataBurst(kind, slot, cc, dataType, info96);
}

AmbeBits randomFrame(std::mt19937& rng)
{
    AmbeBits d{};
    for (auto& b : d) b = static_cast<char>(rng() & 1);
    // Pitch index b0 (bits 0-3, 37-39) 120-127 would mean erasure/tone/silence.
    const int b0 = (d[0] << 6) | (d[1] << 5) | (d[2] << 4) | (d[3] << 3) | (d[37] << 2) | (d[38] << 1) | d[39];
    if (b0 >= 120) d[0] = 0;
    return d;
}

Bits voiceBurst(const uint8_t f[3][72], const Bits& centre48)
{
    Bits b(264);
    std::copy(f[0], f[0] + 72, b.begin());
    std::copy(f[1], f[1] + 36, b.begin() + 72);
    std::copy(centre48.begin(), centre48.end(), b.begin() + 108);
    std::copy(f[1] + 36, f[1] + 72, b.begin() + 156);
    std::copy(f[2], f[2] + 72, b.begin() + 192);
    return b;
}

// EMB around 32 embedded bits.
Bits embCentre(int cc, int lcss, const uint8_t* emb32)
{
    Bits emb(16);
    intToBits(qr1676Encode((cc << 3) | lcss), 16, emb.data());
    Bits c(48);
    std::copy(emb.begin(), emb.begin() + 8, c.begin());
    std::copy(emb32, emb32 + 32, c.begin() + 8);
    std::copy(emb.begin() + 8, emb.end(), c.begin() + 40);
    return c;
}

struct CallBursts {
    std::vector<Bits> bursts;
};

CallBursts callBursts(const DmrTxConfig& cfg, const DmrTxCall& c, std::mt19937& rng, std::vector<AmbeBits>& sent)
{
    CallBursts out;
    const int cc = cfg.colorCode;
    const Bits lc = voiceLc(c);
    if (c.header) {
        for (int k = 0; k < 2; k++) out.bursts.push_back(lcBurst(cfg.kind, c.slot, cc, 1, lc));
    }
    const std::vector<Bits> alias = c.alias.empty() ? std::vector<Bits>() : aliasLcs(c.alias);
    for (int sf = 0; sf < c.superframes; sf++) {
        // Embedded LC: the call's LC, with a talker alias every other
        // superframe.
        const Bits& emb = alias.empty() || sf % 2 == 0 ? lc : alias[static_cast<size_t>(sf / 2) % alias.size()];
        uint8_t emb128[128];
        embeddedLcEncode(emb.data(), emb128);
        for (int b = 0; b < 6; b++) {
            uint8_t f[3][72];
            for (auto& frame : f) {
                const AmbeBits d = randomFrame(rng);
                sent.push_back(d);
                ambeEncode(d, frame);
            }
            Bits centre;
            if (b == 0) {
                centre = syncBits(cfg.kind, c.slot, true);
            } else if (b <= 4) {
                const int lcss = b == 1 ? 1 : b == 4 ? 2 : 3;
                centre = embCentre(cc, lcss, emb128 + 32 * (b - 1));
            } else {
                const uint8_t null32[32] = {};
                centre = embCentre(cc, 0, null32);
            }
            out.bursts.push_back(voiceBurst(f, centre));
        }
    }
    out.bursts.push_back(lcBurst(cfg.kind, c.slot, cc, 2, lc));
    return out;
}

std::vector<float> rrc(int sps, double beta, int span)
{
    const int half = span * sps;
    std::vector<float> h(static_cast<size_t>(2 * half + 1));
    double sum = 0;
    for (int i = -half; i <= half; i++) {
        const double t = static_cast<double>(i) / sps;
        double v;
        if (i == 0) {
            v = 1 - beta + 4 * beta / M_PI;
        } else if (std::fabs(std::fabs(t) - 1 / (4 * beta)) < 1e-9) {
            v = beta / std::sqrt(2.0) *
                ((1 + 2 / M_PI) * std::sin(M_PI / (4 * beta)) + (1 - 2 / M_PI) * std::cos(M_PI / (4 * beta)));
        } else {
            v = (std::sin(M_PI * t * (1 - beta)) + 4 * beta * t * std::cos(M_PI * t * (1 + beta))) /
                (M_PI * t * (1 - (4 * beta * t) * (4 * beta * t)));
        }
        h[static_cast<size_t>(i + half)] = static_cast<float>(v);
        sum += v;
    }
    // A run of equal symbols gives that symbol's level.
    for (float& v : h) v = static_cast<float>(v / sum * sps);
    return h;
}

// Deviation at 48 kHz (10 samples per symbol), Hz.
std::vector<float> deviation48(const DmrTx& tx, double scale)
{
    constexpr int sps = 10;
    const auto h = rrc(sps, 0.2, 8);
    const int half = static_cast<int>(h.size() / 2);
    std::vector<float> f(tx.symbols.size() * sps, 0.f);
    for (size_t k = 0; k < tx.symbols.size(); k++) {
        const float a = static_cast<float>(tx.symbols[k] * 648.0 * scale);
        if (a == 0.f) continue;
        const long c = static_cast<long>(k * sps + sps / 2);
        for (int i = -half; i <= half; i++) {
            const long n = c + i;
            if (n >= 0 && n < static_cast<long>(f.size())) f[static_cast<size_t>(n)] += a * h[static_cast<size_t>(i + half)];
        }
    }
    return f;
}

} // namespace

void ambeEncode(const AmbeBits& d, uint8_t* tx72)
{
    char fr[4][24] = {};
    uint32_t c0 = 0, c1 = 0;
    for (int i = 0; i < 12; i++) c0 = (c0 << 1) | static_cast<uint32_t>(d[static_cast<size_t>(i)] & 1);
    for (int i = 12; i < 24; i++) c1 = (c1 << 1) | static_cast<uint32_t>(d[static_cast<size_t>(i)] & 1);
    // C0: Golay (23,12) + overall parity in bit 0; C1: Golay (23,12).
    const uint32_t w0 = (c0 << 11) | golay23Parity(c0), w1 = (c1 << 11) | golay23Parity(c1);
    int ones = 0;
    for (int b = 0; b < 23; b++) {
        fr[0][b + 1] = static_cast<char>((w0 >> b) & 1);
        ones += fr[0][b + 1];
        fr[1][b] = static_cast<char>((w1 >> b) & 1);
    }
    fr[0][0] = static_cast<char>(ones & 1);
    for (int i = 0; i < 11; i++) fr[2][10 - i] = d[static_cast<size_t>(24 + i)];
    for (int i = 0; i < 14; i++) fr[3][13 - i] = d[static_cast<size_t>(35 + i)];
    // C1 is scrambled with a sequence seeded by C0's data bits.
    uint32_t pr = 16 * c0;
    for (int j = 22; j >= 0; j--) {
        pr = (173 * pr + 13849) % 65536;
        fr[1][j] = static_cast<char>(fr[1][j] ^ (pr >> 15));
    }
    ambeInterleave(fr, tx72);
}

DmrTx buildDmr(const DmrTxConfig& cfg, double seconds)
{
    DmrTx tx;
    std::mt19937 rng(cfg.seed);
    const int nBursts = static_cast<int>(seconds / 0.03);
    tx.symbols.assign(static_cast<size_t>(nBursts) * kSymbolsPerBurst, 0);
    tx.on.assign(tx.symbols.size(), cfg.kind == DmrTxKind::Repeater ? 1 : 0);

    // Each call's bursts, from its first burst slot on.
    struct Active {
        int startBurst;
        CallBursts b;
        int slot;
    };
    std::vector<Active> active;
    for (const auto& c : cfg.calls) {
        int first = static_cast<int>(std::ceil(c.startS / 0.03));
        if (first % 2 != c.slot) first++;
        active.push_back({first, callBursts(cfg, c, rng, tx.frames[c.slot]), c.slot});
    }
    uint8_t idle96[96] = {};
    for (int i = 0; i < nBursts; i++) {
        const int slot = i % 2;
        const Bits* burst = nullptr;
        Bits idle;
        for (const auto& a : active) {
            if (a.slot != slot || i < a.startBurst) continue;
            const int k = (i - a.startBurst) / 2;
            if (k < static_cast<int>(a.b.bursts.size())) burst = &a.b.bursts[static_cast<size_t>(k)];
        }
        if (!burst) {
            if (cfg.kind != DmrTxKind::Repeater) continue;
            idle = dataBurst(cfg.kind, slot, cfg.colorCode, 9, idle96);
            burst = &idle;
        }
        Bits all(2 * kSymbolsPerBurst, 0);
        if (cfg.kind == DmrTxKind::Repeater) {
            // CACH: TACT (AT busy, TC = this burst's slot, LCSS 0) on its
            // interleaved positions, no short LC.
            Bits tact(7);
            intToBits(hamming743Encode((1 << 3) | (slot << 2)), 7, tact.data());
            const int pos[7] = {0, 4, 8, 12, 14, 18, 22};
            for (int k = 0; k < 7; k++) all[static_cast<size_t>(pos[k])] = tact[static_cast<size_t>(k)];
        }
        std::copy(burst->begin(), burst->end(), all.begin() + 24);
        for (int j = 0; j < kSymbolsPerBurst; j++) {
            const size_t at = static_cast<size_t>(i) * kSymbolsPerBurst + static_cast<size_t>(j);
            const int dibit = (all[static_cast<size_t>(2 * j)] << 1) | all[static_cast<size_t>(2 * j + 1)];
            tx.symbols[at] = static_cast<int8_t>(dibit == 1 ? 3 : dibit == 0 ? 1 : dibit == 2 ? -1 : -3);
            if (cfg.kind != DmrTxKind::Repeater && j >= 12) tx.on[at] = 1;  // the burst, not the guard
        }
    }
    return tx;
}

std::vector<float> dmrDeviationHz(const DmrTx& tx, int rate, double deviationScale)
{
    const auto f48 = deviation48(tx, deviationScale);
    const double step = 48000.0 / rate;
    std::vector<float> out(static_cast<size_t>(f48.size() / step));
    for (size_t n = 0; n < out.size(); n++) {
        const double x = n * step;
        const size_t i = static_cast<size_t>(x);
        const double fr = x - static_cast<double>(i);
        out[n] = static_cast<float>(i + 1 < f48.size() ? f48[i] * (1 - fr) + f48[i + 1] * fr : f48[i]);
    }
    return out;
}

std::vector<uint8_t> modulateDmr(const DmrTxConfig& cfg, const DmrTx& tx)
{
    const auto f48 = deviation48(tx, cfg.deviationScale);
    const double rate = cfg.sampleRate;
    const double seconds = static_cast<double>(tx.symbols.size()) / 4800.0;
    const size_t n = static_cast<size_t>(seconds * rate);
    // Carrier power 1; noise in 12.5 kHz 1/snr.
    const double noiseVar = std::pow(10.0, -cfg.snrDb / 10) * rate / 12500.0;
    const double scale = cfg.rms / std::sqrt((1 + noiseVar) / 2);
    const double sigma = std::sqrt(noiseVar / 2) * scale;
    std::mt19937 rng(cfg.seed * 31 + 5);
    std::normal_distribution<float> normal(0.f, 1.f);
    std::vector<float> table(1 << 20);
    for (auto& v : table) v = normal(rng);
    size_t ni = 0;
    std::vector<uint8_t> out(2 * n);
    double phase = 0.4;
    const double clock = 1 + cfg.clockPpm * 1e-6;
    double amp = 0;
    for (size_t k = 0; k < n; k++) {
        if ((k & 4095) == 0) ni = rng() % (table.size() - 3 * 4096);
        const double x = static_cast<double>(k) / rate * 48000.0 * clock;
        const size_t i = static_cast<size_t>(x);
        double f = 0;
        bool on = false;
        if (i + 1 < f48.size()) {
            const double fr = x - static_cast<double>(i);
            f = f48[i] * (1 - fr) + f48[i + 1] * fr;
            on = tx.on[i / 10] != 0;
        }
        // 0.5 ms power ramps, as a radio keying its bursts.
        const double target = on ? 1.0 : 0.0;
        amp += std::max(-1.0, std::min(1.0, (target - amp))) * std::min(1.0, 2000.0 / rate);
        phase += 2 * M_PI * (cfg.offsetHz + f) / rate;
        if (phase > M_PI) phase -= 2 * M_PI;
        if (phase < -M_PI) phase += 2 * M_PI;
        const double re = scale * amp * std::cos(phase) + sigma * table[ni++];
        const double im = scale * amp * std::sin(phase) + sigma * table[ni++];
        out[2 * k] = static_cast<uint8_t>(std::max(0.0, std::min(255.0, std::round(127.5 + 127.5 * re))));
        out[2 * k + 1] = static_cast<uint8_t>(std::max(0.0, std::min(255.0, std::round(127.5 + 127.5 * im))));
    }
    return out;
}

} // namespace hrdab::test
