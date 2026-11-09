#include "receiver.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <sstream>

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
      pad_(*this),
      fm_(*this, *this),
      nb_(*this, *this)
{
    source_->onStatus = [this](bool isError, const std::string& message) { listener_.onStatus(isError, message); };
}

Receiver::~Receiver()
{
    halt();
}

bool Receiver::startLocked(Mode mode)
{
    if (running_ && mode_ == mode) return true;
    // Switching modes: the other mode's threads must not read the ring.
    if (running_) stopLocked();
    // DAB and FM need 2.048 MS/s; NB brings its own rate. The source is
    // stopped here, which is when a rate change is allowed.
    const uint32_t rate = mode == Mode::Nb ? nbRate_ : static_cast<uint32_t>(kSampleRate);
    if (source_->sampleRate() != rate && !source_->setSampleRate(rate)) {
        HR_LOGW("could not set the sample rate to %u", rate);
        return false;
    }
    ring_.reopen();
    stop_ = false;
    source_->setGainIndex(gainIndex_);
    if (!source_->start(ring_)) return false;
    mode_ = mode;
    if (mode == Mode::Nb) {
        nbThread_ = std::thread([this] {
            raiseThreadPriority(-16);
            nb_.run(stop_);
        });
    } else if (mode == Mode::Dab) {
        ofdmThread_ = std::thread([this] {
            raiseThreadPriority(-16);
            ofdm_.run(stop_);
        });
        decoderThread_ = std::thread([this] {
            raiseThreadPriority(-10);
            decoderLoop();
        });
    } else {
        fmThread_ = std::thread([this] {
            raiseThreadPriority(-16);
            fm_.run(stop_);
        });
    }
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
    if (fmThread_.joinable()) fmThread_.join();
    if (nbThread_.joinable()) nbThread_.join();
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
    if (!startLocked(Mode::Dab)) return false;
    return tuned;
}

bool Receiver::fmTune(uint32_t hz)
{
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    stopService();
    // Leave DAB before retuning, so the OFDM thread never sees FM samples.
    if (running_ && mode_ != Mode::Fm) stopLocked();
    const bool tuned = source_->setFrequency(hz - FmDemod::kIfShiftHz);
    if (!tuned) HR_LOGW("fmTune: tuner did not accept %u Hz", hz);
    fm_.requestPlay();
    ring_.clear();
    ring_.interrupt();
    if (!startLocked(Mode::Fm)) return false;
    return tuned;
}

bool Receiver::fmSurvey(uint32_t centerHz, uint32_t lowHz, uint32_t highHz, std::vector<FmCarrier>& out)
{
    out.clear();
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    stopService();
    if (running_ && mode_ != Mode::Fm) stopLocked();
    if (!source_->setFrequency(centerHz)) {
        HR_LOGW("fmSurvey: tuner did not accept %u Hz", centerHz);
        return false;
    }
    fm_.requestSurvey();
    ring_.clear();
    ring_.interrupt();
    if (!startLocked(Mode::Fm)) return false;
    std::vector<float> spectrum;
    if (!fm_.waitSurvey(spectrum, 3000)) {
        HR_LOGW("fmSurvey: no spectrum at %u Hz", centerHz);
        return false;
    }
    out = findFmCarriers(spectrum, centerHz, lowHz, highHz);
    return true;
}

// --- narrowband ---

void Receiver::nbConfigureLocked()
{
    NbConfig cfg;
    cfg.sampleRate = nbRate_;
    cfg.loHz = nbLoHz_;
    cfg.channelsHz = nbChannels_;
    cfg.freqHz = nbFreqHz_;
    cfg.mode = nbMode_;
    cfg.retune = nbRetune_;
    nb_.configure(cfg);
}

bool Receiver::nbRetuneLocked(uint32_t centerHz)
{
    std::vector<uint32_t> freqs = nbChannels_;
    freqs.push_back(nbFreqHz_);
    nbLoHz_ = NbDemod::placeLo(nbRate_, centerHz, freqs);
    const bool tuned = source_->setFrequency(nbLoHz_);
    if (!tuned) HR_LOGW("nb: tuner did not accept %u Hz", nbLoHz_);
    nbRetune_++;
    nbConfigureLocked();
    ring_.clear();
    ring_.interrupt();
    if (!startLocked(Mode::Nb)) return false;
    return tuned;
}

bool Receiver::nbStart(uint32_t sampleRate, uint32_t centerHz, const std::vector<uint32_t>& channelsHz,
                       uint32_t freqHz, NbMode mode, float squelchDb)
{
    if (!NbDemod::supportedRate(sampleRate)) {
        HR_LOGW("nbStart: unsupported sample rate %u", sampleRate);
        return false;
    }
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    stopService();
    // Leave DAB/FM (or NB at another rate) before retuning: their threads
    // must never see NB samples, and the rate only changes while stopped.
    if (running_ && (mode_ != Mode::Nb || nbRate_ != sampleRate)) stopLocked();
    nbRate_ = sampleRate;
    nbChannels_ = channelsHz;
    nbFreqHz_ = freqHz;
    nbMode_ = mode;
    nb_.setSquelch(squelchDb);
    uint32_t center = centerHz;
    if (!NbDemod::canListen(sampleRate, NbDemod::placeLo(sampleRate, center, {freqHz}), freqHz, mode)) center = freqHz;
    return nbRetuneLocked(center);
}

bool Receiver::nbTune(uint32_t freqHz, NbMode mode)
{
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (!running_ || mode_ != Mode::Nb) return false;
    nbFreqHz_ = freqHz;
    nbMode_ = mode;
    if (NbDemod::canListen(nbRate_, nbLoHz_, freqHz, mode)) {
        // Same window: only the channel chain restarts, no retune.
        nbConfigureLocked();
        return true;
    }
    return nbRetuneLocked(freqHz);
}

void Receiver::nbSetSquelch(float squelchDb)
{
    nb_.setSquelch(squelchDb);
}

bool Receiver::nbSetChannels(uint32_t centerHz, const std::vector<uint32_t>& channelsHz)
{
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (!running_ || mode_ != Mode::Nb) return false;
    nbChannels_ = channelsHz;
    std::vector<uint32_t> freqs = nbChannels_;
    freqs.push_back(nbFreqHz_);
    if (NbDemod::placeLo(nbRate_, centerHz, freqs) == nbLoHz_) {
        nbConfigureLocked();
        return true;
    }
    return nbRetuneLocked(centerHz);
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

std::string Receiver::fmInfoJson()
{
    const FmDemod::Info info = fm_.info();
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "{\"valid\":%s,\"levelDb\":%.1f,\"snrDb\":%.1f,\"stereo\":%s,\"offsetHz\":%.0f,\"pilot\":%.3f,"
                  "\"rdsSync\":%s,\"pi\":",
                  info.valid ? "true" : "false", info.status.levelDbfs - gainDb(), info.status.snrDb,
                  info.status.stereo ? "true" : "false", info.status.offsetHz, info.status.pilot,
                  info.rdsSync ? "true" : "false");
    std::string out = buf;
    out += info.pi >= 0 ? std::to_string(info.pi) : "null";
    out += ",\"ps\":";
    out += info.ps.empty() ? "null" : "\"" + jsonEscape(info.ps) + "\"";
    out += ",\"rt\":";
    out += info.rt.empty() ? "null" : "\"" + jsonEscape(info.rt) + "\"";
    out += "}";
    return out;
}

std::string Receiver::fmCarriersJson(const std::vector<FmCarrier>& carriers)
{
    std::string out = "[";
    const float gain = gainDb();
    for (size_t i = 0; i < carriers.size(); i++) {
        char buf[96];
        std::snprintf(buf, sizeof(buf), "%s{\"freqKhz\":%u,\"levelDb\":%.1f,\"marginDb\":%.1f}", i ? "," : "",
                      carriers[i].freqHz / 1000, carriers[i].levelDbfs - gain, carriers[i].marginDb);
        out += buf;
    }
    out += "]";
    return out;
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

void Receiver::pushItem(const int8_t* soft, bool lost, bool erased)
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
        stats_.queueDrops++;
        HR_LOGW("decoder too slow - dropped queued frames");
    }
    FrameItem item;
    item.lost = lost;
    item.erased = erased;
    item.generation = ofdmGeneration_;
    if (!lost) {
        if (!pool_.empty()) {
            item.soft = std::move(pool_.back());
            pool_.pop_back();
        }
        item.soft.resize(kFrameSoftBits);
        if (erased) std::memset(item.soft.data(), 0, kFrameSoftBits);
        else std::memcpy(item.soft.data(), soft, kFrameSoftBits);
    }
    queue_.push_back(std::move(item));
    queueCv_.notify_one();
}

void Receiver::onFrame(const int8_t* soft)
{
    stats_.framesOk++;
    pushItem(soft, false, false);
}

void Receiver::onFrameLost(bool inTimeline)
{
    // In the timeline: an erasure keeps the time de-interleaver and the
    // super frame alignment; the Viterbi decoder and RS usually bridge one
    // frame, since time interleaving spreads it over 16 logical frames.
    // Resetting instead cost ~1 s of audio for every single lost frame.
    if (inTimeline) stats_.framesErased++;
    else stats_.gaps++;
    pushItem(nullptr, !inTimeline, inTimeline);
}

void Receiver::onSync(bool synced)
{
    if (!synced && synced_) {
        stats_.syncLosses++;
        HR_LOGW("DAB: sync lost (offset %.0f Hz, clock %.1f ppm)", ofdm_.frequencyOffsetHz(), ofdm_.sampleClockPpm());
    }
    synced_ = synced;
    listener_.onSync(synced);
}

void Receiver::onSnr(float snrDb)
{
    stats_.snrDb = snrDb;
    listener_.onSnr(snrDb);
}

// One line of reception statistics per period - what tells a weak or
// drifting signal (SNR, offsets, erasures, sync losses, FIC/RS/AU errors)
// from a starved pipeline (ring/queue drops). Decoder thread.
void Receiver::logStats(bool force)
{
    constexpr auto kStatsPeriod = std::chrono::seconds(10);
    const auto now = std::chrono::steady_clock::now();
    if (stats_.since == std::chrono::steady_clock::time_point{}) stats_.since = now;
    if (!force && now - stats_.since < kStatsPeriod) return;
    const double secs = std::chrono::duration<double>(now - stats_.since).count();
    const int ficOk = fic_.fibsOk() - stats_.ficOkBase;
    const int ficBad = fic_.fibsBad() - stats_.ficBadBase;
    const int auErr = superframe_.auCrcErrors() - stats_.auErrorsBase;
    const size_t ringDropped = ring_.takeDropped();
    HR_LOGI("DAB stats %.0fs: SNR %.1f dB, carrier %.0f Hz, clock %.1f ppm, phase %.1f deg, timing %+.0f, gain %.1f dB (%d changes) | "
            "frames ok %d erased %d gaps %d, sync lost %d | FIC CRC bad %d/%d | superframes %d, RS fixed %d, "
            "RS uncorrectable %d | AU CRC bad %d/%d | dropped: I/Q %zu bytes, decoder queue %d",
            secs, stats_.snrDb.load(), ofdm_.frequencyOffsetHz(), ofdm_.sampleClockPpm(), ofdm_.commonPhaseDeg(),
            ofdm_.lastTimingStep(), gainDb(), stats_.gainChanges.exchange(0), stats_.framesOk.exchange(0), stats_.framesErased.exchange(0),
            stats_.gaps.exchange(0), stats_.syncLosses.exchange(0), ficBad, ficOk + ficBad, stats_.superframes,
            stats_.rsCorrected, stats_.rsUncorrectable, auErr, stats_.auTotal, ringDropped,
            stats_.queueDrops.exchange(0));
    stats_.ficOkBase = fic_.fibsOk();
    stats_.ficBadBase = fic_.fibsBad();
    stats_.auErrorsBase = superframe_.auCrcErrors();
    stats_.superframes = 0;
    stats_.rsCorrected = 0;
    stats_.rsUncorrectable = 0;
    stats_.auTotal = 0;
    stats_.since = now;
}

void Receiver::onLevel(float rms, float clipRatio)
{
    adjustGain(rms, clipRatio, synced_, std::chrono::milliseconds(250));
}

bool Receiver::adjustGain(float rms, float clipRatio, bool synced, std::chrono::milliseconds searchInterval)
{
    // Software AGC on the tuner's LNA/mixer gain. While searching it reacts
    // quickly; once synchronised it only steps for clear over/under drive,
    // since every gain change briefly disturbs the signal.
    const auto now = std::chrono::steady_clock::now();
    const auto minInterval = synced ? std::chrono::milliseconds(2000) : searchInterval;
    if (now - lastGainChange_ < minInterval) return false;
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
    if (step == 0) return false;
    int g = gainIndex_ + step;
    if (g < 0) g = 0;
    if (g >= source_->gainCount()) g = source_->gainCount() - 1;
    if (g == gainIndex_) return false;
    gainIndex_ = g;
    lastGainChange_ = now;
    stats_.gainChanges++;
    source_->setGainIndex(g);
    HR_LOGI("AGC: rms %.3f clip %.4f -> gain %.1f dB", rms, clipRatio, source_->gainTenthsDb(g) / 10.0);
    return true;
}

// --- FM thread ---

bool Receiver::onFmLevel(float rms, float clipRatio, bool settled)
{
    // FmDemod paces its reports and waits for the new gain to arrive itself,
    // so no extra hold-off while searching.
    return adjustGain(rms, clipRatio, settled, std::chrono::milliseconds(0));
}

void Receiver::onFmAudio(const int16_t* pcm, int frames)
{
    listener_.onFmAudio(pcm, frames);
}

void Receiver::onFmStatus(const FmStatus& status)
{
    listener_.onFmStatus(status, gainDb());
}

void Receiver::onFmRds(int pi, const std::string& ps, const std::string& rt)
{
    listener_.onFmRds(pi, ps, rt);
}

// --- NB thread ---

bool Receiver::onNbLevel(float rms, float clipRatio, bool settled)
{
    return adjustGain(rms, clipRatio, settled, std::chrono::milliseconds(0));
}

void Receiver::onNbAudio(const int16_t* pcm, int frames)
{
    listener_.onNbAudio(pcm, frames);
}

void Receiver::onNbReport(const NbReport& report)
{
    listener_.onNbReport(report, gainDb());
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
            stats_.ficOkBase = 0;
            stats_.ficBadBase = 0;
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
                // An erased frame has no FIC worth decoding; its MSC part
                // (all zero = "don't know") still goes through, see onFrameLost.
                if (!item.erased) fic_.processFrame(item.soft.data());
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
        logStats(false);
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
    stats_.auTotal++;
    if (!playing_) return;
    if (ok) pad_.processAccessUnit(data, len);
    listener_.onAccessUnit(data, len, ok);
}

void Receiver::onSuperframeStats(bool rsUncorrectable, int rsCorrected)
{
    stats_.superframes++;
    stats_.rsCorrected += rsCorrected;
    if (rsUncorrectable) stats_.rsUncorrectable++;
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
