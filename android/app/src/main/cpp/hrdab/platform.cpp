// The few OS-specific bits of the receiver that are not about USB or
// sockets (see rtl2832/usbfs_transport and rtltcp_source for those).

#include "common.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <sys/resource.h>
#endif

namespace hrdab {

void raiseThreadPriority(int nice)
{
#ifdef _WIN32
    const int p = nice <= -19 ? THREAD_PRIORITY_HIGHEST : nice <= -16 ? THREAD_PRIORITY_ABOVE_NORMAL : THREAD_PRIORITY_NORMAL;
    SetThreadPriority(GetCurrentThread(), p);
#else
    // Linux: PRIO_PROCESS with who = 0 applies to the calling thread only.
    setpriority(PRIO_PROCESS, 0, nice);
#endif
}

} // namespace hrdab
