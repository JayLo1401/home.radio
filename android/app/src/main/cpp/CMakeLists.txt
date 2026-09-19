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

# --- libusb (LGPL-2.1, github.com/libusb/libusb) - vendored 2026-09-18 for
# direct RTL-SDR USB access. Source list and config.h are libusb's own
# official Android build files (android/jni/libusb.mk, android/config.h) -
# not guessed - just adapted from ndk-build to CMake.
add_library(usb1.0 STATIC
    libusb/core.c
    libusb/descriptor.c
    libusb/hotplug.c
    libusb/io.c
    libusb/sync.c
    libusb/strerror.c
    libusb/os/linux_usbfs.c
    libusb/os/events_posix.c
    libusb/os/threads_posix.c
    libusb/os/linux_netlink.c
)
target_include_directories(usb1.0 PUBLIC libusb)
target_link_libraries(usb1.0 ${log-lib})

# --- librtlsdr (GPL-2.0, github.com/steve-m/librtlsdr) - vendored 2026-09-18.
# Only one function is added on top of the unmodified vendor source:
# rtlsdr_open_from_fd() in librtlsdr.c, for the Android USB-permission flow
# (see that function's doc comment).
#
# rtl_tcp.c is librtlsdr's own reference rtl_tcp server (upstream tools/),
# vendored as-is except: main() renamed to rtl_tcp_main() and made callable
# with a constructed argv (so we reuse 100% of its real option handling and
# the actual wire-protocol worker threads), plus an fd-based device-open path
# for Android added right where rtlsdr_open() used to be unconditionally
# called (see rtl_tcp_set_usb_fd() in that file). This is our own local
# "unser eigener USB-TCP Dienst": same rtl_tcp protocol on localhost, but
# backed by our direct USB connection instead of an external rtl_tcp process.
add_library(rtlsdr STATIC
    librtlsdr/librtlsdr.c
    librtlsdr/tuner_e4k.c
    librtlsdr/tuner_fc0012.c
    librtlsdr/tuner_fc0013.c
    librtlsdr/tuner_fc2580.c
    librtlsdr/tuner_r82xx.c
    librtlsdr/rtl_tcp.c
    librtlsdr/convenience/convenience.c
)
target_include_directories(rtlsdr PUBLIC librtlsdr/include)
target_link_libraries(rtlsdr PUBLIC usb1.0)

add_library(rtlsdrnative SHARED
    rtlsdr_jni.cpp
)
target_include_directories(rtlsdrnative PRIVATE librtlsdr)
target_compile_features(rtlsdrnative PRIVATE cxx_std_17)
target_link_libraries(rtlsdrnative rtlsdr usb1.0 ${log-lib})

# --- DAB+ decoding core (GPL-2.0/3.0, vendored 2026-09-19 from welle.io's
# own src/backend + src/various + src/input/rtl_tcp.* + src/libs/{fec,
# kiss_fft} - github.com/AlbrechtL/welle.io) - this is the actual OFDM
# demodulation / FIC+MSC decoding / DAB+ superframe+RS+AAC pipeline "so wie
# welle.io" the project has been aiming for, taken as real, working upstream
# source rather than reimplemented, matching this project's fdk-aac/libusb/
# librtlsdr precedent. Two small patches on top of the unmodified vendor
# source (see the files themselves): decoder_adapter.cpp/.h drop the plain
# DAB (MP2/mpg123) path since this project only targets DAB+ (dab_decoder.*
# and libs/mpg123, libs/faad2 were deliberately not vendored), and
# dabplus_decoder.h's fdk-aac include is adjusted to match how this
# project's already-vendored fdk-aac exposes its own header (see
# dab_native.cpp for the same pattern).
#
# Sample input is welle.io's own CRTL_TCP_Client (input/rtl_tcp.cpp): it
# connects to an rtl_tcp-protocol server exactly like RtlSdrTestScreen's
# client does - our own USB-TCP service, an external driver app, or a
# network service - so the DAB decoder is just another client of whichever
# of those three the user picked in Settings, no separate USB device access
# needed here at all.
add_library(dabcore STATIC
    dabcore/backend/charsets.cpp
    dabcore/backend/dab-audio.cpp
    dabcore/backend/dab-constants.cpp
    dabcore/backend/dabplus_decoder.cpp
    dabcore/backend/decoder_adapter.cpp
    dabcore/backend/eep-protection.cpp
    dabcore/backend/fib-processor.cpp
    dabcore/backend/fic-handler.cpp
    dabcore/backend/freq-interleaver.cpp
    dabcore/backend/mot_manager.cpp
    dabcore/backend/msc-handler.cpp
    dabcore/backend/ofdm-decoder.cpp
    dabcore/backend/ofdm-processor.cpp
    dabcore/backend/pad_decoder.cpp
    dabcore/backend/phasereference.cpp
    dabcore/backend/phasetable.cpp
    dabcore/backend/protTables.cpp
    dabcore/backend/radio-receiver.cpp
    dabcore/backend/tii-decoder.cpp
    dabcore/backend/tools.cpp
    dabcore/backend/uep-protection.cpp
    dabcore/backend/viterbi.cpp
    dabcore/various/Socket.cpp
    dabcore/various/fft.cpp
    dabcore/various/Xtan2.cpp
    dabcore/various/profiling.cpp
    dabcore/input/rtl_tcp.cpp
    dabcore/libs/fec/decode_rs_char.c
    dabcore/libs/fec/encode_rs_char.c
    dabcore/libs/fec/init_rs_char.c
    dabcore/libs/kiss_fft/kiss_fft.c
)
target_include_directories(dabcore PUBLIC
    dabcore
    dabcore/backend
    dabcore/various
    dabcore/input
    dabcore/libs/fec
    dabcore/libs/kiss_fft
)
target_compile_definitions(dabcore PUBLIC KISSFFT DABLIN_AAC_FDKAAC)
target_compile_features(dabcore PUBLIC cxx_std_17)
target_link_libraries(dabcore PUBLIC fdk-aac)

# direct_rtlsdr_input.cpp/.h (home_radio addition, 2026-09-19, not part of any
# vendored library - see that header's own doc comment) is the "own USB
# service" mode's alternative InputInterface: it drives librtlsdr directly,
# skipping the in-process rtl_tcp server/client round trip CRTL_TCP_Client
# otherwise goes through for that mode. Hence dabrtlsdrnative now also needs
# librtlsdr's own "rtlsdr"/"usb1.0" static libs, not just dabcore.
add_library(dabrtlsdrnative SHARED
    dabcore_jni.cpp
    direct_rtlsdr_input.cpp
)
target_compile_features(dabrtlsdrnative PRIVATE cxx_std_17)
target_link_libraries(dabrtlsdrnative dabcore rtlsdr usb1.0 ${log-lib})
