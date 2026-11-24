package at.jaycloud.home.system.browser

import android.util.Log
import android.webkit.WebView

/**
 * androidx.webkit (WebViewCompat) by reflection: it is in the app (webview_flutter's
 * dependency, androidx.webkit 1.15.0) but not on our compile classpath, and we
 * don't add dependencies. proguard-rules.pro keeps the few methods used here.
 */
internal object WebKitCompat {
    private const val TAG = "WebKitCompat"

    private fun supported(feature: String): Boolean = try {
        val c = Class.forName("androidx.webkit.WebViewFeature")
        c.getMethod("isFeatureSupported", String::class.java).invoke(null, feature) as Boolean
    } catch (e: Throwable) {
        false
    }

    /**
     * Runs [script] in every frame of every page before the page's own
     * scripts (WebViewCompat.addDocumentStartJavaScript). False where the
     * WebView can't - then the caller injects at page start.
     */
    fun addDocumentStartScript(webView: WebView, script: String): Boolean {
        if (!supported("DOCUMENT_START_SCRIPT")) return false
        return try {
            val c = Class.forName("androidx.webkit.WebViewCompat")
            c.getMethod("addDocumentStartJavaScript", WebView::class.java, String::class.java, Set::class.java)
                .invoke(null, webView, script, setOf("*"))
            true
        } catch (e: Throwable) {
            Log.w(TAG, "addDocumentStartJavaScript: $e")
            false
        }
    }

    /** No "X-Requested-With: <app id>" header - it tells sites this is an app's WebView. */
    fun hideRequestedWithHeader(webView: WebView) {
        if (!supported("REQUESTED_WITH_HEADER_ALLOW_LIST")) return
        try {
            val c = Class.forName("androidx.webkit.WebSettingsCompat")
            c.getMethod("setRequestedWithHeaderOriginAllowList", android.webkit.WebSettings::class.java, Set::class.java)
                .invoke(null, webView.settings, emptySet<String>())
        } catch (e: Throwable) {
            Log.w(TAG, "setRequestedWithHeaderOriginAllowList: $e")
        }
    }
}
