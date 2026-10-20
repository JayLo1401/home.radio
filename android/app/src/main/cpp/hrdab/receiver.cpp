#include "receiver.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>
#include <sys/resource.h>

#include "common.h"

namespace hrdab {

namespace {

constexpr size_t kRingBytes = 8 * 1024 * 1024; // ~2 s of I/Q
constexpr size_t kMaxQueuedFrames = 6;          // ~0.6 s of demodulated frames

std::string jsonEscape(const std::string& s)
{
    std::string out;
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

} // namespace

Receiver::Receiver(std::unique_ptr<SampleSource> source, ReceiverListener& listener)
    : source_(std::move(source)),
      listener_(listener),
      ring_(kRingBytes),
      ofdm_(*this, *this),
      fic_(ensemble_, *this),
      superframe_(*this),
      pad_(*this)
{
    source_->onStatus = [this](bool isError, const std::string& message) { listener_.onStatus(isError, message); };
}

Receiver::~Receiver()
{
    halt();
}

bool Receiver::startLocked()
{
    if (running_) return true;
    ring_.reopen();
    stop_ = false;
    source_->setGainIndex(gainIndex_);
    if (!source_->start(ring_)) return false;
    ofdmThread_ = std::thread([this] {
        setpriority(PRIO_PROCESS, 0, -16);
        ofdm_.run(stop_);
    });
    decoderThread_ = std::thread([this] {
        setpriority(PRIO_PROCESS, 0, -10);
        decoderLoop();
    });
    running_ = true;
    return true;
}

void Receiver::stopLocked()
{
    if (!running_) return;
    stop_ = true;
    ring_.abort();
    queueCv_.notify_all();
    if (ofdmThread_.joinable()) ofdmThread_.join();
    if (decoderThread_.joinable()) decoderThread_.join();
    source_->stop();
    {
        std::lock_guard<std::mutex> lock(queueMutex_);
        queue_.clear();
    }
    running_ = false;
}

bool Receiver::tune(uint32_t hz)
{
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    stopService();
    generation_++;
    ensemble_.clear();
    const bool tuned = source_->setFrequency(hz);
    if (!tuned) HR_LOGW("tune: tuner did not accept %u Hz", hz);
    ofdm_.requestReset(hz);
    ring_.clear();
    ring_.interrupt();
    {
        std::lock_guard<std::mutex> qlock(queueMutex_);
        queue_.clear();
    }
    if (!startLocked()) return false;
    return tuned;
}

void Receiver::halt()
{
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    stopService();
    stopLocked();
}

bool Receiver::playService(uint32_t sid)
{
    Subchannel sub;
    {
        std::lock_guard<std::mutex> lock(ensemble_.mutex);
        auto it = ensemble_.services.find(sid);
        if (it == ensemble_.services.end()) return false;
        const ServiceComponent* audio = nullptr;
        for (const auto& c : it->second.components) {
            if (c.tmid != 0) continue;
            if (!audio || c.primary) audio = &c;
        }
        if (!audio) return false;
        if (audio->ascty != 63) {
            HR_LOGW("service 0x%04x is plain DAB (MPEG layer II) - not supported", sid);
            return false;
        }
        auto sc = ensemble_.subchannels.find(audio->subchId);
        if (sc == ensemble_.subchannels.end() || !sc->second.eep) return false;
        sub = sc->second;
    }
    std::lock_guard<std::mutex> lock(serviceMutex_);
    request_.version++;
    request_.active = true;
    request_.sub = sub;
    playing_ = true;
    HR_LOGI("play service 0x%04x: sub-channel %d, CU %d+%d", sid, sub.id, sub.startCu, sub.sizeCu);
    return true;
}

void Receiver::stopService()
{
    std::lock_guard<std::mutex> lock(serviceMutex_);
    if (!request_.active) return;
    request_.version++;
    request_.active = false;
    playing_ = false;
}

std::string Receiver::ensembleLabel()
{
    std::lock_guard<std::mutex> lock(ensemble_.mutex);
    return ensemble_.label;
}

std::string Receiver::serviceListJson()
{
    std::ostringstream out;
    out << "[";
    std::lock_guard<std::mutex> lock(ensemble_.mutex);
    bool first = true;
    for (const auto& kv : ensemble_.services) {
        const Service& s = kv.second;
        if (s.label.empty() || !s.hasAudio()) continue;
        if (!first) out << ",";
        first = false;
        out << "{\"serviceId\":" << s.sid << ",\"label\":\"" << jsonEscape(s.label) << "\"}";
    }
    out << "]";
    return out.str();
}

// --- OFDM thread ---

int Receiver::readIq(uint8_t* dst, int bytes)
{
    return static_cast<int>(ring_.read(dst, static_cast<size_t>(bytes)));
}

void Receiver::onReset()
{
    ofdmGeneration_ = generation_.load();
}

void Receiver::pushItem(const int8_t* soft, bool lost)
{
    std::lock_guard<std::mutex> lock(queueMutex_);
    if (queue_.size() >= kMaxQueuedFrames) {
        // Decoder fell behind: drop the backlog and mark the gap.
        for (auto& item : queue_) {
            if (!item.soft.empty()) pool_.push_back(std::move(item.soft));
        }
        queue_.clear();
        FrameItem gap;
        gap.lost = true;
        gap.generation = ofdmGeneration_;
        queue_.push_back(std::move(gap));
        HR_LOGW("decoder too slow - dropped queued frames");
    }
    FrameItem item;
    item.lost = lost;
    item.generation = ofdmGeneration_;
    if (!lost) {
        if (!pool_.empty()) {
            item.soft = std::move(pool_.back());
            pool_.pop_back();
        }
        item.soft.resize(kFrameSoftBits);
        std::memcpy(item.soft.data(), soft, kFrameSoftBits);
    }
    queue_.push_back(std::move(item));
    queueCv_.notify_one();
}

void Receiver::onFrame(const int8_t* soft)
{
    pushItem(soft, false);
}

void Receiver::onFrameLost()
{
    pushItem(nullptr, true);
}

void Receiver::onSync(bool synced)
{
    synced_ = synced;
    listener_.onSync(synced);
}

void Receiver::onSnr(float snrDb)
{
    listener_.onSnr(snrDb);
}

void Receiver::onLevel(float rms, float clipRatio)
{
    // Software AGC on the tuner's LNA/mixer gain. While searching it reacts
    // quickly; once synchronised it only steps for clear over/under drive,
    // since every gain change briefly disturbs the signal.
    const auto now = std::chrono::steady_clock::now();
    const bool synced = synced_;
    const auto minInterval = std::chrono::milliseconds(synced ? 2000 : 250);
    if (now - lastGainChange_ < minInterval) return;
    int step = 0;
    if (!synced && rms > 0.f) {
        // Searching: jump most of the way to the target level at once
        // (one gain step is ~1.6 dB on average).
        const float db = 20.f * std::log10(0.22f / rms);
        if (std::fabs(db) > 2.5f) step = static_cast<int>(std::lround(db / 1.6f * 0.7f));
        if (step > 4) step = 4;
        if (step < -6) step = -6;
    }
    if (clipRatio > 0.01f) step = std::min(step, -3);
    else if (clipRatio > 0.002f) step = std::min(step, -1);
    else if (!synced) {
        // handled above
    } else {
        if (rms < 0.05f) step = 1;
        else if (rms > 0.55f) step = -1;
    }
    if (step == 0) return;
    int g = gainIndex_ + step;
    if (g < 0) g = 0;
    if (g >= source_->gainCount()) g = source_->gainCount() - 1;
    if (g == gainIndex_) return;
    gainIndex_ = g;
    lastGainChange_ = now;
    source_->setGainIndex(g);
    HR_LOGI("AGC: rms %.3f clip %.4f -> gain %.1f dB", rms, clipRatio, source_->gainTenthsDb(g) / 10.0);
}

// --- decoder thread ---

void Receiver::applyServiceRequest()
{
    ServiceRequest req;
    {
        std::lock_guard<std::mutex> lock(serviceMutex_);
        if (request_.version == appliedVersion_) return;
        req = request_;
    }
    appliedVersion_ = req.version;
    superframe_.reset();
    pad_.reset();
    sub_.reset();
    serviceActive_ = req.active && sub_.configure(req.sub);
    auErrorsReported_ = 0;
}

void Receiver::decoderLoop()
{
    while (true) {
        FrameItem item;
        {
            std::unique_lock<std::mutex> lock(queueMutex_);
            queueCv_.wait(lock, [this] { return stop_.load() || !queue_.empty(); });
            if (stop_) return;
            item = std::move(queue_.front());
            queue_.pop_front();
        }
        const uint32_t gen = generation_;
        if (gen != decoderGeneration_) {
            decoderGeneration_ = gen;
            // tune() already cleared it, but a FIC frame of the old channel
            // that was mid-decode at that moment may have refilled it.
            ensemble_.clear();
            fic_.resetStats();
            superframe_.reset();
            pad_.reset();
            sub_.reset();
        }
        applyServiceRequest();

        if (item.generation == gen) {
            if (item.lost) {
                // Gap in the CIF timeline: the time de-interleaver and the
                // super frame alignment have to start over.
                sub_.reset();
                superframe_.reset();
            } else {
                fic_.processFrame(item.soft.data());
                if (serviceActive_) {
                    const int8_t* msc = item.soft.data() + kFicSymbols * kBitsPerSymbol;
                    for (int c = 0; c < kCifsPerFrame; c++) {
                        if (sub_.processCif(msc + c * kCifBits, cifBytes_)) superframe_.processFrame(cifBytes_);
                    }
                    const auto now = std::chrono::steady_clock::now();
                    if (now - lastAacReport_ > std::chrono::seconds(2)) {
                        lastAacReport_ = now;
                        const int errors = superframe_.auCrcErrors();
                        if (errors != auErrorsReported_) {
                            listener_.onAacErrors(errors - auErrorsReported_);
                            auErrorsReported_ = errors;
                        }
                    }
                }
            }
        }

        if (!item.soft.empty()) {
            std::lock_guard<std::mutex> lock(queueMutex_);
            pool_.push_back(std::move(item.soft));
        }
    }
}

void Receiver::onEnsembleLabel(const std::string& label)
{
    listener_.onEnsembleLabel(label);
}

void Receiver::onServiceDetected(uint32_t sid)
{
    listener_.onServiceDetected(sid);
}

void Receiver::onAudioParams(const AudioParams& params)
{
    if (!playing_) return;
    listener_.onAudioConfig(params.audioSpecificConfig(), params.outputSampleRate(), params.outputChannels());
    listener_.onAudioFormat(params.describe(sub_.bitrateKbps()));
}

void Receiver::onAccessUnit(const uint8_t* data, int len, bool ok)
{
    if (!playing_) return;
    if (ok) pad_.processAccessUnit(data, len);
    listener_.onAccessUnit(data, len, ok);
}

void Receiver::onSuperframeStats(bool rsUncorrectable, int rsCorrected)
{
    const auto now = std::chrono::steady_clock::now();
    if (!rsUncorrectable && rsCorrected == 0 && now - lastRsReport_ < std::chrono::seconds(2)) return;
    lastRsReport_ = now;
    listener_.onRsErrors(rsUncorrectable, rsCorrected);
}

void Receiver::onDynamicLabel(const std::string& text)
{
    if (playing_) listener_.onDynamicLabel(text);
}

void Receiver::onSlide(const std::vector<uint8_t>& data, int contentSubType)
{
    if (playing_) listener_.onSlide(data, contentSubType);
}

} // namespace hrdab
