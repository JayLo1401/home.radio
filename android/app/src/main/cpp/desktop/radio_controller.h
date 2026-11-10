#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "audio_player.h"
#include "json.h"
#include "receiver.h"
#include "rtltcp_source.h"

namespace hrdab {

// Runs posted jobs one after another on its own thread (Kotlin's
// single-thread executors and the Android main thread).
class SerialExecutor {
public:
    SerialExecutor();
    ~SerialExecutor();
    void post(std::function<void()> job);

private:
    void loop();
    std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<std::function<void()>> jobs_;
    bool stop_ = false;
    std::thread thread_;
};

// A detached worker thread that can be waited for with a timeout, like
// Kotlin's Thread.join(ms): after the timeout the caller moves on and the
// thread finishes on its own.
class BgThread {
public:
    static std::shared_ptr<BgThread> start(std::function<void()> body);
    // True if the thread has finished (within timeoutMs).
    bool join(int timeoutMs);
    bool isCurrent() const { return std::this_thread::get_id() == id_; }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool done_ = false;
    std::thread::id id_;
};

// The desktop port of DabRtlSdrPlugin.kt: the same method names, arguments,
// event payloads, scan flows, thresholds and timings, on top of the same
// native Receiver (instead of IntegratedDabEngine/JNI) and AudioPlayer
// (instead of DabAacPlayer). Kotlin's main thread is `main_`, its fmExecutor
// is `fm_`; replies and events go out through the sink as JSON (replies as
// {"type":"__reply","id":..,"value":..} or {..,"error":code,"message":..}).
class RadioController : private ReceiverListener {
public:
    using Sink = std::function<void(const std::string& json)>;

    RadioController(Sink sink, std::string dataDir);
    ~RadioController() override;

    // Queues a method call; never blocks.
    void call(int64_t id, const std::string& method, const std::string& argsJson);
    void setDataDir(const std::string& dir);
    // Stops every activity and closes the session (app exit).
    void shutdown();

private:
    struct FmInfo {
        bool valid = false;
        double levelDb = -100, snrDb = 0, offsetHz = 0;
        bool stereo = false, rdsSync = false;
        std::optional<int> pi;
        std::optional<std::string> ps, rt;
    };
    struct FmCandidate {
        int freqKhz;
        double levelDb;
    };
    struct FmStation {
        int freqKhz;
        double levelDb;
        bool stereo;
        std::optional<int> pi;
        std::optional<std::string> ps;
    };
    struct NbFilterSettings {
        int bandwidthHz = 0;
        bool noiseBlanker = false;
        bool voiceFilter = true;
        int agc = 0;
    };
    using Event = JsonWriter;

    // --- ReceiverListener (receiver threads) ---
    void onSync(bool synced) override;
    void onEnsembleLabel(const std::string& label) override;
    void onServiceDetected(uint32_t sid) override;
    void onDynamicLabel(const std::string& text) override;
    void onSnr(float snrDb) override;
    void onRsErrors(bool uncorrectable, int corrected) override;
    void onAacErrors(int count) override;
    void onAudioFormat(const std::string& format) override;
    void onAudioConfig(const std::vector<uint8_t>& asc, int sampleRate, int channels) override;
    void onAccessUnit(const uint8_t* data, int len, bool ok) override;
    void onSlide(const std::vector<uint8_t>& data, int contentSubType) override;
    void onStatus(bool isError, const std::string& message) override;
    void onFmAudio(const int16_t* pcm, int frames) override;
    void onFmStatus(const FmStatus& status, float gainDb) override;
    void onFmRds(int pi, const std::string& ps, const std::string& rt) override;
    void onNbAudio(const int16_t* pcm, int frames) override;
    void onNbReport(const NbReport& report, float gainDb) override;

    // --- output ---
    void emit(const std::string& json);
    void replyRaw(int64_t id, const std::string& valueJson);
    void replyBool(int64_t id, bool value) { replyRaw(id, value ? "true" : "false"); }
    void replyNull(int64_t id) { replyRaw(id, "null"); }
    void replyError(int64_t id, const std::string& code, const std::string& message);
    void emitSimple(const char* type, const char* key, const std::string& value);
    void emitFmRds(int freqKhz, std::optional<int> pi, const std::optional<std::string>& ps,
                   const std::optional<std::string>& rt);

    // --- engine (IntegratedDabEngine's role; engineMutex_) ---
    bool engineCreateTcp(const std::string& host, int port);
    bool engineCreateUsb(std::string& error);
    void engineDestroy();
    void engineTune(uint32_t hz);
    void engineHalt();
    std::string engineEnsembleLabel();
    std::vector<std::pair<int, std::string>> engineServices();
    bool enginePlayService(int sid);
    void engineStopService();
    bool engineFmTune(uint32_t hz);
    std::optional<std::vector<FmCandidate>> engineFmSurvey(uint32_t centerHz);
    std::optional<FmInfo> engineFmInfo();
    bool engineNbStart(int sampleRate, int centerHz, const std::vector<uint32_t>& channels, int freqHz, int mode,
                       float squelchDb);
    bool engineNbTune(int freqHz, int mode);
    void engineNbSetSquelch(float squelchDb);
    bool engineNbSetChannels(int centerHz, const std::vector<uint32_t>& channels);
    void engineNbSetFilters(const NbFilterSettings& f);

    // --- plugin logic (DabRtlSdrPlugin.kt) ---
    void onMethodCall(int64_t id, const std::string& method, const Json& args);
    bool handleFmCall(int64_t id, const std::string& method, const Json& args);
    bool handleNbCall(int64_t id, const std::string& method, const Json& args);
    bool ensureCreated();
    void destroySession();
    void useDirectUsb(int64_t id);
    void stopScanIfRunning();
    void stopLogoFetchIfRunning();
    void stopPlayback();
    void scanBand3(std::optional<int> onlyFreqKhz);
    void fetchLogos(const std::vector<std::pair<int, int>>& stations);
    void saveSlide(const std::vector<uint8_t>& data, int contentSubType);
    void stopDabActivities();
    void stopFmActivities();
    void leaveDab();
    void leaveFm();
    void leaveNb();
    void ensureNbPlayer();
    void applyNbFilters();
    void stopFmScanIfRunning();
    void cancelFmSeek();
    void stopFmPlayback();
    void ensureFmPlayer();
    bool fmPlayBlocking(int freqKhz);
    std::vector<FmCandidate> fmSurvey(int centerKhz);
    std::optional<FmStation> fmProbe(int freqKhz, bool waitRds, const std::function<bool()>& keepGoing);
    void scanFm();
    void seekFm(int fromKhz, bool up, int myId);
    void playServiceThread(int64_t id, int freqKhz, int serviceId, int myRequestId);

    std::shared_ptr<AudioPlayer> player(std::shared_ptr<AudioPlayer>& slot);
    std::shared_ptr<AudioPlayer> takePlayer(std::shared_ptr<AudioPlayer>& slot);
    std::shared_ptr<BgThread> getThread(std::shared_ptr<BgThread>& slot);
    void setThread(std::shared_ptr<BgThread>& slot, std::shared_ptr<BgThread> t);

    Sink sink_;
    std::mutex sinkMutex_;
    std::mutex dataDirMutex_;
    std::string dataDir_;

    std::mutex engineMutex_;
    std::unique_ptr<Receiver> rx_;

    std::mutex sessionMutex_;
    std::atomic<bool> created_{false};
    std::string lastHost_ = "127.0.0.1";
    int lastPort_ = 1234;
    std::string endpointKey() const;
    std::string sessionEndpoint_; // "host:port" of a live TCP session, empty = none
    bool usbSession_ = false;

    std::mutex playerMutex_;
    std::shared_ptr<AudioPlayer> audioPlayer_;
    std::shared_ptr<AudioPlayer> fmPlayer_;
    std::shared_ptr<AudioPlayer> nbPlayer_;

    std::atomic<int> playRequestId_{0};
    std::atomic<bool> scanRunning_{false};
    std::atomic<bool> scanSyncSeen_{false};
    std::atomic<bool> logoFetchRunning_{false};
    std::atomic<float> lastSnrDb_{0.f};

    std::mutex contextMutex_;
    std::optional<std::pair<int, int>> currentContext_;
    std::optional<std::string> lastLogoPath_;

    std::atomic<bool> fmActive_{false};
    std::atomic<bool> fmMuted_{false};
    std::atomic<int> fmFreqKhz_{0};
    std::atomic<bool> fmScanRunning_{false};
    std::atomic<int> fmSeekId_{0};
    std::atomic<bool> nbActive_{false};

    std::mutex nbFiltersMutex_;
    NbFilterSettings nbFilters_;

    std::mutex threadMutex_;
    std::shared_ptr<BgThread> scanThread_;
    std::shared_ptr<BgThread> logoFetchThread_;
    std::shared_ptr<BgThread> fmScanThread_;
    std::shared_ptr<BgThread> fmSeekThread_;

    SerialExecutor main_;
    SerialExecutor fm_;
};

} // namespace hrdab
