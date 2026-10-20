#include "fic.h"

#include "charset.h"
#include "dab_tables.h"

namespace hrdab {

namespace {

constexpr int kFicInfoBits = 768;                  // 3 FIBs
constexpr int kFicMotherBits = 4 * (kFicInfoBits + 6); // 3096

} // namespace

FicDecoder::FicDecoder(Ensemble& ensemble, FicListener& listener)
    : ensemble_(ensemble), listener_(listener), mother_(kFicMotherBits), bits_(kFicInfoBits)
{
}

void FicDecoder::processFrame(const int8_t* soft)
{
    const auto& pi16 = puncturingVector(16);
    const auto& pi15 = puncturingVector(15);
    const auto& tail = puncturingTail();
    for (int block = 0; block < kFicBlocksPerFrame; block++) {
        const int8_t* in = soft + block * kFicBlockBits;
        int8_t* out = mother_.data();
        // Mode I FIC: 21 blocks of 128 bits with PI16, 3 with PI15, tail PI_X.
        in += depuncture(in, pi16.data(), 32, 21 * 128, out);
        out += 21 * 128;
        in += depuncture(in, pi15.data(), 32, 3 * 128, out);
        out += 3 * 128;
        depuncture(in, tail.data(), 24, 24, out);

        viterbi_.decode(mother_.data(), kFicInfoBits, bits_.data());
        energyDispersal(bits_.data(), kFicInfoBits);

        uint8_t fibs[3 * kFibBytes];
        for (int i = 0; i < 3 * kFibBytes; i++) {
            uint8_t v = 0;
            for (int b = 0; b < 8; b++) v = static_cast<uint8_t>((v << 1) | bits_[i * 8 + b]);
            fibs[i] = v;
        }
        for (int f = 0; f < 3; f++) processFib(fibs + f * kFibBytes);
    }
}

bool FicDecoder::processFib(const uint8_t* fib)
{
    if (!crc16Ok(fib, kFibBytes)) {
        fibsBad_++;
        return false;
    }
    fibsOk_++;
    int pos = 0;
    while (pos < kFibBytes - 2) {
        const uint8_t header = fib[pos];
        if (header == 0xFF) break; // end marker
        const int type = header >> 5;
        const int len = header & 0x1F;
        if (len == 0 || pos + 1 + len > kFibBytes - 2) break;
        const uint8_t* body = fib + pos + 1;
        if (type == 0) fig0(body, len);
        else if (type == 1) fig1(body, len);
        pos += 1 + len;
    }
    return true;
}

void FicDecoder::fig0(const uint8_t* d, int len)
{
    const bool otherEnsemble = d[0] & 0x40;
    const bool pd = d[0] & 0x20;
    const int ext = d[0] & 0x1F;
    if (otherEnsemble) return;

    if (ext == 0 && len >= 3) {
        std::lock_guard<std::mutex> lock(ensemble_.mutex);
        ensemble_.eid = static_cast<uint16_t>((d[1] << 8) | d[2]);
        return;
    }

    if (ext == 1) {
        int p = 1;
        while (p + 3 <= len) {
            Subchannel sc;
            sc.id = d[p] >> 2;
            sc.startCu = ((d[p] & 0x03) << 8) | d[p + 1];
            const bool longForm = d[p + 2] & 0x80;
            if (longForm) {
                if (p + 4 > len) break;
                const int option = (d[p + 2] >> 4) & 0x07;
                sc.eep = option == 0 || option == 1;
                sc.optionB = option == 1;
                sc.level = (d[p + 2] >> 2) & 0x03;
                sc.sizeCu = ((d[p + 2] & 0x03) << 8) | d[p + 3];
                p += 4;
            } else {
                sc.eep = false; // UEP (short form) - MPEG layer II only
                p += 3;
            }
            std::lock_guard<std::mutex> lock(ensemble_.mutex);
            ensemble_.subchannels[sc.id] = sc;
        }
        return;
    }

    if (ext == 2) {
        int p = 1;
        while (p < len) {
            const int sidLen = pd ? 4 : 2;
            if (p + sidLen + 1 > len) break;
            uint32_t sid = 0;
            for (int i = 0; i < sidLen; i++) sid = (sid << 8) | d[p + i];
            p += sidLen;
            const int count = d[p] & 0x0F;
            p++;
            std::vector<ServiceComponent> comps;
            for (int i = 0; i < count && p + 2 <= len; i++, p += 2) {
                ServiceComponent c;
                c.tmid = d[p] >> 6;
                if (c.tmid == 0 || c.tmid == 1) {
                    c.ascty = d[p] & 0x3F;
                    c.subchId = d[p + 1] >> 2;
                }
                c.primary = d[p + 1] & 0x02;
                comps.push_back(c);
            }
            if (pd) continue; // data services (32-bit SId) are not listed
            bool isNew = false;
            {
                std::lock_guard<std::mutex> lock(ensemble_.mutex);
                auto it = ensemble_.services.find(sid);
                if (it == ensemble_.services.end()) {
                    it = ensemble_.services.emplace(sid, Service{}).first;
                    it->second.sid = sid;
                    isNew = true;
                }
                it->second.components = comps;
            }
            if (isNew) listener_.onServiceDetected(sid);
        }
        return;
    }
}

void FicDecoder::fig1(const uint8_t* d, int len)
{
    const int charset = d[0] >> 4;
    const bool otherEnsemble = d[0] & 0x08;
    const int ext = d[0] & 0x07;
    if (otherEnsemble) return;

    if (ext == 0 && len >= 1 + 2 + 16) {
        const std::string label = dabTextToUtf8(d + 3, 16, charset);
        bool changed = false;
        {
            std::lock_guard<std::mutex> lock(ensemble_.mutex);
            ensemble_.eid = static_cast<uint16_t>((d[1] << 8) | d[2]);
            if (ensemble_.label != label) {
                ensemble_.label = label;
                changed = true;
            }
        }
        if (changed) listener_.onEnsembleLabel(label);
        return;
    }

    if (ext == 1 && len >= 1 + 2 + 16) {
        const uint32_t sid = static_cast<uint32_t>((d[1] << 8) | d[2]);
        const std::string label = dabTextToUtf8(d + 3, 16, charset);
        bool isNew = false;
        {
            std::lock_guard<std::mutex> lock(ensemble_.mutex);
            auto it = ensemble_.services.find(sid);
            if (it == ensemble_.services.end()) {
                it = ensemble_.services.emplace(sid, Service{}).first;
                it->second.sid = sid;
                isNew = true;
            }
            it->second.label = label;
        }
        if (isNew) listener_.onServiceDetected(sid);
    }
}

} // namespace hrdab
