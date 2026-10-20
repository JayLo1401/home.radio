# IntegratedDabEngine's onNative*() callbacks are only called from native code
# (hrdab_jni.cpp, via GetMethodID with the literal name/signature). R8 cannot
# see that and would strip/rename them in minified builds, so keep the class
# untouched. (Kotlin -> native `external fun`s are covered by R8's default
# `native <methods>` keep rule.)
-keep class at.jaycloud.home.radio.dab.IntegratedDabEngine {
    *;
}
