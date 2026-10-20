#include "pad.h"

#include <algorithm>

#include "charset.h"
#include "dab_tables.h"

namespace hrdab {

namespace {

const int kSubfieldLen[8] = {4, 6, 8, 12, 16, 24, 32, 48};

constexpr int kAppDgli = 1;
constexpr int kAppDlsStart = 2;
constexpr int kAppDlsCont = 3;
constexpr int kAppMotStart = 12;
constexpr int kAppMotCont = 13;

constexpr size_t kMaxMotObjects = 6;
constexpr size_t kMaxMotBody = 1024 * 1024;

} // namespace

void PadDecoder::reset()
{
    lastAppType_ = -1;
    dlsBuf_.clear();
    dlsActive_ = false;
    dlsSegments_.clear();
    dlsToggle_ = -1;
    dlsLastSeg_ = -1;
    lastLabel_.clear();
    motBuf_.clear();
    motExpected_ = 0;
    motActive_ = false;
    mot_.clear();
}

void PadDecoder::processAccessUnit(const uint8_t* au, int len)
{
    // The PAD travels in a data_stream_element that is the first syntax
    // element of the AU (TS 102 563 clause 5.4.3).
    if (len < 2 || (au[0] >> 5) != 4) return;
    int count = au[1];
    int pos = 2;
    if (count == 255) {
        if (len < 3) return;
        count += au[2];
        pos = 3;
    }
    if (pos + count > len) return;
    processPad(au + pos, count);
}

void PadDecoder::processPad(const uint8_t* pad, int len)
{
    if (len < 2) return;
    const uint8_t f0 = pad[len - 2];
    const uint8_t f1 = pad[len - 1];
    if ((f0 >> 6) != 0) return; // only F-PAD type 00 carries X-PAD info
    const int xpadInd = (f0 >> 4) & 0x03;
    const bool ci = f1 & 0x02;
    const int xlen = len - 2;
    if (xpadInd == 0 || xlen <= 0) return;

    // X-PAD bytes are transmitted in reverse order.
    std::vector<uint8_t> xp(static_cast<size_t>(xlen));
    for (int i = 0; i < xlen; i++) xp[static_cast<size_t>(i)] = pad[xlen - 1 - i];

    auto continuation = [this](const uint8_t* d, int n) {
        if (lastAppType_ == kAppDlsStart || lastAppType_ == kAppDlsCont) {
            subfield(kAppDlsCont, d, n, false);
        } else if (lastAppType_ == kAppMotStart || lastAppType_ == kAppMotCont) {
            subfield(kAppMotCont, d, n, false);
        }
    };

    if (xpadInd == 1) { // short X-PAD: 4 bytes
        if (ci) {
            const int app = xp[0] & 0x1F;
            subfield(app, xp.data() + 1, std::min(3, xlen - 1), true);
            lastAppType_ = app;
        } else {
            continuation(xp.data(), std::min(4, xlen));
        }
        return;
    }

    if (!ci) {
        continuation(xp.data(), xlen);
        return;
    }

    int apps[4];
    int lens[4];
    int count = 0;
    int pos = 0;
    while (count < 4 && pos < xlen) {
        const uint8_t b = xp[static_cast<size_t>(pos++)];
        const int app = b & 0x1F;
        if (app == 0) break; // end marker
        apps[count] = app;
        lens[count] = kSubfieldLen[b >> 5];
        count++;
    }
    for (int i = 0; i < count && pos < xlen; i++) {
        const int n = std::min(lens[i], xlen - pos);
        subfield(apps[i], xp.data() + pos, n, true);
        lastAppType_ = apps[i];
        pos += n;
    }
}

void PadDecoder::subfield(int appType, const uint8_t* data, int len, bool start)
{
    (void)start;
    switch (appType) {
        case kAppDgli:
            if (len >= 2) motExpected_ = ((data[0] & 0x3F) << 8) | data[1];
            break;
        case kAppDlsStart:
            dlsBuf_.assign(data, data + len);
            dlsActive_ = true;
            break;
        case kAppDlsCont:
            if (!dlsActive_) return;
            dlsBuf_.insert(dlsBuf_.end(), data, data + len);
            break;
        case kAppMotStart:
            motBuf_.assign(data, data + len);
            motActive_ = motExpected_ > 0;
            break;
        case kAppMotCont:
            if (!motActive_) return;
            motBuf_.insert(motBuf_.end(), data, data + len);
            break;
        default:
            return;
    }

    if ((appType == kAppDlsStart || appType == kAppDlsCont) && dlsActive_ && dlsBuf_.size() >= 2) {
        int total;
        if (dlsBuf_[0] & 0x10) { // command
            const int cmd = dlsBuf_[0] & 0x0F;
            total = cmd == 2 ? 2 + (dlsBuf_[1] & 0x0F) + 1 + 2 : 4;
        } else {
            total = 2 + (dlsBuf_[0] & 0x0F) + 1 + 2;
        }
        if (static_cast<int>(dlsBuf_.size()) >= total) {
            dlsActive_ = false;
            dlsGroup(std::vector<uint8_t>(dlsBuf_.begin(), dlsBuf_.begin() + total));
        } else if (dlsBuf_.size() > 64) {
            dlsActive_ = false;
        }
    }

    if ((appType == kAppMotStart || appType == kAppMotCont) && motActive_ &&
        static_cast<int>(motBuf_.size()) >= motExpected_) {
        motActive_ = false;
        motGroup(std::vector<uint8_t>(motBuf_.begin(), motBuf_.begin() + motExpected_));
        motExpected_ = 0;
    }
}

void PadDecoder::dlsGroup(const std::vector<uint8_t>& g)
{
    const int total = static_cast<int>(g.size());
    if (!crc16Ok(g.data(), total)) return;
    const int toggle = (g[0] >> 7) & 1;
    const bool first = g[0] & 0x40;
    const bool last = g[0] & 0x20;
    if (g[0] & 0x10) {
        if ((g[0] & 0x0F) == 1) { // remove label
            dlsSegments_.clear();
            dlsLastSeg_ = -1;
        }
        return;
    }
    if (toggle != dlsToggle_) {
        dlsSegments_.clear();
        dlsLastSeg_ = -1;
        dlsToggle_ = toggle;
    }
    const int seg = first ? 0 : (g[1] >> 4) & 0x07;
    if (first) dlsCharset_ = g[1] >> 4;
    dlsSegments_[seg] = std::string(g.begin() + 2, g.end() - 2);
    if (last) dlsLastSeg_ = seg;
    if (dlsLastSeg_ < 0) return;

    std::string raw;
    for (int i = 0; i <= dlsLastSeg_; i++) {
        auto it = dlsSegments_.find(i);
        if (it == dlsSegments_.end()) return;
        raw += it->second;
    }
    const std::string text =
        dabTextToUtf8(reinterpret_cast<const uint8_t*>(raw.data()), static_cast<int>(raw.size()), dlsCharset_);
    if (text != lastLabel_) {
        lastLabel_ = text;
        listener_.onDynamicLabel(text);
    }
}

void PadDecoder::motGroup(const std::vector<uint8_t>& g)
{
    const int size = static_cast<int>(g.size());
    if (size < 3) return;
    const bool ext = g[0] & 0x80;
    const bool crc = g[0] & 0x40;
    const bool segFlag = g[0] & 0x20;
    const bool uaFlag = g[0] & 0x10;
    const int type = g[0] & 0x0F;
    if (type != 3 && type != 4) return; // header mode only (no MOT directory)
    if (crc && !crc16Ok(g.data(), size)) return;
    const int end = crc ? size - 2 : size;
    int pos = ext ? 4 : 2;

    if (!segFlag || pos + 2 > end) return;
    const bool lastSeg = g[static_cast<size_t>(pos)] & 0x80;
    const int segNum = ((g[static_cast<size_t>(pos)] & 0x7F) << 8) | g[static_cast<size_t>(pos + 1)];
    pos += 2;

    if (!uaFlag || pos + 1 > end) return;
    const bool tidFlag = g[static_cast<size_t>(pos)] & 0x10;
    const int liLen = g[static_cast<size_t>(pos)] & 0x0F;
    pos += 1;
    if (!tidFlag || liLen < 2 || pos + liLen > end) return;
    const int tid = (g[static_cast<size_t>(pos)] << 8) | g[static_cast<size_t>(pos + 1)];
    pos += liLen;

    if (pos + 2 > end) return;
    const int segSize = ((g[static_cast<size_t>(pos)] & 0x1F) << 8) | g[static_cast<size_t>(pos + 1)];
    pos += 2;
    if (pos + segSize > end) return;
    std::vector<uint8_t> seg(g.begin() + pos, g.begin() + pos + segSize);

    if (mot_.find(tid) == mot_.end() && mot_.size() >= kMaxMotObjects) mot_.erase(mot_.begin());
    MotObject& obj = mot_[tid];
    if (obj.delivered) return;

    if (type == 3) {
        obj.headerSegs[segNum] = std::move(seg);
        if (lastSeg) obj.headerLast = segNum;
        if (obj.headerLast >= 0 && obj.contentType < 0) {
            std::vector<uint8_t> h;
            for (int i = 0; i <= obj.headerLast; i++) {
                auto it = obj.headerSegs.find(i);
                if (it == obj.headerSegs.end()) return;
                h.insert(h.end(), it->second.begin(), it->second.end());
            }
            if (h.size() < 7) return;
            obj.contentType = (h[5] >> 1) & 0x3F;
            obj.contentSubType = ((h[5] & 0x01) << 8) | h[6];
        }
    } else {
        size_t have = 0;
        for (const auto& kv : obj.bodySegs) have += kv.second.size();
        if (have + seg.size() > kMaxMotBody) {
            mot_.erase(tid);
            return;
        }
        obj.bodySegs[segNum] = std::move(seg);
        if (lastSeg) obj.bodyLast = segNum;
    }

    if (obj.bodyLast < 0 || obj.contentType < 0) return;
    if (static_cast<int>(obj.bodySegs.size()) <= obj.bodyLast) return;
    std::vector<uint8_t> body;
    for (int i = 0; i <= obj.bodyLast; i++) {
        auto it = obj.bodySegs.find(i);
        if (it == obj.bodySegs.end()) return;
        body.insert(body.end(), it->second.begin(), it->second.end());
    }
    obj.delivered = true;
    obj.bodySegs.clear();
    if (obj.contentType == 2) listener_.onSlide(body, obj.contentSubType);
}

} // namespace hrdab
