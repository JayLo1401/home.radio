# NativeDabDecoder.onAuFromNative() is only called reflectively from native
# code (android/app/src/main/cpp/dab_native.cpp, via JNI GetMethodID with the
# literal name/signature) - R8 can't see that usage and was stripping/
# renaming it in minified builds, crashing every DAB+ playback attempt with
# NoSuchMethodError (found 2026-09-16). Keep the whole class untouched.
-keep class org.lotzapp.home_radio.dab.NativeDabDecoder {
    *;
}
