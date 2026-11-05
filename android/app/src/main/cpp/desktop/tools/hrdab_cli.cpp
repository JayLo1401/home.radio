// Command-line driver for hrdab's desktop C API - exercises the same calls
// the app makes, against a real rtl_tcp server or USB stick, without the UI.
// Built with -DHRDAB_BUILD_CLI=ON (not part of the app bundle).
//
//   hrdab_cli <source> dabscan [freqKhz]
//   hrdab_cli <source> dabplay <freqKhz> <serviceId> <seconds>
//   hrdab_cli <source> fm <freqKhz> <seconds>
//   hrdab_cli <source> fmscan
//   hrdab_cli <source> fmseek <fromKhz> up|down
//   hrdab_cli <source> nb <freqHz> <mode> <seconds> [squelchDb] [sampleRate]
//   hrdab_cli usbdevices
// <source> is host:port (rtl_tcp) or "usb".
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#include "hrdab_desktop.h"

namespace {

std::mutex g_mutex;
std::condition_variable g_cv;
std::string g_waitFor;
bool g_seen = false;
std::string g_lastReply;
int64_t g_replyId = -1;
std::atomic<int64_t> g_t0{0};

int64_t nowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

void onEvent(char* json)
{
    std::string s(json);
    hrdab_free(json);
    const bool noisy = s.find("\"nbSpectrum\"") != std::string::npos || s.find("\"rsErrors\"") != std::string::npos;
    if (!noisy || std::getenv("HRDAB_CLI_ALL")) {
        std::printf("[%6.1f] %s\n", (nowMs() - g_t0) / 1000.0, s.size() > 400 ? (s.substr(0, 400) + "...").c_str() : s.c_str());
        std::fflush(stdout);
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_waitFor.empty() && s.find(g_waitFor) != std::string::npos) g_seen = true;
    if (s.find("\"__reply\"") != std::string::npos) {
        const std::string tag = "\"id\":" + std::to_string(g_replyId) + ",";
        if (s.find(tag) != std::string::npos) g_lastReply = s;
    }
    g_cv.notify_all();
}

int64_t g_nextId = 1;

// Calls and waits for the reply.
std::string call(const char* method, const std::string& args, int timeoutMs = 30000)
{
    std::unique_lock<std::mutex> lock(g_mutex);
    g_replyId = g_nextId++;
    g_lastReply.clear();
    const int64_t id = g_replyId;
    lock.unlock();
    hrdab_call(id, method, args.c_str());
    lock.lock();
    g_cv.wait_for(lock, std::chrono::milliseconds(timeoutMs), [] { return !g_lastReply.empty(); });
    return g_lastReply;
}

bool waitFor(const std::string& needle, int timeoutMs)
{
    std::unique_lock<std::mutex> lock(g_mutex);
    g_waitFor = needle;
    g_seen = false;
    const bool ok = g_cv.wait_for(lock, std::chrono::milliseconds(timeoutMs), [] { return g_seen; });
    g_waitFor.clear();
    return ok;
}

} // namespace

int main(int argc, char** argv)
{
    g_t0 = nowMs();
    if (argc >= 2 && std::strcmp(argv[1], "usbdevices") == 0) {
        char* s = hrdab_usb_devices();
        std::printf("%s\n", s ? s : "(null)");
        hrdab_free(s);
        return 0;
    }
    if (argc < 3) {
        std::fprintf(stderr, "usage: see hrdab_cli.cpp\n");
        return 2;
    }
    hrdab_init(onEvent, ".");
    const std::string source = argv[1];
    const std::string cmd = argv[2];
    if (source == "usb") {
        std::printf("useDirectUsb -> %s\n", call("useDirectUsb", "{}").c_str());
    } else {
        const size_t colon = source.find(':');
        const std::string host = source.substr(0, colon);
        const std::string port = colon == std::string::npos ? "1234" : source.substr(colon + 1);
        std::printf("setServer -> %s\n", call("setServer", "{\"host\":\"" + host + "\",\"port\":" + port + "}").c_str());
    }

    if (cmd == "dabscan") {
        const std::string args = argc > 3 ? std::string("{\"freqKhz\":") + argv[3] + "}" : "{}";
        call("scanBand3", args);
        waitFor("\"scanFinished\"", 600000);
    } else if (cmd == "dabplay" && argc > 5) {
        const std::string r = call("playService", std::string("{\"freqKhz\":") + argv[3] + ",\"serviceId\":" + argv[4] + "}");
        std::printf("playService -> %s\n", r.c_str());
        std::this_thread::sleep_for(std::chrono::seconds(std::atoi(argv[5])));
        call("stopPlayback", "{}");
    } else if (cmd == "fm" && argc > 4) {
        std::printf("fmPlay -> %s\n", call("fmPlay", std::string("{\"freqKhz\":") + argv[3] + "}").c_str());
        std::this_thread::sleep_for(std::chrono::seconds(std::atoi(argv[4])));
        call("fmStop", "{}");
    } else if (cmd == "fmscan") {
        call("fmScan", "{}");
        waitFor("\"fmScanFinished\"", 600000);
    } else if (cmd == "fmseek" && argc > 4) {
        call("fmSeek", std::string("{\"fromKhz\":") + argv[3] + ",\"up\":" + (std::strcmp(argv[4], "up") == 0 ? "true" : "false") + "}");
        waitFor("\"fmSeekResult\"", 120000);
        std::this_thread::sleep_for(std::chrono::seconds(5));
        call("fmStop", "{}");
    } else if (cmd == "nb" && argc > 5) {
        const std::string squelch = argc > 6 ? argv[6] : "0";
        const std::string rate = argc > 7 ? argv[7] : "2048000";
        const std::string args = std::string("{\"sampleRate\":") + rate + ",\"centerHz\":" + argv[3] +
                                 ",\"channelsHz\":[" + argv[3] + "],\"freqHz\":" + argv[3] + ",\"mode\":\"" + argv[4] +
                                 "\",\"squelchDb\":" + squelch + "}";
        std::printf("nbStart -> %s\n", call("nbStart", args).c_str());
        std::this_thread::sleep_for(std::chrono::seconds(std::atoi(argv[5])));
        call("nbStop", "{}");
    } else {
        std::fprintf(stderr, "unknown command\n");
    }
    hrdab_shutdown();
    return 0;
}
