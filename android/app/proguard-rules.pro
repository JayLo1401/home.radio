# IntegratedDabEngine's onNative*() callbacks are only called from native code
# (hrdab_jni.cpp, via GetMethodID with the literal name/signature). R8 cannot
# see that and would strip/rename them in minified builds, so keep the class
# untouched. (Kotlin -> native `external fun`s are covered by R8's default
# `native <methods>` keep rule.)
-keep class at.jaycloud.home.system.dab.IntegratedDabEngine {
    *;
}

# Browser (browser/WebKitCompat.kt): androidx.webkit (webview_flutter's
# dependency) is called by reflection - keep what it uses.
-keep class androidx.webkit.WebViewFeature { public static *; }
-keep class androidx.webkit.WebViewCompat { public static *; }
-keep class androidx.webkit.WebSettingsCompat { public static *; }
-keep class androidx.webkit.ScriptHandler { *; }

# media_kit on Android (films via libmpv): libmpv / libmediakitandroidhelper
# call these classes over JNI (FindClass / GetMethodID with literal names),
# which R8 cannot see.
-keep class com.alexmercerind.** { *; }
