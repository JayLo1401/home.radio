// JNI bridge for home_radio's own DAB+ receiver (cpp/hrdab), used by
// at.jaycloud.home.radio.dab.IntegratedDabEngine.
//
// One global session, like the rest of the app's DAB code: one stick, one
// ensemble at a time. Callbacks arrive on the receiver's own threads, which
// get attached to the JVM on first use.

#include <jni.h>
#include <pthread.h>

#include <memory>
#include <mutex>
#include <string>

#include "common.h"
#include "receiver.h"
#include "rtl2832.h"
#include "rtltcp_source.h"

using namespace hrdab;

namespace {

JavaVM* g_jvm = nullptr;

struct Methods {
    jmethodID onSync, onEnsembleLabel, onServiceDetected, onDynamicLabel, onSnr, onRsErrors, onAacErrors,
        onAudioFormat, onAudioConfig, onAccessUnit, onSlide, onStatus;
};

// ART aborts when a thread exits while still attached, so every thread we
// attach gets detached again by this key's destructor when it ends.
pthread_key_t g_detachKey;
pthread_once_t g_detachOnce = PTHREAD_ONCE_INIT;

void detachThread(void*)
{
    if (g_jvm) g_jvm->DetachCurrentThread();
}

JNIEnv* env()
{
    JNIEnv* e = nullptr;
    const jint r = g_jvm->GetEnv(reinterpret_cast<void**>(&e), JNI_VERSION_1_6);
    if (r == JNI_EDETACHED) {
        if (g_jvm->AttachCurrentThread(&e, nullptr) != JNI_OK) return nullptr;
        pthread_once(&g_detachOnce, [] { pthread_key_create(&g_detachKey, detachThread); });
        pthread_setspecific(g_detachKey, reinterpret_cast<void*>(1));
    } else if (r != JNI_OK) {
        return nullptr;
    }
    return e;
}

jstring utf8(JNIEnv* e, const std::string& s)
{
    // NewStringUTF wants modified UTF-8; go through a byte array + String
    // constructor so 4-byte sequences (emoji in DLS) don't abort the VM.
    jbyteArray bytes = e->NewByteArray(static_cast<jsize>(s.size()));
    e->SetByteArrayRegion(bytes, 0, static_cast<jsize>(s.size()), reinterpret_cast<const jbyte*>(s.data()));
    jclass stringClass = e->FindClass("java/lang/String");
    jmethodID ctor = e->GetMethodID(stringClass, "<init>", "([BLjava/lang/String;)V");
    jstring charset = e->NewStringUTF("UTF-8");
    auto result = static_cast<jstring>(e->NewObject(stringClass, ctor, bytes, charset));
    e->DeleteLocalRef(charset);
    e->DeleteLocalRef(stringClass);
    e->DeleteLocalRef(bytes);
    return result;
}

jbyteArray byteArray(JNIEnv* e, const uint8_t* data, int len)
{
    jbyteArray a = e->NewByteArray(len);
    if (a && len > 0) e->SetByteArrayRegion(a, 0, len, reinterpret_cast<const jbyte*>(data));
    return a;
}

class JniListener : public ReceiverListener {
public:
    JniListener(JNIEnv* e, jobject target) : target_(e->NewGlobalRef(target))
    {
        jclass c = e->GetObjectClass(target);
        m_.onSync = e->GetMethodID(c, "onNativeSync", "(Z)V");
        m_.onEnsembleLabel = e->GetMethodID(c, "onNativeEnsembleLabel", "(Ljava/lang/String;)V");
        m_.onServiceDetected = e->GetMethodID(c, "onNativeServiceDetected", "(I)V");
        m_.onDynamicLabel = e->GetMethodID(c, "onNativeDynamicLabel", "(Ljava/lang/String;)V");
        m_.onSnr = e->GetMethodID(c, "onNativeSnr", "(F)V");
        m_.onRsErrors = e->GetMethodID(c, "onNativeRsErrors", "(ZI)V");
        m_.onAacErrors = e->GetMethodID(c, "onNativeAacErrors", "(I)V");
        m_.onAudioFormat = e->GetMethodID(c, "onNativeAudioFormat", "(Ljava/lang/String;)V");
        m_.onAudioConfig = e->GetMethodID(c, "onNativeAudioConfig", "([BII)V");
        m_.onAccessUnit = e->GetMethodID(c, "onNativeAccessUnit", "([BZ)V");
        m_.onSlide = e->GetMethodID(c, "onNativeSlide", "([BI)V");
        m_.onStatus = e->GetMethodID(c, "onNativeStatus", "(ZLjava/lang/String;)V");
        e->DeleteLocalRef(c);
        if (e->ExceptionCheck()) {
            e->ExceptionDescribe();
            e->ExceptionClear();
        }
    }

    void release(JNIEnv* e) { e->DeleteGlobalRef(target_); }

    void onSync(bool synced) override { call(m_.onSync, static_cast<jboolean>(synced)); }
    void onEnsembleLabel(const std::string& label) override { callString(m_.onEnsembleLabel, label); }
    void onServiceDetected(uint32_t sid) override { call(m_.onServiceDetected, static_cast<jint>(sid)); }
    void onDynamicLabel(const std::string& text) override { callString(m_.onDynamicLabel, text); }
    void onSnr(float snrDb) override { call(m_.onSnr, static_cast<jfloat>(snrDb)); }
    void onRsErrors(bool uncorrectable, int corrected) override
    {
        call(m_.onRsErrors, static_cast<jboolean>(uncorrectable), static_cast<jint>(corrected));
    }
    void onAacErrors(int count) override { call(m_.onAacErrors, static_cast<jint>(count)); }
    void onAudioFormat(const std::string& format) override { callString(m_.onAudioFormat, format); }
    void onAudioConfig(const std::vector<uint8_t>& asc, int sampleRate, int channels) override
    {
        JNIEnv* e = env();
        if (!e || !m_.onAudioConfig) return;
        jbyteArray a = byteArray(e, asc.data(), static_cast<int>(asc.size()));
        e->CallVoidMethod(target_, m_.onAudioConfig, a, static_cast<jint>(sampleRate), static_cast<jint>(channels));
        e->DeleteLocalRef(a);
        clear(e);
    }
    void onAccessUnit(const uint8_t* data, int len, bool ok) override
    {
        JNIEnv* e = env();
        if (!e || !m_.onAccessUnit) return;
        jbyteArray a = byteArray(e, data, ok ? len : 0);
        e->CallVoidMethod(target_, m_.onAccessUnit, a, static_cast<jboolean>(ok));
        e->DeleteLocalRef(a);
        clear(e);
    }
    void onSlide(const std::vector<uint8_t>& data, int contentSubType) override
    {
        JNIEnv* e = env();
        if (!e || !m_.onSlide) return;
        jbyteArray a = byteArray(e, data.data(), static_cast<int>(data.size()));
        e->CallVoidMethod(target_, m_.onSlide, a, static_cast<jint>(contentSubType));
        e->DeleteLocalRef(a);
        clear(e);
    }
    void onStatus(bool isError, const std::string& message) override
    {
        JNIEnv* e = env();
        if (!e || !m_.onStatus) return;
        jstring s = utf8(e, message);
        e->CallVoidMethod(target_, m_.onStatus, static_cast<jboolean>(isError), s);
        e->DeleteLocalRef(s);
        clear(e);
    }

private:
    static void clear(JNIEnv* e)
    {
        if (e->ExceptionCheck()) {
            e->ExceptionDescribe();
            e->ExceptionClear();
        }
    }

    template <typename... Args>
    void call(jmethodID m, Args... args)
    {
        JNIEnv* e = env();
        if (!e || !m) return;
        e->CallVoidMethod(target_, m, args...);
        clear(e);
    }

    void callString(jmethodID m, const std::string& s)
    {
        JNIEnv* e = env();
        if (!e || !m) return;
        jstring js = utf8(e, s);
        e->CallVoidMethod(target_, m, js);
        e->DeleteLocalRef(js);
        clear(e);
    }

    jobject target_;
    Methods m_{};
};

struct Session {
    std::unique_ptr<JniListener> listener;
    std::unique_ptr<Receiver> receiver;
};

std::mutex g_mutex;
std::unique_ptr<Session> g_session;

jboolean create(JNIEnv* e, jobject thiz, std::unique_ptr<SampleSource> source)
{
    auto session = std::make_unique<Session>();
    session->listener = std::make_unique<JniListener>(e, thiz);
    session->receiver = std::make_unique<Receiver>(std::move(source), *session->listener);
    g_session = std::move(session);
    return JNI_TRUE;
}

} // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*)
{
    g_jvm = vm;
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativeCreateUsb(JNIEnv* e, jobject thiz, jint fd)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_session) return JNI_TRUE;
    auto rtl = std::make_unique<Rtl2832Source>(static_cast<int>(fd));
    if (!rtl->open()) return JNI_FALSE;
    return create(e, thiz, std::move(rtl));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativeCreateTcp(JNIEnv* e, jobject thiz, jstring jHost, jint port)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_session) return JNI_TRUE;
    const char* host = e->GetStringUTFChars(jHost, nullptr);
    std::string h = host ? host : "127.0.0.1";
    if (host) e->ReleaseStringUTFChars(jHost, host);
    return create(e, thiz, std::make_unique<RtlTcpSource>(h, static_cast<int>(port)));
}

extern "C" JNIEXPORT void JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativeDestroy(JNIEnv* e, jobject)
{
    std::unique_ptr<Session> session;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        session = std::move(g_session);
    }
    if (!session) return;
    session->receiver.reset();
    session->listener->release(e);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativeTune(JNIEnv*, jobject, jint hz)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_session) return JNI_FALSE;
    return g_session->receiver->tune(static_cast<uint32_t>(hz)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativeHalt(JNIEnv*, jobject)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_session) g_session->receiver->halt();
}

extern "C" JNIEXPORT jstring JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativeGetEnsembleLabel(JNIEnv* e, jobject)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return utf8(e, g_session ? g_session->receiver->ensembleLabel() : std::string());
}

extern "C" JNIEXPORT jstring JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativeGetServiceListJson(JNIEnv* e, jobject)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return utf8(e, g_session ? g_session->receiver->serviceListJson() : std::string("[]"));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativePlayService(JNIEnv*, jobject, jint sid)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_session) return JNI_FALSE;
    return g_session->receiver->playService(static_cast<uint32_t>(sid)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_at_jaycloud_home_radio_dab_IntegratedDabEngine_nativeStopService(JNIEnv*, jobject)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_session) g_session->receiver->stopService();
}
