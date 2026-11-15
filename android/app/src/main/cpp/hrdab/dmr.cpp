#include "dmr.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "common.h"
#include "dmr_fec.h"
#include "json.h"

#ifdef HRDAB_MBELIB
extern "C" {
#include "mbelib.h"
}
#endif

namespace hrdab {

using namespace dmr;

namespace {

constexpr int kRate = 48000;                 // internal rate, 10 samples per symbol
constexpr int kSps = 10;
constexpr int kSyncEnd = 77;                 // burst symbol of the last sync symbol (R12)
constexpr int kBurstSymbols = 132;
constexpr int kCachSymbols = 12;
constexpr int64_t kBurstSpacing = kRate * 30 / 1000;   // next burst, other slot
constexpr int64_t kSlotSpacing = 2 * kBurstSpacing;    // next burst, same slot
// From the last sync symbol until the burst's end (plus timing margin) is in.
constexpr int64_t kBurstTail = (kBurstSymbols - 1 - kSyncEnd) * kSps + 4;
// A followed call's burst waits this much longer, so a sync found in it is
// handled first (as the same burst).
constexpr int64_t kTrackerLag = 40;
// Normalised correlation for a new sync (noise alone reaches ~0.8 a few
// times a second - every burst is verified further on), and for burst A of
// a call being followed, where the sync is expected.
constexpr float kAcquireRho = 0.85f;
constexpr float kTrackRho = 0.55f;
// Plausible symbol levels: +-3 = 1944 Hz deviation (+-10 % allowed, more
// for cheap radios), carrier within the channel filter.
constexpr float kMinHalfHz = 900, kMaxHalfHz = 3200, kMaxCenterHz = 3500;
constexpr int kPrebuffer = 720;              // 90 ms of 8 kHz audio before playing
constexpr int kFifoSize = 8000;
constexpr float kAmbeGain = 7.f / 32768.f;   // mbelib's own float -> PCM scale
constexpr int kMaxPending = 6 * 160;         // audio of a call not yet confirmed

// Voice sync patterns (table 9.2); the data patterns are their complement.
const uint64_t kSyncs[4] = {0x755FD7DF75F7ull, 0x7F7D5DD57DFDull, 0x5D577F7757FFull, 0x7DFFD5F55D5Full};

// Root raised cosine, roll-off `beta`, unity DC gain, `span` symbols
// either side, Hamming window.
std::vector<float> rrcTaps(int sps, double beta, int span)
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
        v *= 0.54 + 0.46 * std::cos(M_PI * i / half);
        h[static_cast<size_t>(i + half)] = static_cast<float>(v);
        sum += v;
    }
    for (float& v : h) v = static_cast<float>(v / sum);
    return h;
}

// 4FSK slicer: level relative to +-3 -> dibit (01 +3, 00 +1, 10 -1, 11 -3).
inline int dibitOf(float v)
{
    return v >= 2.f ? 1 : v >= 0.f ? 0 : v >= -2.f ? 2 : 3;
}

inline float levelOf(float v)
{
    return v >= 2.f ? 3.f : v >= 0.f ? 1.f : v >= -2.f ? -1.f : -3.f;
}

// Code units -> UTF-8 for the talker alias: format 1 = 7-bit ASCII or ISO
// 8859-1, 2 = UTF-8 (checked), 3 = UTF-16 (BMP). NUL padding is dropped;
// characters JNI's modified UTF-8 cannot carry (outside the BMP) and other
// control characters become '?'.
void appendCodePoint(std::string& out, uint32_t cp)
{
    if (cp == 0) return;
    if (cp < 0x20 || cp == 0x7F || cp > 0xFFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
        out += '?';
    } else if (cp < 0x80) {
        out += static_cast<char>(cp);
    } else if (cp < 0x800) {
        out += static_cast<char>(0xC0 | (cp >> 6));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
        out += static_cast<char>(0xE0 | (cp >> 12));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    }
}

std::string aliasText(int format, const std::vector<uint32_t>& units)
{
    std::string out;
    if (format == 2) {
        size_t i = 0;
        while (i < units.size()) {
            const uint32_t b = units[i];
            const int more = b < 0x80 ? 0 : (b & 0xE0) == 0xC0 ? 1 : (b & 0xF0) == 0xE0 ? 2 : (b & 0xF8) == 0xF0 ? 3 : -1;
            if (more < 0) {
                out += '?';
                i++;
                continue;
            }
            if (i + static_cast<size_t>(more) >= units.size()) break;  // the rest is still to come
            uint32_t cp = more == 0 ? b : b & (0x3Fu >> more);
            bool ok = true;
            for (int k = 1; k <= more && ok; k++) {
                const uint32_t c = units[i + static_cast<size_t>(k)];
                ok = (c & 0xC0) == 0x80;
                cp = (cp << 6) | (c & 0x3F);
            }
            if (!ok) {
                out += '?';
                i++;
                continue;
            }
            appendCodePoint(out, cp);
            i += static_cast<size_t>(more) + 1;
        }
    } else {
        for (uint32_t u : units) appendCodePoint(out, u);
    }
    while (!out.empty() && out.back() == ' ') out.pop_back();
    return out;
}

} // namespace

struct DmrDecoder::Slot {
    // voice superframe being followed
    bool voice = false;
    bool confirmed = false;
    int64_t nextT = 0;            // expected tSync of the next burst of this slot
    int burst = 0;                // its position in the superframe, 0 = A
    int pattern = 0;
    float center = 0, half = 1944;
    int misses = 0;
    int goodEmb = 0;
    int cc = -1;
    std::vector<float> pending;   // audio of a call not yet confirmed
    // embedded LC fragments
    uint8_t emb[128] = {};
    int frag = 0;
    // the call
    int64_t headerT = -1000000;   // last voice LC header
    int64_t confirmedT = -1000000;
    int64_t voiceT = -1;          // last confirmed voice burst
    int callType = 0;
    uint32_t src = 0, dst = 0;
    bool privacy = false, piHeader = false, emergency = false;
    long frames = 0, errorBits = 0;
    // talker alias: header (49 bits) + 3 blocks (56 bits)
    uint8_t aliasBits[217] = {};
    int aliasHave = 0;            // bit k: header / block k received
    int aliasFormat = 0, aliasLength = 0;
    std::string alias;
#ifdef HRDAB_MBELIB
    mbe_parms cur{}, prev{}, prevEnh{};
#endif

    void resetCall()
    {
        callType = 0;
        src = dst = 0;
        privacy = piHeader = emergency = false;
        frames = errorBits = 0;
        aliasHave = 0;
        aliasFormat = aliasLength = 0;
        alias.clear();
    }
};

DmrDecoder::DmrDecoder()
{
    // x3 (16 -> 48 kS/s), the matched filter doing the interpolation.
    rrc_.init(rrcTaps(kSps, 0.2, 8), 3, 1);
    ring_.assign(kRingSize, 0.f);
    in48_.resize(3 * 512);
    fifo_.assign(kFifoSize, 0.f);
    for (int p = 0; p < 4; p++) {
        for (int k = 0; k < 24; k++) {
            const int dibit = static_cast<int>((kSyncs[p] >> (46 - 2 * k)) & 3);
            pat_[p][k] = dibit == 1 ? 1.f : -1.f;  // 01 = +3, 11 = -3
        }
    }
    for (auto& s : slots_) s = std::make_unique<Slot>();
    reset();
}

DmrDecoder::~DmrDecoder() = default;

void DmrDecoder::reset()
{
    rrc_.reset();
    std::fill(ring_.begin(), ring_.end(), 0.f);
    t_ = 0;
    nextDue_ = INT64_MAX;
    peakValid_ = false;
    lastEmit_ = -1000000;
    tasks_.clear();
    lastBsT_ = -1;
    lastBsSlot_ = 0;
    for (auto& s : slots_) *s = Slot();
    audioSlot_ = -1;
    validT_ = prevValidT_ = -1000000;
    source_ = 0;
    colorCode_ = -1;
    fifoRead_ = fifoCount_ = 0;
    playing_ = false;
}

void DmrDecoder::process(const float* hz, int n)
{
    while (n > 0) {
        const int m = std::min(n, 512);
        const int got = rrc_.process(hz, m, in48_.data());
        for (int i = 0; i < got; i++) push(in48_[static_cast<size_t>(i)]);
        hz += m;
        n -= m;
    }
}

void DmrDecoder::push(float y)
{
    ring_[static_cast<size_t>(t_ & kRingMask)] = y;
    detectSync();
    t_++;
    if (t_ >= nextDue_) runDue();
}

void DmrDecoder::detectSync()
{
    const int64_t t = t_;
    if (t < 24 * kSps) return;
    float s[24];
    float sum = 0, sum2 = 0;
    for (int k = 0; k < 24; k++) {
        const float v = at(t - static_cast<int64_t>(23 - k) * kSps);
        s[k] = v;
        sum += v;
        sum2 += v * v;
    }
    // Every pattern has as many +3 as -3: the correlation ignores the
    // carrier offset; normalised by the spread it ignores the level too.
    const float var = sum2 - sum * sum / 24.f;
    if (var > 1.f) {
        float best = 0;
        int bestP = 0;
        for (int p = 0; p < 4; p++) {
            float c = 0;
            for (int k = 0; k < 24; k++) c += pat_[p][k] * s[k];
            if (std::fabs(c) > std::fabs(best)) {
                best = c;
                bestP = p;
            }
        }
        const float rho = best / std::sqrt(24.f * var);
        if (std::fabs(rho) >= kAcquireRho && t > lastEmit_ + 3 * kSps &&
            (!peakValid_ || std::fabs(rho) > std::fabs(peakRho_))) {
            peakValid_ = true;
            peakT_ = t;
            peakRho_ = rho;
            peakPattern_ = bestP;
        }
    }
    if (!peakValid_ || t - peakT_ < 6) return;
    peakValid_ = false;
    lastEmit_ = peakT_;
    Task task;
    task.tSync = peakT_;
    task.pattern = peakPattern_;
    task.voice = peakRho_ > 0;
    levelsFrom(task.tSync, task.pattern, task.voice, task.center, task.half);
    if (task.half < kMinHalfHz || task.half > kMaxHalfHz || std::fabs(task.center) > kMaxCenterHz) return;
    tasks_.push_back(task);
    updateDue();
}

float DmrDecoder::rhoAt(int64_t tSync, int pattern) const
{
    float sum = 0, sum2 = 0, c = 0;
    for (int k = 0; k < 24; k++) {
        const float v = at(tSync - static_cast<int64_t>(23 - k) * kSps);
        sum += v;
        sum2 += v * v;
        c += pat_[pattern][k] * v;
    }
    const float var = sum2 - sum * sum / 24.f;
    return var > 1.f ? c / std::sqrt(24.f * var) : 0.f;
}

void DmrDecoder::levelsFrom(int64_t tSync, int pattern, bool voice, float& center, float& half) const
{
    // The sync symbols are all +-3: their means give both levels.
    double hi = 0, lo = 0;
    int nh = 0, nl = 0;
    for (int k = 0; k < 24; k++) {
        const float v = at(tSync - static_cast<int64_t>(23 - k) * kSps);
        const float sign = pat_[pattern][k] * (voice ? 1.f : -1.f);
        if (sign > 0) {
            hi += v;
            nh++;
        } else {
            lo += v;
            nl++;
        }
    }
    hi /= std::max(nh, 1);
    lo /= std::max(nl, 1);
    center = static_cast<float>((hi + lo) / 2);
    half = static_cast<float>((hi - lo) / 2);
}

void DmrDecoder::updateDue()
{
    int64_t due = INT64_MAX;
    for (const Task& k : tasks_) due = std::min(due, k.tSync + kBurstTail);
    for (const auto& s : slots_) {
        if (s->voice) due = std::min(due, s->nextT + kBurstTail + kTrackerLag);
    }
    nextDue_ = due;
}

void DmrDecoder::runDue()
{
    for (size_t i = 0; i < tasks_.size();) {
        if (tasks_[i].tSync + kBurstTail <= t_) {
            const Task task = tasks_[i];
            tasks_.erase(tasks_.begin() + static_cast<long>(i));
            syncBurst(task);
        } else {
            i++;
        }
    }
    for (int s = 0; s < 2; s++) {
        if (slots_[s]->voice && slots_[s]->nextT + kBurstTail + kTrackerLag <= t_) trackerBurst(s);
    }
    updateDue();
}

int DmrDecoder::refine(int64_t tSync, float center, float half, int range) const
{
    // The sampling instant with the least distance to the nearest symbol
    // level over the whole burst.
    const float scale = 3.f / half;
    int best = 0;
    float bestErr = 1e30f;
    for (int d = -range; d <= range; d++) {
        float err = 0;
        for (int j = 0; j < kBurstSymbols; j++) {
            const float v = (at(tSync + static_cast<int64_t>(j - kSyncEnd) * kSps + d) - center) * scale;
            const float e = v - levelOf(v);
            err += e * e;
        }
        if (err < bestErr || (err == bestErr && std::abs(d) < std::abs(best))) {
            bestErr = err;
            best = d;
        }
    }
    return best;
}

void DmrDecoder::slice(int64_t tSync, int first, int count, float center, float half, uint8_t* bits) const
{
    const float scale = 3.f / half;
    for (int j = 0; j < count; j++) {
        const float v = (at(tSync + static_cast<int64_t>(first + j - kSyncEnd) * kSps) - center) * scale;
        const int d = dibitOf(v);
        bits[2 * j] = static_cast<uint8_t>(d >> 1);
        bits[2 * j + 1] = static_cast<uint8_t>(d & 1);
    }
}

void DmrDecoder::syncBurst(const Task& task)
{
    const int64_t ts = task.tSync + refine(task.tSync, task.center, task.half, 2);
    uint8_t bits[2 * kBurstSymbols];
    slice(ts, 0, kBurstSymbols, task.center, task.half, bits);
    int slot = 0;
    int bsByTiming = -1;
    if (task.pattern == 0) {
        // Repeater: the CACH before the burst numbers it (TC); its Hamming
        // (7,4) is a perfect code, so a clean word is trusted over the
        // timing, a corrected one only without timing.
        uint8_t cach[2 * kCachSymbols];
        slice(ts, -kCachSymbols, kCachSymbols, task.center, task.half, cach);
        const uint32_t tact = (cach[0] << 6) | (cach[4] << 5) | (cach[8] << 4) | (cach[12] << 3) | (cach[14] << 2) |
                              (cach[18] << 1) | cach[22];
        int errors = 9;
        const int d4 = hamming743Decode(tact, &errors);
        if (lastBsT_ >= 0) {
            const double k = static_cast<double>(ts - lastBsT_) / kBurstSpacing;
            const long n = std::lround(k);
            if (n > 0 && n < 200 && std::fabs(k - n) * kBurstSpacing < 40) bsByTiming = lastBsSlot_ ^ static_cast<int>(n & 1);
        }
        if (d4 >= 0 && errors == 0) slot = (d4 >> 2) & 1;
        else if (bsByTiming >= 0) slot = bsByTiming;
        else if (d4 >= 0) slot = (d4 >> 2) & 1;
    } else if (task.pattern == 1) {
        // MS sourced: one radio per slot; a second one on another timing
        // is the other slot.
        auto expects = [&](int s) { return slots_[s]->voice && std::llabs(ts - slots_[s]->nextT) < 60; };
        slot = expects(0) ? 0 : expects(1) ? 1 : (slots_[0]->voice && slots_[0]->confirmed) ? 1 : 0;
    } else {
        slot = task.pattern - 2;
    }
    bool valid = true;
    if (task.voice) {
        Slot& s = *slots_[slot];
        s.center = task.center;
        s.half = task.half;
        voiceBurst(slot, ts, bits, true, task.pattern);
    } else {
        valid = dataBurst(slot, task, bits);
    }
    if (task.pattern == 0 && valid) {
        lastBsT_ = ts;
        lastBsSlot_ = slot;
    }
}

bool DmrDecoder::dataBurst(int slot, const Task& task, const uint8_t* bits)
{
    // Slot Type: 10 bits either side of the sync.
    const uint32_t word = (bitsToInt(bits + 98, 10) << 10) | bitsToInt(bits + 156, 10);
    const int st = golay2087Decode(word);
    if (st < 0) return false;
    const int cc = st >> 4, dataType = st & 15;
    // Rate 3/4 and rate 1 data are not BPTC coded - nothing to verify them by.
    if (dataType == 8 || dataType == 10 || dataType > 11) return false;
    uint8_t info[196];
    std::memcpy(info, bits, 98);
    std::memcpy(info + 98, bits + 166, 98);
    uint8_t i96[96];
    if (!bptc19696Decode(info, i96)) return false;
    markValid(task.pattern);
    colorCode_ = cc;
    Slot& s = *slots_[slot];
    s.cc = cc;
    switch (dataType) {
        case 1:    // voice LC header
        case 2: {  // terminator with LC
            uint8_t b[12];
            for (int i = 0; i < 12; i++) b[i] = static_cast<uint8_t>(bitsToInt(i96 + 8 * i, 8));
            uint8_t parity[3];
            rs129Parity(b, parity);
            const uint32_t got = ((static_cast<uint32_t>(b[9]) << 16) | (b[10] << 8) | b[11]) ^
                                 (dataType == 1 ? kMaskVoiceLcHeader : kMaskTerminatorLc);
            const uint32_t want = (static_cast<uint32_t>(parity[0]) << 16) | (parity[1] << 8) | parity[2];
            if (got == want) fullLc(slot, i96, dataType == 1);
            if (dataType == 2) endCall(slot);
            break;
        }
        case 0:  // privacy indicator header (after the LC header): encrypted voice follows
            s.piHeader = true;
            s.headerT = t_;
            break;
        default:
            // CSBK, data, idle: the slot no longer carries this call.
            if (s.voice) endCall(slot);
            break;
    }
    return true;
}

void DmrDecoder::fullLc(int slot, const uint8_t* lc, bool header)
{
    Slot& s = *slots_[slot];
    const int flco = static_cast<int>(bitsToInt(lc + 2, 6));
    const int fid = static_cast<int>(bitsToInt(lc + 8, 8));
    if (flco == 0 || flco == 3) {
        // Group / unit to unit voice channel user (TS 102 361-2, 7.1.1.1/2);
        // manufacturers' feature sets use the same layout.
        const int options = static_cast<int>(bitsToInt(lc + 16, 8));
        const uint32_t dst = bitsToInt(lc + 24, 24), src = bitsToInt(lc + 48, 24);
        const int type = flco == 0 ? 1 : 2;
        // Another call or talker: its own alias and statistics. (Late
        // entry, IDs still unknown, keeps what the call has so far.)
        if (s.src != 0 && (src != s.src || dst != s.dst || type != s.callType)) s.resetCall();
        if (header) s.piHeader = false;  // a PI header follows the LC header
        s.callType = type;
        s.src = src;
        s.dst = dst;
        s.emergency = (options & 0x80) != 0;
        s.privacy = (options & 0x40) != 0;
        if (header) s.headerT = t_;
        return;
    }
    if (header || fid != 0 || flco < 4 || flco > 7) return;
    // Talker alias (7.1.1.4/5): header with format, length and 49 bits,
    // blocks 1-3 with 56 bits each.
    if (flco == 4) {
        s.aliasFormat = static_cast<int>(bitsToInt(lc + 16, 2));
        s.aliasLength = static_cast<int>(bitsToInt(lc + 18, 5));
        std::memcpy(s.aliasBits, lc + 23, 49);
    } else {
        std::memcpy(s.aliasBits + 49 + 56 * (flco - 5), lc + 16, 56);
    }
    s.aliasHave |= 1 << (flco - 4);
    if (!(s.aliasHave & 1)) return;
    // The part received so far, from the start.
    int bitsHave = 49;
    for (int k = 1; k < 4 && (s.aliasHave & (1 << k)); k++) bitsHave += 56;
    const int unitBits = s.aliasFormat == 0 ? 7 : s.aliasFormat == 3 ? 16 : 8;
    const int skip = s.aliasFormat == 0 ? 0 : 1;  // reserved bit before 8/16-bit units
    std::vector<uint32_t> units;
    for (int i = 0; i < s.aliasLength; i++) {
        const int at = skip + i * unitBits;
        if (at + unitBits > bitsHave) break;
        units.push_back(bitsToInt(s.aliasBits + at, unitBits));
    }
    s.alias = aliasText(s.aliasFormat == 0 ? 1 : s.aliasFormat, units);
}

void DmrDecoder::embeddedLc(int slot, const uint8_t* lc72)
{
    fullLc(slot, lc72, false);
}

void DmrDecoder::startVoice(int slot, int64_t tSync)
{
    Slot& s = *slots_[slot];
    const bool afterHeader = t_ - s.headerT < kRate / 2;
    const bool continuing = t_ - s.confirmedT < kRate;  // resynchronised within a call
    s.voice = true;
    s.confirmed = afterHeader || continuing;
    s.nextT = tSync;
    s.burst = 0;
    s.misses = 0;
    s.goodEmb = 0;
    s.frag = 0;
    s.pending.clear();
    if (!afterHeader && !continuing) s.resetCall();  // late entry: IDs from the embedded LC
    if (!continuing) {
        s.frames = s.errorBits = 0;
#ifdef HRDAB_MBELIB
        mbe_initMbeParms(&s.cur, &s.prev, &s.prevEnh);
#endif
    }
    if (s.confirmed) confirm(slot);
}

void DmrDecoder::confirm(int slot)
{
    Slot& s = *slots_[slot];
    s.confirmed = true;
    s.confirmedT = t_;
    markValid(s.pattern);
    if (!s.pending.empty()) {
        std::vector<float> held;
        held.swap(s.pending);
        emitAudio(slot, held.data(), static_cast<int>(held.size()));
    }
}

void DmrDecoder::endCall(int slot)
{
    Slot& s = *slots_[slot];
    s.voice = false;
    s.confirmed = false;
    s.pending.clear();
    s.frag = 0;
    if (audioSlot_ == slot) audioSlot_ = -1;
}

void DmrDecoder::voiceBurst(int slot, int64_t tSync, const uint8_t* bits, bool syncA, int pattern)
{
    Slot& s = *slots_[slot];
    if (syncA) {
        const bool expected = s.voice && s.burst == 0 && std::llabs(tSync - s.nextT) < 60;
        s.pattern = pattern;
        if (!expected) {
            startVoice(slot, tSync);
        } else if (!s.confirmed) {
            confirm(slot);  // a second superframe right on time
        }
        s.misses = 0;
        s.frag = 0;
    } else {
        // EMB (QR 16,7): colour code, PI, LCSS - must decode, with the
        // call's colour code.
        const uint32_t word = (bitsToInt(bits + 108, 8) << 8) | bitsToInt(bits + 148, 8);
        int errors = 9;
        const int emb = qr1676Decode(word, &errors);
        const bool ok = emb >= 0 && (s.cc < 0 || (emb >> 3) == s.cc);
        if (!ok) {
            // A tentative call ends at the first bad EMB, a confirmed one
            // after three in a row (fading).
            if (!s.confirmed || ++s.misses >= 3) {
                endCall(slot);
                return;
            }
        } else {
            s.misses = 0;
            s.cc = emb >> 3;
            if (!s.confirmed && errors <= 1 && ++s.goodEmb >= 2) confirm(slot);
            if (s.confirmed) colorCode_ = s.cc;
            const uint8_t* frag = bits + 116;
            switch (emb & 3) {
                case 1:  // first fragment
                    std::memcpy(s.emb, frag, 32);
                    s.frag = 1;
                    break;
                case 3:  // continuation
                    if (s.frag == 1 || s.frag == 2) {
                        std::memcpy(s.emb + 32 * s.frag, frag, 32);
                        s.frag++;
                    } else {
                        s.frag = 0;
                    }
                    break;
                case 2:  // last
                    if (s.frag == 3) {
                        std::memcpy(s.emb + 96, frag, 32);
                        uint8_t lc[72];
                        if (embeddedLcDecode(s.emb, lc)) embeddedLc(slot, lc);
                    }
                    s.frag = 0;
                    break;
                default:  // single burst: null LC or reverse channel (burst F)
                    s.frag = 0;
                    break;
            }
        }
    }
    voiceFrames(slot, bits);
    if (s.confirmed) {
        s.voiceT = tSync;
        s.confirmedT = t_;
        markValid(s.pattern);
    }
    s.nextT = tSync + kSlotSpacing;
    s.burst = (s.burst + 1) % 6;
}

void DmrDecoder::trackerBurst(int slot)
{
    Slot& s = *slots_[slot];
    const int64_t t0 = s.nextT;
    uint8_t bits[2 * kBurstSymbols];
    if (s.burst == 0) {
        // Burst A without a sync found: look for it right here, with less
        // margin than for a new one. Not there: the call is over.
        float best = 0;
        int64_t bestT = t0;
        for (int d = -3; d <= 3; d++) {
            const float rho = rhoAt(t0 + d, s.pattern);
            if (rho > best) {
                best = rho;
                bestT = t0 + d;
            }
        }
        if (best < kTrackRho) {
            endCall(slot);
            return;
        }
        float center, half;
        levelsFrom(bestT, s.pattern, true, center, half);
        if (half >= kMinHalfHz && half <= kMaxHalfHz) {
            s.center = center;
            s.half = half;
        }
        slice(bestT, 0, kBurstSymbols, s.center, s.half, bits);
        voiceBurst(slot, bestT, bits, true, s.pattern);
        return;
    }
    const int64_t ts = t0 + refine(t0, s.center, s.half, 3);
    slice(ts, 0, kBurstSymbols, s.center, s.half, bits);
    // Follow the levels (drifting carrier, fading) by the decided symbols.
    {
        const float scale = 3.f / s.half;
        double hi = 0, lo = 0;
        int nh = 0, nl = 0;
        for (int j = 0; j < kBurstSymbols; j++) {
            const float y = at(ts + static_cast<int64_t>(j - kSyncEnd) * kSps);
            const float l = levelOf((y - s.center) * scale);
            if (l == 3.f) {
                hi += y;
                nh++;
            } else if (l == -3.f) {
                lo += y;
                nl++;
            }
        }
        if (nh >= 8 && nl >= 8) {
            const float c = static_cast<float>((hi / nh + lo / nl) / 2), h = static_cast<float>((hi / nh - lo / nl) / 2);
            if (h >= kMinHalfHz && h <= kMaxHalfHz) {
                s.center += 0.5f * (c - s.center);
                s.half += 0.5f * (h - s.half);
            }
        }
    }
    voiceBurst(slot, ts, bits, false, s.pattern);
}

void DmrDecoder::voiceFrames(int slot, const uint8_t* bits)
{
    // Vocoder socket: VS(215)..VS(108) before the sync/EMB, VS(107)..VS(0)
    // after it; three 72-bit frames, the middle one split by the centre.
    uint8_t f[3][72];
    std::memcpy(f[0], bits, 72);
    std::memcpy(f[1], bits + 72, 36);
    std::memcpy(f[1] + 36, bits + 156, 36);
    std::memcpy(f[2], bits + 192, 72);
    Slot& s = *slots_[slot];
    for (auto& frame : f) {
        char fr[4][24];
        ambeDeinterleave(frame, fr);
#ifdef HRDAB_MBELIB
        float pcm[160];
        char ambe[49];
        char errText[64];
        int errs = 0, errs2 = 0;
        mbe_processAmbe3600x2450Framef(pcm, &errs, &errs2, errText, fr, ambe, &s.cur, &s.prev, &s.prevEnh, 3);
        s.frames++;
        s.errorBits += errs2;
        if (onAmbeFrame) onAmbeFrame(slot, ambe, errs2);
        for (float& v : pcm) v = std::max(-0.98f, std::min(0.98f, v * kAmbeGain));
        emitAudio(slot, pcm, 160);
#else
        s.frames++;
#endif
    }
}

void DmrDecoder::emitAudio(int slot, const float* pcm, int n)
{
    Slot& s = *slots_[slot];
    if (s.privacy || s.piHeader) return;  // encrypted: nothing to hear
    if (!s.confirmed) {
        // Held until the call is confirmed (or dropped).
        s.pending.insert(s.pending.end(), pcm, pcm + n);
        if (s.pending.size() > static_cast<size_t>(kMaxPending)) {
            s.pending.erase(s.pending.begin(), s.pending.end() - kMaxPending);
        }
        return;
    }
    // One slot at a time: the call that started first, until it ends.
    if (audioSlot_ < 0 || (audioSlot_ != slot && !slots_[audioSlot_]->voice)) audioSlot_ = slot;
    if (audioSlot_ == slot) fifoPush(pcm, n);
}

void DmrDecoder::fifoPush(const float* pcm, int n)
{
    for (int i = 0; i < n; i++) {
        if (fifoCount_ == static_cast<size_t>(kFifoSize)) {
            fifoRead_ = (fifoRead_ + 1) % kFifoSize;
            fifoCount_--;
        }
        fifo_[(fifoRead_ + fifoCount_) % kFifoSize] = pcm[i];
        fifoCount_++;
    }
}

bool DmrDecoder::pullAudio(float* out, int n)
{
    if (!playing_ && fifoCount_ >= static_cast<size_t>(kPrebuffer)) playing_ = true;
    int i = 0;
    if (playing_) {
        for (; i < n && fifoCount_ > 0; i++) {
            out[i] = fifo_[fifoRead_];
            fifoRead_ = (fifoRead_ + 1) % kFifoSize;
            fifoCount_--;
        }
        if (fifoCount_ == 0) playing_ = false;
    }
    const bool any = i > 0;
    for (; i < n; i++) out[i] = 0.f;
    return any;
}

void DmrDecoder::markValid(int pattern)
{
    if (t_ != validT_) prevValidT_ = validT_;
    validT_ = t_;
    source_ = pattern == 0 ? 1 : pattern == 1 ? 2 : 3;
}

bool DmrDecoder::recentlyValid(int ms, int count) const
{
    return t_ - (count >= 2 ? prevValidT_ : validT_) <= static_cast<int64_t>(ms) * (kRate / 1000);
}

DmrStatus DmrDecoder::status() const
{
    DmrStatus st;
    st.sync = recentlyValid(1000);
    st.source = source_;
    st.colorCode = colorCode_;
    st.audioSlot = audioSlot_;
#ifdef HRDAB_MBELIB
    st.voiceDecoder = true;
#endif
    for (int i = 0; i < 2; i++) {
        const Slot& s = *slots_[i];
        DmrSlotStatus& o = st.slots[i];
        o.active = s.voice && s.confirmed;
        o.callType = s.callType;
        o.src = s.src;
        o.dst = s.dst;
        o.alias = s.alias;
        o.encrypted = s.privacy || s.piHeader;
        o.emergency = s.emergency;
        o.errorRate = s.frames > 0 ? static_cast<float>(s.errorBits) / static_cast<float>(s.frames) : 0.f;
        o.secondsAgo = s.voiceT >= 0 ? static_cast<double>(t_ - s.voiceT) / kRate : -1;
    }
    return st;
}

std::string dmrStatusJson(const DmrStatus& st)
{
    JsonWriter w;
    w.beginObject()
        .str("type", "nbDmr")
        .boolean("sync", st.sync)
        .str("source", st.source == 1 ? "repeater" : st.source == 2 ? "radio" : st.source == 3 ? "direct" : "")
        .num("colorCode", st.colorCode)
        .num("audioSlot", st.audioSlot + 1)
        .boolean("voiceDecoder", st.voiceDecoder)
        .beginArray("slots");
    for (int i = 0; i < 2; i++) {
        const DmrSlotStatus& s = st.slots[i];
        w.beginObject()
            .num("slot", i + 1)
            .boolean("active", s.active)
            .str("callType", s.callType == 1 ? "group" : s.callType == 2 ? "private" : "")
            .num("src", static_cast<int64_t>(s.src))
            .num("dst", static_cast<int64_t>(s.dst))
            .str("alias", s.alias)
            .boolean("encrypted", s.encrypted)
            .boolean("emergency", s.emergency)
            .dbl("errorRate", s.errorRate, 2)
            .dbl("secondsAgo", s.secondsAgo, 1)
            .endObject();
    }
    w.endArray().endObject();
    return w.text();
}

} // namespace hrdab
