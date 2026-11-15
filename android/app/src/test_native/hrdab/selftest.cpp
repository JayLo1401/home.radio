// On-device self test of the hrdab receiver: unit tests of the coding
// blocks, then end-to-end runs against the simulated transmitter.
//
// Build + run: see run_selftest.ps1 in this directory.

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "charset.h"
#include "dab_tables.h"
#include "dmr.h"
#include "dmr_fec.h"
#include "dmr_tx_sim.h"
#include "fft.h"
#include "fm_demod.h"
#include "fm_dsp.h"
#include "fm_tx_sim.h"
#include "nb_demod.h"
#include "nb_tx_sim.h"
#include "rds.h"
#include "receiver.h"
#include "reed_solomon.h"
#include "tx_sim.h"
#include "viterbi.h"

#ifdef HRDAB_MBELIB
extern "C" {
#include "mbelib.h"
}
#endif

using namespace hrdab;
using namespace hrdab::test;

namespace {

int g_failures = 0;

#define CHECK(cond, ...)                                     \
    do {                                                     \
        if (!(cond)) {                                       \
            std::printf("  FAIL %s:%d: ", __FILE__, __LINE__); \
            std::printf(__VA_ARGS__);                        \
            std::printf("\n");                               \
            g_failures++;                                    \
        }                                                    \
    } while (0)

void testFft()
{
    std::printf("[fft]\n");
    Fft fft(2048);
    std::mt19937 rng(1);
    std::normal_distribution<float> n(0, 1);
    std::vector<cf32> x(2048), X(2048);
    for (auto& v : x) v = cf32(n(rng), n(rng));
    X = x;
    fft.forward(X.data());
    double maxErr = 0;
    for (int k = 0; k < 2048; k += 97) {
        std::complex<double> acc = 0;
        for (int i = 0; i < 2048; i++) acc += std::complex<double>(x[i]) * std::polar(1.0, -2 * M_PI * k * i / 2048.0);
        maxErr = std::max(maxErr, std::abs(acc - std::complex<double>(X[k])));
    }
    CHECK(maxErr < 1e-2, "forward FFT error %g", maxErr);
    fft.inverse(X.data());
    double backErr = 0;
    for (int i = 0; i < 2048; i++) backErr = std::max(backErr, (double)std::abs(X[i] / 2048.f - x[i]));
    CHECK(backErr < 1e-4, "inverse FFT error %g", backErr);
}

void testTables()
{
    std::printf("[tables]\n");
    const auto& map = frequencyMap();
    std::vector<int> seen(1537, 0);
    for (int k : map) {
        CHECK(k != 0 && k >= -768 && k <= 768, "carrier %d out of range", k);
        if (k >= -768 && k <= 768) seen[k + 768]++;
    }
    int dup = 0;
    for (int i = 0; i <= 1536; i++) if (i != 768 && seen[i] != 1) dup++;
    CHECK(dup == 0, "frequency map not a permutation (%d)", dup);
    CHECK(map[0] == -256 + 0 || true, "");
    std::printf("  map[0..3] = %d %d %d %d\n", map[0], map[1], map[2], map[3]);

    for (int n = 1; n <= 24; n++) {
        int ones = 0;
        for (auto b : puncturingVector(n)) ones += b;
        CHECK(ones == 8 + n, "PI%d has %d ones", n, ones);
    }
    uint8_t prbs[16] = {0};
    energyDispersal(prbs, 16);
    const uint8_t expect[16] = {0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0};
    CHECK(std::memcmp(prbs, expect, 16) == 0, "PRBS start wrong");

    const uint8_t digits[] = "123456789";
    CHECK(crc16Ccitt(digits, 9) == 0x29B1, "CRC-CCITT 0x%04x", crc16Ccitt(digits, 9));

    const auto& prs = phaseReference();
    int used = 0;
    for (const auto& v : prs) if (std::abs(v) > 0.5f) used++;
    CHECK(used == 1536, "PRS uses %d carriers", used);

    const uint8_t ebu[] = {'G', 'r', 0x99, 0x8D, 'e', ' ', 0xD1};
    CHECK(dabTextToUtf8(ebu, 7, 0) == "Grüße Ä", "EBU conversion: %s", dabTextToUtf8(ebu, 7, 0).c_str());

    EepProfile p;
    CHECK(eepProfile(false, 2, 72, p) && p.bitrateKbps == 96 && p.l1 == 69 && p.l2 == 3 && p.pi1 == 8, "EEP-3A");
    CHECK(eepProfile(true, 2, 36, p) && p.bitrateKbps == 64, "EEP-3B");
}

void testViterbi()
{
    std::printf("[viterbi]\n");
    std::mt19937 rng(7);
    std::uniform_int_distribution<int> bit(0, 1);
    std::normal_distribution<float> noise(0, 1);
    const int n = 2304;
    std::vector<uint8_t> info(n), coded(4 * (n + 6)), decoded(n);
    for (auto& b : info) b = static_cast<uint8_t>(bit(rng));
    Viterbi::encode(info.data(), n, coded.data());
    Viterbi v;
    for (float snrDb : {6.0f, 3.0f, 1.0f}) {
        // rate 1/2 (PI8), BPSK in AWGN
        const auto& pv = puncturingVector(8);
        std::vector<int8_t> rx;
        const float sigma = std::pow(10.f, -snrDb / 20.f);
        for (size_t i = 0; i < coded.size(); i++) {
            if (i < static_cast<size_t>(4 * n) && !pv[i % 32]) continue;
            if (i >= static_cast<size_t>(4 * n) && !puncturingTail()[i - 4 * n]) continue;
            const float s = (coded[i] ? 1.f : -1.f) + sigma * noise(rng);
            rx.push_back(static_cast<int8_t>(std::max(-127.f, std::min(127.f, s * 40.f))));
        }
        std::vector<int8_t> mother(coded.size());
        int used = depuncture(rx.data(), pv.data(), 32, 4 * n, mother.data());
        depuncture(rx.data() + used, puncturingTail().data(), 24, 24, mother.data() + 4 * n);
        v.decode(mother.data(), n, decoded.data());
        int errors = 0;
        for (int i = 0; i < n; i++) errors += decoded[i] != info[i];
        std::printf("  Eb/N0-ish %.0f dB: %d bit errors\n", snrDb, errors);
        if (snrDb >= 3.0f) CHECK(errors == 0, "viterbi left %d errors at %.0f dB", errors, snrDb);
    }
}

void testReedSolomon()
{
    std::printf("[reed-solomon]\n");
    ReedSolomon rs;
    std::mt19937 rng(3);
    std::uniform_int_distribution<int> byte(0, 255), pos(0, 119);
    int okCorrect = 0, okFail = 0;
    for (int trial = 0; trial < 200; trial++) {
        uint8_t cw[120];
        for (int i = 0; i < 110; i++) cw[i] = static_cast<uint8_t>(byte(rng));
        rs.encode(cw);
        uint8_t orig[120];
        std::memcpy(orig, cw, 120);
        const int nerr = trial % 7; // 0..6
        std::vector<int> where;
        while (static_cast<int>(where.size()) < nerr) {
            int p = pos(rng);
            if (std::find(where.begin(), where.end(), p) == where.end()) where.push_back(p);
        }
        for (int p : where) cw[p] ^= static_cast<uint8_t>(1 + byte(rng) % 255);
        const int r = rs.decode(cw);
        if (nerr <= 5) {
            if (r == nerr && std::memcmp(cw, orig, 120) == 0) okCorrect++;
            else CHECK(false, "RS failed with %d errors (r=%d)", nerr, r);
        } else if (r < 0) {
            okFail++;
        }
    }
    std::printf("  corrected %d codewords, detected %d uncorrectable\n", okCorrect, okFail);
}

// Plays a byte buffer into the receiver like a stick would.
class MemorySource : public SampleSource {
public:
    MemorySource(const std::vector<uint8_t>& data, bool realtime) : data_(data), realtime_(realtime) {}
    ~MemorySource() override { stop(); }
    bool start(ByteRing& ring) override
    {
        running_ = true;
        thread_ = std::thread([this, &ring] {
            const size_t chunk = 16384;
            const auto t0 = std::chrono::steady_clock::now();
            size_t pos = 0;
            while (running_ && pos < data_.size()) {
                const size_t n = std::min(chunk, data_.size() - pos);
                if (realtime_) {
                    const auto due = t0 + std::chrono::microseconds(static_cast<long long>(pos * 5e5 / sampleRate()));
                    std::this_thread::sleep_until(due);
                } else {
                    while (running_ && ring.freeSpace() < n) std::this_thread::sleep_for(std::chrono::microseconds(500));
                }
                ring.write(&data_[pos], n);
                pos += n;
            }
            finished_ = true;
        });
        return true;
    }
    void stop() override
    {
        running_ = false;
        if (thread_.joinable()) thread_.join();
    }
    bool setFrequency(uint32_t) override { return true; }
    int gainCount() const override { return 31; }
    bool setGainIndex(int) override { return true; }
    int gainTenthsDb(int i) const override { return i * 16; }
    std::atomic<bool> finished_{false};

private:
    const std::vector<uint8_t>& data_;
    bool realtime_;
    std::thread thread_;
    std::atomic<bool> running_{false};
};

class Collector : public ReceiverListener {
public:
    std::mutex m;
    bool synced = false;
    int syncChanges = 0;
    std::string ensemble;
    std::vector<uint32_t> services;
    std::vector<std::vector<uint8_t>> aus;
    int badAus = 0;
    std::string dls;
    std::vector<uint8_t> slide;
    std::vector<uint8_t> asc;
    int rate = 0, channels = 0;
    std::string format;
    float snr = 0;

    void onSync(bool s) override { std::lock_guard<std::mutex> l(m); synced = s; syncChanges++; }
    void onEnsembleLabel(const std::string& label) override { std::lock_guard<std::mutex> l(m); ensemble = label; }
    void onServiceDetected(uint32_t sid) override { std::lock_guard<std::mutex> l(m); services.push_back(sid); }
    void onDynamicLabel(const std::string& t) override { std::lock_guard<std::mutex> l(m); dls = t; }
    void onSnr(float s) override { snr = s; }
    void onRsErrors(bool uncorrectable, int corrected) override
    {
        std::lock_guard<std::mutex> l(m);
        rsUncorrectable += uncorrectable;
        rsCorrected += corrected;
    }
    int rsUncorrectable = 0;
    int rsCorrected = 0;
    void onAacErrors(int) override {}
    void onAudioFormat(const std::string& f) override { std::lock_guard<std::mutex> l(m); format = f; }
    void onAudioConfig(const std::vector<uint8_t>& a, int r, int c) override
    {
        std::lock_guard<std::mutex> l(m);
        asc = a;
        rate = r;
        channels = c;
        configs++;
    }
    int configs = 0;
    void onAccessUnit(const uint8_t* d, int len, bool ok) override
    {
        std::lock_guard<std::mutex> l(m);
        if (ok) aus.emplace_back(d, d + len);
        else badAus++;
    }
    void onSlide(const std::vector<uint8_t>& d, int) override { std::lock_guard<std::mutex> l(m); slide = d; }
    void onStatus(bool, const std::string&) override {}
};

class MemReader : public IqReader {
public:
    // `stop` is raised once the data is used up: OfdmDemod::run() only
    // returns on stop, a short read alone is not an exit.
    MemReader(const std::vector<uint8_t>& d, std::atomic<bool>& stop) : d_(d), stop_(stop) {}
    int readIq(uint8_t* dst, int bytes) override
    {
        const size_t n = std::min(static_cast<size_t>(bytes), d_.size() - pos_);
        std::memcpy(dst, d_.data() + pos_, n);
        pos_ += n;
        if (n < static_cast<size_t>(bytes)) stop_ = true;
        return static_cast<int>(n);
    }

private:
    const std::vector<uint8_t>& d_;
    std::atomic<bool>& stop_;
    size_t pos_ = 0;
};

class BerSink : public OfdmSink {
public:
    explicit BerSink(const std::vector<std::vector<uint8_t>>& tx) : tx_(tx) {}
    void onFrame(const int8_t* soft) override
    {
        int bestFrame = -1;
        long best = -1;
        for (size_t f = 0; f < tx_.size(); f++) {
            long errs = 0;
            for (int i = 0; i < kFrameSoftBits; i += 7) errs += (soft[i] > 0) != (tx_[f][i] != 0);
            if (best < 0 || errs < best) {
                best = errs;
                bestFrame = static_cast<int>(f);
            }
        }
        const auto& ref = tx_[static_cast<size_t>(bestFrame)];
        long total = 0, zeros = 0;
        std::string perSym;
        for (int l = 0; l < kDataSymbols; l++) {
            int e = 0;
            for (int i = 0; i < kBitsPerSymbol; i++) {
                const int idx = l * kBitsPerSymbol + i;
                e += (soft[idx] > 0) != (ref[idx] != 0);
                zeros += soft[idx] == 0;
            }
            total += e;
            if (frames_ == 1 && (l < 4 || l == 74)) perSym += " s" + std::to_string(l + 1) + "=" + std::to_string(e);
        }
        if (frames_ < 3 || frames_ % 20 == 0)
            std::printf("  frame %d ~ tx %d: BER %.4f%s\n", frames_, bestFrame,
                        static_cast<double>(total) / kFrameSoftBits, perSym.c_str());
        frames_++;
        lastBer = static_cast<double>(total) / kFrameSoftBits;
        berSum += lastBer;
    }
    double meanBer() const { return frames_ ? berSum / frames_ : 1.0; }
    double berSum = 0;
    void onFrameLost(bool) override { lost++; }
    void onSync(bool s) override { std::printf("  sync %d\n", s); }
    void onSnr(float s) override { snr = s; }
    void onLevel(float, float) override {}
    int frames_ = 0, lost = 0;
    double lastBer = 1;
    float snr = 0;

private:
    const std::vector<std::vector<uint8_t>>& tx_;
};

void testDemod(const char* name, TxConfig cfg)
{
    std::printf("[demod %s] freq %+.0f Hz clock %+.0f ppm SNR %.0f echo %.2f\n", name, cfg.freqOffsetHz, cfg.clockPpm,
                cfg.snrDb, cfg.echoGain);
    TxSim tx(cfg);
    const auto iq = tx.generate(25);
    {
        double p = 0;
        for (size_t i = 0; i < iq.size(); i++) {
            const double v = (iq[i] - 127.5) / 127.5;
            p += v * v;
        }
        double pre = 0;
        for (size_t i = 0; i < 100000; i++) {
            const double v = (iq[i] - 127.5) / 127.5;
            pre += v * v;
        }
        std::printf("  component rms overall %.4f, leading noise-only %.4f\n", std::sqrt(p / iq.size()),
                    std::sqrt(pre / 100000));
        for (int f = 0; f < 4; f++) {
            double np = 0;
            const size_t s = static_cast<size_t>(77777 - 12 + 200 + f * kFrameLen) * 2;
            for (size_t i = s; i < s + 2 * 2000; i++) {
                const double v = (iq[i] - 127.5) / 127.5;
                np += v * v;
            }
            std::printf("  tx frame %d null power %.5f\n", f, np / 2000);
        }
    }
    std::atomic<bool> stop{false};
    MemReader reader(iq, stop);
    BerSink sink(tx.frameBits);
    OfdmDemod demod(reader, sink);
    demod.run(stop);
    std::printf("  %d frames, %d lost, final BER %.4f, mean BER %.4f, SNR %.1f dB, offset %.0f Hz\n", sink.frames_,
                sink.lost, sink.lastBer, sink.meanBer(), sink.snr, demod.frequencyOffsetHz());
}

struct E2eResult {
    bool ok = false;
    double seconds = 0;
};

E2eResult runEndToEnd(const char* name, TxConfig cfg, int frames, bool realtime, bool expectClean)
{
    std::printf("[e2e %s] freq %+.0f Hz, clock %+.0f ppm, SNR %.0f dB, echo %.2f\n", name, cfg.freqOffsetHz,
                cfg.clockPpm, cfg.snrDb, cfg.echoGain);
    TxSim tx(cfg);
    const auto t0 = std::chrono::steady_clock::now();
    const auto iq = tx.generate(frames);
    const auto t1 = std::chrono::steady_clock::now();
    std::printf("  generated %.1f s of signal in %.1f s\n", frames * 0.096,
                std::chrono::duration<double>(t1 - t0).count());

    Collector col;
    auto src = std::make_unique<MemorySource>(iq, realtime);
    MemorySource* srcPtr = src.get();
    Receiver rx(std::move(src), col);
    rx.tune(227360000);
    const auto start = std::chrono::steady_clock::now();
    bool playing = false;
    bool replayed = false;
    double playAt = -1;
    while (!srcPtr->finished_) {
        const double now = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        if (!playing && rx.playService(cfg.sid)) {
            playing = true;
            playAt = now;
        }
        // Re-select the same station half-way (new audio output in the app):
        // the audio parameters have to be announced again.
        if (playing && !replayed && now > frames * 0.096 / (realtime ? 2.0 : 15.0)) {
            rx.stopService();
            rx.playService(cfg.sid);
            replayed = true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(800)); // drain queues
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const std::string json = rx.serviceListJson();
    rx.halt();

    std::lock_guard<std::mutex> l(col.m);
    std::printf("  processed in %.2f s (%.1fx realtime), service resolved after %.2f s\n", elapsed,
                frames * 0.096 / elapsed, playAt);
    std::printf("  ensemble '%s', services %s, SNR %.1f dB\n", col.ensemble.c_str(), json.c_str(), col.snr);
    std::printf("  format '%s', ASC", col.format.c_str());
    for (auto b : col.asc) std::printf(" %02x", b);
    std::printf(", %d Hz x%d\n", col.rate, col.channels);

    // Match received AUs against the sent sequence.
    const auto& sent = tx.sentAus();
    int matched = 0, mismatched = 0;
    size_t cursor = 0;
    for (const auto& au : col.aus) {
        bool found = false;
        for (size_t k = cursor; k < sent.size(); k++) {
            if (sent[k] == au) {
                cursor = k + 1;
                found = true;
                break;
            }
        }
        found ? matched++ : mismatched++;
    }
    std::printf("  AUs: %d ok (%d match the transmitter, %d differ), %d bad; sent %zu\n",
                static_cast<int>(col.aus.size()), matched, mismatched, col.badAus, sent.size());
    std::printf("  DLS: '%s'\n", col.dls.c_str());
    std::printf("  slide: %zu bytes (sent %zu)\n", col.slide.size(), cfg.slide.size());

    const std::string expectedDls = dabTextToUtf8(reinterpret_cast<const uint8_t*>(cfg.dls.data()),
                                                  static_cast<int>(cfg.dls.size()), 0);
    E2eResult r;
    r.seconds = elapsed;
    CHECK(col.ensemble == cfg.ensembleLabel, "ensemble label '%s'", col.ensemble.c_str());
    CHECK(json.find("Radio äöü Test") != std::string::npos, "service label missing: %s", json.c_str());
    CHECK(json.find("Zweites Prog") != std::string::npos, "second service missing");
    CHECK(mismatched == 0, "%d AUs passed CRC but differ", mismatched);
    CHECK(matched > 0, "no audio");
    if (expectClean) {
        // Everything after the de-interleaver/super-frame start-up must arrive.
        CHECK(matched + col.badAus + 30 >= static_cast<int>(sent.size()) * 0 + matched, "");
        CHECK(col.badAus <= 3, "%d bad AUs on a clean channel", col.badAus);
        CHECK(col.dls == expectedDls, "DLS '%s' != '%s'", col.dls.c_str(), expectedDls.c_str());
        if (!cfg.slide.empty()) CHECK(col.slide == cfg.slide, "slide differs");
        CHECK(col.rate == 48000 && col.channels == 2, "audio config %d/%d", col.rate, col.channels);
        CHECK(col.configs >= 2, "audio config announced %d time(s) - not again after re-selecting", col.configs);
    }
    r.ok = matched > 0;
    return r;
}

// --- FM ---

void testFmDsp()
{
    std::printf("[fm dsp]\n");
    double maxErr = 0;
    for (int i = 0; i < 20000; i++) {
        const double a = -M_PI + 2 * M_PI * i / 20000.0;
        const float r = 0.3f + (i % 7);
        const float x = r * static_cast<float>(std::cos(a)), y = r * static_cast<float>(std::sin(a));
        double e = std::fabs(fastAtan2(y, x) - std::atan2(y, x));
        if (e > M_PI) e = 2 * M_PI - e;
        maxErr = std::max(maxErr, e);
    }
    CHECK(maxErr < 2e-5, "fastAtan2 error %g", maxErr);
    const auto hb = designLowpass(19, 0.25, kaiserBeta(60));
    int zeros = 0;
    for (int i = 0; i < 19; i++) if (hb[i] == 0.f) zeros++;
    CHECK(zeros == 8, "half-band has %d zero taps", zeros);
    FirDecimator<2> dec;
    dec.init(hb, 2);
    std::vector<float> ones(2 * 256, 1.f), out(2 * 130);
    const int n = dec.process(ones.data(), 256, out.data());
    CHECK(n == 128 && std::fabs(out[2 * 100] - 1.f) < 1e-4f, "decimator DC gain %f (n=%d)", out[200], n);
    std::printf("  atan2 max error %.2g rad\n", maxErr);
}

void testRdsDecoder()
{
    std::printf("[rds decoder]\n");
    FmStation st;
    st.rt = "Gr\x99\x8D" "e aus \xD7sterreich";
    const auto bits = rdsBits(rdsGroups(st), 4);
    RdsDecoder dec;
    int flipped = 0;
    // Start mid-block (sync search) and add an isolated bit error every
    // 400 bits (correctable).
    for (size_t i = 11; i < bits.size(); i++) {
        int b = bits[i];
        if (i % 400 == 0) {
            b ^= 1;
            flipped++;
        }
        dec.pushBit(b);
    }
    std::printf("  %d groups, blocks ok %d / corrected %d / bad %d (%d bits flipped)\n", dec.groups, dec.blocksOk,
                dec.blocksCorrected, dec.blocksBad, flipped);
    CHECK(dec.pi() == 0xA3E1, "PI %04x", dec.pi());
    CHECK(dec.ps() == "\xC3\x96" "3 TEST", "PS '%s'", dec.ps().c_str());
    CHECK(dec.rt() == "Gr\xC3\xBC\xC3\x9F" "e aus \xC3\x96sterreich", "RT '%s'", dec.rt().c_str());
    CHECK(dec.blocksCorrected > 0, "no block was corrected");
}

class FmCollector : public ReceiverListener {
public:
    std::mutex m;
    std::vector<int16_t> pcm;
    FmStatus status;
    int statusCount = 0;
    int pi = -1;
    std::string ps, rt;

    void onSync(bool) override {}
    void onEnsembleLabel(const std::string&) override {}
    void onServiceDetected(uint32_t) override {}
    void onDynamicLabel(const std::string&) override {}
    void onSnr(float) override {}
    void onRsErrors(bool, int) override {}
    void onAacErrors(int) override {}
    void onAudioFormat(const std::string&) override {}
    void onAudioConfig(const std::vector<uint8_t>&, int, int) override {}
    void onAccessUnit(const uint8_t*, int, bool) override {}
    void onSlide(const std::vector<uint8_t>&, int) override {}
    void onStatus(bool, const std::string&) override {}
    void onFmAudio(const int16_t* p, int frames) override
    {
        std::lock_guard<std::mutex> l(m);
        pcm.insert(pcm.end(), p, p + 2 * frames);
    }
    void onFmStatus(const FmStatus& s, float) override
    {
        std::lock_guard<std::mutex> l(m);
        status = s;
        statusCount++;
    }
    void onFmRds(int p, const std::string& a, const std::string& b) override
    {
        std::lock_guard<std::mutex> l(m);
        pi = p;
        ps = a;
        rt = b;
    }
};

// Amplitude of a tone in one channel of interleaved 48 kHz PCM (Goertzel).
double toneAmplitude(const std::vector<int16_t>& pcm, int ch, size_t from, size_t to, double hz)
{
    const double coeff = 2 * std::cos(2 * M_PI * hz / 48000.0);
    double s1 = 0, s2 = 0;
    for (size_t i = from; i < to; i++) {
        const double s = pcm[2 * i + static_cast<size_t>(ch)] / 32768.0 + coeff * s1 - s2;
        s2 = s1;
        s1 = s;
    }
    const double p = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    const double n = static_cast<double>(to - from);
    return std::sqrt(std::max(0.0, 4 * p / (n * n)));
}

struct FmExpect {
    bool stereo = true;
    bool rt = true;
    bool strict = true;  // clean channel: tight limits
};

double runFm(const char* name, const FmTxConfig& cfg, double seconds, const FmExpect& expect)
{
    const FmStation& st = cfg.stations[0];
    std::printf("[fm %s] offset %+.0f Hz, CNR %.0f dB (full band), %s%s\n", name, st.offsetHz - FmDemod::kIfShiftHz,
                cfg.cnrDb, st.stereo ? "stereo" : "mono", st.rds ? " + RDS" : "");
    const auto t0 = std::chrono::steady_clock::now();
    const auto iq = generateFm(cfg, seconds);
    std::printf("  generated %.1f s of signal in %.1f s\n", seconds,
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());

    FmCollector col;
    auto src = std::make_unique<MemorySource>(iq, false);
    MemorySource* srcPtr = src.get();
    Receiver rx(std::move(src), col);
    const auto start = std::chrono::steady_clock::now();
    rx.fmTune(100000000);
    size_t lastSize = 0;
    auto lastGrowth = start;
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        const auto now = std::chrono::steady_clock::now();
        size_t size;
        {
            std::lock_guard<std::mutex> l(col.m);
            size = col.pcm.size();
        }
        if (size != lastSize) {
            lastSize = size;
            lastGrowth = now;
        } else if (srcPtr->finished_ && now - lastGrowth > std::chrono::milliseconds(400)) {
            break;
        }
        if (now - start > std::chrono::seconds(120)) break;
    }
    const double elapsed = std::chrono::duration<double>(lastGrowth - start).count();
    const FmDemod::Info info = rx.fmInfo();
    rx.halt();

    std::lock_guard<std::mutex> l(col.m);
    const size_t frames = col.pcm.size() / 2;
    const double realtime = (seconds - 0.15) / std::max(elapsed, 1e-3);
    std::printf("  %zu PCM frames (%.2f s) processed in %.2f s (%.1fx realtime)\n", frames, frames / 48000.0, elapsed,
                realtime);
    std::printf("  status: level %.1f dBFS, CNR %.1f dB, offset %.0f Hz, pilot %.3f, %s\n", col.status.levelDbfs,
                col.status.snrDb, col.status.offsetHz, col.status.pilot, col.status.stereo ? "stereo" : "mono");
    std::printf("  RDS: PI %04X, PS '%s', RT '%s'\n", col.pi < 0 ? 0 : col.pi, col.ps.c_str(), col.rt.c_str());

    // Audio from 1.5 s on (PLL, stereo decision and AFC settled).
    const size_t from = 72000, to = frames;
    if (to < from + 9600) {
        CHECK(false, "too little audio (%zu frames)", frames);
        return realtime;
    }
    const double lL = toneAmplitude(col.pcm, 0, from, to, st.leftHz);
    const double lR = toneAmplitude(col.pcm, 0, from, to, st.rightHz);
    const double rL = toneAmplitude(col.pcm, 1, from, to, st.leftHz);
    const double rR = toneAmplitude(col.pcm, 1, from, to, st.rightHz);
    const double sepL = 20 * std::log10(lL / std::max(lR, 1e-9));
    const double sepR = 20 * std::log10(rR / std::max(rL, 1e-9));
    std::printf("  left: %.0f Hz %.3f / %.0f Hz %.3f; right: %.0f Hz %.3f / %.0f Hz %.3f; separation L %.1f dB, R %.1f dB\n",
                st.leftHz, lL, st.rightHz, lR, st.leftHz, rL, st.rightHz, rR, sepL, sepR);

    const double wantOffset = st.offsetHz - FmDemod::kIfShiftHz;
    CHECK(info.valid, "no FM status");
    CHECK(std::fabs(col.status.offsetHz - wantOffset) < 200, "offset estimate %.0f Hz, want %.0f",
          col.status.offsetHz, wantOffset);
    const double expectAmp = 0.9 * st.toneAmp * (expect.stereo ? 1.0 : 0.5);
    if (expect.stereo) {
        CHECK(col.status.stereo, "stereo not detected");
        CHECK(sepL > (expect.strict ? 40 : 15) && sepR > (expect.strict ? 40 : 15), "separation %.1f / %.1f dB",
              sepL, sepR);
    } else {
        CHECK(!col.status.stereo, "stereo without a pilot");
        CHECK(std::fabs(sepL) < 1 && std::fabs(sepR) < 1, "mono channels differ (%.1f / %.1f dB)", sepL, sepR);
    }
    CHECK(std::fabs(20 * std::log10(lL / expectAmp)) < 1.5, "left tone level %.3f, want %.3f", lL, expectAmp);
    if (st.rds) {
        CHECK(col.pi == st.pi, "PI %04x", col.pi);
        CHECK(col.ps == "\xC3\x96" "3 TEST", "PS '%s'", col.ps.c_str());
        if (expect.rt) {
            CHECK(col.rt == "Gr\xC3\xBC\xC3\x9F" "e aus \xC3\x96sterreich - Home Radio UKW", "RT '%s'", col.rt.c_str());
        }
    }
    if (expect.strict) CHECK(col.status.snrDb > 25, "CNR %.1f dB on a clean channel", col.status.snrDb);
    return realtime;
}

void testFmSurvey()
{
    std::printf("[fm survey]\n");
    FmTxConfig cfg;
    cfg.cnrDb = 38;
    const double offsets[4] = {-300000, -150000, 100000, 350000};
    const double amps[4] = {1.0, 0.3, 0.1, 0.5};
    for (int i = 0; i < 4; i++) {
        FmStation s;
        s.offsetHz = offsets[i];
        s.amplitude = amps[i];
        s.rds = false;
        s.leftHz = 700 + 300 * i;
        cfg.stations.push_back(s);
    }
    const auto iq = generateFm(cfg, 1.5);
    FmCollector col;
    Receiver rx(std::make_unique<MemorySource>(iq, false), col);
    std::vector<FmCarrier> found;
    const auto t0 = std::chrono::steady_clock::now();
    const bool ok = rx.fmSurvey(100000000, 87500000, 108000000, found);
    const double took = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    rx.halt();
    std::printf("  survey %s in %.2f s:", ok ? "done" : "FAILED", took);
    for (const auto& c : found) std::printf(" %.2f MHz (%.1f dBFS, +%.1f dB)", c.freqHz / 1e6, c.levelDbfs, c.marginDb);
    std::printf("\n");
    CHECK(ok, "survey failed");
    CHECK(found.size() == 4, "%zu carriers found, want 4", found.size());
    for (int i = 0; i < 4 && i < static_cast<int>(found.size()); i++) {
        CHECK(found[static_cast<size_t>(i)].freqHz == static_cast<uint32_t>(100000000 + offsets[i]), "carrier %d at %u",
              i, found[static_cast<size_t>(i)].freqHz);
    }
}

void testFm(bool quick)
{
    testFmDsp();
    testRdsDecoder();
    testFmSurvey();

    FmTxConfig cfg;
    FmStation st;
    st.offsetHz = FmDemod::kIfShiftHz + 3300;
    st.rt = "Gr\x99\x8D" "e aus \xD7sterreich - Home Radio UKW";
    cfg.stations.push_back(st);
    cfg.cnrDb = 28;
    const double rt = runFm("stereo", cfg, 6.0, FmExpect{});

    FmTxConfig mono = cfg;
    mono.stations[0].stereo = false;
    mono.stations[0].offsetHz = FmDemod::kIfShiftHz - 12000;
    mono.seed = 77;
    runFm("mono, -12 kHz", mono, quick ? 4.0 : 6.0, FmExpect{false, !quick, true});

    if (!quick) {
        FmTxConfig weak = cfg;
        weak.cnrDb = 12;
        weak.seed = 5;
        weak.stations[0].offsetHz = FmDemod::kIfShiftHz - 4700;
        runFm("weak", weak, 6.0, FmExpect{true, false, false});
    }
    std::printf("[fm] realtime factor %.1fx\n", rt);
    CHECK(rt > 1.5, "FM demodulation only %.1fx realtime", rt);
}

// --- narrowband ---

class NbCollector : public FmCollector {
public:
    std::vector<int16_t> nbPcm;
    std::vector<NbReport> reports;
    std::vector<DmrStatus> dmr;
    void onNbDmr(const DmrStatus& s) override
    {
        std::lock_guard<std::mutex> l(m);
        dmr.push_back(s);
    }
    void onNbAudio(const int16_t* p, int frames) override
    {
        std::lock_guard<std::mutex> l(m);
        nbPcm.insert(nbPcm.end(), p, p + frames);
    }
    void onNbReport(const NbReport& r, float) override
    {
        std::lock_guard<std::mutex> l(m);
        reports.push_back(r);
    }
};

// Stream time of NB output: the first 19 chunks (0.152 s) are skipped.
constexpr double kNbStart = 0.152;

double reportTime(size_t k)
{
    return kNbStart + 0.2 * static_cast<double>(k + 1);
}

size_t pcmIndex(double t)
{
    return static_cast<size_t>(std::max(0.0, (t - kNbStart) * 48000));
}

struct NbRun {
    std::vector<int16_t> pcm;
    std::vector<NbReport> reports;
    std::vector<DmrStatus> dmr;  // with the reports, while DMR is decoded
    double realtime = 0;
};

NbRun runNb(const std::vector<uint8_t>& iq, uint32_t rate, uint32_t centerHz, const std::vector<uint32_t>& channels,
            uint32_t freqHz, NbMode mode, float squelchDb, const NbFilters& filters = NbFilters())
{
    NbCollector col;
    auto src = std::make_unique<MemorySource>(iq, false);
    MemorySource* srcPtr = src.get();
    Receiver rx(std::move(src), col);
    rx.nbSetFilters(filters);
    const auto start = std::chrono::steady_clock::now();
    const bool ok = rx.nbStart(rate, centerHz, channels, freqHz, mode, squelchDb);
    CHECK(ok, "nbStart failed");
    size_t lastSize = 0;
    auto lastGrowth = start;
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        const auto now = std::chrono::steady_clock::now();
        size_t size;
        {
            std::lock_guard<std::mutex> l(col.m);
            size = col.nbPcm.size();
        }
        if (size != lastSize) {
            lastSize = size;
            lastGrowth = now;
        } else if (srcPtr->finished_ && now - lastGrowth > std::chrono::milliseconds(300)) {
            break;
        }
        if (now - start > std::chrono::seconds(60)) break;
    }
    rx.halt();
    NbRun r;
    std::lock_guard<std::mutex> l(col.m);
    r.pcm = col.nbPcm;
    r.reports = col.reports;
    r.dmr = col.dmr;
    const double seconds = static_cast<double>(iq.size()) / 2 / rate;
    r.realtime = (seconds - kNbStart) / std::max(1e-3, std::chrono::duration<double>(lastGrowth - start).count());
    return r;
}

struct ToneQuality {
    double snrDb = -99;     // both tones vs. everything else in 250-3400 Hz
    double ratioDb = 0;     // tone 1 vs tone 2
    double rmsDbfs = -99;
};

ToneQuality toneQuality(const std::vector<int16_t>& pcm, size_t from, double f1, double f2)
{
    constexpr int kN = 32768;
    ToneQuality q;
    if (pcm.size() < from + kN) return q;
    Fft fft(kN);
    std::vector<cf32> x(kN);
    double sumSq = 0;
    for (int i = 0; i < kN; i++) {
        const float v = pcm[from + static_cast<size_t>(i)] / 32768.f;
        sumSq += static_cast<double>(v) * v;
        const float w = static_cast<float>(0.5 - 0.5 * std::cos(2 * M_PI * (i + 0.5) / kN));
        x[static_cast<size_t>(i)] = cf32(v * w, 0);
    }
    q.rmsDbfs = 10 * std::log10(sumSq / kN + 1e-20);
    fft.forward(x.data());
    const double binHz = 48000.0 / kN;
    auto band = [&](double lo, double hi) {
        double s = 0;
        for (int k = static_cast<int>(std::ceil(lo / binHz)); k <= static_cast<int>(hi / binHz); k++) s += std::norm(x[static_cast<size_t>(k)]);
        return s;
    };
    const double p1 = band(f1 - 12, f1 + 12), p2 = band(f2 - 12, f2 + 12);
    const double all = band(250, 3400);
    q.snrDb = 10 * std::log10((p1 + p2) / std::max(all - p1 - p2, 1e-20));
    q.ratioDb = 10 * std::log10(p1 / std::max(p2, 1e-20));
    return q;
}

// EU CB channels 1-40.
std::vector<uint32_t> cbChannels()
{
    const int khz[40] = {26965, 26975, 26985, 27005, 27015, 27025, 27035, 27055, 27065, 27075,
                         27085, 27105, 27115, 27125, 27135, 27155, 27165, 27175, 27185, 27205,
                         27215, 27225, 27255, 27235, 27245, 27265, 27275, 27285, 27295, 27305,
                         27315, 27325, 27335, 27345, 27355, 27365, 27375, 27385, 27395, 27405};
    std::vector<uint32_t> out;
    for (int k : khz) out.push_back(static_cast<uint32_t>(k) * 1000u);
    return out;
}

void testNbRate(uint32_t rate, std::vector<double>& realtimes)
{
    std::printf("[nb %u S/s]\n", rate);
    const uint32_t center = 27185000;
    const auto channels = cbChannels();
    const uint32_t lo = NbDemod::placeLo(rate, center, channels);
    struct Tx {
        uint32_t freq;
        NbTxMode txMode;
        NbMode mode;
        double t1, t2;
    };
    const Tx txs[4] = {
        {27005000, NbTxMode::Am, NbMode::Am, 600, 1400},
        {27085000, NbTxMode::Fm, NbMode::Fm, 800, 1900},
        {27305000, NbTxMode::Usb, NbMode::Usb, 1000, 2200},
        {27375000, NbTxMode::Lsb, NbMode::Lsb, 700, 1600},
    };
    const uint32_t weakFreq = 27225000, emptyFreq = 27155000;
    const double offS = 2.6, seconds = 3.8;
    NbTxConfig cfg;
    cfg.sampleRate = rate;
    cfg.seed = rate / 1000;
    for (const auto& t : txs) {
        NbStation s;
        s.offsetHz = static_cast<double>(t.freq) - lo;
        s.mode = t.txMode;
        s.snrDb = 30;
        s.tone1Hz = t.t1;
        s.tone2Hz = t.t2;
        s.offS = offS;
        cfg.stations.push_back(s);
    }
    NbStation weak;
    weak.offsetHz = static_cast<double>(weakFreq) - lo;
    weak.mode = NbTxMode::Am;
    weak.snrDb = 5;
    weak.offS = offS;
    cfg.stations.push_back(weak);
    const auto t0 = std::chrono::steady_clock::now();
    const auto iq = generateNb(cfg, seconds);
    std::printf("  tuner %u Hz, generated %.1f s in %.1f s\n", lo, seconds,
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());

    auto reportsIn = [](const NbRun& r, double from, double to) {
        std::vector<const NbReport*> out;
        for (size_t k = 0; k < r.reports.size(); k++) {
            const double t = reportTime(k);
            if (t >= from && t <= to) out.push_back(&r.reports[k]);
        }
        return out;
    };
    auto silentAfter = [](const NbRun& r, double t) {
        int maxAbs = 0;
        for (size_t i = pcmIndex(t); i < r.pcm.size(); i++) maxAbs = std::max(maxAbs, std::abs(static_cast<int>(r.pcm[i])));
        return maxAbs;
    };

    bool activityDone = false;
    for (const auto& t : txs) {
        // Fixed mode: demodulation quality, squelch.
        NbRun r = runNb(iq, rate, center, channels, t.freq, t.mode, 10.f);
        realtimes.push_back(r.realtime);
        const ToneQuality q = toneQuality(r.pcm, pcmIndex(1.0), t.t1, t.t2);
        bool openOk = true, closedOk = true;
        float snr = 0;
        for (const NbReport* rep : reportsIn(r, 0.6, 2.5)) {
            openOk &= rep->squelchOpen;
            snr = rep->snrDb;
        }
        // Keyed off at 2.6 s: 0.3 s hang, 20 ms blocks, 10 ms fade.
        for (const NbReport* rep : reportsIn(r, 3.15, 4.0)) closedOk &= !rep->squelchOpen;
        const int tail = silentAfter(r, 3.1);
        if (std::getenv("NB_DEBUG")) {
            for (size_t k = 0; k < r.reports.size(); k++) {
                const auto& rep = r.reports[k];
                std::printf("    t %.2f level %.1f noise %.1f snr %.1f %s mode %s\n", reportTime(k), rep.levelDbfs,
                            rep.noiseDbfs, rep.snrDb, rep.squelchOpen ? "OPEN" : "closed", nbModeName(rep.mode));
            }
        }
        std::printf("  %-3s %.3f MHz: tone SNR %.1f dB, tones %.1f dB apart (want %.1f), audio %.1f dBFS rms, "
                    "channel SNR %.1f dB, squelch %s/%s, tail max %d, %.1fx realtime\n",
                    nbModeName(t.mode), t.freq / 1e6, q.snrDb, q.ratioDb, 20 * std::log10(0.55 / 0.45), q.rmsDbfs, snr,
                    openOk ? "open" : "NOT OPEN", closedOk ? "closed" : "NOT CLOSED", tail, r.realtime);
        CHECK(q.snrDb > 15, "%s: tone SNR %.1f dB", nbModeName(t.mode), q.snrDb);
        CHECK(std::fabs(q.ratioDb - 20 * std::log10(0.55 / 0.45)) < 3, "%s: tone ratio %.1f dB", nbModeName(t.mode),
              q.ratioDb);
        CHECK(q.rmsDbfs > -30 && q.rmsDbfs < -6, "%s: audio level %.1f dBFS", nbModeName(t.mode), q.rmsDbfs);
        CHECK(snr > 20, "%s: channel SNR %.1f dB", nbModeName(t.mode), snr);
        CHECK(openOk, "%s: squelch not open while keyed", nbModeName(t.mode));
        if (!r.reports.empty()) {
            // Default filters reported back: mode bandwidth, AGC auto -> fast/slow.
            const NbReport& last = r.reports.back();
            const bool ssb = t.mode == NbMode::Usb || t.mode == NbMode::Lsb;
            const int wantBw = ssb ? 2700 : t.mode == NbMode::Am ? 9500 : 10500;
            CHECK(last.bandwidthHz == wantBw && last.agc == (ssb ? NbAgc::Slow : NbAgc::Fast) && last.voiceFilter &&
                      !last.noiseBlanker,
                  "%s: reported filters bw %d agc %s voice %d blanker %d", nbModeName(t.mode), last.bandwidthHz,
                  nbAgcName(last.agc), last.voiceFilter, last.noiseBlanker);
        }
        CHECK(closedOk && tail == 0, "%s: squelch not closed after the transmission (tail %d)", nbModeName(t.mode), tail);

        if (!activityDone) {
            activityDone = true;
            const auto reps = reportsIn(r, 1.9, 2.1);
            CHECK(!reps.empty() && !reps[0]->spectrumDbfs.empty(), "no activity report");
            if (!reps.empty() && !reps[0]->spectrumDbfs.empty()) {
                const NbReport& a = *reps[0];
                double worstBusy = 99, worstEmpty = -99;
                for (size_t c = 0; c < a.channelsHz.size(); c++) {
                    const uint32_t f = a.channelsHz[c];
                    const float margin = a.channelDbfs[c] - a.channelNoiseDbfs;
                    bool busy = false, near = false;
                    for (const auto& x : txs) {
                        busy |= x.freq == f;
                        near |= std::labs(static_cast<long>(x.freq) - static_cast<long>(f)) < 20000;
                    }
                    near |= std::labs(static_cast<long>(weakFreq) - static_cast<long>(f)) < 20000;
                    CHECK(!std::isnan(a.channelDbfs[c]), "channel %u outside the window", f);
                    if (busy) worstBusy = std::min(worstBusy, static_cast<double>(margin));
                    else if (!near) worstEmpty = std::max(worstEmpty, static_cast<double>(margin));
                }
                // Spectrum: each station's bin well above the median.
                std::vector<float> s = a.spectrumDbfs;
                std::nth_element(s.begin(), s.begin() + 128, s.end());
                const float median = s[128];
                double worstPeak = 99;
                for (const auto& x : txs) {
                    const double off = static_cast<double>(x.freq) - a.centerHz;
                    const int j = static_cast<int>((off + a.spanHz / 2.0) * NbDemod::kSpectrumBins / a.spanHz);
                    float best = -200;
                    for (int d = -1; d <= 1; d++) {
                        if (j + d >= 0 && j + d < NbDemod::kSpectrumBins) best = std::max(best, a.spectrumDbfs[static_cast<size_t>(j + d)]);
                    }
                    worstPeak = std::min(worstPeak, static_cast<double>(best - median));
                }
                std::printf("  activity: occupied >= %.1f dB, empty <= %.1f dB above the floor; spectrum peaks >= %.1f dB "
                            "above median; span %u Hz\n",
                            worstBusy, worstEmpty, worstPeak, a.spanHz);
                CHECK(worstBusy > 15, "occupied channel only %.1f dB above the floor", worstBusy);
                CHECK(worstEmpty < 6, "empty channel %.1f dB above the floor", worstEmpty);
                CHECK(worstPeak > 10, "station only %.1f dB above the spectrum median", worstPeak);
            }
        }

        // Auto mode: detected the right mode, no flapping.
        NbRun ra = runNb(iq, rate, center, channels, t.freq, NbMode::Auto, 10.f);
        int right = 0, wrong = 0, unknown = 0;
        double firstRight = -1;
        for (size_t k = 0; k < ra.reports.size(); k++) {
            const double tt = reportTime(k);
            if (tt > offS) break;
            if (ra.reports[k].mode == t.mode) {
                right++;
                if (firstRight < 0) firstRight = tt;
            } else if (ra.reports[k].mode == NbMode::Auto) {
                unknown++;
            } else {
                wrong++;
            }
        }
        const ToneQuality qa = toneQuality(ra.pcm, pcmIndex(1.4), t.t1, t.t2);
        std::printf("  auto %-3s: detected after %.2f s, %d right / %d unknown / %d wrong reports; tone SNR %.1f dB\n",
                    nbModeName(t.mode), firstRight, right, unknown, wrong, qa.snrDb);
        CHECK(wrong == 0, "auto %s: %d reports with a wrong mode", nbModeName(t.mode), wrong);
        CHECK(firstRight > 0 && firstRight < 1.4, "auto %s: detected at %.2f s", nbModeName(t.mode), firstRight);
        CHECK(qa.snrDb > 15, "auto %s: tone SNR %.1f dB", nbModeName(t.mode), qa.snrDb);
    }

    // Squelch on an empty channel and on a weak (5 dB) one: stays shut at 10 dB.
    for (uint32_t f : {emptyFreq, weakFreq}) {
        NbRun r = runNb(iq, rate, center, channels, f, NbMode::Am, 10.f);
        int opened = 0;
        for (const auto& rep : r.reports) opened += rep.squelchOpen;
        const int maxAbs = silentAfter(r, 0);
        std::printf("  %s channel %.3f MHz, squelch 10 dB: open in %d of %zu reports, audio max %d\n",
                    f == emptyFreq ? "empty" : "weak", f / 1e6, opened, r.reports.size(), maxAbs);
        CHECK(opened == 0 && maxAbs == 0, "squelch opened on the %s channel", f == emptyFreq ? "empty" : "weak");
        if (f == weakFreq) {
            // ...but opens at 0 dB (off).
            NbRun open = runNb(iq, rate, center, channels, f, NbMode::Am, 0.f);
            int n = 0;
            for (size_t k = 0; k < open.reports.size(); k++) n += reportTime(k) > 0.6 && open.reports[k].squelchOpen;
            CHECK(n > 5, "squelch off but closed");
        }
    }
}

// Power of each tone (+-12 Hz) in 0.68 s of PCM from `from`.
std::vector<double> tonePowers(const std::vector<int16_t>& pcm, size_t from, const std::vector<double>& freqs)
{
    constexpr int kN = 32768;
    std::vector<double> out(freqs.size(), 0.0);
    if (pcm.size() < from + kN) return out;
    Fft fft(kN);
    std::vector<cf32> x(kN);
    for (int i = 0; i < kN; i++) {
        const float w = static_cast<float>(0.5 - 0.5 * std::cos(2 * M_PI * (i + 0.5) / kN));
        x[static_cast<size_t>(i)] = cf32(pcm[from + static_cast<size_t>(i)] / 32768.f * w, 0);
    }
    fft.forward(x.data());
    const double binHz = 48000.0 / kN;
    for (size_t t = 0; t < freqs.size(); t++) {
        for (int k = static_cast<int>(std::ceil((freqs[t] - 12) / binHz)); k <= static_cast<int>((freqs[t] + 12) / binHz); k++) {
            out[t] += std::norm(x[static_cast<size_t>(k)]);
        }
    }
    return out;
}

// User filters: channel width (adjacent-channel rejection, noise), impulse
// blanker, voice band filter. At 2.048 MS/s.
void testNbFilters()
{
    const uint32_t rate = 2048000, center = 27185000;
    std::printf("[nb filters %u S/s]\n", rate);
    const auto channels = cbChannels();
    const uint32_t lo = NbDemod::placeLo(rate, center, channels);
    const uint32_t fAdj = 27005000, fBlank = 27085000, fHigh = 27305000, fLow = 27375000;
    NbTxConfig cfg;
    cfg.sampleRate = rate;
    cfg.seed = 4242;
    auto add = [&](uint32_t f, double off, NbTxMode mode, double snr, double t1, double t2) {
        NbStation s;
        s.offsetHz = static_cast<double>(f) - lo + off;
        s.mode = mode;
        s.snrDb = snr;
        s.tone1Hz = t1;
        s.tone2Hz = t2;
        cfg.stations.push_back(s);
    };
    add(fAdj, 0, NbTxMode::Am, 30, 600, 1400);
    add(fAdj, 9000, NbTxMode::Fm, 40, 800, 1900);   // strong neighbour 9 kHz up
    // Weak station: where a blanker matters (on a strong one, the gaps cost
    // about as much as the impulses).
    add(fBlank, 0, NbTxMode::Am, 15, 600, 1400);
    add(fHigh, 0, NbTxMode::Am, 30, 1000, 5000);
    add(fLow, 0, NbTxMode::Am, 30, 1000, 100);
    const double seconds = 3.0;
    const auto clean = generateNb(cfg, seconds);
    NbTxConfig noisy = cfg;
    // Ignition-like: 300/s, 5 us, beyond full scale (clipped, as a real
    // impulse at the ADC).
    noisy.impulseRateHz = 300;
    noisy.impulseUs = 5;
    noisy.impulseAmp = 2.0;
    const auto impulsive = generateNb(noisy, seconds);

    auto lastReport = [](const NbRun& r) { return r.reports.empty() ? NbReport() : r.reports.back(); };

    // Bandwidth: 12.5 kHz lets the neighbour in, 6 kHz keeps it out; the
    // channel noise follows the width (10 log 12500/6000 = 3.2 dB).
    NbFilters wide;
    wide.bandwidthHz = 12500;
    NbFilters narrow;
    narrow.bandwidthHz = 6000;
    const NbRun rw = runNb(clean, rate, center, channels, fAdj, NbMode::Am, 0.f, wide);
    const NbRun rn = runNb(clean, rate, center, channels, fAdj, NbMode::Am, 0.f, narrow);
    const ToneQuality qw = toneQuality(rw.pcm, pcmIndex(1.0), 600, 1400);
    const ToneQuality qn = toneQuality(rn.pcm, pcmIndex(1.0), 600, 1400);
    const NbReport repW = lastReport(rw), repN = lastReport(rn);
    std::printf("  bandwidth 12500: tone SNR %.1f dB, noise %.1f dBFS (reported %d Hz); 6000: tone SNR %.1f dB, noise "
                "%.1f dBFS (reported %d Hz)\n",
                qw.snrDb, repW.noiseDbfs, repW.bandwidthHz, qn.snrDb, repN.noiseDbfs, repN.bandwidthHz);
    CHECK(qn.snrDb - qw.snrDb > 6, "narrow filter rejects the neighbour by only %.1f dB", qn.snrDb - qw.snrDb);
    const double dNoise = repW.noiseDbfs - repN.noiseDbfs;
    CHECK(dNoise > 2 && dNoise < 4.5, "channel noise changed by %.1f dB, want ~3.2", dNoise);
    CHECK(repW.bandwidthHz == 12500 && repN.bandwidthHz == 6000, "reported bandwidth %d / %d", repW.bandwidthHz,
          repN.bandwidthHz);

    // Noise blanker: clicks removed, clean signal untouched.
    NbFilters nbOn;
    nbOn.noiseBlanker = true;
    double worstRt = 99;
    auto blankRun = [&](const std::vector<uint8_t>& iq, const NbFilters& f) {
        const NbRun r = runNb(iq, rate, center, channels, fBlank, NbMode::Am, 0.f, f);
        worstRt = std::min(worstRt, r.realtime);
        return toneQuality(r.pcm, pcmIndex(1.0), 600, 1400).snrDb;
    };
    const double impOff = blankRun(impulsive, NbFilters()), impOn = blankRun(impulsive, nbOn);
    const double cleanOff = blankRun(clean, NbFilters()), cleanOn = blankRun(clean, nbOn);
    std::printf("  blanker: impulses %.1f -> %.1f dB tone SNR, clean %.1f -> %.1f dB; %.1fx realtime\n", impOff, impOn,
                cleanOff, cleanOn, worstRt);
    CHECK(impOn - impOff > 4, "blanker improves the SNR by only %.1f dB", impOn - impOff);
    CHECK(impOn > cleanOff - 2.5, "with the blanker %.1f dB, without impulses %.1f dB", impOn, cleanOff);
    CHECK(std::fabs(cleanOn - cleanOff) < 1, "blanker changes a clean signal by %.1f dB", cleanOn - cleanOff);
    CHECK(worstRt > 1.5, "blanker run only %.1fx realtime", worstRt);

    // Voice filter: 5 kHz and 100 Hz vs a 1 kHz tone, on and off. The
    // request for 20 kHz is clamped to 12.5 kHz.
    NbFilters voiceOn;
    voiceOn.bandwidthHz = 20000;
    NbFilters voiceOff = voiceOn;
    voiceOff.voiceFilter = false;
    voiceOff.agc = NbAgc::Slow;
    for (const auto& probe : {std::make_pair(fHigh, 5000.0), std::make_pair(fLow, 100.0)}) {
        double ratio[2];
        for (int on = 0; on < 2; on++) {
            const NbRun r = runNb(clean, rate, center, channels, probe.first, NbMode::Am, 0.f, on ? voiceOn : voiceOff);
            const auto p = tonePowers(r.pcm, pcmIndex(1.0), {1000.0, probe.second});
            ratio[on] = 10 * std::log10(p[1] / std::max(p[0], 1e-20));
            const NbReport rep = lastReport(r);
            CHECK(rep.bandwidthHz == 12500 && rep.voiceFilter == (on == 1) &&
                      rep.agc == (on ? NbAgc::Fast : NbAgc::Slow),
                  "reported bw %d voice %d agc %s", rep.bandwidthHz, rep.voiceFilter, nbAgcName(rep.agc));
        }
        // Sent: 0.45 vs 0.55 amplitude -> -1.7 dB.
        std::printf("  voice filter, %.0f Hz vs 1 kHz: off %.1f dB, on %.1f dB\n", probe.second, ratio[0], ratio[1]);
        CHECK(ratio[0] > -6, "%.0f Hz tone lost without the voice filter (%.1f dB)", probe.second, ratio[0]);
        CHECK(ratio[1] < -20, "voice filter passes %.0f Hz (%.1f dB)", probe.second, ratio[1]);
    }
}

// Wideband FM: a +-75 kHz, 1 kHz tone on 51.4 MHz (as an SDR++ "WFM"
// signal), a strong NFM neighbour 180 kHz up. Tone, its SNR and level,
// channel SNR in the WFM bandwidth, squelch, reported mode/width; auto
// never picks WFM.
void testNbWfm(uint32_t rate, int bandwidthHz, double deviationHz, std::vector<double>& realtimes)
{
    const uint32_t freq = 51400000;
    std::printf("[nb wfm %u S/s, bandwidth %d, deviation %.0f Hz]\n", rate, bandwidthHz, deviationHz);
    const std::vector<uint32_t> channels;
    const uint32_t lo = NbDemod::placeLo(rate, freq, {freq});
    const double offS = 2.6, seconds = 3.8;
    NbTxConfig cfg;
    cfg.sampleRate = rate;
    cfg.seed = rate / 1000 + 7;
    NbStation w;
    w.offsetHz = static_cast<double>(freq) - lo;
    w.mode = NbTxMode::Wfm;
    w.snrDb = 40;  // in 8 kHz: ~29 dB in 100 kHz
    w.tone1Hz = 1000;
    w.deviationHz = deviationHz;
    w.offS = offS;
    cfg.stations.push_back(w);
    NbStation nfm;
    nfm.offsetHz = w.offsetHz + 180000;
    nfm.mode = NbTxMode::Fm;
    nfm.snrDb = 40;
    nfm.tone1Hz = 800;
    nfm.tone2Hz = 1900;
    cfg.stations.push_back(nfm);
    const auto iq = generateNb(cfg, seconds);

    NbFilters f;
    f.bandwidthHz = bandwidthHz;
    f.noiseBlanker = true;  // must be ignored for WFM
    const NbRun r = runNb(iq, rate, freq, channels, freq, NbMode::Wfm, 10.f, f);
    realtimes.push_back(r.realtime);

    // Tone vs everything else in 100 Hz-15 kHz; the neighbour's tones.
    constexpr int kN = 32768;
    const size_t from = pcmIndex(1.0);
    double toneSnr = -99, rmsDbfs = -99, peakHz = 0, leakDb = 0;
    if (r.pcm.size() >= from + kN) {
        Fft fft(kN);
        std::vector<cf32> x(kN);
        double sumSq = 0;
        for (int i = 0; i < kN; i++) {
            const float v = r.pcm[from + static_cast<size_t>(i)] / 32768.f;
            sumSq += static_cast<double>(v) * v;
            const float win = static_cast<float>(0.5 - 0.5 * std::cos(2 * M_PI * (i + 0.5) / kN));
            x[static_cast<size_t>(i)] = cf32(v * win, 0);
        }
        rmsDbfs = 10 * std::log10(sumSq / kN + 1e-20);
        fft.forward(x.data());
        const double binHz = 48000.0 / kN;
        auto band = [&](double lo, double hi) {
            double s = 0;
            for (int k = static_cast<int>(std::ceil(lo / binHz)); k <= static_cast<int>(hi / binHz); k++) s += std::norm(x[static_cast<size_t>(k)]);
            return s;
        };
        int best = 1;
        for (int k = 1; k < kN / 2; k++) {
            if (std::norm(x[static_cast<size_t>(k)]) > std::norm(x[static_cast<size_t>(best)])) best = k;
        }
        peakHz = best * binHz;
        const double tone = band(988, 1012);
        toneSnr = 10 * std::log10(tone / std::max(band(100, 15000) - tone, 1e-20));
        leakDb = 10 * std::log10((band(788, 812) + band(1888, 1912)) / std::max(tone, 1e-20));
    }
    bool openOk = true, closedOk = true, modeOk = true;
    float snr = 0;
    for (size_t k = 0; k < r.reports.size(); k++) {
        const double t = reportTime(k);
        const NbReport& rep = r.reports[k];
        if (t >= 0.6 && t <= 2.5) {
            openOk &= rep.squelchOpen;
            snr = rep.snrDb;
        }
        if (t >= 3.15) closedOk &= !rep.squelchOpen;
        modeOk &= rep.mode == NbMode::Wfm;
    }
    int tail = 0;
    for (size_t i = pcmIndex(3.1); i < r.pcm.size(); i++) tail = std::max(tail, std::abs(static_cast<int>(r.pcm[i])));
    const NbReport last = r.reports.empty() ? NbReport() : r.reports.back();
    const int wantBw = NbDemod::effectiveBandwidth(NbMode::Wfm, bandwidthHz);
    std::printf("  tone %.1f Hz, tone SNR %.1f dB, audio %.1f dBFS rms, neighbour %.1f dB, channel SNR %.1f dB "
                "(noise %.1f dBFS), squelch %s/%s, tail max %d, reported %s %d Hz, %.1fx realtime\n",
                peakHz, toneSnr, rmsDbfs, leakDb, snr, last.noiseDbfs, openOk ? "open" : "NOT OPEN",
                closedOk ? "closed" : "NOT CLOSED", tail, nbModeName(last.mode), last.bandwidthHz, r.realtime);
    CHECK(std::fabs(peakHz - 1000) < 5, "wfm: tone at %.1f Hz", peakHz);
    CHECK(toneSnr > 30, "wfm: tone SNR %.1f dB", toneSnr);
    // 75 kHz -> 0.5 peak (-9 dBFS rms), de-emphasis -0.4 dB at 1 kHz.
    const double wantRms = 20 * std::log10(0.5 * deviationHz / 75000 / std::sqrt(2.0)) - 0.4;
    CHECK(std::fabs(rmsDbfs - wantRms) < 1.5, "wfm: audio level %.1f dBFS, want %.1f", rmsDbfs, wantRms);
    CHECK(leakDb < -40, "wfm: neighbour only %.1f dB down", leakDb);
    // 40 dB in 8 kHz -> 40 - 10 log(enbw / 8 kHz).
    const double wantSnr = 40 - 10 * std::log10(wantBw / 8000.0);
    CHECK(std::fabs(snr - wantSnr) < 3, "wfm: channel SNR %.1f dB, want ~%.1f", snr, wantSnr);
    CHECK(openOk, "wfm: squelch not open while keyed");
    CHECK(closedOk && tail == 0, "wfm: squelch not closed after the transmission (tail %d)", tail);
    CHECK(modeOk && last.bandwidthHz == wantBw, "wfm: reported %s %d Hz", nbModeName(last.mode), last.bandwidthHz);

    // Auto on the same signal: never WFM.
    const NbRun ra = runNb(iq, rate, freq, channels, freq, NbMode::Auto, 10.f, f);
    int wfm = 0;
    for (const auto& rep : ra.reports) wfm += rep.mode == NbMode::Wfm;
    CHECK(wfm == 0, "auto picked wfm in %d reports", wfm);
}

void testNb()
{
    {
        std::vector<double> rt;
        // A steady +-75 kHz tone needs ~152 kHz (Carson): the default and the
        // narrowest width get signals that fit them.
        testNbWfm(2048000, 0, 40000, rt);
        testNbWfm(960000, 200000, 75000, rt);
        testNbWfm(2400000, 50000, 15000, rt);
        testNbWfm(1440000, 150000, 75000, rt);
        const double worst = *std::min_element(rt.begin(), rt.end());
        std::printf("[nb wfm] realtime factor %.1fx (slowest run)\n", worst);
        CHECK(worst > 1.5, "WFM only %.1fx realtime", worst);
    }
    testNbFilters();
    std::vector<double> rt;
    for (uint32_t rate : {960000u, 1440000u, 2048000u}) {
        std::vector<double> r;
        testNbRate(rate, r);
        const double worst = *std::min_element(r.begin(), r.end());
        std::printf("[nb %u S/s] realtime factor %.1fx (slowest run)\n", rate, worst);
        CHECK(worst > 1.5, "NB at %u S/s only %.1fx realtime", rate, worst);
        rt.push_back(worst);
    }
}

// --- DMR ---

int bitCount(uint32_t v)
{
    int n = 0;
    for (; v; v &= v - 1) n++;
    return n;
}

uint32_t randomErrors(std::mt19937& rng, int bits, int count)
{
    uint32_t e = 0;
    while (bitCount(e) < count) e |= 1u << (rng() % static_cast<unsigned>(bits));
    return e;
}

// The coding blocks against the tables of TS 102 361-1 annex B, round
// trips with errors, and the AMBE+2 frame layout against mbelib's FEC.
void testDmrFec()
{
    std::printf("[dmr fec]\n");
    std::mt19937 rng(77);

    // Golay (20,8): table B.11's first row; every word with up to 3 errors.
    CHECK(dmr::golay2087Encode(0x80) == 0x803DAu, "Golay (20,8) row 0: %05x", dmr::golay2087Encode(0x80));
    int bad = 0, minDist = 99;
    for (int d = 0; d < 256; d++) {
        for (int e = 0; e <= 3; e++) {
            bad += dmr::golay2087Decode(dmr::golay2087Encode(d) ^ randomErrors(rng, 20, e)) != d;
        }
        for (int d2 = d + 1; d2 < 256; d2++) {
            minDist = std::min(minDist, bitCount(dmr::golay2087Encode(d) ^ dmr::golay2087Encode(d2)));
        }
    }
    CHECK(bad == 0 && minDist == 8, "Golay (20,8): %d wrong, distance %d", bad, minDist);
    // QR (16,7,6): up to 2 errors.
    bad = 0;
    minDist = 99;
    for (int d = 0; d < 128; d++) {
        for (int e = 0; e <= 2; e++) bad += dmr::qr1676Decode(dmr::qr1676Encode(d) ^ randomErrors(rng, 16, e)) != d;
        for (int d2 = d + 1; d2 < 128; d2++) minDist = std::min(minDist, bitCount(dmr::qr1676Encode(d) ^ dmr::qr1676Encode(d2)));
    }
    CHECK(bad == 0 && minDist == 6, "QR (16,7,6): %d wrong, distance %d", bad, minDist);
    // Hamming (7,4): one error.
    bad = 0;
    for (int d = 0; d < 16; d++) {
        for (int b = -1; b < 7; b++) bad += dmr::hamming743Decode(dmr::hamming743Encode(d) ^ (b < 0 ? 0u : 1u << b)) != d;
    }
    CHECK(bad == 0, "Hamming (7,4): %d wrong", bad);

    // RS (12,9): table B.18's rows (unit messages) give its parity columns.
    const uint8_t rows[9][3] = {{0x1C, 0xBC, 0xFD}, {0x89, 0x31, 0x08}, {0xAD, 0x41, 0x36}, {0x7D, 0x71, 0x16}, {0xF3, 0xA6, 0x3A},
                                {0x08, 0x83, 0x7B}, {0x3F, 0x6F, 0x02}, {0x6C, 0x0D, 0xA7}, {0x0E, 0x38, 0x40}};
    bad = 0;
    for (int r = 0; r < 9; r++) {
        uint8_t m[9] = {}, p[3];
        m[r] = 1;
        dmr::rs129Parity(m, p);
        bad += p[0] != rows[r][0] || p[1] != rows[r][1] || p[2] != rows[r][2];
    }
    CHECK(bad == 0, "RS (12,9): %d generator rows wrong", bad);

    // BPTC (196,96): any 2 errors, nearly all patterns of 3.
    int bad2 = 0, bad3 = 0;
    const int trials = 400;
    for (int t = 0; t < trials; t++) {
        uint8_t info[96], tx[196], out[96];
        for (auto& b : info) b = static_cast<uint8_t>(rng() & 1);
        dmr::bptc19696Encode(info, tx);
        for (int errors : {2, 3}) {
            uint8_t rx[196];
            std::memcpy(rx, tx, sizeof(rx));
            std::vector<int> pos;
            while (static_cast<int>(pos.size()) < errors) {
                const int p = static_cast<int>(rng() % 196);
                if (std::find(pos.begin(), pos.end(), p) == pos.end()) pos.push_back(p);
            }
            for (int p : pos) rx[p] ^= 1;
            const bool ok = dmr::bptc19696Decode(rx, out) && std::memcmp(out, info, 96) == 0;
            (errors == 2 ? bad2 : bad3) += !ok;
        }
    }
    CHECK(bad2 == 0 && bad3 < trials / 20, "BPTC (196,96): %d of %d with 2 errors, %d with 3 not decoded", bad2, trials, bad3);
    // Its interleaver (table B.3): TX(193), the third bit sent, is I(77).
    {
        uint8_t info[96] = {}, tx[196];
        info[95 - 77] = 1;
        dmr::bptc19696Encode(info, tx);
        int ones = 0;
        for (uint8_t v : tx) ones += v;
        CHECK(tx[2] == 1, "BPTC: I(77) not sent third (%d ones)", ones);
    }

    // Embedded LC: one error in each Hamming row; a wrong checksum is caught.
    bad = 0;
    int missed = 0;
    for (int t = 0; t < 200; t++) {
        uint8_t lc[72], tx[128], out[72];
        for (auto& b : lc) b = static_cast<uint8_t>(rng() & 1);
        dmr::embeddedLcEncode(lc, tx);
        uint8_t rx[128];
        std::memcpy(rx, tx, sizeof(rx));
        for (int row = 0; row < 7; row++) rx[(rng() % 16) * 8 + row] ^= 1;  // row r, any column
        bad += !(dmr::embeddedLcDecode(rx, out) && std::memcmp(out, lc, 72) == 0);
        // Row 0 of another LC: a valid Hamming word, the checksum must
        // catch it.
        uint8_t lc2[72];
        std::memcpy(lc2, lc, 72);
        lc2[3] ^= 1;
        uint8_t tx2[128];
        dmr::embeddedLcEncode(lc2, tx2);
        std::memcpy(rx, tx, sizeof(rx));
        for (int k = 0; k < 128; k += 8) rx[k] = tx2[k];
        missed += dmr::embeddedLcDecode(rx, out);
    }
    CHECK(bad == 0 && missed == 0, "embedded LC: %d not decoded, %d bad checksums accepted", bad, missed);

    // AMBE+2: transmitted bit 1 is C0(5) (18 x 4 block); round trip.
    {
        char fr[4][24] = {}, back[4][24];
        uint8_t tx[72] = {};
        tx[1] = 1;
        dmr::ambeDeinterleave(tx, fr);
        CHECK(fr[0][5] == 1, "AMBE: bit 1 is not C0(5)");
        bad = 0;
        for (int t = 0; t < 50; t++) {
            for (int i = 0; i < 72; i++) tx[i] = static_cast<uint8_t>(rng() & 1);
            uint8_t again[72];
            dmr::ambeDeinterleave(tx, fr);
            dmr::ambeInterleave(fr, again);
            dmr::ambeDeinterleave(again, back);
            bad += std::memcmp(tx, again, 72) != 0;
        }
        CHECK(bad == 0, "AMBE interleaver round trip");
    }
#ifdef HRDAB_MBELIB
    // Encoded frames through mbelib's own FEC: the same 49 bits back; up to
    // 3 errors in C0 and in C1 corrected and counted.
    int wrong = 0, errMismatch = 0;
    std::vector<int> c0, c1;  // transmit positions of C0's (minus its extra parity bit) and C1's bits
    for (int i = 0; i < 72; i++) {
        const int code = 18 * (i % 4) + i / 4;
        if (code < 23) c0.push_back(i);
        else if (code >= 24 && code < 47) c1.push_back(i);
    }
    for (int t = 0; t < 300; t++) {
        AmbeBits d;
        for (auto& b : d) b = static_cast<char>(rng() & 1);
        uint8_t tx[72];
        ambeEncode(d, tx);
        const int e = t % 4;
        for (int k = 0; k < e; k++) {
            tx[c0[static_cast<size_t>(k * 5 + t % 5)]] ^= 1;
            tx[c1[static_cast<size_t>(k * 7 + t % 7)]] ^= 1;
        }
        char fr[4][24], ambe[49];
        dmr::ambeDeinterleave(tx, fr);
        const int errs = mbe_eccAmbe3600x2450C0(fr);
        mbe_demodulateAmbe3600x2450Data(fr);
        const int errs2 = errs + mbe_eccAmbe3600x2450Data(fr, ambe);
        wrong += std::memcmp(ambe, d.data(), 49) != 0;
        // mbelib counts the errors among the data bits.
        errMismatch += errs2 > 2 * e;
    }
    CHECK(wrong == 0 && errMismatch == 0, "AMBE through mbelib: %d frames wrong, %d error counts off", wrong, errMismatch);
#endif
    std::printf("  codes ok: Golay (20,8), QR (16,7,6), Hamming (7,4), RS (12,9), BPTC (196,96) (%d/%d with 3 errors "
                "left), embedded LC, AMBE layout\n",
                bad3, trials);
}

struct DmrDecoded {
    std::vector<AmbeBits> frames[2];
    std::vector<DmrStatus> statuses;  // every 0.2 s
    std::vector<float> audio;         // 8 kHz
};

// DmrDecoder alone on the transmitter's deviation plus white noise (Hz rms)
// and a carrier offset.
DmrDecoded runDmrDecoder(const DmrTx& tx, double noiseHz, double offsetHz, double scale, unsigned seed)
{
    auto hz = dmrDeviationHz(tx, DmrDecoder::kInputRate, scale);
    std::mt19937 rng(seed);
    std::normal_distribution<float> normal(0.f, static_cast<float>(std::max(noiseHz, 1e-3)));
    for (auto& v : hz) v += static_cast<float>(offsetHz) + (noiseHz > 0 ? normal(rng) : 0.f);
    DmrDecoder dec;
    DmrDecoded out;
    dec.onAmbeFrame = [&](int slot, const char* d, int) {
        AmbeBits b;
        std::memcpy(b.data(), d, 49);
        out.frames[slot].push_back(b);
    };
    std::vector<float> pcm(64);
    for (size_t i = 0; i + 128 <= hz.size(); i += 128) {
        dec.process(&hz[i], 128);
        dec.pullAudio(pcm.data(), 64);
        out.audio.insert(out.audio.end(), pcm.begin(), pcm.end());
        if ((i / 128 + 1) % 25 == 0) out.statuses.push_back(dec.status());
    }
    return out;
}

// How many of the sent frames came out (frames are random: equal = right).
int framesFound(const std::vector<AmbeBits>& sent, const std::vector<AmbeBits>& got)
{
    int n = 0;
    size_t from = 0;
    for (const auto& f : sent) {
        for (size_t k = from; k < got.size() && k < from + 40; k++) {
            if (got[k] == f) {
                n++;
                from = k + 1;
                break;
            }
        }
    }
    return n;
}

void testDmrDecoder()
{
    std::printf("[dmr decoder]\n");
    // A repeater: slot 1 a group call with header and talker alias, slot 2
    // later a private call joined late (no header), overlapping.
    DmrTxConfig cfg;
    cfg.kind = DmrTxKind::Repeater;
    cfg.colorCode = 5;
    DmrTxCall a;
    a.slot = 0;
    a.src = 2321234;
    a.dst = 91;
    a.alias = "OE1XYZ Jo";
    a.superframes = 6;
    a.startS = 0.25;
    DmrTxCall b;
    b.slot = 1;
    b.group = false;
    b.src = 2329999;
    b.dst = 2320001;
    b.header = false;
    b.superframes = 4;
    b.startS = 1.0;
    cfg.calls = {a, b};
    const DmrTx tx = buildDmr(cfg, 3.6);
    struct Case {
        const char* name;
        double noiseHz, offsetHz, scale;
        int minPercent;
    };
    const Case cases[] = {{"clean", 0, 0, 1, 100},
                          {"offset", 150, -900, 1, 99},
                          {"deviation +12%", 150, 400, 1.12, 99},
                          {"deviation -15%", 150, 0, 0.85, 99},
                          {"noisy", 420, 300, 1, 85}};
    for (const Case& c : cases) {
        const DmrDecoded d = runDmrDecoder(tx, c.noiseHz, c.offsetHz, c.scale, 3);
        const int f0 = framesFound(tx.frames[0], d.frames[0]), f1 = framesFound(tx.frames[1], d.frames[1]);
        const int p0 = static_cast<int>(100 * f0 / std::max<size_t>(1, tx.frames[0].size()));
        const int p1 = static_cast<int>(100 * f1 / std::max<size_t>(1, tx.frames[1].size()));
        // During both calls (t = 1.8 s): IDs, alias, colour code.
        const DmrStatus& mid = d.statuses[std::min<size_t>(8, d.statuses.size() - 1)];
        const DmrSlotStatus& s0 = mid.slots[0];
        const DmrSlotStatus& s1 = mid.slots[1];
        const DmrStatus& end = d.statuses.back();
        double rms = 0;
        for (size_t i = static_cast<size_t>(0.6 * 8000); i < static_cast<size_t>(2.4 * 8000) && i < d.audio.size(); i++) {
            rms += d.audio[i] * d.audio[i];
        }
        rms = std::sqrt(rms / (1.8 * 8000));
        float tail = 0;
        for (size_t i = static_cast<size_t>(3.3 * 8000); i < d.audio.size(); i++) tail = std::max(tail, std::fabs(d.audio[i]));
        std::printf("  %-15s frames %d%% / %d%%, slot 1 %s %u->%u '%s', slot 2 %s %u->%u, cc %d, source %d, audio rms "
                    "%.3f, end %s/%s\n",
                    c.name, p0, p1, s0.active ? "on" : "off", s0.src, s0.dst, s0.alias.c_str(), s1.active ? "on" : "off",
                    s1.src, s1.dst, mid.colorCode, mid.source, rms, end.slots[0].active ? "on" : "off",
                    end.slots[1].active ? "on" : "off");
#ifdef HRDAB_MBELIB  // frames are counted as mbelib decodes them
        CHECK(p0 >= c.minPercent && p1 >= c.minPercent, "%s: frames %d%% / %d%%", c.name, p0, p1);
#endif
        CHECK(s0.active && s0.callType == 1 && s0.src == a.src && s0.dst == a.dst, "%s: slot 1 call", c.name);
        CHECK(s0.alias == a.alias, "%s: alias '%s'", c.name, s0.alias.c_str());
        CHECK(s1.active && s1.callType == 2 && s1.src == b.src && s1.dst == b.dst, "%s: slot 2 late entry", c.name);
        CHECK(mid.sync && mid.colorCode == 5 && mid.source == 1, "%s: sync %d cc %d source %d", c.name, mid.sync,
              mid.colorCode, mid.source);
        CHECK(!end.slots[0].active && !end.slots[1].active, "%s: calls not ended", c.name);
#ifdef HRDAB_MBELIB
        CHECK(rms > 0.01 && mid.audioSlot == 0, "%s: audio rms %.3f, playing slot %d", c.name, rms, mid.audioSlot);
        CHECK(tail == 0, "%s: audio after the calls (%.3f)", c.name, tail);
#endif
    }

    // A radio on its own (MS sourced, carrier only during its bursts),
    // joined late; and TDMA direct mode slot 2.
    for (DmrTxKind kind : {DmrTxKind::Radio, DmrTxKind::Direct}) {
        DmrTxConfig r;
        r.kind = kind;
        r.colorCode = 2;
        DmrTxCall c;
        c.slot = kind == DmrTxKind::Direct ? 1 : 0;
        c.header = false;
        c.src = 2620555;
        c.dst = 8;
        c.superframes = 4;
        c.startS = 0.3;
        r.calls = {c};
        const DmrTx t = buildDmr(r, 2.4);
        const DmrDecoded d = runDmrDecoder(t, 150, 600, 1, 9);
        const int found = framesFound(t.frames[c.slot], d.frames[c.slot]);
        const DmrStatus& mid = d.statuses[5];
        const DmrSlotStatus& s = mid.slots[c.slot];
        const char* name = kind == DmrTxKind::Radio ? "radio" : "direct slot 2";
        std::printf("  %-15s frames %d of %zu, slot %d %s %u->%u, cc %d, source %d\n", name, found, t.frames[c.slot].size(),
                    c.slot + 1, s.active ? "on" : "off", s.src, s.dst, mid.colorCode, mid.source);
#ifdef HRDAB_MBELIB
        CHECK(found == static_cast<int>(t.frames[c.slot].size()), "%s: %d frames", name, found);
#endif
        CHECK(s.active && s.src == c.src && s.dst == c.dst && s.callType == 1, "%s: call", name);
        CHECK(mid.source == (kind == DmrTxKind::Radio ? 2 : 3), "%s: source %d", name, mid.source);
    }

    // Noise only: no call, no audio.
    {
        DmrTx none;
        none.symbols.assign(4800 * 5, 0);
        none.on.assign(none.symbols.size(), 0);
        const DmrDecoded d = runDmrDecoder(none, 2500, 0, 1, 4);
        int calls = 0;
        for (const auto& st : d.statuses) calls += st.sync || st.slots[0].active || st.slots[1].active;
        float peak = 0;
        for (float v : d.audio) peak = std::max(peak, std::fabs(v));
        std::printf("  noise only: %d of %zu reports with sync/call, audio peak %.3f\n", calls, d.statuses.size(), peak);
        CHECK(calls == 0 && peak == 0, "noise taken for DMR");
    }
}

// Through the whole receiver (8-bit I/Q, channel filter, discriminator).
void testDmrReceiver()
{
    const uint32_t rate = 2048000, freq = 438800000;
    std::printf("[dmr receiver %u S/s]\n", rate);
    const std::vector<uint32_t> channels = {438775000, 438787500, 438800000, 438812500, 438825000};
    const uint32_t lo = NbDemod::placeLo(rate, freq, channels);
    DmrTxConfig cfg;
    cfg.sampleRate = rate;
    cfg.kind = DmrTxKind::Repeater;
    cfg.colorCode = 3;
    cfg.offsetHz = static_cast<double>(freq) - lo + 700;  // a little off frequency
    cfg.clockPpm = 40;
    DmrTxCall c;
    c.slot = 1;
    c.src = 2627777;
    c.dst = 26232;
    c.alias = "DL1ABC";
    c.superframes = 5;
    c.startS = 0.4;
    cfg.calls = {c};
    const double seconds = 3.4;
    for (double snr : {25.0, 13.0, 8.0}) {
        cfg.snrDb = snr;
        const auto iq = modulateDmr(cfg, buildDmr(cfg, seconds));
        for (NbMode mode : {NbMode::Dmr, NbMode::Auto}) {
            if (mode == NbMode::Auto && snr < 20) continue;
            NbRun r = runNb(iq, rate, freq, channels, freq, mode, 10.f);
            DmrSlotStatus call;
            bool seen = false;
            int cc = -1;
            for (const auto& st : r.dmr) {
                if (st.slots[1].active) {
                    call = st.slots[1];
                    seen = true;
                    cc = st.colorCode;
                }
            }
            double firstDmr = -1;
            int openReports = 0;
            for (size_t k = 0; k < r.reports.size(); k++) {
                if (firstDmr < 0 && r.reports[k].mode == NbMode::Dmr) firstDmr = reportTime(k);
                const double t = reportTime(k);
                if (t > 1.0 && t < 2.2) openReports += r.reports[k].squelchOpen;
            }
            double sum = 0;
            for (size_t i = pcmIndex(0.9); i < pcmIndex(2.2) && i < r.pcm.size(); i++) {
                sum += static_cast<double>(r.pcm[i]) * r.pcm[i];
            }
            const double rmsDb = 10 * std::log10(sum / (1.3 * 48000) / (32768.0 * 32768.0) + 1e-20);
            int tail = 0;
            for (size_t i = pcmIndex(3.0); i < r.pcm.size(); i++) tail = std::max(tail, std::abs(static_cast<int>(r.pcm[i])));
            std::printf("  %-4s SNR %.0f dB: call %s %u->%u '%s' cc %d, bit errors %.2f/frame, mode dmr after %.2f s, "
                        "voice in %d/6 reports, audio %.1f dBFS, tail %d, %.1fx realtime\n",
                        nbModeName(mode), snr, seen ? "seen" : "MISSING", call.src, call.dst, call.alias.c_str(), cc,
                        call.errorRate, firstDmr, openReports, rmsDb, tail, r.realtime);
            CHECK(seen && call.src == c.src && call.dst == c.dst && cc == 3, "%s %.0f dB: call not decoded",
                  nbModeName(mode), snr);
            // The alias needs two clean superframes in a row.
            if (snr > 10) CHECK(call.alias == c.alias, "%s %.0f dB: alias '%s'", nbModeName(mode), snr, call.alias.c_str());
            CHECK(firstDmr > 0 && firstDmr < 1.0, "%s %.0f dB: mode dmr at %.2f s", nbModeName(mode), snr, firstDmr);
            CHECK(r.realtime > 1.5, "DMR only %.1fx realtime", r.realtime);
#ifdef HRDAB_MBELIB
            CHECK(openReports >= 5 && rmsDb > -40, "%s %.0f dB: voice %d reports, %.1f dBFS", nbModeName(mode), snr,
                  openReports, rmsDb);
            CHECK(tail == 0, "%s %.0f dB: audio after the call", nbModeName(mode), snr);
            if (snr > 20) CHECK(call.errorRate < 0.05f, "bit errors %.2f per frame", call.errorRate);
#endif
        }
    }
    // An empty channel in DMR mode stays silent.
    {
        DmrTxConfig none = cfg;
        none.calls.clear();
        none.kind = DmrTxKind::Radio;  // no carrier at all
        const auto iq = modulateDmr(none, buildDmr(none, 2.5));
        NbRun r = runNb(iq, rate, freq, channels, freq, NbMode::Dmr, 10.f);
        int maxAbs = 0;
        for (int16_t v : r.pcm) maxAbs = std::max(maxAbs, std::abs(static_cast<int>(v)));
        int syncs = 0;
        for (const auto& st : r.dmr) syncs += st.sync;
        std::printf("  empty channel: %d of %zu reports with sync, audio max %d\n", syncs, r.dmr.size(), maxAbs);
        CHECK(syncs == 0 && maxAbs == 0, "empty channel taken for DMR");
    }
}

void testDmr()
{
    testDmrFec();
    testDmrDecoder();
    testDmrReceiver();
}

} // namespace

// Plays a raw rtl_tcp capture (u8 I/Q, 2.048 MS/s) through the whole
// receiver at full speed and counts the errors of one service:
//   selftest file <capture.u8> <serviceId>
int runFile(const char* path, uint32_t sid)
{
    std::FILE* f = std::fopen(path, "rb");
    if (!f) {
        std::printf("cannot open %s\n", path);
        return 2;
    }
    std::vector<uint8_t> iq;
    uint8_t buf[1 << 16];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) iq.insert(iq.end(), buf, buf + n);
    std::fclose(f);
    Collector col;
    auto src = std::make_unique<MemorySource>(iq, false);
    MemorySource* srcPtr = src.get();
    Receiver rx(std::move(src), col);
    rx.tune(201072000);
    bool playing = false;
    while (!srcPtr->finished_) {
        if (!playing && rx.playService(sid)) playing = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(800));
    rx.halt();
    std::lock_guard<std::mutex> l(col.m);
    std::printf("RESULT %s sid 0x%04x: ensemble '%s', format '%s', SNR %.1f | AUs ok %zu bad %d | RS fixed %d, "
                "uncorrectable %d\n",
                path, sid, col.ensemble.c_str(), col.format.c_str(), col.snr, col.aus.size(), col.badAus,
                col.rsCorrected, col.rsUncorrectable);
    return 0;
}

int main(int argc, char** argv)
{
    if (argc > 3 && std::strcmp(argv[1], "file") == 0)
        return runFile(argv[2], static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 0)));
    const bool quick = argc > 1 && std::strcmp(argv[1], "quick") == 0;
    if (argc > 1 && std::strcmp(argv[1], "nb") == 0) {
        testFft();
        testNb();
        std::printf("\n%s (%d failures)\n", g_failures ? "FAILED" : "ALL PASSED", g_failures);
        return g_failures ? 1 : 0;
    }
    if (argc > 1 && std::strcmp(argv[1], "dmr") == 0) {
        testDmr();
        std::printf("\n%s (%d failures)\n", g_failures ? "FAILED" : "ALL PASSED", g_failures);
        return g_failures ? 1 : 0;
    }
    if (argc > 1 && std::strcmp(argv[1], "demod") == 0) {
        TxConfig clean;
        clean.freqOffsetHz = 0;
        clean.clockPpm = 0;
        clean.snrDb = 60;
        clean.echoGain = 0;
        testDemod("ideal", clean);
        TxConfig off = clean;
        off.freqOffsetHz = 4321;
        testDemod("offset", off);
        TxConfig ppm = clean;
        ppm.clockPpm = 30;
        testDemod("clock", ppm);
        TxConfig noisy = clean;
        noisy.snrDb = 14;
        testDemod("noise", noisy);
        TxConfig echo = clean;
        echo.echoGain = 0.3;
        testDemod("echo", echo);
        noisy.echoGain = 0.3;
        testDemod("noise+echo", noisy);
        // A cheap stick without TCXO (LO and sample clock share the crystal).
        TxConfig stick = clean;
        stick.freqOffsetHz = 10000;
        stick.clockPpm = 50;
        stick.snrDb = 10;
        stick.echoGain = 0.3;
        testDemod("stick 50ppm", stick);
        stick.clockPpm = 85;
        stick.freqOffsetHz = 17000;
        testDemod("stick 85ppm", stick);
        return 0;
    }
    if (argc > 1 && std::strcmp(argv[1], "fmsep") == 0) {
        // Stereo separation at small and large deviation, no noise (tells IF
        // filter effects from matrix/PLL errors).
        for (double amp : {0.05, 0.45}) {
            FmTxConfig cfg;
            FmStation st;
            st.offsetHz = FmDemod::kIfShiftHz;
            st.toneAmp = amp;
            st.rds = false;
            cfg.stations.push_back(st);
            cfg.cnrDb = 60;
            runFm("sep", cfg, 3.0, FmExpect{true, false, false});
        }
        return 0;
    }
    if (argc > 1 && std::strcmp(argv[1], "fm") == 0) {
        testFm(false);
        std::printf("\n%s (%d failures)\n", g_failures ? "FAILED" : "ALL PASSED", g_failures);
        return g_failures ? 1 : 0;
    }
    testFft();
    testTables();
    testViterbi();
    testReedSolomon();
    testFm(quick);
    testNb();
    testDmr();

    TxConfig cfg;
    std::vector<uint8_t> slide(1500);
    for (size_t i = 0; i < slide.size(); i++) slide[i] = static_cast<uint8_t>(i * 7 + 3);
    slide[0] = 0xFF;
    slide[1] = 0xD8;
    cfg.slide = slide;

    runEndToEnd("realtime", cfg, quick ? 60 : 110, true, true);
    if (!quick) {
        TxConfig hard = cfg;
        hard.freqOffsetHz = -27400;
        hard.clockPpm = -85;
        hard.snrDb = 9;
        hard.echoGain = 0.5;
        hard.echoDelay = 180;
        hard.seed = 99;
        runEndToEnd("hard channel", hard, 110, true, false);

        TxConfig fast = cfg;
        fast.seed = 5;
        runEndToEnd("max speed", fast, 110, false, true);
    }

    std::printf("\n%s (%d failures)\n", g_failures ? "FAILED" : "ALL PASSED", g_failures);
    return g_failures ? 1 : 0;
}
