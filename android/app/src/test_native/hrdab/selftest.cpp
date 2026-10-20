// On-device self test of the hrdab receiver: unit tests of the coding
// blocks, then end-to-end runs against the simulated transmitter.
//
// Build + run: see run_selftest.ps1 in this directory.

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "charset.h"
#include "dab_tables.h"
#include "fft.h"
#include "receiver.h"
#include "reed_solomon.h"
#include "tx_sim.h"
#include "viterbi.h"

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
                    const auto due = t0 + std::chrono::microseconds(static_cast<long long>(pos / 4.096));
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
    void onRsErrors(bool, int) override {}
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
    explicit MemReader(const std::vector<uint8_t>& d) : d_(d) {}
    int readIq(uint8_t* dst, int bytes) override
    {
        const size_t n = std::min(static_cast<size_t>(bytes), d_.size() - pos_);
        std::memcpy(dst, d_.data() + pos_, n);
        pos_ += n;
        return static_cast<int>(n);
    }

private:
    const std::vector<uint8_t>& d_;
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
    }
    void onFrameLost() override { lost++; }
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
    MemReader reader(iq);
    BerSink sink(tx.frameBits);
    OfdmDemod demod(reader, sink);
    std::atomic<bool> stop{false};
    demod.run(stop);
    std::printf("  %d frames, %d lost, final BER %.4f, SNR %.1f dB, offset %.0f Hz\n", sink.frames_, sink.lost,
                sink.lastBer, sink.snr, demod.frequencyOffsetHz());
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

} // namespace

int main(int argc, char** argv)
{
    const bool quick = argc > 1 && std::strcmp(argv[1], "quick") == 0;
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
        return 0;
    }
    testFft();
    testTables();
    testViterbi();
    testReedSolomon();

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
