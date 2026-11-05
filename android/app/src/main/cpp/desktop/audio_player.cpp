#include "audio_player.h"

#include <algorithm>
#include <chrono>
#include <cstring>

#include <aacdecoder_lib.h>

#include "common.h"
#include "miniaudio.h"

namespace hrdab {

namespace {

constexpr int kBandMs = 60;
constexpr int kRingMs = 3000;
constexpr int kFadeSteps = 30; // x ~10 ms
constexpr size_t kMaxQueued = 64;

bool isSbr(const std::vector<uint8_t>& asc)
{
    if (asc.empty()) return false;
    const int aot = asc[0] >> 3;
    return aot == 5 || aot == 29;
}

void dataCallback(ma_device* device, void* output, const void*, ma_uint32 frames)
{
    static_cast<AudioPlayer*>(device->pUserData)->render(static_cast<int16_t*>(output), frames);
}

// FDK-AAC for raw DAB+ access units, configured from the AudioSpecificConfig
// the super frame decoder builds (960-sample frames, SBR/PS signalled
// explicitly), exactly what Android's MediaCodec gets as csd-0.
class AacDecoder {
public:
    ~AacDecoder() { close(); }

    bool open(const std::vector<uint8_t>& asc)
    {
        close();
        handle_ = aacDecoder_Open(TT_MP4_RAW, 1);
        if (!handle_) return false;
        std::vector<uint8_t> conf = asc;
        UCHAR* confPtr = conf.data();
        const UINT confLen = static_cast<UINT>(conf.size());
        if (aacDecoder_ConfigRaw(handle_, &confPtr, &confLen) != AAC_DEC_OK) {
            HR_LOGE("AAC: decoder rejected the audio config");
            close();
            return false;
        }
        return true;
    }

    // Decodes one access unit into `out` (interleaved); false on error.
    bool decode(const uint8_t* data, int len, std::vector<int16_t>& out, int& rate, int& channels)
    {
        if (!handle_) return false;
        UCHAR* in = const_cast<UCHAR*>(data);
        const UINT size = static_cast<UINT>(len);
        UINT valid = size;
        if (aacDecoder_Fill(handle_, &in, &size, &valid) != AAC_DEC_OK) return false;
        out.resize(8 * 2048);
        const AAC_DECODER_ERROR err =
            aacDecoder_DecodeFrame(handle_, reinterpret_cast<INT_PCM*>(out.data()), static_cast<INT>(out.size()), 0);
        if (err != AAC_DEC_OK) return false;
        const CStreamInfo* info = aacDecoder_GetStreamInfo(handle_);
        if (!info || info->numChannels <= 0 || info->frameSize <= 0) return false;
        rate = info->sampleRate;
        channels = info->numChannels;
        out.resize(static_cast<size_t>(info->frameSize) * static_cast<size_t>(info->numChannels));
        return true;
    }

    void close()
    {
        if (handle_) aacDecoder_Close(handle_);
        handle_ = nullptr;
    }

private:
    HANDLE_AACDECODER handle_ = nullptr;
};

} // namespace

struct AudioPlayer::Device {
    ma_device device{};
};

AudioPlayer::AudioPlayer(int prebufferMs) : prebufferMs_(prebufferMs) {}

AudioPlayer::~AudioPlayer()
{
    stop();
}

void AudioPlayer::start()
{
    if (running_) return;
    running_ = true;
    decoderThread_ = std::thread(&AudioPlayer::decodeLoop, this);
    outputThread_ = std::thread(&AudioPlayer::outputLoop, this);
}

void AudioPlayer::stop()
{
    if (!running_.exchange(false)) return;
    queueCv_.notify_all();
    if (decoderThread_.joinable()) decoderThread_.join();
    if (outputThread_.joinable()) outputThread_.join();
    std::lock_guard<std::mutex> lock(queueMutex_);
    queue_.clear();
}

void AudioPlayer::onAudioConfig(const std::vector<uint8_t>& asc, int sampleRate, int channels)
{
    if (!running_) return;
    Item item;
    item.config = true;
    item.data = asc;
    item.sampleRate = sampleRate;
    item.channels = channels;
    std::lock_guard<std::mutex> lock(queueMutex_);
    if (queue_.size() < kMaxQueued) queue_.push_back(std::move(item));
    queueCv_.notify_one();
}

void AudioPlayer::onAccessUnit(const uint8_t* data, int len, bool ok)
{
    if (!running_) return;
    Item item;
    item.ok = ok;
    if (ok && len > 0) item.data.assign(data, data + len);
    std::lock_guard<std::mutex> lock(queueMutex_);
    if (queue_.size() >= kMaxQueued) {
        HR_LOGW("AU queue full, dropping");
        return;
    }
    queue_.push_back(std::move(item));
    queueCv_.notify_one();
}

void AudioPlayer::onPcm(const int16_t* pcm, int samples, int sampleRate, int channels)
{
    if (!running_) return;
    configureRing(sampleRate, channels);
    pushPcm(pcm, static_cast<size_t>(samples), false);
}

// --- decoder thread ---

void AudioPlayer::decodeLoop()
{
    AacDecoder decoder;
    bool haveDecoder = false;
    int frameSamples = 960; // per channel, at the output rate
    std::vector<int16_t> pcm;
    while (running_) {
        Item item;
        {
            std::unique_lock<std::mutex> lock(queueMutex_);
            queueCv_.wait_for(lock, std::chrono::milliseconds(20), [this] { return !running_ || !queue_.empty(); });
            if (!running_) break;
            if (queue_.empty()) continue;
            item = std::move(queue_.front());
            queue_.pop_front();
        }
        if (item.config) {
            haveDecoder = decoder.open(item.data);
            // SBR doubles the 960-sample core frame.
            frameSamples = isSbr(item.data) ? 1920 : 960;
            configureRing(item.sampleRate, item.channels);
            if (haveDecoder) HR_LOGI("AAC decoder for %d Hz x%d", item.sampleRate, item.channels);
        } else if (!haveDecoder) {
            // no config yet - nothing to decode against
        } else if (item.ok && !item.data.empty()) {
            int rate = 0, channels = 0;
            if (decoder.decode(item.data.data(), static_cast<int>(item.data.size()), pcm, rate, channels)) {
                configureRing(rate, channels);
                pushPcm(pcm.data(), pcm.size(), false);
            } else {
                pcm.assign(static_cast<size_t>(frameSamples) * std::max(outChannels_.load(), 1), 0);
                pushPcm(pcm.data(), pcm.size(), true);
            }
        } else {
            // Damaged AU: keep the timeline with silence rather than feeding
            // garbage to the decoder.
            pcm.assign(static_cast<size_t>(frameSamples) * std::max(outChannels_.load(), 1), 0);
            pushPcm(pcm.data(), pcm.size(), true);
        }
    }
}

void AudioPlayer::configureRing(int rate, int channels)
{
    std::lock_guard<std::mutex> lock(ringMutex_);
    if (rate == outRate_ && channels == outChannels_ && !ring_.empty()) return;
    outRate_ = rate;
    outChannels_ = channels;
    ring_.assign(static_cast<size_t>(rate) * static_cast<size_t>(channels) * kRingMs / 1000, 0);
    ringRead_ = 0;
    ringFill_ = 0;
}

void AudioPlayer::pushPcm(const int16_t* pcm, size_t samples, bool silent)
{
    std::lock_guard<std::mutex> lock(ringMutex_);
    const size_t cap = ring_.size();
    if (cap == 0) return;
    if (samples > cap) {
        pcm += samples - cap;
        samples = cap;
    }
    // Overflow means playback stalled for seconds - drop the oldest.
    if (ringFill_ + samples > cap) {
        const size_t overflow = ringFill_ + samples - cap;
        ringRead_ = (ringRead_ + overflow) % cap;
        ringFill_ -= overflow;
    }
    size_t w = (ringRead_ + ringFill_) % cap;
    for (size_t i = 0; i < samples; i++) {
        ring_[w] = pcm[i];
        if (++w == cap) w = 0;
    }
    ringFill_ += samples;
    if (!silent) realPcmPending_ = true;
}

// --- output ---

void AudioPlayer::render(int16_t* out, uint32_t frames)
{
    const int channels = deviceChannels_;
    const size_t want = static_cast<size_t>(frames) * static_cast<size_t>(channels);
    bool real = false;
    {
        std::lock_guard<std::mutex> lock(ringMutex_);
        const int rate = outRate_;
        const size_t prebufferSamples = static_cast<size_t>(rate) * channels * prebufferMs_ / 1000;
        const size_t band = static_cast<size_t>(rate) * channels * kBandMs / 1000;
        if (channels != outChannels_ || ring_.empty()) {
            std::memset(out, 0, want * sizeof(int16_t)); // device about to be reopened
            return;
        }
        if (prebuffering_ && ringFill_ >= prebufferSamples) prebuffering_ = false;
        if (!prebuffering_ && ringFill_ < want) {
            prebuffering_ = true; // underrun: rebuild the cushion
            HR_LOGW("underrun, re-buffering");
        }
        if (prebuffering_) {
            std::memset(out, 0, want * sizeof(int16_t));
        } else {
            // Clock drift: +-1 frame per period outside the band.
            int adjust = 0;
            if (ringFill_ > prebufferSamples + band) adjust = 1;
            else if (ringFill_ + band < prebufferSamples) adjust = -1;
            const size_t take = (static_cast<size_t>(frames) + adjust) * channels;
            const size_t cap = ring_.size();
            const size_t n = std::min(take, ringFill_);
            const size_t copy = std::min(n, want);
            for (size_t i = 0; i < copy; i++) out[i] = ring_[(ringRead_ + i) % cap];
            // repeating a frame: duplicate the last one
            for (size_t i = copy; i < want; i++) {
                out[i] = copy >= static_cast<size_t>(channels) ? out[copy - channels + (i - copy) % channels] : 0;
            }
            ringRead_ = (ringRead_ + n) % cap;
            ringFill_ -= n;
            real = realPcmPending_;
        }
    }
    if (real && !prebuffering_) {
        writes_++;
        if (fadeStep_ < kFadeSteps) {
            fadeStep_++;
            const int gain = fadeStep_ * 256 / kFadeSteps;
            for (size_t i = 0; i < want; i++) out[i] = static_cast<int16_t>(out[i] * gain / 256);
        }
    }
}

void AudioPlayer::outputLoop()
{
    raiseThreadPriority(-16);
    std::unique_ptr<Device> dev;
    int devRate = 0;
    int devChannels = 0;
    auto close = [&] {
        if (dev) ma_device_uninit(&dev->device);
        dev.reset();
    };
    while (running_) {
        const int rate = outRate_;
        const int channels = outChannels_;
        if (rate > 0 && channels > 0 && (!dev || rate != devRate || channels != devChannels)) {
            close();
            {
                std::lock_guard<std::mutex> lock(ringMutex_);
                deviceChannels_ = channels;
                prebuffering_ = true;
                fadeStep_ = 0;
            }
            auto d = std::make_unique<Device>();
            ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
            cfg.playback.format = ma_format_s16;
            cfg.playback.channels = static_cast<ma_uint32>(channels);
            cfg.sampleRate = static_cast<ma_uint32>(rate);
            cfg.periodSizeInMilliseconds = 10;
            cfg.performanceProfile = ma_performance_profile_low_latency;
            cfg.dataCallback = dataCallback;
            cfg.pUserData = this;
            if (ma_device_init(nullptr, &cfg, &d->device) != MA_SUCCESS) {
                HR_LOGE("audio: no output device");
                std::this_thread::sleep_for(std::chrono::milliseconds(1000));
                continue;
            }
            if (ma_device_start(&d->device) != MA_SUCCESS) {
                ma_device_uninit(&d->device);
                HR_LOGE("audio: output device would not start");
                std::this_thread::sleep_for(std::chrono::milliseconds(1000));
                continue;
            }
            dev = std::move(d);
            devRate = rate;
            devChannels = channels;
            HR_LOGI("audio: %d Hz x%d, prebuffer %d ms", rate, channels, prebufferMs_);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    close();
}

} // namespace hrdab
