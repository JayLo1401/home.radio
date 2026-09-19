/*
 * JNI bridge for our own RTL-SDR USB-TCP service (home_radio, 2026-09-18).
 *
 * This is intentionally thin: all of the actual RTL2832U handling and the
 * rtl_tcp wire protocol live in the vendored librtlsdr/rtl_tcp.c (see that
 * file). This bridge only:
 *   - hands the already-permitted Android USB file descriptor to
 *     rtl_tcp_set_usb_fd()/rtlsdr_open_from_fd(),
 *   - builds an argv[] for rtl_tcp_main() from the parameters the Kotlin
 *     side collected (frequency, sample rate, gain, ...),
 *   - runs rtl_tcp_main() on a background thread, since it blocks for the
 *     whole server lifetime,
 *   - lets Kotlin request a stop via rtl_tcp_request_exit().
 *
 * Java/Kotlin class: org.lotzapp.home_radio.rtlsdr.RtlSdrUsbServer
 */

#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "rtl_tcp_bridge.h"

#define LOG_TAG "RtlSdrUsbServer"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

std::thread g_serverThread;
std::atomic<bool> g_running{false};
std::atomic<int> g_lastResult{0};

void serverThreadMain(std::vector<std::string> argvStrings) {
	std::vector<char *> argv;
	argv.reserve(argvStrings.size());
	for (auto &s : argvStrings)
		argv.push_back(const_cast<char *>(s.c_str()));

	LOGI("rtl_tcp_main starting (%zu args)", argv.size());
	int r = rtl_tcp_main(static_cast<int>(argv.size()), argv.data());
	LOGI("rtl_tcp_main returned %d", r);
	g_lastResult.store(r);
	g_running.store(false);
}

} // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_org_lotzapp_home_1radio_rtlsdr_RtlSdrUsbServer_nativeStart(
	JNIEnv *env, jobject /*thiz*/, jint usbFd, jstring jBindAddr, jint port,
	jlong frequencyHz, jint sampleRateHz, jint gainTenthsDb, jint ppmError,
	jboolean directSampling, jboolean biasTee) {
	if (g_running.load()) {
		LOGE("start requested while already running");
		return JNI_FALSE;
	}
	if (g_serverThread.joinable())
		g_serverThread.join();

	const char *bindAddrChars = env->GetStringUTFChars(jBindAddr, nullptr);
	std::string bindAddr = bindAddrChars ? bindAddrChars : "127.0.0.1";
	if (bindAddrChars)
		env->ReleaseStringUTFChars(jBindAddr, bindAddrChars);

	rtl_tcp_set_usb_fd(usbFd);

	std::vector<std::string> argv;
	argv.emplace_back("rtl_tcp");
	argv.emplace_back("-a");
	argv.emplace_back(bindAddr);
	argv.emplace_back("-p");
	argv.emplace_back(std::to_string(port));
	argv.emplace_back("-f");
	argv.emplace_back(std::to_string(frequencyHz));
	argv.emplace_back("-s");
	argv.emplace_back(std::to_string(sampleRateHz));
	argv.emplace_back("-g");
	/* rtl_tcp's -g is tenths of a dB as a decimal string, e.g. "40.2" for
	 * 402 tenths; 0 means "automatic gain" (matches our gainTenthsDb=0). */
	argv.emplace_back(std::to_string(gainTenthsDb / 10.0));
	argv.emplace_back("-P");
	argv.emplace_back(std::to_string(ppmError));
	if (directSampling)
		argv.emplace_back("-D");
	if (biasTee)
		argv.emplace_back("-T");

	g_running.store(true);
	g_lastResult.store(0);
	g_serverThread = std::thread(serverThreadMain, std::move(argv));
	return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_org_lotzapp_home_1radio_rtlsdr_RtlSdrUsbServer_nativeStop(JNIEnv *, jobject) {
	rtl_tcp_request_exit();
	if (g_serverThread.joinable())
		g_serverThread.join();
	g_running.store(false);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_lotzapp_home_1radio_rtlsdr_RtlSdrUsbServer_nativeIsRunning(JNIEnv *, jobject) {
	return g_running.load() ? JNI_TRUE : JNI_FALSE;
}
