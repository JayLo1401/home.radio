// JNI port of DABlin's DAB+ superframe decoder (SuperframeFilter, from
// dabplus_decoder.cpp/h - github.com/opendigitalradio/dablin, GPLv3,
// Copyright (C) 2015-2024 Stefan Poeschel). Only the transport-layer logic
// (5-CIF accumulation, RS(120,110) outer FEC via the real libfec, Fire-code
// superframe sync, AU boundary parsing + CRC16 check) is ported - AAC
// decoding itself is left to Android's own MediaCodec on the Kotlin side
// (NativeDabDecoder.kt), matching what DABlin's own AACDecoder classes are
// a thin wrapper around anyway (FDK-AAC / FAAD2).
//
// The RS decode step uses Phil Karn's actual, unmodified LGPL-2.1 `libfec`
// char/RS codec (fec/init_rs_char.c, fec/decode_rs_char.c -
// github.com/quiet/libfec) rather than a hand-ported translation, to remove
// any possibility of a subtle porting bug in that step.

#include <jni.h>
#include <android/log.h>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" {
#include "fec.h"
}

#define TAG "DabNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

namespace {

// --- CRC16, table-driven, same construction as DABlin's CalcCRC ------------
struct Crc16 {
    uint16_t lut[256];
    bool initial_invert;
    bool final_invert;

    Crc16(bool initial_invert_, bool final_invert_, uint16_t gen_polynom) {
        initial_invert = initial_invert_;
        final_invert = final_invert_;
        for (int value = 0; value < 256; value++) {
            uint16_t crc = value << 8;
            for (int i = 0; i < 8; i++) {
                crc = (crc & 0x8000) ? (uint16_t) ((crc << 1) ^ gen_polynom) : (uint16_t) (crc << 1);
            }
            lut[value] = crc;
        }
    }

    uint16_t calc(const uint8_t *data, size_t offset, size_t len) const {
        uint16_t crc = initial_invert ? 0xFFFF : 0x0000;
        for (size_t i = offset; i < offset + len; i++) {
            crc = (uint16_t) ((crc << 8) ^ lut[(crc >> 8) ^ data[i]]);
        }
        return final_invert ? (uint16_t) ~crc : crc;
    }
};

const Crc16 CRC_CCITT(true, true, 0x1021);
const Crc16 CRC_FIRE_CODE(false, false, 0x782F);

constexpr int RS_CODEWORD_LEN = 120;
constexpr int RS_PAD = 135;

// Stat indices (see NativeDabDecoder.kt's nativeGetStat callers).
enum StatIndex {
    STAT_SYNC_ATTEMPTS = 0,
    STAT_SYNC_SUCCESSES = 1,
    STAT_RS_UNCORRECTABLE = 2,
    STAT_RS_CORRECTED = 3,
    STAT_AU_OK = 4,
    STAT_AU_FAIL = 5,
    STAT_AU_OK_BY_INDEX = 6,   // 6..11 (up to 6 AUs)
    STAT_AU_FAIL_BY_INDEX = 12, // 12..17
};

struct SuperframeFormat {
    bool dac_rate = false;
    bool sbr_flag = false;
    bool channel_mode = false;
    bool ps_flag = false;

    int coreSrIndex() const { return dac_rate ? (sbr_flag ? 6 : 3) : (sbr_flag ? 8 : 5); }
    int coreChConfig() const { return channel_mode ? 2 : 1; }
    int extensionSrIndex() const { return dac_rate ? 3 : 5; }
    int sampleRateHz() const { return dac_rate ? 48000 : 32000; }
    int channels() const { return (channel_mode || ps_flag) ? 2 : 1; }
};

struct DabDecoderState {
    void *rs_handle = nullptr;

    size_t frame_len = 0;
    int frame_count = 0;
    std::vector<uint8_t> sf_raw;
    size_t sf_len = 0;

    bool format_set = false;
    uint8_t format_raw = 0;
    SuperframeFormat format;

    int num_aus = 0;
    int au_start[7] = {0};

    int64_t stats[18] = {0};

    JavaVM *jvm = nullptr;
    jobject callback_obj = nullptr; // global ref to the Kotlin NativeDabDecoder instance
    jmethodID callback_method = nullptr;

    ~DabDecoderState() {
        if (rs_handle) free_rs_char(rs_handle);
    }
};

std::vector<uint8_t> buildAsc(const SuperframeFormat &format) {
    std::vector<uint8_t> bytes;
    bytes.push_back((uint8_t) ((0b00010 << 3) | (format.coreSrIndex() >> 1)));
    bytes.push_back((uint8_t) (((format.coreSrIndex() & 0x01) << 7) | (format.coreChConfig() << 3) | 0b100));
    if (format.sbr_flag) {
        bytes.push_back(0x56);
        bytes.push_back(0xE5);
        uint8_t last = (uint8_t) (0x80 | (format.extensionSrIndex() << 3));
        if (format.ps_flag) last |= 0x05;
        bytes.push_back(last);
        if (format.ps_flag) {
            bytes.push_back(0x48);
            bytes.push_back(0x80);
        }
    }
    return bytes;
}

// Mirrors RSDecoder::DecodeSuperframe exactly (dabplus_decoder.cpp).
void decodeRs(DabDecoderState *st, uint8_t *sf) {
    int subch_index = (int) (st->sf_len / RS_CODEWORD_LEN);
    uint8_t rs_packet[RS_CODEWORD_LEN];
    int corr_pos[10];

    for (int i = 0; i < subch_index; i++) {
        for (int pos = 0; pos < RS_CODEWORD_LEN; pos++)
            rs_packet[pos] = sf[pos * subch_index + i];

        int corr_count = decode_rs_char(st->rs_handle, rs_packet, corr_pos, 0);
        if (corr_count == -1) {
            st->stats[STAT_RS_UNCORRECTABLE]++;
        } else {
            st->stats[STAT_RS_CORRECTED] += corr_count;
        }

        for (int j = 0; j < corr_count; j++) {
            int pos = corr_pos[j] - RS_PAD;
            if (pos < 0) continue;
            sf[pos * subch_index + i] = rs_packet[pos];
        }
    }
}

// Mirrors SuperframeFilter::CheckSync exactly (dabplus_decoder.cpp).
bool checkSync(DabDecoderState *st, const uint8_t *sf) {
    if (sf[3] == 0x00 && sf[4] == 0x00) return false;

    uint16_t crc_stored = (uint16_t) ((sf[0] << 8) | sf[1]);
    uint16_t crc_calced = CRC_FIRE_CODE.calc(sf, 2, 9);
    if (crc_stored != crc_calced) return false;

    st->format_raw = sf[2];
    st->format.dac_rate = (sf[2] & 0x40) != 0;
    st->format.sbr_flag = (sf[2] & 0x20) != 0;
    st->format.channel_mode = (sf[2] & 0x10) != 0;
    st->format.ps_flag = (sf[2] & 0x08) != 0;

    st->num_aus = st->format.dac_rate ? (st->format.sbr_flag ? 3 : 6) : (st->format.sbr_flag ? 2 : 4);
    st->au_start[0] = st->format.dac_rate ? (st->format.sbr_flag ? 6 : 11) : (st->format.sbr_flag ? 5 : 8);
    st->au_start[st->num_aus] = (int) (st->sf_len / RS_CODEWORD_LEN * 110);

    st->au_start[1] = (sf[3] << 4) | (sf[4] >> 4);
    if (st->num_aus >= 3) st->au_start[2] = ((sf[4] & 0x0F) << 8) | sf[5];
    if (st->num_aus >= 4) st->au_start[3] = (sf[6] << 4) | (sf[7] >> 4);
    if (st->num_aus == 6) {
        st->au_start[4] = ((sf[7] & 0x0F) << 8) | sf[8];
        st->au_start[5] = (sf[9] << 4) | (sf[10] >> 4);
    }

    for (int i = 0; i < st->num_aus; i++)
        if (st->au_start[i] >= st->au_start[i + 1]) return false;

    return true;
}

void feedOneFrame(JNIEnv *env, DabDecoderState *st, const uint8_t *data, size_t len) {
    if (st->frame_len) {
        if (st->frame_len != len) return; // subchannel reconfigured mid-stream - ignore
    } else {
        if (len < 10 || (5 * len) % RS_CODEWORD_LEN != 0) {
            LOGW("frame len %zu not usable - ignoring", len);
            return;
        }
        st->frame_len = len;
        st->sf_len = 5 * st->frame_len;
        st->sf_raw.assign(st->sf_len, 0);
    }

    if (st->frame_count == 5) {
        for (int i = 0; i < 4; i++)
            memcpy(&st->sf_raw[i * st->frame_len], &st->sf_raw[(i + 1) * st->frame_len], st->frame_len);
    } else {
        st->frame_count++;
    }
    memcpy(&st->sf_raw[(st->frame_count - 1) * st->frame_len], data, st->frame_len);

    if (st->frame_count < 5) return;

    std::vector<uint8_t> sf(st->sf_raw); // decode on a copy, exactly like the reference
    decodeRs(st, sf.data());

    st->stats[STAT_SYNC_ATTEMPTS]++;
    if (!checkSync(st, sf.data())) return; // frame_count stays 5 -> next feed() slides the window by one CIF
    st->stats[STAT_SYNC_SUCCESSES]++;

    auto asc = buildAsc(st->format);
    jbyteArray ascArray = env->NewByteArray((jsize) asc.size());
    env->SetByteArrayRegion(ascArray, 0, (jsize) asc.size(), (const jbyte *) asc.data());

    int auDurationMs = 120 / st->num_aus;
    int sampleRateHz = st->format.sampleRateHz();
    int channels = st->format.channels();

    for (int i = 0; i < st->num_aus; i++) {
        int start = st->au_start[i];
        int end = st->au_start[i + 1];
        if (start < 0 || (size_t) end > sf.size() || end - start < 2) continue;
        int auLen = end - start - 2;
        uint16_t crcStored = (uint16_t) ((sf[end - 2] << 8) | sf[end - 1]);
        uint16_t crcCalced = CRC_CCITT.calc(sf.data(), (size_t) start, (size_t) auLen);

        jbyteArray auArray = nullptr;
        if (crcStored != crcCalced) {
            st->stats[STAT_AU_FAIL]++;
            if (i < 6) st->stats[STAT_AU_FAIL_BY_INDEX + i]++;
        } else {
            st->stats[STAT_AU_OK]++;
            if (i < 6) st->stats[STAT_AU_OK_BY_INDEX + i]++;
            auArray = env->NewByteArray(auLen);
            env->SetByteArrayRegion(auArray, 0, auLen, (const jbyte *) &sf[start]);
        }

        env->CallVoidMethod(st->callback_obj, st->callback_method, auArray, ascArray, sampleRateHz, channels, auDurationMs);
        if (auArray) env->DeleteLocalRef(auArray);
    }
    env->DeleteLocalRef(ascArray);

    st->frame_count = 0;
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_org_lotzapp_home_1radio_dab_NativeDabDecoder_nativeCreate(JNIEnv *env, jobject thiz) {
    auto *st = new DabDecoderState();
    st->rs_handle = init_rs_char(8, 0x11D, 0, 1, 10, 135);
    if (!st->rs_handle) {
        LOGW("init_rs_char failed");
        delete st;
        return 0;
    }
    env->GetJavaVM(&st->jvm);
    st->callback_obj = env->NewGlobalRef(thiz);
    jclass cls = env->GetObjectClass(thiz);
    st->callback_method = env->GetMethodID(cls, "onAuFromNative", "([B[BIII)V");
    return (jlong) st;
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_NativeDabDecoder_nativeFeed(JNIEnv *env, jobject, jlong handle, jbyteArray data) {
    auto *st = (DabDecoderState *) handle;
    if (!st) return;
    jsize len = env->GetArrayLength(data);
    jbyte *bytes = env->GetByteArrayElements(data, nullptr);
    feedOneFrame(env, st, (const uint8_t *) bytes, (size_t) len);
    env->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_NativeDabDecoder_nativeReset(JNIEnv *, jobject, jlong handle) {
    auto *st = (DabDecoderState *) handle;
    if (!st) return;
    st->frame_count = 0;
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_NativeDabDecoder_nativeDestroy(JNIEnv *env, jobject, jlong handle) {
    auto *st = (DabDecoderState *) handle;
    if (!st) return;
    if (st->callback_obj) env->DeleteGlobalRef(st->callback_obj);
    delete st;
}

extern "C" JNIEXPORT jlong JNICALL
Java_org_lotzapp_home_1radio_dab_NativeDabDecoder_nativeGetStat(JNIEnv *, jobject, jlong handle, jint index) {
    auto *st = (DabDecoderState *) handle;
    if (!st || index < 0 || index >= 18) return 0;
    return st->stats[index];
}
