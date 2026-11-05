// miniaudio's implementation (third_party/miniaudio, public domain / MIT-0).
// Playback only; the backends (WASAPI, PulseAudio, ALSA) are loaded at
// runtime, so the library links against nothing but libc/libdl/pthread.
// The MA_NO_* switches are set for all of hrdab in CMakeLists.txt.
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
