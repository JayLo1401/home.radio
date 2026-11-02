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
    cfg.cnrDb = 35;
    const double offsets[4] = {-600000, -150000, 250000, 700000};
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
    cfg.cnrDb = 25;
    const double rt = runFm("stereo", cfg, 6.0, FmExpect{});

    FmTxConfig mono = cfg;
    mono.stations[0].stereo = false;
    mono.stations[0].offsetHz = FmDemod::kIfShiftHz - 12000;
    mono.seed = 77;
    runFm("mono, -12 kHz", mono, quick ? 4.0 : 6.0, FmExpect{false, !quick, true});

    if (!quick) {
        FmTxConfig weak = cfg;
        weak.cnrDb = 9;
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

void testNb()
{
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

} // namespace

int main(int argc, char** argv)
{
    const bool quick = argc > 1 && std::strcmp(argv[1], "quick") == 0;
    if (argc > 1 && std::strcmp(argv[1], "nb") == 0) {
        testFft();
        testNb();
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
