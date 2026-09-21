# NativeDabDecoder.onAuFromNative() is only called reflectively from native
# code (android/app/src/main/cpp/dab_native.cpp, via JNI GetMethodID with the
# literal name/signature) - R8 can't see that usage and was stripping/
# renaming it in minified builds, crashing every DAB+ playback attempt with
# NoSuchMethodError (found 2026-09-16). Keep the whole class untouched.
-keep class org.lotzapp.home_radio.dab.NativeDabDecoder {
    *;
}

# Same issue, same fix, for DabRtlSdrPlugin's nativeOn*() callbacks (see
# dabcore_jni.cpp's GetMethodID calls: nativeOnSyncChange, nativeOnMot,
# nativeOnSnr, etc.) - this class's own `external fun native*()` methods
# (Kotlin -> native) are already protected by R8's default `native
# <methods>` keep rule, but the reverse direction (native -> Kotlin, called
# by literal method name/signature rather than a normal call site R8 can
# see) is not, and crashed every release-build DAB+ playback attempt the
# same way NativeDabDecoder's did (found 2026-09-19, on-device
# NoSuchMethodError for nativeOnSyncChange).
-keep class org.lotzapp.home_radio.dab.DabRtlSdrPlugin {
    *;
}
