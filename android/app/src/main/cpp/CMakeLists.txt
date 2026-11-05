cmake_minimum_required(VERSION 3.18.1)
project(hrdab)

# The NDK does not enable NEON for 32-bit ARM by default (it is mandatory and
# always on for arm64). The OFDM/FFT/Viterbi code benefits from it.
if(ANDROID_ABI STREQUAL "armeabi-v7a")
    add_compile_options(-mfpu=neon -mfloat-abi=softfp)
endif()

find_library(log-lib log)

# hrdab: home_radio's own DAB+ receiver (see hrdab/common.h) - OFDM, FIC/MSC,
# DAB+ super frames, PAD and an RTL2832U/R820T driver over usbfs. No
# third-party code; AAC is decoded by Android's MediaCodec on the Kotlin side
# (DabAacPlayer). Also the FM (UKW) receiver with stereo decoder and RDS
# (fm_demod, rds), sharing the same stick and sample stream, and the
# narrowband receiver for CB/airband (nb_demod: AM/NFM/SSB, squelch, auto
# mode, activity monitor).
#
# The Windows/Linux desktop builds compile the same sources (minus the JNI
# glue and usbfs) into hrdab.dll / libhrdab.so - see desktop/CMakeLists.txt.
add_library(hrdab SHARED
    hrdab/charset.cpp
    hrdab/dab_tables.cpp
    hrdab/fft.cpp
    hrdab/fic.cpp
    hrdab/fm_demod.cpp
    hrdab/fm_dsp.cpp
    hrdab/hrdab_jni.cpp
    hrdab/msc.cpp
    hrdab/nb_demod.cpp
    hrdab/ofdm.cpp
    hrdab/pad.cpp
    hrdab/platform.cpp
    hrdab/r82xx.cpp
    hrdab/rds.cpp
    hrdab/receiver.cpp
    hrdab/reed_solomon.cpp
    hrdab/rtl2832.cpp
    hrdab/rtltcp_source.cpp
    hrdab/superframe.cpp
    hrdab/usbfs_transport.cpp
    hrdab/viterbi.cpp
)
target_compile_features(hrdab PRIVATE cxx_std_17)
# Real-time DSP: optimise even in debug builds (an unoptimised Viterbi/FFT
# cannot keep up with 2 MS/s on TV-box CPUs).
target_compile_options(hrdab PRIVATE -O2)
target_link_libraries(hrdab ${log-lib})
