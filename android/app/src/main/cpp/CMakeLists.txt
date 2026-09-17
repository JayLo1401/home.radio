cmake_minimum_required(VERSION 3.18.1)
project(dabnative)

# Fraunhofer FDK AAC (fdk-aac/, vendored from github.com/mstorsjo/fdk-aac
# v2.0.3) - the same production-grade AAC decoder DABlin/OMRI-based DAB+
# players use (and that many Android builds ship for MediaCodec itself),
# in place of going through Android's own MediaCodec API. Built as a static
# lib; only its decoder is used here.
set(FDK_AAC_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory(fdk-aac)

# fdk-aac's libSBRdec/src/lpp_tran.cpp includes AOSP's system/core
# "log/log.h" under #ifdef __ANDROID__, which isn't part of the standalone
# NDK sysroot (fdk-aac is normally built inside a full AOSP tree, where it
# is) - it doesn't actually call anything from it, so a minimal local stub
# (android_log_shim/log/log.h) is enough.
target_include_directories(fdk-aac PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/android_log_shim)

add_library(dabnative SHARED
    dab_native.cpp
    usb_ioctl.cpp
    fec/init_rs_char.c
    fec/decode_rs_char.c
)

target_include_directories(dabnative PRIVATE fec)

find_library(log-lib log)
target_link_libraries(dabnative fdk-aac ${log-lib})
