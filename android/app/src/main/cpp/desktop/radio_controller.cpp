#include "radio_controller.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <future>
#include <map>
#include <set>

#include "common.h"
#include "libusb_transport.h"
#include "rtl2832.h"
#include "rtltcp_source.h"

namespace hrdab {

namespace {

// How long a scan waits for OFDM sync before calling a channel empty.
constexpr int64_t kEmptyChannelMs = 3000;

// FM (UKW) band and scan parameters, in kHz (see DabRtlSdrPlugin.kt).
constexpr int kFmLowKhz = 87500;
constexpr int kFmHighKhz = 108000;
constexpr int kFmWindowKhz = 1600;
constexpr double kFmMaxOffsetHz = 30000;
constexpr double kFmStationSnrDb = 10;
constexpr double kFmMinSnrDb = 6;
constexpr int64_t kFmWeakWaitMs = 2500;
constexpr int64_t kFmWeakRdsWaitMs = 5000;
constexpr int64_t kFmRdsWaitMs = 4000;
constexpr int64_t kFmNoRdsMs = 2000;
constexpr int kFmAudioRate = 48000;
constexpr int kFmPrebufferMs = 250;

// Narrowband audio: 48 kHz mono, continuous. Shorter cushion than Android's
// 250 ms: the desktop audio stack has far less jitter, and the squelch
// should open as close to the transmission as possible.
constexpr int kNbAudioRate = 48000;
constexpr int kNbPrebufferMs = 150;

struct Channel {
    const char* label;
    int freqKhz;
};

// The DAB Band III channel plan (DabChannels.kt).
const Channel kBand3[] = {
    {"5A", 174928},  {"5B", 176640},  {"5C", 178352},  {"5D", 180064},  {"6A", 181936},  {"6B", 183648},
    {"6C", 185360},  {"6D", 187072},  {"7A", 188928},  {"7B", 190640},  {"7C", 192352},  {"7D", 194064},
    {"8A", 195936},  {"8B", 197648},  {"8C", 199360},  {"8D", 201072},  {"9A", 202928},  {"9B", 204640},
    {"9C", 206352},  {"9D", 208064},  {"10A", 209936}, {"10N", 210096}, {"10B", 211648}, {"10C", 213360},
    {"10D", 215072}, {"11A", 216928}, {"11N", 217088}, {"11B", 218640}, {"11C", 220352}, {"11D", 222064},
    {"12A", 223936}, {"12N", 224096}, {"12B", 225648}, {"12C", 227360}, {"12D", 229072}, {"13A", 230784},
    {"13B", 232496}, {"13C", 234208}, {"13D", 235776}, {"13E", 237488}, {"13F", 239200},
};

int64_t nowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

void sleepMs(int ms)
{
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// IntegratedDabEngine.nbModeCode / nbAgcCode.
int nbModeCode(const std::string& mode)
{
    if (mode == "auto") return 0;
    if (mode == "am") return 1;
    if (mode == "fm") return 2;
    if (mode == "usb") return 3;
    if (mode == "lsb") return 4;
    if (mode == "wfm") return 5;
    return -1;
}

int nbAgcCode(const std::string& agc)
{
    if (agc == "auto") return 0;
    if (agc == "fast") return 1;
    if (agc == "slow") return 2;
    return -1;
}

// The Kotlin side read these through "%.1f" JSON; keep the same rounding.
double round1(double v)
{
    return std::round(v * 10.0) / 10.0;
}

std::vector<uint32_t> intList(const Json& args, const char* key)
{
    std::vector<uint32_t> out;
    for (const Json& v : args[key].items()) {
        if (v.isNumber() && v.asInt() > 0) out.push_back(static_cast<uint32_t>(v.asInt()));
    }
    return out;
}

} // namespace

// --- SerialExecutor / BgThread ---

SerialExecutor::SerialExecutor() : thread_(&SerialExecutor::loop, this) {}

SerialExecutor::~SerialExecutor()
{
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stop_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
}

void SerialExecutor::post(std::function<void()> job)
{
    {
        std::lock_guard<std::mutex> lock(mutex_);
        jobs_.push_back(std::move(job));
    }
    cv_.notify_one();
}

void SerialExecutor::loop()
{
    while (true) {
        std::function<void()> job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this] { return stop_ || !jobs_.empty(); });
            if (jobs_.empty()) return;
            job = std::move(jobs_.front());
            jobs_.pop_front();
        }
        job();
    }
}

std::shared_ptr<BgThread> BgThread::start(std::function<void()> body)
{
    auto t = std::make_shared<BgThread>();
    std::thread th([t, body = std::move(body)] {
        body();
        {
            std::lock_guard<std::mutex> lock(t->mutex_);
            t->done_ = true;
        }
        t->cv_.notify_all();
    });
    t->id_ = th.get_id();
    th.detach();
    return t;
}

bool BgThread::join(int timeoutMs)
{
    if (isCurrent()) return false;
    std::unique_lock<std::mutex> lock(mutex_);
    return cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this] { return done_; });
}

// --- RadioController ---

RadioController::RadioController(Sink sink, std::string dataDir) : sink_(std::move(sink)), dataDir_(std::move(dataDir))
{
}

RadioController::~RadioController()
{
    shutdown();
}

void RadioController::setDataDir(const std::string& dir)
{
    std::lock_guard<std::mutex> lock(dataDirMutex_);
    dataDir_ = dir;
}

void RadioController::shutdown()
{
    // On the main executor like every method call, so it can't interleave
    // with one that is still running. Called on app exit: wait until the
    // stick / rtl_tcp connection is closed, but never hang the exit.
    auto done = std::make_shared<std::promise<void>>();
    auto finished = done->get_future();
    main_.post([this, done] {
        stopScanIfRunning();
        stopLogoFetchIfRunning();
        stopPlayback();
        leaveFm();
        destroySession();
        done->set_value();
    });
    finished.wait_for(std::chrono::seconds(3));
}

void RadioController::call(int64_t id, const std::string& method, const std::string& argsJson)
{
    Json args = Json::parse(argsJson);
    main_.post([this, id, method, args = std::move(args)] { onMethodCall(id, method, args); });
}

std::shared_ptr<AudioPlayer> RadioController::player(std::shared_ptr<AudioPlayer>& slot)
{
    std::lock_guard<std::mutex> lock(playerMutex_);
    return slot;
}

std::shared_ptr<AudioPlayer> RadioController::takePlayer(std::shared_ptr<AudioPlayer>& slot)
{
    std::lock_guard<std::mutex> lock(playerMutex_);
    return std::move(slot);
}

std::shared_ptr<BgThread> RadioController::getThread(std::shared_ptr<BgThread>& slot)
{
    std::lock_guard<std::mutex> lock(threadMutex_);
    return slot;
}

void RadioController::setThread(std::shared_ptr<BgThread>& slot, std::shared_ptr<BgThread> t)
{
    std::lock_guard<std::mutex> lock(threadMutex_);
    slot = std::move(t);
}

// --- output ---

void RadioController::emit(const std::string& json)
{
    std::lock_guard<std::mutex> lock(sinkMutex_);
    if (sink_) sink_(json);
}

void RadioController::replyRaw(int64_t id, const std::string& valueJson)
{
    Event e;
    e.beginObject().str("type", "__reply").num("id", id).raw("value", valueJson).endObject();
    emit(e.text());
}

void RadioController::replyError(int64_t id, const std::string& code, const std::string& message)
{
    Event e;
    e.beginObject().str("type", "__reply").num("id", id).str("error", code).str("message", message).endObject();
    emit(e.text());
}

void RadioController::emitSimple(const char* type, const char* key, const std::string& value)
{
    Event e;
    e.beginObject().str("type", type).str(key, value).endObject();
    emit(e.text());
}

void RadioController::emitFmRds(int freqKhz, std::optional<int> pi, const std::optional<std::string>& ps,
                                const std::optional<std::string>& rt)
{
    Event e;
    e.beginObject().str("type", "fmRds").num("freqKhz", freqKhz);
    if (pi) e.num("pi", *pi);
    else e.null("pi");
    e.strOrNull("ps", ps ? &*ps : nullptr).strOrNull("rt", rt ? &*rt : nullptr).endObject();
    emit(e.text());
}

// --- ReceiverListener ---

void RadioController::onSync(bool synced)
{
    if (synced) scanSyncSeen_ = true;
    Event e;
    e.beginObject().str("type", "syncChange").boolean("sync", synced).endObject();
    emit(e.text());
}

void RadioController::onEnsembleLabel(const std::string& label)
{
    emitSimple("ensembleLabel", "label", label);
}

void RadioController::onServiceDetected(uint32_t sid)
{
    Event e;
    e.beginObject().str("type", "serviceDetected").num("serviceId", static_cast<int32_t>(sid)).endObject();
    emit(e.text());
}

void RadioController::onDynamicLabel(const std::string& text)
{
    emitSimple("dynamicLabel", "label", text);
}

void RadioController::onSnr(float snrDb)
{
    lastSnrDb_ = snrDb;
    Event e;
    e.beginObject().str("type", "snr").dbl("snrDb", snrDb).endObject();
    emit(e.text());
}

void RadioController::onRsErrors(bool uncorrectable, int corrected)
{
    Event e;
    e.beginObject().str("type", "rsErrors").boolean("uncorrected", uncorrectable).num("corrected", corrected).endObject();
    emit(e.text());
}

void RadioController::onAacErrors(int count)
{
    Event e;
    e.beginObject().str("type", "aacErrors").num("count", count).endObject();
    emit(e.text());
}

// e.g. "HE-AAC v2, 48 kHz Parametric Stereo @ 88 kbit/s", for the Now
// Playing banner; sent once per service start / format change.
void RadioController::onAudioFormat(const std::string& format)
{
    emitSimple("audioFormat", "format", format);
}

void RadioController::onAudioConfig(const std::vector<uint8_t>& asc, int sampleRate, int channels)
{
    if (auto p = player(audioPlayer_)) p->onAudioConfig(asc, sampleRate, channels);
}

void RadioController::onAccessUnit(const uint8_t* data, int len, bool ok)
{
    if (auto p = player(audioPlayer_)) p->onAccessUnit(data, ok ? len : 0, ok);
}

void RadioController::onSlide(const std::vector<uint8_t>& data, int contentSubType)
{
    saveSlide(data, contentSubType);
}

// rtl_tcp connection lost/restored (TCP mode) or the stick vanished (USB).
void RadioController::onStatus(bool isError, const std::string& message)
{
    HR_LOGI("status: isError=%d message=%s", isError ? 1 : 0, message.c_str());
    Event e;
    e.beginObject().str("type", "connectionMessage").boolean("isError", isError).str("message", message).endObject();
    emit(e.text());
}

void RadioController::onFmAudio(const int16_t* pcm, int frames)
{
    if (fmMuted_) return;
    if (auto p = player(fmPlayer_)) p->onPcm(pcm, 2 * frames, kFmAudioRate, 2);
}

void RadioController::onFmStatus(const FmStatus& st, float gainDb)
{
    if (!fmActive_ || fmMuted_) return;
    // Level referred to the tuner input, so it does not jump with the AGC.
    Event e;
    e.beginObject()
        .str("type", "fmStatus")
        .num("freqKhz", fmFreqKhz_.load())
        .dbl("levelDb", st.levelDbfs - gainDb)
        .dbl("snrDb", st.snrDb)
        .boolean("stereo", st.stereo)
        .dbl("offsetHz", st.offsetHz)
        .endObject();
    emit(e.text());
}

void RadioController::onFmRds(int pi, const std::string& ps, const std::string& rt)
{
    if (!fmActive_ || fmMuted_) return;
    emitFmRds(fmFreqKhz_, pi >= 0 ? std::optional<int>(pi) : std::nullopt,
              ps.empty() ? std::nullopt : std::optional<std::string>(ps),
              rt.empty() ? std::nullopt : std::optional<std::string>(rt));
}

void RadioController::onNbAudio(const int16_t* pcm, int frames)
{
    if (!nbActive_) return;
    if (auto p = player(nbPlayer_)) p->onPcm(pcm, frames, kNbAudioRate, 1);
}

void RadioController::onNbReport(const NbReport& r, float gainDb)
{
    if (!nbActive_) return;
    // All levels referred to the tuner input (AGC-independent).
    {
        Event e;
        e.beginObject()
            .str("type", "nbStatus")
            .num("freqHz", static_cast<int32_t>(r.freqHz))
            .dbl("levelDb", r.levelDbfs - gainDb)
            .dbl("noiseDb", r.noiseDbfs - gainDb)
            .dbl("snrDb", r.snrDb)
            .boolean("squelchOpen", r.squelchOpen)
            .str("mode", nbModeName(r.mode))
            .num("bandwidthHz", r.bandwidthHz)
            .boolean("noiseBlanker", r.noiseBlanker)
            .boolean("voiceFilter", r.voiceFilter)
            .str("agc", nbAgcName(r.agc))
            .endObject();
        emit(e.text());
    }
    if (r.spectrumDbfs.empty()) return; // no monitor data this time (gain change)
    {
        Event e;
        e.beginObject().str("type", "nbActivity").beginArray("channelsHz");
        for (uint32_t hz : r.channelsHz) e.num(static_cast<int32_t>(hz));
        e.endArray().beginArray("levelsDb");
        // NaN = outside the window -> null
        for (float db : r.channelDbfs) e.dbl(db - gainDb, 1);
        e.endArray().dbl("noiseDb", r.channelNoiseDbfs - gainDb).endObject();
        emit(e.text());
    }
    {
        Event e;
        e.beginObject()
            .str("type", "nbSpectrum")
            .num("centerHz", static_cast<int32_t>(r.centerHz))
            .num("spanHz", static_cast<int32_t>(r.spanHz))
            .beginArray("binsDb");
        for (float db : r.spectrumDbfs) e.dbl(db - gainDb, 1);
        e.endArray().endObject();
        emit(e.text());
    }
}

// --- engine ---

bool RadioController::engineCreateTcp(const std::string& host, int port)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (rx_) return true;
    rx_ = std::make_unique<Receiver>(std::make_unique<RtlTcpSource>(host, port), static_cast<ReceiverListener&>(*this));
    return true;
}

bool RadioController::engineCreateUsb(std::string& error)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (rx_) return true;
    auto usb = LibusbTransport::openFirst(error);
    if (!usb) return false;
    auto rtl = std::make_unique<Rtl2832Source>(std::move(usb));
    if (!rtl->open()) {
        error = "RTL-SDR-Stick antwortet nicht oder hat keinen unterstützten Tuner";
        return false;
    }
    rx_ = std::make_unique<Receiver>(std::move(rtl), static_cast<ReceiverListener&>(*this));
    return true;
}

void RadioController::engineDestroy()
{
    std::unique_ptr<Receiver> rx;
    {
        std::lock_guard<std::mutex> lock(engineMutex_);
        rx = std::move(rx_);
    }
    rx.reset();
}

void RadioController::engineTune(uint32_t hz)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (rx_) rx_->tune(hz);
}

void RadioController::engineHalt()
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (rx_) rx_->halt();
}

std::string RadioController::engineEnsembleLabel()
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    return rx_ ? rx_->ensembleLabel() : std::string();
}

std::vector<std::pair<int, std::string>> RadioController::engineServices()
{
    std::string json;
    {
        std::lock_guard<std::mutex> lock(engineMutex_);
        json = rx_ ? rx_->serviceListJson() : std::string("[]");
    }
    std::vector<std::pair<int, std::string>> out;
    const Json list = Json::parse(json); // must outlive the loop
    for (const Json& s : list.items()) out.emplace_back(s["serviceId"].asInt(), s["label"].asString());
    return out;
}

bool RadioController::enginePlayService(int sid)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    return rx_ && rx_->playService(static_cast<uint32_t>(sid));
}

void RadioController::engineStopService()
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (rx_) rx_->stopService();
}

bool RadioController::engineFmTune(uint32_t hz)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    return rx_ && rx_->fmTune(hz);
}

std::optional<std::vector<RadioController::FmCandidate>> RadioController::engineFmSurvey(uint32_t centerHz)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (!rx_) return std::nullopt;
    std::vector<FmCarrier> carriers;
    if (!rx_->fmSurvey(centerHz, kFmLowKhz * 1000u, kFmHighKhz * 1000u, carriers)) return std::nullopt;
    const float gain = rx_->gainDb();
    std::vector<FmCandidate> out;
    for (const auto& c : carriers) out.push_back({static_cast<int>(c.freqHz / 1000), round1(c.levelDbfs - gain)});
    return out;
}

std::optional<RadioController::FmInfo> RadioController::engineFmInfo()
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    FmInfo out;
    if (!rx_) return out; // {"valid":false}
    const FmDemod::Info info = rx_->fmInfo();
    out.valid = info.valid;
    out.levelDb = round1(info.status.levelDbfs - rx_->gainDb());
    out.snrDb = round1(info.status.snrDb);
    out.stereo = info.status.stereo;
    out.offsetHz = std::round(info.status.offsetHz);
    out.rdsSync = info.rdsSync;
    if (info.pi >= 0) out.pi = info.pi;
    if (!info.ps.empty()) out.ps = info.ps;
    if (!info.rt.empty()) out.rt = info.rt;
    return out;
}

bool RadioController::engineNbStart(int sampleRate, int centerHz, const std::vector<uint32_t>& channels, int freqHz,
                                    int mode, float squelchDb)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (!rx_ || mode < 0 || mode > static_cast<int>(NbMode::Wfm) || sampleRate <= 0 || centerHz <= 0 || freqHz <= 0) {
        return false;
    }
    return rx_->nbStart(static_cast<uint32_t>(sampleRate), static_cast<uint32_t>(centerHz), channels,
                        static_cast<uint32_t>(freqHz), static_cast<NbMode>(mode), squelchDb);
}

bool RadioController::engineNbTune(int freqHz, int mode)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (!rx_ || mode < 0 || mode > static_cast<int>(NbMode::Wfm) || freqHz <= 0) return false;
    return rx_->nbTune(static_cast<uint32_t>(freqHz), static_cast<NbMode>(mode));
}

void RadioController::engineNbSetSquelch(float squelchDb)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (rx_) rx_->nbSetSquelch(squelchDb);
}

bool RadioController::engineNbSetChannels(int centerHz, const std::vector<uint32_t>& channels)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (!rx_ || centerHz <= 0) return false;
    return rx_->nbSetChannels(static_cast<uint32_t>(centerHz), channels);
}

void RadioController::engineNbSetFilters(const NbFilterSettings& s)
{
    std::lock_guard<std::mutex> lock(engineMutex_);
    if (!rx_) return;
    NbFilters f;
    f.bandwidthHz = s.bandwidthHz;
    f.noiseBlanker = s.noiseBlanker;
    f.voiceFilter = s.voiceFilter;
    f.agc = s.agc == 1 ? NbAgc::Fast : s.agc == 2 ? NbAgc::Slow : NbAgc::Auto;
    rx_->nbSetFilters(f);
}

// --- session ---

bool RadioController::ensureCreated()
{
    std::lock_guard<std::mutex> lock(sessionMutex_);
    if (created_) return true;
    created_ = engineCreateTcp(lastHost_, lastPort_);
    sessionEndpoint_ = created_ ? lastHost_ + ":" + std::to_string(lastPort_) : std::string();
    return created_;
}

void RadioController::destroySession()
{
    std::lock_guard<std::mutex> lock(sessionMutex_);
    if (created_) {
        engineDestroy();
        created_ = false;
    }
    sessionEndpoint_.clear();
    usbSession_ = false;
}

// USB counterpart to "setServer": opens the first RTL-SDR stick via libusb.
void RadioController::useDirectUsb(int64_t id)
{
    {
        std::lock_guard<std::mutex> lock(sessionMutex_);
        if (created_ && usbSession_) {
            replyBool(id, true);
            return;
        }
    }
    if (created_) {
        // a TCP session is live - the stick replaces it
        stopPlayback();
        leaveFm();
        destroySession();
    }
    std::string error;
    bool ok;
    {
        std::lock_guard<std::mutex> lock(sessionMutex_);
        ok = engineCreateUsb(error);
        if (ok) {
            created_ = true;
            usbSession_ = true;
        }
    }
    // Like on Android only false; the reason (no stick / no WinUSB driver /
    // no udev rule) is in the log and in listDevices' hasPermission.
    replyBool(id, ok);
}

void RadioController::stopScanIfRunning()
{
    scanRunning_ = false;
    if (auto t = getThread(scanThread_)) t->join(1000);
    setThread(scanThread_, nullptr);
}

void RadioController::stopLogoFetchIfRunning()
{
    logoFetchRunning_ = false;
    if (auto t = getThread(logoFetchThread_)) t->join(1000);
    setThread(logoFetchThread_, nullptr);
}

void RadioController::stopPlayback()
{
    if (created_) engineStopService();
    if (auto p = takePlayer(audioPlayer_)) p->stop();
    std::lock_guard<std::mutex> lock(contextMutex_);
    currentContext_.reset();
}

// A MOT slideshow image of the current station, saved as
// <dataDir>/dab_logos/<freq>_<sid>.jpg|png (see DabRtlSdrPlugin.saveSlide).
void RadioController::saveSlide(const std::vector<uint8_t>& data, int contentSubType)
{
    std::optional<std::pair<int, int>> ctx;
    {
        std::lock_guard<std::mutex> lock(contextMutex_);
        ctx = currentContext_;
    }
    if (!ctx) return;
    std::string dir;
    {
        std::lock_guard<std::mutex> lock(dataDirMutex_);
        dir = dataDir_;
    }
    if (dir.empty()) return;
    const char* ext = contentSubType == 3 ? "png" : "jpg"; // MOT sub-type 1 = JPEG, 3 = PNG
    BgThread::start([this, data, ctx, dir, ext] {
        namespace fs = std::filesystem;
        std::error_code ec;
        const fs::path folder = fs::u8path(dir) / "dab_logos";
        fs::create_directories(folder, ec);
        const fs::path file =
            folder / (std::to_string(ctx->first) + "_" + std::to_string(ctx->second) + "." + ext);
        std::ofstream out(file, std::ios::binary | std::ios::trunc);
        out.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
        out.close();
        if (!out) {
            HR_LOGW("saveSlide: failed to save slideshow image");
            return;
        }
        const std::string path = file.u8string();
        {
            std::lock_guard<std::mutex> lock(contextMutex_);
            lastLogoPath_ = path;
        }
        Event e;
        e.beginObject()
            .str("type", "motLogo")
            .num("freqKhz", ctx->first)
            .num("serviceId", ctx->second)
            .str("path", path)
            .endObject();
        emit(e.text());
    });
}

// Tunes through every Band III channel and reports the ensembles and
// services found (see DabRtlSdrPlugin.scanBand3 for the timing rationale).
void RadioController::scanBand3(std::optional<int> onlyFreqKhz)
{
    if (!ensureCreated()) {
        Event e;
        e.beginObject().str("type", "scanFinished").num("foundCount", 0).str("error", "native_create_failed").endObject();
        emit(e.text());
        return;
    }
    stopLogoFetchIfRunning();
    std::vector<Channel> channels;
    for (const auto& c : kBand3) {
        if (!onlyFreqKhz || c.freqKhz == *onlyFreqKhz) channels.push_back(c);
    }
    const bool single = onlyFreqKhz.has_value();
    int found = 0;
    for (size_t index = 0; index < channels.size(); index++) {
        if (!scanRunning_) break;
        const Channel& channel = channels[index];
        {
            Event e;
            e.beginObject()
                .str("type", "scanProgress")
                .num("index", static_cast<int64_t>(index))
                .num("total", static_cast<int64_t>(channels.size()))
                .str("label", channel.label)
                .num("freqKhz", channel.freqKhz)
                .endObject();
            emit(e.text());
        }
        lastSnrDb_ = 0.f;
        scanSyncSeen_ = false;
        engineTune(static_cast<uint32_t>(channel.freqKhz) * 1000u);
        std::string ensembleLabel;
        std::vector<std::pair<int, std::string>> services;
        const int64_t channelStart = nowMs();
        const int64_t initialDeadline = channelStart + (single ? 15000 : 6000);
        int64_t deadline = initialDeadline;
        size_t lastServiceCount = 0;
        int staleRounds = 0;
        while (scanRunning_ && nowMs() < deadline) {
            sleepMs(500);
            ensembleLabel = engineEnsembleLabel();
            if (ensembleLabel.find_first_not_of(" \t\r\n") == std::string::npos) ensembleLabel.clear();
            services = engineServices();
            const bool foundSomething = !ensembleLabel.empty() || !services.empty();
            if (!single && !foundSomething && !scanSyncSeen_ && nowMs() - channelStart >= kEmptyChannelMs) {
                break; // no DAB+ signal here at all
            }
            if (foundSomething && deadline == initialDeadline) deadline = nowMs() + 8000;
            if (services.size() > lastServiceCount) {
                lastServiceCount = services.size();
                staleRounds = 0;
            } else if (foundSomething) {
                if (++staleRounds >= 4) break;
            }
        }
        if (!ensembleLabel.empty() || !services.empty()) {
            found++;
            HR_LOGI("Channel %s (%d kHz): ensemble='%s', %zu service(s), SNR=%.1fdB", channel.label, channel.freqKhz,
                    ensembleLabel.c_str(), services.size(), static_cast<double>(lastSnrDb_.load()));
            Event e;
            e.beginObject()
                .str("type", "channelLocked")
                .num("index", static_cast<int64_t>(index))
                .str("label", channel.label)
                .num("freqKhz", channel.freqKhz)
                .dbl("snrDb", lastSnrDb_.load());
            if (ensembleLabel.empty()) e.null("ensembleLabel");
            else e.str("ensembleLabel", ensembleLabel);
            e.beginArray("services");
            for (const auto& s : services) e.beginObject().num("serviceId", s.first).str("label", s.second).endObject();
            e.endArray().endObject();
            emit(e.text());
        }
    }
    engineHalt();
    scanRunning_ = false;
    Event e;
    e.beginObject().str("type", "scanFinished").num("foundCount", found).endObject();
    emit(e.text());
}

// Tunes to each (freqKhz, serviceId) in turn and waits for a MOT slideshow
// image; no audio output (see DabRtlSdrPlugin.fetchLogos).
void RadioController::fetchLogos(const std::vector<std::pair<int, int>>& stations)
{
    if (!ensureCreated()) {
        Event e;
        e.beginObject()
            .str("type", "logoScanFinished")
            .num("foundCount", 0)
            .str("error", "native_create_failed")
            .endObject();
        emit(e.text());
        return;
    }
    int found = 0;
    for (size_t index = 0; index < stations.size(); index++) {
        if (!logoFetchRunning_) break;
        const int freqKhz = stations[index].first;
        const int serviceId = stations[index].second;
        {
            Event e;
            e.beginObject()
                .str("type", "logoScanProgress")
                .num("index", static_cast<int64_t>(index))
                .num("total", static_cast<int64_t>(stations.size()))
                .num("freqKhz", freqKhz)
                .num("serviceId", serviceId)
                .endObject();
            emit(e.text());
        }
        stopPlayback();
        {
            std::lock_guard<std::mutex> lock(contextMutex_);
            lastLogoPath_.reset();
            currentContext_ = std::make_pair(freqKhz, serviceId);
        }
        engineTune(static_cast<uint32_t>(freqKhz) * 1000u);
        bool playing = false;
        const int64_t playDeadline = nowMs() + 8000;
        while (logoFetchRunning_ && !playing && nowMs() < playDeadline) {
            playing = enginePlayService(serviceId);
            if (!playing) sleepMs(500);
        }
        auto logoPath = [this] {
            std::lock_guard<std::mutex> lock(contextMutex_);
            return lastLogoPath_;
        };
        if (playing) {
            const int64_t deadline = nowMs() + 15000;
            while (logoFetchRunning_ && !logoPath() && nowMs() < deadline) sleepMs(300);
        }
        const auto path = logoPath();
        Event e;
        if (path) {
            found++;
            e.beginObject()
                .str("type", "logoFound")
                .num("freqKhz", freqKhz)
                .num("serviceId", serviceId)
                .str("path", *path)
                .endObject();
        } else {
            e.beginObject().str("type", "logoNotFound").num("freqKhz", freqKhz).num("serviceId", serviceId).endObject();
        }
        emit(e.text());
    }
    stopPlayback();
    engineHalt();
    logoFetchRunning_ = false;
    Event e;
    e.beginObject().str("type", "logoScanFinished").num("foundCount", found).endObject();
    emit(e.text());
}

// --- FM / NB activity bookkeeping ---

void RadioController::stopDabActivities()
{
    stopScanIfRunning();
    stopLogoFetchIfRunning();
    playRequestId_++; // abort an in-flight playService retry loop
    stopPlayback();
}

void RadioController::stopFmActivities()
{
    fmScanRunning_ = false; // also cancels a scan still queued on fm_
    stopFmScanIfRunning();
    cancelFmSeek();
    stopFmPlayback();
}

void RadioController::leaveDab()
{
    stopDabActivities();
    leaveNb();
}

void RadioController::leaveFm()
{
    stopFmActivities();
    leaveNb();
}

void RadioController::leaveNb()
{
    nbActive_ = false;
    if (auto p = takePlayer(nbPlayer_)) p->stop();
}

void RadioController::ensureNbPlayer()
{
    std::lock_guard<std::mutex> lock(playerMutex_);
    if (nbPlayer_) return;
    auto p = std::make_shared<AudioPlayer>(kNbPrebufferMs);
    p->start();
    nbPlayer_ = p;
}

void RadioController::applyNbFilters()
{
    NbFilterSettings f;
    {
        std::lock_guard<std::mutex> lock(nbFiltersMutex_);
        f = nbFilters_;
    }
    if (created_) engineNbSetFilters(f);
}

void RadioController::stopFmScanIfRunning()
{
    // No thread yet: an fmScan queued behind this call on fm_ was requested
    // later and must not be cancelled by it.
    auto t = getThread(fmScanThread_);
    if (!t) return;
    fmScanRunning_ = false;
    t->join(3000); // a survey in progress takes up to ~1 s
    setThread(fmScanThread_, nullptr);
}

void RadioController::cancelFmSeek()
{
    fmSeekId_++;
    if (auto t = getThread(fmSeekThread_)) t->join(3000);
    setThread(fmSeekThread_, nullptr);
    fmMuted_ = false;
}

void RadioController::stopFmPlayback()
{
    fmActive_ = false;
    if (auto p = takePlayer(fmPlayer_)) p->stop();
}

void RadioController::ensureFmPlayer()
{
    std::lock_guard<std::mutex> lock(playerMutex_);
    if (fmPlayer_) return;
    auto p = std::make_shared<AudioPlayer>(kFmPrebufferMs);
    p->start();
    fmPlayer_ = p;
}

bool RadioController::fmPlayBlocking(int freqKhz)
{
    leaveDab();
    stopFmScanIfRunning();
    cancelFmSeek();
    if (!ensureCreated()) return false;
    fmFreqKhz_ = freqKhz;
    const bool ok = engineFmTune(static_cast<uint32_t>(freqKhz) * 1000u);
    if (ok) {
        ensureFmPlayer();
        fmActive_ = true;
    }
    emitFmRds(freqKhz, std::nullopt, std::nullopt, std::nullopt);
    return ok;
}

std::vector<RadioController::FmCandidate> RadioController::fmSurvey(int centerKhz)
{
    auto r = engineFmSurvey(static_cast<uint32_t>(centerKhz) * 1000u);
    return r ? *r : std::vector<FmCandidate>();
}

// Tunes to a candidate and decides whether a station is there (see
// DabRtlSdrPlugin.fmProbe).
std::optional<RadioController::FmStation> RadioController::fmProbe(int freqKhz, bool waitRds,
                                                                   const std::function<bool()>& keepGoing)
{
    engineFmTune(static_cast<uint32_t>(freqKhz) * 1000u);
    const int64_t start = nowMs();
    bool isStation = false;
    std::optional<FmInfo> last;
    while (keepGoing()) {
        sleepMs(120);
        const int64_t elapsed = nowMs() - start;
        const auto info = engineFmInfo();
        if (!info) continue;
        if (!info->valid) {
            if (elapsed > 2000) return std::nullopt; // no status at all - source trouble
            continue;
        }
        last = info;
        if (!isStation) {
            if (std::fabs(info->offsetHz) > kFmMaxOffsetHz) return std::nullopt;
            // A 19 kHz stereo pilot is as sure a sign of a broadcast as RDS.
            if (info->snrDb >= kFmStationSnrDb || info->pi || info->stereo) {
                isStation = true;
            } else {
                // Weak: give the pilot / RDS time to show up.
                const int64_t limit = info->rdsSync ? kFmWeakRdsWaitMs : info->snrDb >= kFmMinSnrDb ? kFmWeakWaitMs : 1500;
                if (elapsed > limit) return std::nullopt;
                continue;
            }
        }
        if (!waitRds) break;
        if (info->pi && info->ps) break;
        if (elapsed >= kFmRdsWaitMs) break;
        if (!info->rdsSync && !info->pi && elapsed >= kFmNoRdsMs) break;
    }
    if (!last || !isStation || !keepGoing()) return std::nullopt;
    return FmStation{freqKhz, last->levelDb, last->stereo, last->pi, last->ps};
}

// FM band scan: survey of 13 windows of 1.6 MHz, then each candidate probed
// (see DabRtlSdrPlugin.scanFm).
void RadioController::scanFm()
{
    if (!ensureCreated()) {
        Event e;
        e.beginObject().str("type", "fmScanFinished").num("foundCount", 0).str("error", "native_create_failed").endObject();
        emit(e.text());
        return;
    }
    auto running = [this] { return fmScanRunning_.load(); };
    std::vector<int> windows;
    for (int c = kFmLowKhz + kFmWindowKhz / 2; c - kFmWindowKhz / 2 <= kFmHighKhz; c += kFmWindowKhz) windows.push_back(c);
    std::map<int, FmCandidate> candidates;
    for (size_t index = 0; index < windows.size(); index++) {
        if (!running()) break;
        Event e;
        e.beginObject()
            .str("type", "fmScanProgress")
            .num("index", static_cast<int64_t>(index))
            .num("total", static_cast<int64_t>(windows.size()))
            .num("freqKhz", windows[index])
            .str("phase", "survey")
            .endObject();
        emit(e.text());
        for (const auto& c : fmSurvey(windows[index])) candidates[c.freqKhz] = c;
    }
    HR_LOGI("FM scan: %zu candidate(s)", candidates.size());

    int found = 0;
    std::optional<FmStation> pending;
    auto report = [&](const FmStation& st) {
        found++;
        HR_LOGI("FM station %d kHz: %.1f dB, stereo=%d, PI=%d, PS='%s'", st.freqKhz, st.levelDb, st.stereo ? 1 : 0,
                st.pi.value_or(-1), st.ps.value_or("").c_str());
        Event e;
        e.beginObject()
            .str("type", "fmStationFound")
            .num("freqKhz", st.freqKhz)
            .dbl("levelDb", st.levelDb, 1)
            .boolean("stereo", st.stereo);
        if (st.pi) e.num("pi", *st.pi);
        else e.null("pi");
        e.strOrNull("ps", st.ps ? &*st.ps : nullptr).endObject();
        emit(e.text());
    };
    std::vector<FmCandidate> list;
    for (const auto& kv : candidates) list.push_back(kv.second);
    for (size_t index = 0; index < list.size(); index++) {
        if (!running()) break;
        const FmCandidate& cand = list[index];
        {
            Event e;
            e.beginObject()
                .str("type", "fmScanProgress")
                .num("index", static_cast<int64_t>(index))
                .num("total", static_cast<int64_t>(list.size()))
                .num("freqKhz", cand.freqKhz)
                .str("phase", "probe")
                .endObject();
            emit(e.text());
        }
        const auto st = fmProbe(cand.freqKhz, true, running);
        if (!st) continue;
        if (pending && st->freqKhz - pending->freqKhz <= 100 && (!pending->pi || !st->pi || *pending->pi == *st->pi)) {
            // Same station seen twice (splatter / strong sideband): keep the stronger.
            if (st->levelDb > pending->levelDb) pending = st;
            continue;
        }
        if (pending) report(*pending);
        pending = st;
    }
    if (pending && running()) report(*pending);
    engineHalt();
    const bool completed = running();
    fmScanRunning_ = false;
    Event e;
    e.beginObject().str("type", "fmScanFinished").num("foundCount", found);
    if (!completed) e.boolean("cancelled", true);
    e.endObject();
    emit(e.text());
}

// Seek from fromKhz to the next station up/down, wrapping around the band
// once (see DabRtlSdrPlugin.seekFm).
void RadioController::seekFm(int fromKhz, bool up, int myId)
{
    auto current = [this, myId] { return fmSeekId_ == myId; };
    const bool wasPlaying = fmActive_;
    fmMuted_ = true;
    std::optional<int> result;
    if (ensureCreated()) {
        const int half = kFmWindowKhz / 2;
        std::vector<int> first, wrap;
        if (up) {
            for (int c = fromKhz + 50 + half; c - half <= kFmHighKhz; c += kFmWindowKhz) first.push_back(c);
            for (int c = kFmLowKhz + half; c - half < fromKhz; c += kFmWindowKhz) wrap.push_back(c);
        } else {
            for (int c = fromKhz - 50 - half; c + half >= kFmLowKhz; c -= kFmWindowKhz) first.push_back(c);
            for (int c = kFmHighKhz - half; c + half > fromKhz; c -= kFmWindowKhz) wrap.push_back(c);
        }
        std::set<int> probed;
        const std::vector<int>* passes[2] = {&first, &wrap};
        bool stop = false;
        for (int pass = 0; pass < 2 && !stop && !result; pass++) {
            for (int center : *passes[pass]) {
                if (!current()) {
                    stop = true;
                    break;
                }
                auto beyond = [&](int f) {
                    return pass == 0 ? (up ? f > fromKhz : f < fromKhz) : (up ? f < fromKhz : f > fromKhz);
                };
                std::vector<int> cands;
                for (const auto& c : fmSurvey(center)) {
                    if (beyond(c.freqKhz) && !probed.count(c.freqKhz)) cands.push_back(c.freqKhz);
                }
                if (up) std::sort(cands.begin(), cands.end());
                else std::sort(cands.rbegin(), cands.rend());
                for (int f : cands) {
                    if (!current()) {
                        stop = true;
                        break;
                    }
                    probed.insert(f);
                    if (fmProbe(f, false, current)) {
                        result = f;
                        break;
                    }
                }
                if (stop || result) break;
            }
        }
    }
    if (current()) {
        if (result) {
            // The probe left the receiver playing the station.
            fmFreqKhz_ = *result;
            ensureFmPlayer();
            fmActive_ = true;
        } else if (wasPlaying) {
            engineFmTune(static_cast<uint32_t>(fromKhz) * 1000u);
        } else {
            engineHalt();
        }
        fmMuted_ = false;
        Event e;
        e.beginObject().str("type", "fmSeekResult");
        if (result) e.num("freqKhz", *result);
        else e.null("freqKhz");
        e.endObject();
        emit(e.text());
        if (fmActive_) {
            const auto info = engineFmInfo();
            emitFmRds(fmFreqKhz_, info ? info->pi : std::nullopt, info ? info->ps : std::nullopt,
                      info ? info->rt : std::nullopt);
        }
    }
}

bool RadioController::handleFmCall(int64_t id, const std::string& method, const Json& args)
{
    if (method == "fmPlay" || method == "fmTune") {
        const int freqKhz = args.intOr("freqKhz", 0);
        if (freqKhz < kFmLowKhz - 500 || freqKhz > kFmHighKhz + 500) {
            replyError(id, "bad_frequency", "FM frequency out of range: " + std::to_string(freqKhz) + " kHz");
            return true;
        }
        // fmTune keeps the audio running (same player); fmPlay too, since a
        // running player is simply reused.
        fm_.post([this, id, freqKhz] { replyBool(id, fmPlayBlocking(freqKhz)); });
    } else if (method == "fmSeek") {
        const int fallback = fmFreqKhz_ > 0 ? fmFreqKhz_.load() : kFmLowKhz;
        const int fromKhz = args.intOr("fromKhz", fallback);
        const bool up = args.boolOr("up", true);
        const int myId = ++fmSeekId_;
        fm_.post([this, fromKhz, up, myId] {
            leaveDab();
            stopFmScanIfRunning();
            if (auto t = getThread(fmSeekThread_)) t->join(3000); // the superseded seek
            if (fmSeekId_ != myId) return;
            setThread(fmSeekThread_, BgThread::start([this, fromKhz, up, myId] { seekFm(fromKhz, up, myId); }));
        });
        replyNull(id);
    } else if (method == "fmStop") {
        fm_.post([this, id] {
            cancelFmSeek();
            stopFmPlayback();
            if (created_ && !fmScanRunning_) engineHalt();
            replyNull(id);
        });
    } else if (method == "fmScan") {
        bool expected = false;
        if (!fmScanRunning_.compare_exchange_strong(expected, true)) {
            replyError(id, "busy", "An FM scan is already running");
            return true;
        }
        fm_.post([this] {
            if (!fmScanRunning_) {
                // cancelled (DAB took over) before it started
                Event e;
                e.beginObject().str("type", "fmScanFinished").num("foundCount", 0).boolean("cancelled", true).endObject();
                emit(e.text());
                return;
            }
            leaveDab();
            cancelFmSeek();
            stopFmPlayback();
            std::lock_guard<std::mutex> lock(threadMutex_);
            fmScanThread_ = BgThread::start([this] {
                scanFm();
                fmScanRunning_ = false;
                std::lock_guard<std::mutex> lock2(threadMutex_);
                if (fmScanThread_ && fmScanThread_->isCurrent()) fmScanThread_.reset();
            });
        });
        replyNull(id);
    } else if (method == "stopFmScan") {
        fm_.post([this, id] {
            const bool wasRunning = getThread(fmScanThread_) != nullptr;
            stopFmScanIfRunning();
            if (created_ && wasRunning && !fmActive_) engineHalt();
            replyNull(id);
        });
    } else {
        return false;
    }
    return true;
}

// "nbStart", "nbTune", "nbSetSquelch", "nbSetFilters", "nbSetChannels",
// "nbStop"; all run on fm_.
bool RadioController::handleNbCall(int64_t id, const std::string& method, const Json& args)
{
    if (method == "nbStart") {
        const int sampleRate = args.intOr("sampleRate", 2048000);
        const int centerHz = args.intOr("centerHz", 0);
        const auto channels = intList(args, "channelsHz");
        const int freqHz = args.intOr("freqHz", 0);
        const std::string modeName = args.stringOr("mode", "auto");
        const int mode = nbModeCode(modeName);
        const float squelchDb = static_cast<float>(args.doubleOr("squelchDb", 10.0));
        if (mode < 0) {
            replyError(id, "bad_mode", "Unknown NB mode: " + modeName);
            return true;
        }
        if (freqHz <= 0) {
            replyError(id, "bad_frequency", "NB frequency missing");
            return true;
        }
        fm_.post([=] {
            stopDabActivities();
            stopFmActivities();
            bool ok = false;
            if (ensureCreated()) {
                ensureNbPlayer();
                nbActive_ = true;
                applyNbFilters();
                ok = engineNbStart(sampleRate, centerHz > 0 ? centerHz : freqHz, channels, freqHz, mode, squelchDb);
            }
            if (!ok) leaveNb();
            replyBool(id, ok);
        });
    } else if (method == "nbTune") {
        const int freqHz = args.intOr("freqHz", 0);
        const std::string modeName = args.stringOr("mode", "auto");
        const int mode = nbModeCode(modeName);
        if (mode < 0) {
            replyError(id, "bad_mode", "Unknown NB mode: " + modeName);
            return true;
        }
        fm_.post([=] { replyBool(id, nbActive_ && created_ && engineNbTune(freqHz, mode)); });
    } else if (method == "nbSetSquelch") {
        const float squelchDb = static_cast<float>(args.doubleOr("squelchDb", 0.0));
        fm_.post([=] {
            if (created_) engineNbSetSquelch(squelchDb);
            replyNull(id);
        });
    } else if (method == "nbSetFilters") {
        const std::string agcName = args.stringOr("agc", "auto");
        const int agc = nbAgcCode(agcName);
        if (agc < 0) {
            replyError(id, "bad_agc", "Unknown NB AGC mode: " + agcName);
            return true;
        }
        {
            std::lock_guard<std::mutex> lock(nbFiltersMutex_);
            nbFilters_.bandwidthHz = std::max(0, args.intOr("bandwidthHz", 0));
            nbFilters_.noiseBlanker = args.boolOr("noiseBlanker", false);
            nbFilters_.voiceFilter = args.boolOr("voiceFilter", true);
            nbFilters_.agc = agc;
        }
        fm_.post([=] {
            applyNbFilters();
            replyNull(id);
        });
    } else if (method == "nbSetChannels") {
        const int centerHz = args.intOr("centerHz", 0);
        const auto channels = intList(args, "channelsHz");
        fm_.post([=] { replyBool(id, nbActive_ && created_ && engineNbSetChannels(centerHz, channels)); });
    } else if (method == "nbStop") {
        fm_.post([=] {
            const bool wasActive = nbActive_;
            leaveNb();
            if (created_ && wasActive) engineHalt();
            replyNull(id);
        });
    } else {
        return false;
    }
    return true;
}

// The playService retry loop (see DabRtlSdrPlugin "playService"): a resolved
// service is not yet proof that audio flows, so wait for real PCM to reach
// the output and do one full retune + retry if none arrives.
void RadioController::playServiceThread(int64_t id, int freqKhz, int serviceId, int myRequestId)
{
    auto superseded = [this, myRequestId] { return playRequestId_ != myRequestId; };
    bool ok = false;
    bool pcmVerified = false;
    int attempt = 0;
    while (!pcmVerified && attempt < 2) {
        if (superseded()) {
            replyBool(id, false);
            return;
        }
        attempt++;
        engineTune(static_cast<uint32_t>(freqKhz) * 1000u);
        auto p = std::make_shared<AudioPlayer>();
        p->start();
        {
            std::lock_guard<std::mutex> lock(playerMutex_);
            audioPlayer_ = p;
        }
        ok = false;
        const int64_t deadline = nowMs() + 8000;
        while (!ok && !superseded() && nowMs() < deadline) {
            ok = enginePlayService(serviceId);
            if (!ok) sleepMs(200);
        }
        if (superseded()) {
            replyBool(id, false);
            return;
        }
        if (!ok) break; // service never resolved - a retry won't help

        const int64_t writeCountAtStart = p->pcmWriteCount();
        const int64_t pcmDeadline = nowMs() + 4000;
        while (p->pcmWriteCount() == writeCountAtStart && !superseded() && nowMs() < pcmDeadline) sleepMs(200);
        if (superseded()) {
            replyBool(id, false);
            return;
        }
        pcmVerified = p->pcmWriteCount() > writeCountAtStart;
        if (!pcmVerified && attempt < 2) {
            HR_LOGW("playService: 'playing' but no PCM arrived, retrying full tune (attempt %d)", attempt);
            stopPlayback();
        }
    }
    const bool reallyOk = ok && pcmVerified;
    {
        std::lock_guard<std::mutex> lock(contextMutex_);
        if (reallyOk) currentContext_ = std::make_pair(freqKhz, serviceId);
        else currentContext_.reset();
    }
    replyBool(id, reallyOk);
    Event e;
    e.beginObject().str("type", "playbackStatus").str("status", reallyOk ? "playing" : "error").endObject();
    emit(e.text());
}

void RadioController::onMethodCall(int64_t id, const std::string& method, const Json& args)
{
    if (handleFmCall(id, method, args)) return;
    if (handleNbCall(id, method, args)) return;
    if (method == "setServer") {
        const std::string host = args.stringOr("host", "127.0.0.1");
        const int port = args.intOr("port", 1234);
        bool replace;
        {
            std::lock_guard<std::mutex> lock(sessionMutex_);
            lastHost_ = host;
            lastPort_ = port;
            // The rtl_tcp endpoint (or the USB stick) is bound when the
            // session is created, so a different source needs a new one.
            replace = created_ && sessionEndpoint_ != host + ":" + std::to_string(port);
        }
        if (replace) {
            stopPlayback();
            leaveFm();
            destroySession();
        }
        if (!ensureCreated()) {
            replyError(id, "native_create_failed", "Could not create the DAB decoder");
            return;
        }
        // A real TCP probe, so a scan can refuse to start when nothing
        // listens at host:port instead of scanning 41 empty channels.
        BgThread::start([this, id, host, port] { replyBool(id, RtlTcpSource::probe(host, port, 1500)); });
    } else if (method == "useDirectUsb") {
        useDirectUsb(id);
    } else if (method == "scanBand3") {
        const Json& f = args["freqKhz"];
        const std::optional<int> onlyFreqKhz = f.isNumber() ? std::optional<int>(f.asInt()) : std::nullopt;
        bool expected = false;
        if (scanRunning_.compare_exchange_strong(expected, true)) {
            leaveFm(); // one stick: DAB takes it over
            setThread(scanThread_, BgThread::start([this, onlyFreqKhz] {
                          scanBand3(onlyFreqKhz);
                          scanRunning_ = false;
                      }));
            replyNull(id);
        } else {
            replyError(id, "busy", "A scan is already running");
        }
    } else if (method == "stopScan") {
        stopScanIfRunning();
        if (created_) engineHalt();
        replyNull(id);
    } else if (method == "tuneFrequency") {
        const int freqKhz = args.intOr("freqKhz", 0);
        if (!ensureCreated()) {
            replyError(id, "native_create_failed", "Could not create the DAB decoder");
            return;
        }
        leaveFm();
        engineTune(static_cast<uint32_t>(freqKhz) * 1000u);
        replyNull(id);
    } else if (method == "playService") {
        const int freqKhz = args.intOr("freqKhz", 0);
        const int serviceId = args.intOr("serviceId", 0);
        if (!ensureCreated()) {
            replyError(id, "native_create_failed", "Could not create the DAB decoder");
            return;
        }
        // One shared session: a running scan or logo fetch would keep
        // retuning underneath this request.
        stopScanIfRunning();
        stopLogoFetchIfRunning();
        stopPlayback();
        leaveFm();
        const int myRequestId = ++playRequestId_;
        BgThread::start([=] { playServiceThread(id, freqKhz, serviceId, myRequestId); });
    } else if (method == "stopPlayback") {
        // Stopping joins the audio threads - keep that off this thread.
        BgThread::start([this, id] {
            stopPlayback();
            replyNull(id);
        });
    } else if (method == "resetSession") {
        BgThread::start([this, id] {
            stopScanIfRunning();
            stopLogoFetchIfRunning();
            stopPlayback();
            leaveFm();
            destroySession();
            replyNull(id);
        });
    } else if (method == "getEnsembleLabel") {
        Event v;
        v.str(nullptr, created_ ? engineEnsembleLabel() : std::string());
        replyRaw(id, v.text());
    } else if (method == "fetchLogos") {
        std::vector<std::pair<int, int>> stations;
        for (const Json& s : args["stations"].items()) stations.emplace_back(s["freqKhz"].asInt(), s["serviceId"].asInt());
        if (stations.empty()) {
            replyNull(id);
            return;
        }
        bool expected = false;
        if (!logoFetchRunning_.compare_exchange_strong(expected, true)) {
            replyError(id, "busy", "A logo fetch is already running");
            return;
        }
        stopScanIfRunning();
        leaveFm();
        setThread(logoFetchThread_, BgThread::start([this, stations] {
                      fetchLogos(stations);
                      logoFetchRunning_ = false;
                  }));
        replyNull(id);
    } else if (method == "stopLogoFetch") {
        stopLogoFetchIfRunning();
        if (created_) engineHalt();
        replyNull(id);
    } else {
        replyError(id, "not_implemented", "Unknown method: " + method);
    }
}

} // namespace hrdab
