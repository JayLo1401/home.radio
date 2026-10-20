#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace hrdab {

class PadListener {
public:
    virtual ~PadListener() = default;
    virtual void onDynamicLabel(const std::string& text) = 0;
    // A complete MOT object of content type "image"; subtype 1 = JPEG, 3 = PNG.
    virtual void onSlide(const std::vector<uint8_t>& data, int contentSubType) = 0;
};

// Programme associated data carried in the DAB+ access units: X-PAD
// (EN 300 401 clause 7.4), dynamic label segments (clause 7.4.5.2) and MOT
// slideshow objects in X-PAD data groups (EN 301 234, header mode).
class PadDecoder {
public:
    explicit PadDecoder(PadListener& listener) : listener_(listener) {}

    void reset();
    // A DAB+ access unit (without CRC). Only its leading data stream element
    // is looked at.
    void processAccessUnit(const uint8_t* au, int len);
    // PAD bytes as in a frame: X-PAD (reversed) followed by the 2 F-PAD bytes.
    void processPad(const uint8_t* pad, int len);

private:
    void subfield(int appType, const uint8_t* data, int len, bool start);
    void dlsGroup(const std::vector<uint8_t>& g);
    void motGroup(const std::vector<uint8_t>& g);

    PadListener& listener_;
    int lastAppType_ = -1;

    // Dynamic label
    std::vector<uint8_t> dlsBuf_;
    bool dlsActive_ = false;
    std::map<int, std::string> dlsSegments_; // raw bytes per segment number
    int dlsCharset_ = 0;
    int dlsToggle_ = -1;
    int dlsLastSeg_ = -1;
    std::string lastLabel_;

    // MOT
    std::vector<uint8_t> motBuf_;
    int motExpected_ = 0;
    bool motActive_ = false;
    struct MotObject {
        std::vector<uint8_t> header;
        std::map<int, std::vector<uint8_t>> headerSegs;
        int headerLast = -1;
        std::map<int, std::vector<uint8_t>> bodySegs;
        int bodyLast = -1;
        int contentType = -1;
        int contentSubType = -1;
        bool delivered = false;
    };
    std::map<int, MotObject> mot_; // by transport id
};

} // namespace hrdab
