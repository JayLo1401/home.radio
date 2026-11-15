// DMR (ETSI TS 102 361, the open standard of Tier I/II radios: amateur
// repeaters on 70 cm, DMR446, business radio) on the narrowband
// receiver's FM discriminator - written from the standard, no code of
// other DMR decoders:
//  - 4FSK at 4800 symbols/s: the discriminator (16 kS/s) goes through the
//    matching root-raised-cosine filter (roll-off 0.2) up to 48 kS/s, ten
//    samples per symbol;
//  - frame sync: the 24-symbol sync patterns (BS/MS sourced, TDMA direct
//    mode slot 1/2; voice and data are each other's complement) by
//    normalised correlation, which also gives the symbol levels and the
//    carrier offset; the burst around it is sliced from there;
//  - both TDMA slots: on a repeater's output the CACH's TC bit says which
//    slot a burst belongs to; a voice superframe (bursts A-F, 360 ms) is
//    followed from its sync in burst A, bursts B-F carry the EMB instead;
//  - data/control bursts: Slot Type (Golay 20,8: colour code, data type),
//    BPTC (196,96); voice LC header and terminator with their RS (12,9)
//    check give the call's source and destination (group or unit);
//  - embedded LC of bursts B-E (late entry: IDs also without the header),
//    talker alias (the radio's call sign/name) and the privacy bit;
//  - voice: the three AMBE+2 frames of every voice burst go to mbelib
//    (when built with HRDAB_MBELIB), 8 kHz audio of one slot at a time.
//
// A voice sync on its own (e.g. noise that happens to look like one) only
// starts a tentative call: it is reported and heard once the following
// bursts' EMB or the next superframe's sync confirm it.
//
// Not thread-safe; runs on the NB thread.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "fm_dsp.h"

namespace hrdab {

struct DmrSlotStatus {
    bool active = false;          // voice call in progress (confirmed)
    int callType = 0;             // 0 unknown, 1 group, 2 unit to unit
    uint32_t src = 0, dst = 0;    // radio ID, group/target; 0 = not yet known
    std::string alias;            // talker alias (UTF-8), "" = none
    bool encrypted = false;       // privacy: no audio
    bool emergency = false;
    float errorRate = 0;          // corrected bit errors per voice frame, this call
    double secondsAgo = -1;       // since the last voice burst, -1 = none yet
};

struct DmrStatus {
    bool sync = false;            // valid DMR bursts within the last second
    int source = 0;               // 0 unknown, 1 repeater (BS), 2 radio (MS), 3 direct mode
    int colorCode = -1;
    int audioSlot = -1;           // 0/1: the slot being played, -1 none
    bool voiceDecoder = false;    // built with the AMBE+2 decoder (mbelib)
    DmrSlotStatus slots[2];
};

// {"type":"nbDmr", "sync", "source" ("repeater"/"radio"/"direct"/""),
// "colorCode" (-1 unknown), "audioSlot" (1/2, 0 none), "voiceDecoder",
// "slots": [{"slot" 1/2, "active", "callType" ("group"/"private"/""),
// "src", "dst" (0 unknown), "alias", "encrypted", "emergency",
// "errorRate", "secondsAgo" (-1 never)}]}.
std::string dmrStatusJson(const DmrStatus& status);

class DmrDecoder {
public:
    static constexpr int kInputRate = 16000;
    static constexpr int kAudioRate = 8000;

    DmrDecoder();
    ~DmrDecoder();

    // Everything back to the start (new channel).
    void reset();
    // FM discriminator output in Hz (deviation), at kInputRate.
    void process(const float* hz, int n);
    // n samples of 8 kHz audio of the slot being played (silence when
    // none or while the jitter buffer fills); returns whether voice plays.
    bool pullAudio(float* out, int n);
    bool playing() const { return playing_; }
    // At least `count` (1 or 2) bursts verified by their FEC (or of a
    // confirmed call) within `ms`.
    bool recentlyValid(int ms, int count = 1) const;
    DmrStatus status() const;

    // Test hook: each decoded AMBE+2 frame's 49 data bits (as mbelib's
    // ambe_d) and the bit errors its FEC corrected.
    std::function<void(int slot, const char* ambe49, int errors)> onAmbeFrame;

private:
    struct Slot;
    struct Task {
        int64_t tSync = 0;        // centre of the last sync symbol
        int pattern = 0;          // 0 BS, 1 MS, 2 direct slot 1, 3 direct slot 2
        bool voice = false;
        float center = 0, half = 1;
    };

    void push(float y);
    void detectSync();
    void runDue();
    void updateDue();
    float at(int64_t t) const { return ring_[static_cast<size_t>(t & kRingMask)]; }
    int refine(int64_t tSync, float center, float half, int range) const;
    void slice(int64_t tSync, int first, int count, float center, float half, uint8_t* bits) const;
    float rhoAt(int64_t tSync, int pattern) const;
    void levelsFrom(int64_t tSync, int pattern, bool voice, float& center, float& half) const;
    void syncBurst(const Task& task);
    void trackerBurst(int slot);
    bool dataBurst(int slot, const Task& task, const uint8_t* bits);
    void voiceBurst(int slot, int64_t tSync, const uint8_t* bits, bool syncA, int pattern);
    void fullLc(int slot, const uint8_t* lc72, bool header);
    void embeddedLc(int slot, const uint8_t* lc72);
    void startVoice(int slot, int64_t tSync);
    void confirm(int slot);
    void endCall(int slot);
    void voiceFrames(int slot, const uint8_t* bits);
    void emitAudio(int slot, const float* pcm, int n);
    void fifoPush(const float* pcm, int n);
    void markValid(int pattern);

    static constexpr int kRingSize = 4096;
    static constexpr int64_t kRingMask = kRingSize - 1;

    RationalResampler<1> rrc_;    // 16 -> 48 kS/s with the matched filter
    std::vector<float> in48_;
    std::vector<float> ring_;
    int64_t t_ = 0;               // samples at 48 kS/s so far
    int64_t nextDue_ = 0;

    // sync search
    float pat_[4][24];
    bool peakValid_ = false;
    int64_t peakT_ = 0;
    float peakRho_ = 0;           // signed: negative = data sync
    int peakPattern_ = 0;
    int64_t lastEmit_ = -1000000;
    std::vector<Task> tasks_;

    // repeater slot numbering (CACH / timing)
    int64_t lastBsT_ = -1;
    int lastBsSlot_ = 0;

    std::unique_ptr<Slot> slots_[2];
    int audioSlot_ = -1;
    int64_t validT_ = -1000000;   // last verified burst
    int64_t prevValidT_ = -1000000;  // the one before
    int source_ = 0;
    int colorCode_ = -1;

    // audio out (8 kHz)
    std::vector<float> fifo_;
    size_t fifoRead_ = 0, fifoCount_ = 0;
    bool playing_ = false;
};

} // namespace hrdab
