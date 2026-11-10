# hrdab for the desktop: home_radio's own receiver (../hrdab, the same
# sources as the Android build minus the JNI glue and usbfs) as
# hrdab.dll / libhrdab.so with a plain-C API for dart:ffi (hrdab_desktop.h),
# plus what Android's framework provides there:
#  - RTL-SDR over USB: libusb-1.0 (libusb_transport). Windows: built here
#    from the release source tarball into libusb-1.0.dll (LGPL, so a
#    separate DLL next to the exe). Linux: the system library via pkg-config.
#  - AAC: FDK-AAC (the decoder behind Android's MediaCodec; 960-sample DAB+
#    frames with SBR and PS), fetched from its release tarball and linked in
#    statically - decoder part only.
#  - audio output: miniaudio (vendored in third_party/, public domain).
#
# Used by windows/CMakeLists.txt and linux/CMakeLists.txt via
# add_subdirectory; sets HRDAB_BUNDLED_LIBRARIES in the parent scope for
# the install step. Downloads need network access at configure time; point
# FETCHCONTENT_SOURCE_DIR_FDK_AAC / FETCHCONTENT_SOURCE_DIR_LIBUSB at
# unpacked copies to build offline.
cmake_minimum_required(VERSION 3.24)
project(hrdab_desktop LANGUAGES C CXX)

include(FetchContent)

set(HRDAB_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../hrdab")

# The runner adds UNICODE globally; libusb and miniaudio pick their WinAPI
# variants themselves.
remove_definitions(-DUNICODE -D_UNICODE)
if(MSVC)
  # Real-time DSP is built optimised even in debug builds (see the Android
  # CMakeLists); /RTC1 cannot be combined with /O2.
  foreach(lang C CXX)
    string(REPLACE "/RTC1" "" CMAKE_${lang}_FLAGS_DEBUG "${CMAKE_${lang}_FLAGS_DEBUG}")
  endforeach()
endif()

# --- FDK-AAC (decoder only) ---
FetchContent_Declare(fdk_aac
  URL https://github.com/mstorsjo/fdk-aac/archive/refs/tags/v2.0.3.tar.gz
  URL_HASH SHA256=e25671cd96b10bad896aa42ab91a695a9e573395262baed4e4a2ff178d6a3a78
  # No add_subdirectory: only the decoder sources are compiled, below, and
  # fdk-aac's own install rules must not end up in the app bundle.
  SOURCE_SUBDIR do-not-add
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(fdk_aac)
set(FDK_DIR "${fdk_aac_SOURCE_DIR}")
configure_file("${FDK_DIR}/NOTICE" "${CMAKE_CURRENT_BINARY_DIR}/licenses/fdk-aac.txt" COPYONLY)
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio/LICENSE" "${CMAKE_CURRENT_BINARY_DIR}/licenses/miniaudio.txt" COPYONLY)
set(HRDAB_LICENSES "${CMAKE_CURRENT_BINARY_DIR}/licenses/fdk-aac.txt" "${CMAKE_CURRENT_BINARY_DIR}/licenses/miniaudio.txt")
set(FDK_LIBS libAACdec libArithCoding libDRCdec libFDK libMpegTPDec libPCMutils libSACdec libSBRdec libSYS)
set(FDK_SOURCES "")
set(FDK_INCLUDES "")
foreach(lib ${FDK_LIBS})
  file(GLOB lib_sources "${FDK_DIR}/${lib}/src/*.cpp")
  list(APPEND FDK_SOURCES ${lib_sources})
  list(APPEND FDK_INCLUDES "${FDK_DIR}/${lib}/include")
endforeach()
add_library(hrdab_fdkaac STATIC ${FDK_SOURCES})
target_include_directories(hrdab_fdkaac PUBLIC ${FDK_INCLUDES})
set_target_properties(hrdab_fdkaac PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden)
if(MSVC)
  target_compile_options(hrdab_fdkaac PRIVATE /O2 /W0)
  target_compile_definitions(hrdab_fdkaac PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
  target_compile_options(hrdab_fdkaac PRIVATE -O2 -w -fno-exceptions -fno-rtti)
endif()

# --- libusb ---
set(HRDAB_EXTRA_LIBRARIES "")
if(WIN32)
  FetchContent_Declare(libusb
    URL https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
    URL_HASH SHA256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
    SOURCE_SUBDIR do-not-add
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  )
  FetchContent_MakeAvailable(libusb)
  set(USB_DIR "${libusb_SOURCE_DIR}")
  configure_file("${USB_DIR}/COPYING" "${CMAKE_CURRENT_BINARY_DIR}/licenses/libusb.txt" COPYONLY)
  list(APPEND HRDAB_LICENSES "${CMAKE_CURRENT_BINARY_DIR}/licenses/libusb.txt")
  # Same file list and settings as libusb's own msvc/libusb_dll.vcxproj.
  add_library(libusb-1.0 SHARED
    "${USB_DIR}/libusb/core.c"
    "${USB_DIR}/libusb/descriptor.c"
    "${USB_DIR}/libusb/hotplug.c"
    "${USB_DIR}/libusb/io.c"
    "${USB_DIR}/libusb/strerror.c"
    "${USB_DIR}/libusb/sync.c"
    "${USB_DIR}/libusb/os/events_windows.c"
    "${USB_DIR}/libusb/os/threads_windows.c"
    "${USB_DIR}/libusb/os/windows_common.c"
    "${USB_DIR}/libusb/os/windows_usbdk.c"
    "${USB_DIR}/libusb/os/windows_winusb.c"
    "${USB_DIR}/libusb/libusb-1.0.def"
    "${USB_DIR}/libusb/libusb-1.0.rc"
  )
  target_include_directories(libusb-1.0 PRIVATE "${USB_DIR}/msvc" "${USB_DIR}/libusb")
  target_include_directories(libusb-1.0 INTERFACE "${USB_DIR}/libusb")
  target_compile_definitions(libusb-1.0 PRIVATE _WIN32_WINNT=_WIN32_WINNT_VISTA _CRT_SECURE_NO_WARNINGS)
  target_compile_options(libusb-1.0 PRIVATE /W0)
  set_target_properties(libusb-1.0 PROPERTIES OUTPUT_NAME "libusb-1.0")
  set(HRDAB_LIBUSB libusb-1.0)
  list(APPEND HRDAB_EXTRA_LIBRARIES "$<TARGET_FILE:libusb-1.0>")
else()
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(LIBUSB REQUIRED IMPORTED_TARGET libusb-1.0)
  set(HRDAB_LIBUSB PkgConfig::LIBUSB)
endif()

# --- hrdab ---
add_library(hrdab SHARED
  "${HRDAB_SRC}/charset.cpp"
  "${HRDAB_SRC}/dab_tables.cpp"
  "${HRDAB_SRC}/fft.cpp"
  "${HRDAB_SRC}/fic.cpp"
  "${HRDAB_SRC}/fm_demod.cpp"
  "${HRDAB_SRC}/fm_dsp.cpp"
  "${HRDAB_SRC}/json.cpp"
  "${HRDAB_SRC}/msc.cpp"
  "${HRDAB_SRC}/nb_demod.cpp"
  "${HRDAB_SRC}/ofdm.cpp"
  "${HRDAB_SRC}/pad.cpp"
  "${HRDAB_SRC}/platform.cpp"
  "${HRDAB_SRC}/r82xx.cpp"
  "${HRDAB_SRC}/rds.cpp"
  "${HRDAB_SRC}/receiver.cpp"
  "${HRDAB_SRC}/reed_solomon.cpp"
  "${HRDAB_SRC}/rtl2832.cpp"
  "${HRDAB_SRC}/rtltcp_source.cpp"
  "${HRDAB_SRC}/superframe.cpp"
  "${HRDAB_SRC}/viterbi.cpp"
  audio_player.cpp
  hrdab_desktop.cpp
  libusb_transport.cpp
  miniaudio_impl.c
  radio_controller.cpp
)
target_compile_features(hrdab PRIVATE cxx_std_17)
target_include_directories(hrdab PRIVATE "${HRDAB_SRC}" "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio")
target_compile_definitions(hrdab PRIVATE
  HRDAB_STDERR_LOG
  HRDAB_BUILDING
  MA_NO_DECODING MA_NO_ENCODING MA_NO_GENERATION MA_NO_RESOURCE_MANAGER MA_NO_NODE_GRAPH MA_NO_ENGINE)
set_target_properties(hrdab PROPERTIES
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  POSITION_INDEPENDENT_CODE ON)
if(MSVC)
  target_compile_options(hrdab PRIVATE /O2 /utf-8 /W3 /wd4244 /wd4267 /wd4305)
  target_compile_definitions(hrdab PRIVATE _USE_MATH_DEFINES _CRT_SECURE_NO_WARNINGS NOMINMAX)
  target_link_libraries(hrdab PRIVATE hrdab_fdkaac ${HRDAB_LIBUSB} ws2_32)
else()
  target_compile_options(hrdab PRIVATE -O2 -Wall -Wno-unused-variable -Wno-unused-function)
  find_package(Threads REQUIRED)
  target_link_libraries(hrdab PRIVATE hrdab_fdkaac ${HRDAB_LIBUSB} Threads::Threads ${CMAKE_DL_LIBS} m)
  # Only the hrdab_* C API is exported; FDK's symbols stay private.
  target_link_options(hrdab PRIVATE "LINKER:--exclude-libs,ALL")
endif()

option(HRDAB_BUILD_CLI "Build hrdab_cli, a command-line driver for tests against real hardware" OFF)
if(HRDAB_BUILD_CLI)
  add_executable(hrdab_cli tools/hrdab_cli.cpp)
  target_include_directories(hrdab_cli PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_compile_features(hrdab_cli PRIVATE cxx_std_17)
  target_link_libraries(hrdab_cli PRIVATE hrdab)
endif()

get_directory_property(HRDAB_HAS_PARENT PARENT_DIRECTORY)
if(HRDAB_HAS_PARENT)
  set(HRDAB_BUNDLED_LIBRARIES "$<TARGET_FILE:hrdab>" ${HRDAB_EXTRA_LIBRARIES} PARENT_SCOPE)
  # Third-party license texts for the bundle's data/licenses.
  set(HRDAB_LICENSE_FILES ${HRDAB_LICENSES} PARENT_SCOPE)
endif()
