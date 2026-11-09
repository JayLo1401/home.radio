#include "hrdab_desktop.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>

#ifdef _WIN32
#include <io.h>
#define isatty _isatty
#define fileno _fileno
#else
#include <unistd.h>
#endif

#include "libusb_transport.h"
#include "radio_controller.h"

using namespace hrdab;

namespace {

std::atomic<hrdab_event_callback> g_callback{nullptr};
std::mutex g_mutex;
// Never destroyed: detached worker threads may still finish their last
// steps while the process exits.
RadioController* g_controller = nullptr;

char* copyString(const std::string& s)
{
    auto* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (!p) return nullptr;
    std::memcpy(p, s.data(), s.size());
    p[s.size()] = '\0';
    return p;
}

void sink(const std::string& json)
{
    const hrdab_event_callback cb = g_callback.load();
    if (!cb) return;
    if (char* p = copyString(json)) cb(p);
}

RadioController& controller()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_controller) g_controller = new RadioController(sink, std::string());
    return *g_controller;
}

// The receiver logs to stderr (HR_LOG*), which a GUI app on Windows simply
// loses. Unless stderr is a terminal (hrdab_cli, the app started from a
// shell on Linux), it goes to <dataDir>/hrdab.log instead; the previous
// run's log is kept as hrdab.log.1.
void redirectLog(const std::string& dataDir)
{
    static std::once_flag once;
    std::call_once(once, [&] {
        if (dataDir.empty() || isatty(fileno(stderr))) return;
        const std::filesystem::path dir = std::filesystem::u8path(dataDir);
        const std::filesystem::path log = dir / "hrdab.log";
        std::error_code ec;
        std::filesystem::create_directories(dir, ec);
        std::filesystem::rename(log, dir / "hrdab.log.1", ec);
#ifdef _WIN32
        FILE* f = _wfreopen(log.wstring().c_str(), L"w", stderr);
#else
        FILE* f = std::freopen(log.string().c_str(), "w", stderr);
#endif
        // Unbuffered: MSVC has no line buffering, and the last lines before
        // a crash are the interesting ones.
        if (f) std::setvbuf(stderr, nullptr, _IONBF, 0);
    });
}

} // namespace

extern "C" {

int32_t hrdab_api_version(void)
{
    return HRDAB_API_VERSION;
}

void hrdab_init(hrdab_event_callback callback, const char* dataDir)
{
    redirectLog(dataDir ? dataDir : "");
    g_callback = callback;
    controller().setDataDir(dataDir ? dataDir : "");
}

void hrdab_shutdown(void)
{
    // Callback first: the runner calls this while the engine goes down, so
    // nothing may reach the Dart side any more.
    g_callback = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_controller) return; // never used
    }
    controller().shutdown();
}

void hrdab_call(int64_t id, const char* method, const char* argsJson)
{
    controller().call(id, method ? method : "", argsJson ? argsJson : "{}");
}

char* hrdab_usb_devices(void)
{
    return copyString(LibusbTransport::listDevicesJson());
}

void hrdab_free(char* p)
{
    std::free(p);
}

} // extern "C"
