// Plain-C API of hrdab.dll / libhrdab.so, the desktop (Windows/Linux) build
// of home_radio's own receiver. Dart binds it with dart:ffi
// (lib/data/services/desktop/hrdab_ffi.dart).
//
// One process-wide controller, the desktop port of DabRtlSdrPlugin.kt. All
// calls return immediately; the work runs on the library's own threads and
// everything comes back through the event callback as UTF-8 JSON:
//  - the receiver's events, with the same "type"s and fields as the Android
//    EventChannel ("scanProgress", "fmStatus", "nbSpectrum", ...)
//  - method results: {"type":"__reply","id":<id>,"value":<result>} or
//    {"type":"__reply","id":<id>,"error":"<code>","message":"..."}
// The callback may be invoked from any thread (Dart: NativeCallable.listener)
// and owns the string: release it with hrdab_free().
#pragma once

#include <stdint.h>

#if defined(_WIN32) && defined(HRDAB_BUILDING)
#define HRDAB_API __declspec(dllexport)
#elif defined(_WIN32)
#define HRDAB_API __declspec(dllimport)
#else
#define HRDAB_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*hrdab_event_callback)(char* json);

// Bumped whenever a signature or the protocol changes.
#define HRDAB_API_VERSION 1
HRDAB_API int32_t hrdab_api_version(void);

// Sets (or replaces, e.g. after a hot restart) the event callback and the
// directory slideshow images are saved under (<dataDir>/dab_logos/).
// Starts the controller on first use. A NULL callback drops events.
HRDAB_API void hrdab_init(hrdab_event_callback callback, const char* dataDir);

// Stops every activity, closes the stick / rtl_tcp connection and drops the
// callback. hrdab_init may be called again afterwards.
HRDAB_API void hrdab_shutdown(void);

// A method of the "home_radio/dab_rtlsdr" channel ("setServer", "scanBand3",
// "fmPlay", "nbStart", ...) with its arguments as a JSON object; the result
// arrives as a "__reply" event with the same id.
HRDAB_API void hrdab_call(int64_t id, const char* method, const char* argsJson);

// RTL-SDR sticks visible to libusb, as JSON (RtlSdrUsbService.listDevices).
// Synchronous and quick. Release with hrdab_free().
HRDAB_API char* hrdab_usb_devices(void);

HRDAB_API void hrdab_free(char* p);

#ifdef __cplusplus
}
#endif
