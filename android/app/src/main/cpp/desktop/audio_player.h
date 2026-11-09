#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace hrdab {

// Desktop counterpart of DabAacPlayer.kt: decodes the raw HE-AAC/AAC access
// units of DAB+ (FDK-AAC - the decoder Android's MediaCodec uses too, with
// 960-sample frames, SBR and PS) and plays them through miniaudio (WASAPI on
// Windows, PulseAudio/ALSA on Linux, both loaded at runtime).
//
// Same structure and timing as on Android, decoupled so neither the native
// receiver nor the decoder can be held up by the sound card:
//  - receiver thread -> onAccessUnit only enqueues (drops if full)
//  - decoder thread: FDK in, PCM into a ring buffer
//  - miniaudio's device callback: ring buffer -> speaker, with the
//    prebuffer (start and after an underrun), +-60 ms clock drift band
//    (one sample frame dropped/repeated per period) and fade-in
//  - output thread: (re)opens the device whenever rate/channels change
//
// FM and NB use the same output with ready-made PCM (onPcm).
class AudioPlayer {
public:
    explicit AudioPlayer(int prebufferMs = 400);
    ~AudioPlayer();

    void start();
    void stop();

    // New stream parameters (also sent again after every retune/service change).
    void onAudioConfig(const std::vector<uint8_t>& asc, int sampleRate, int channels);
    void onAccessUnit(const uint8_t* data, int len, bool ok);
    // Ready-made interleaved 16-bit PCM; `samples` counts all channels.
    void onPcm(const int16_t* pcm, int samples, int sampleRate, int channels);

    // Number of real (non-silence) PCM periods played so far.
    int64_t pcmWriteCount() const { return writes_; }

    // miniaudio data callback (public for the C trampoline).
    void render(int16_t* out, uint32_t frames);

private:
    struct Item {
        bool config = false;
        std::vector<uint8_t> data; // ASC or AU
        int sampleRate = 0;
        int channels = 0;
        bool ok = false;
    };
    struct Device;

    void decodeLoop();
    void outputLoop();
    void configureRing(int rate, int channels);
    void pushPcm(const int16_t* pcm, size_t samples, bool silent);

    const int prebufferMs_;
    std::atomic<bool> running_{false};
    std::thread decoderThread_;
    std::thread outputThread_;

    std::mutex queueMutex_;
    std::condition_variable queueCv_;
    std::deque<Item> queue_;

    // PCM ring (interleaved 16-bit), guarded by ringMutex_.
    std::mutex ringMutex_;
    std::vector<int16_t> ring_;
    size_t ringRead_ = 0;
    size_t ringFill_ = 0;
    std::atomic<int> outRate_{0};
    std::atomic<int> outChannels_{0};
    bool realPcmPending_ = false;

    // Device callback state.
    bool prebuffering_ = true;
    int fadeStep_ = 0;
    int deviceChannels_ = 0;
    std::atomic<int64_t> writes_{0};

    // Statistics, logged every 10 s by the output thread.
    std::atomic<int> underruns_{0};
    std::atomic<int> ausDecoded_{0};
    std::atomic<int> ausDamaged_{0};   // CRC failed upstream: silence
    std::atomic<int> decodeErrors_{0}; // FDK rejected the AU: silence
    std::atomic<int> ausDropped_{0};   // queue full
    std::atomic<int> minFillMs_{-1};
};

} // namespace hrdab
