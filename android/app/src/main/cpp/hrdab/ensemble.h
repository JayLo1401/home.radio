#pragma once

#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace hrdab {

struct Subchannel {
    int id = -1;
    int startCu = 0;
    int sizeCu = 0;
    bool eep = false;    // long form (EEP); short form = UEP, not supported
    bool optionB = false;
    int level = 0;       // 0..3 = protection level 1..4
};

struct ServiceComponent {
    int tmid = 0;        // 0 = MSC stream audio
    int ascty = 0;       // 63 = DAB+, 0 = MPEG layer II
    int subchId = -1;
    bool primary = false;
};

struct Service {
    uint32_t sid = 0;
    std::string label;
    std::vector<ServiceComponent> components;

    bool hasAudio() const
    {
        for (const auto& c : components) if (c.tmid == 0) return true;
        return false;
    }
};

// What the FIC has told us about the currently tuned ensemble. Written by
// the decoder thread, read from JNI calls - always access under `mutex`.
struct Ensemble {
    std::mutex mutex;
    uint16_t eid = 0;
    std::string label;
    std::map<uint32_t, Service> services;
    std::map<int, Subchannel> subchannels;

    void clear()
    {
        std::lock_guard<std::mutex> lock(mutex);
        eid = 0;
        label.clear();
        services.clear();
        subchannels.clear();
    }
};

} // namespace hrdab
