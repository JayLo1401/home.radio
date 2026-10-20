// home_radio's own DAB+ receiver ("Integrierte DAB Verbindung").
//
// Everything under cpp/hrdab/ is written for this project from the public
// standards (ETSI EN 300 401 for DAB, ETSI TS 102 563 for DAB+, ETSI
// TS 101 756 for the label character sets) and from the RTL2832U/R820T
// register-level behaviour. No third-party source is used; AAC decoding is
// left to Android's own MediaCodec on the Kotlin side.
//
// Transmission mode I only - the only mode in use in Band III today.
#pragma once

#include <complex>
#include <cstddef>
#include <cstdint>

#if defined(__ANDROID__) && !defined(HRDAB_STDERR_LOG)
#include <android/log.h>
#define HR_LOGI(...) __android_log_print(ANDROID_LOG_INFO, "hrdab", __VA_ARGS__)
#define HR_LOGW(...) __android_log_print(ANDROID_LOG_WARN, "hrdab", __VA_ARGS__)
#define HR_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "hrdab", __VA_ARGS__)
#else
#include <cstdio>
#define HR_LOGI(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#define HR_LOGW(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#define HR_LOGE(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#endif

namespace hrdab {

using cf32 = std::complex<float>;

// Mode I timing, in samples at 2.048 MS/s.
constexpr int kSampleRate = 2048000;
constexpr int kFftLen = 2048;          // useful symbol part Tu
constexpr int kGuardLen = 504;         // cyclic prefix Tg
constexpr int kSymbolLen = kFftLen + kGuardLen;
constexpr int kNullLen = 2656;
constexpr int kSymbolsPerFrame = 76;   // phase reference symbol + 75 data symbols
constexpr int kFrameLen = kNullLen + kSymbolsPerFrame * kSymbolLen; // 196608 = 96 ms

constexpr int kCarriers = 1536;
constexpr int kBitsPerSymbol = 2 * kCarriers;
constexpr int kDataSymbols = kSymbolsPerFrame - 1;
constexpr int kFicSymbols = 3;
constexpr int kFrameSoftBits = kDataSymbols * kBitsPerSymbol;

constexpr int kFicBlocksPerFrame = 4;
constexpr int kFicBlockBits = kFicSymbols * kBitsPerSymbol / kFicBlocksPerFrame; // 2304
constexpr int kFibBytes = 32;

constexpr int kCifsPerFrame = 4;
constexpr int kCuBits = 64;
constexpr int kCusPerCif = 864;
constexpr int kCifBits = kCuBits * kCusPerCif; // 55296 = 18 symbols

} // namespace hrdab
