/*
 * JNI bridge for the vendored welle.io DAB+ decoding core (see
 * cpp/dabcore/ and CMakeLists.txt's "dabcore" target doc comment).
 *
 * This wires three things together:
 *   - CRTL_TCP_Client (dabcore/input/rtl_tcp.cpp) as the sample source -
 *     it connects to an rtl_tcp-protocol server exactly like
 *     RtlSdrTestScreen's own client does, so this DAB decoder is just
 *     another client of whichever source (own USB service / external app /
 *     network service) the user picked in Settings.
 *   - AndroidRadioController, implementing RadioControllerInterface -
 *     forwards ensemble/sync/service events to Kotlin.
 *   - AndroidProgrammeHandler, implementing ProgrammeHandlerInterface -
 *     forwards decoded PCM audio and PAD (dynamic label) to Kotlin.
 *
 * There is a single, global DAB session (no multi-instance support) - one
 * dongle, one ensemble being scanned/decoded at a time, matching how the
 * rest of this app's native DAB/RTL-SDR code is structured.
 *
 * Java/Kotlin class: org.lotzapp.home_radio.dab.DabRtlSdrPlugin
 */

#include <jni.h>
#include <android/log.h>
#include <memory>
#include <mutex>
#include <string>
#include <sstream>

#include "radio-controller.h"
#include "radio-receiver.h"
#include "rtl_tcp.h"

#define LOG_TAG "DabRtlSdr"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

JavaVM* g_jvm = nullptr;
jobject g_listener = nullptr; // global ref to the Kotlin DabRtlSdrPlugin instance

jmethodID m_onSyncChange = nullptr;
jmethodID m_onEnsembleLabel = nullptr;
jmethodID m_onServiceDetected = nullptr;
jmethodID m_onDynamicLabel = nullptr;
jmethodID m_onAudioPcm = nullptr;
jmethodID m_onRsErrors = nullptr;
jmethodID m_onAacErrors = nullptr;

/* Attaches the calling thread to the JVM if needed. welle.io's OFDM/decoder
 * threads are created internally by the vendored library (std::thread), not
 * by us, so they are never already attached. Left attached for the thread's
 * lifetime (a handful of long-lived internal threads only - not a
 * per-callback leak in practice) rather than detaching after every call,
 * which would be needlessly expensive given how often onNewAudio() fires. */
JNIEnv* attachedEnv()
{
    if (!g_jvm) return nullptr;
    JNIEnv* env = nullptr;
    jint r = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (r == JNI_EDETACHED) {
        if (g_jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
            return nullptr;
        }
    } else if (r != JNI_OK) {
        return nullptr;
    }
    return env;
}

class AndroidRadioController : public RadioControllerInterface {
public:
    void onSNR(float) override {}

    void onFrequencyCorrectorChange(int, int) override {}

    void onSyncChange(char isSync) override
    {
        JNIEnv* env = attachedEnv();
        if (env && g_listener && m_onSyncChange) {
            env->CallVoidMethod(g_listener, m_onSyncChange, isSync != 0);
        }
    }

    void onSignalPresence(bool) override {}

    void onServiceDetected(uint32_t sId) override
    {
        JNIEnv* env = attachedEnv();
        if (env && g_listener && m_onServiceDetected) {
            env->CallVoidMethod(g_listener, m_onServiceDetected, static_cast<jint>(sId));
        }
    }

    void onNewEnsemble(uint16_t) override {}

    void onSetEnsembleLabel(DabLabel& label) override
    {
        JNIEnv* env = attachedEnv();
        if (env && g_listener && m_onEnsembleLabel) {
            jstring jLabel = env->NewStringUTF(label.utf8_label().c_str());
            env->CallVoidMethod(g_listener, m_onEnsembleLabel, jLabel);
            env->DeleteLocalRef(jLabel);
        }
    }

    void onDateTimeUpdate(const dab_date_time_t&) override {}

    void onFIBDecodeSuccess(bool, const uint8_t*) override {}

    void onNewImpulseResponse(std::vector<float>&&) override {}

    void onConstellationPoints(std::vector<DSPCOMPLEX>&&) override {}

    void onNewNullSymbol(std::vector<DSPCOMPLEX>&&) override {}

    void onTIIMeasurement(tii_measurement_t&&) override {}

    void onMessage(message_level_t level, const std::string& text, const std::string& text2) override
    {
        if (level == message_level_t::Error) {
            LOGW("%s %s", text.c_str(), text2.c_str());
        } else {
            LOGI("%s %s", text.c_str(), text2.c_str());
        }
    }

    void onInputFailure() override
    {
        LOGE("input failure");
    }
};

class AndroidProgrammeHandler : public ProgrammeHandlerInterface {
public:
    void onFrameErrors(int) override {}

    void onNewAudio(std::vector<int16_t>&& audioData, int sampleRate, const std::string&) override
    {
        JNIEnv* env = attachedEnv();
        if (!env || !g_listener || !m_onAudioPcm) return;
        // Always stereo-interleaved (see DecoderAdapter::PutAudio - it
        // upmixes mono to stereo itself), native/little-endian int16 PCM -
        // exactly what DabAudioPlayer already expects on the Kotlin side.
        const size_t byteLen = audioData.size() * sizeof(int16_t);
        jbyteArray pcm = env->NewByteArray(static_cast<jsize>(byteLen));
        if (!pcm) return;
        env->SetByteArrayRegion(pcm, 0, static_cast<jsize>(byteLen), reinterpret_cast<const jbyte*>(audioData.data()));
        env->CallVoidMethod(g_listener, m_onAudioPcm, pcm, static_cast<jint>(sampleRate), static_cast<jint>(2));
        env->DeleteLocalRef(pcm);
    }

    void onRsErrors(bool uncorrectedErrors, int numCorrectedErrors) override
    {
        JNIEnv* env = attachedEnv();
        if (env && g_listener && m_onRsErrors) {
            env->CallVoidMethod(g_listener, m_onRsErrors, uncorrectedErrors, static_cast<jint>(numCorrectedErrors));
        }
    }

    void onAacErrors(int aacErrors) override
    {
        JNIEnv* env = attachedEnv();
        if (env && g_listener && m_onAacErrors) {
            env->CallVoidMethod(g_listener, m_onAacErrors, static_cast<jint>(aacErrors));
        }
    }

    void onNewDynamicLabel(const std::string& label) override
    {
        JNIEnv* env = attachedEnv();
        if (env && g_listener && m_onDynamicLabel) {
            jstring jLabel = env->NewStringUTF(label.c_str());
            env->CallVoidMethod(g_listener, m_onDynamicLabel, jLabel);
            env->DeleteLocalRef(jLabel);
        }
    }

    void onMOT(const mot_file_t&) override {}

    void onPADLengthError(size_t, size_t) override {}
};

struct DabSession {
    AndroidRadioController controller;
    AndroidProgrammeHandler programmeHandler;
    std::unique_ptr<CRTL_TCP_Client> input;
    std::unique_ptr<RadioReceiver> receiver;
    Service currentService{0};
    bool playing = false;
};

std::mutex g_sessionMutex;
std::unique_ptr<DabSession> g_session;

/* JSON is built by hand rather than pulling in a JSON library: the only
 * strings involved are DAB service/ensemble labels, and '"'/'\\'/control
 * chars are escaped below - everything else in the payload is numeric. */
std::string jsonEscape(const std::string& s)
{
    std::ostringstream out;
    for (unsigned char c : s) {
        switch (c) {
            case '"': out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out << buf;
                } else {
                    out << c;
                }
        }
    }
    return out.str();
}

} // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*)
{
    g_jvm = vm;
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeCreate(JNIEnv* env, jobject thiz)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (g_session) {
        LOGW("nativeCreate: session already exists");
        return JNI_TRUE;
    }

    g_listener = env->NewGlobalRef(thiz);
    jclass cls = env->GetObjectClass(thiz);
    m_onSyncChange = env->GetMethodID(cls, "nativeOnSyncChange", "(Z)V");
    m_onEnsembleLabel = env->GetMethodID(cls, "nativeOnEnsembleLabel", "(Ljava/lang/String;)V");
    m_onServiceDetected = env->GetMethodID(cls, "nativeOnServiceDetected", "(I)V");
    m_onDynamicLabel = env->GetMethodID(cls, "nativeOnDynamicLabel", "(Ljava/lang/String;)V");
    m_onAudioPcm = env->GetMethodID(cls, "nativeOnAudioPcm", "([BII)V");
    m_onRsErrors = env->GetMethodID(cls, "nativeOnRsErrors", "(ZI)V");
    m_onAacErrors = env->GetMethodID(cls, "nativeOnAacErrors", "(I)V");
    env->ExceptionClear();

    auto session = std::make_unique<DabSession>();
    session->input = std::make_unique<CRTL_TCP_Client>(session->controller);
    RadioReceiverOptions options;
    session->receiver = std::make_unique<RadioReceiver>(session->controller, *session->input, options, 1);
    g_session = std::move(session);
    LOGI("nativeCreate: session ready");
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeDestroy(JNIEnv*, jobject)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (!g_session) return;
    g_session->receiver->stop();
    // CRTL_TCP_Client::stop() is private - its destructor calls it already,
    // so resetting the unique_ptr below is enough to close the connection.
    g_session.reset();
    if (g_listener) {
        JNIEnv* env = attachedEnv();
        if (env) env->DeleteGlobalRef(g_listener);
        g_listener = nullptr;
    }
    LOGI("nativeDestroy: session torn down");
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeSetServer(JNIEnv* env, jobject, jstring jHost, jint port)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (!g_session) return;
    const char* host = env->GetStringUTFChars(jHost, nullptr);
    g_session->input->setServerAddress(host ? host : "127.0.0.1");
    g_session->input->setPort(static_cast<uint16_t>(port));
    if (host) env->ReleaseStringUTFChars(jHost, host);
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeSetFrequency(JNIEnv*, jobject, jint hz)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (!g_session) return;
    g_session->input->setFrequency(hz);
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeRestart(JNIEnv*, jobject, jboolean scan)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (!g_session) return;
    g_session->receiver->restart(scan == JNI_TRUE);
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeStop(JNIEnv*, jobject)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (!g_session) return;
    g_session->receiver->stop();
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeGetEnsembleLabel(JNIEnv* env, jobject)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (!g_session) return env->NewStringUTF("");
    return env->NewStringUTF(g_session->receiver->getEnsembleLabel().utf8_label().c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeGetServiceListJson(JNIEnv* env, jobject)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    std::ostringstream out;
    out << "[";
    if (g_session) {
        bool first = true;
        for (const Service& s : g_session->receiver->getServiceList()) {
            if (!g_session->receiver->serviceHasAudioComponent(s)) continue;
            if (!first) out << ",";
            first = false;
            out << "{\"serviceId\":" << s.serviceId
                << ",\"label\":\"" << jsonEscape(s.serviceLabel.utf8_label()) << "\"}";
        }
    }
    out << "]";
    return env->NewStringUTF(out.str().c_str());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativePlayService(JNIEnv*, jobject, jint serviceId)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (!g_session) return JNI_FALSE;
    Service s = g_session->receiver->getService(static_cast<uint32_t>(serviceId));
    if (s.serviceId == 0) return JNI_FALSE;
    g_session->currentService = s;
    bool ok = g_session->receiver->playSingleProgramme(g_session->programmeHandler, "", s);
    g_session->playing = ok;
    return ok ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_dab_DabRtlSdrPlugin_nativeStopPlayback(JNIEnv*, jobject)
{
    std::lock_guard<std::mutex> lock(g_sessionMutex);
    if (!g_session || !g_session->playing) return;
    g_session->receiver->removeServiceToDecode(g_session->currentService);
    g_session->playing = false;
}
