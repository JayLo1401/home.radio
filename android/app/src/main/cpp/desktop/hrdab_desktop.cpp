#include "hrdab_desktop.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

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

} // namespace

extern "C" {

int32_t hrdab_api_version(void)
{
    return HRDAB_API_VERSION;
}

void hrdab_init(hrdab_event_callback callback, const char* dataDir)
{
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
