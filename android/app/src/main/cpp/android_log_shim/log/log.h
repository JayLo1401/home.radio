// Minimal stand-in for AOSP's system/core/liblog/include/log/log.h, which
// isn't part of the standalone NDK sysroot. fdk-aac's lpp_tran.cpp includes
// this under #ifdef __ANDROID__ for two things: nothing from log.h itself
// (no ALOG*/__android_log_print calls in that file), and
// android_errorWriteLog() (declared in AOSP's log/log_read.h, transitively
// pulled in via log/log.h there) - used as a security-bulletin marker
// (CVE tag 112160868) at two known-bad-input bail-out points, not for any
// functional purpose. A real implementation logs to the device's security
// event log; a no-op stub is fine here.
#pragma once
#include <android/log.h>

#ifdef __cplusplus
extern "C" {
#endif
static inline int android_errorWriteLog(int tag, const char *subTag) {
    (void) tag;
    (void) subTag;
    return 0;
}
#ifdef __cplusplus
}
#endif
