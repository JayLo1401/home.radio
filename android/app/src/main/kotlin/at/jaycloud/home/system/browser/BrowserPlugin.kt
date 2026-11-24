package at.jaycloud.home.system.browser

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.ServiceWorkerClient
import android.webkit.ServiceWorkerController
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebStorage
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.Executors

/**
 * The browser ("Browser" part): the platform view "home_system/browser_view"
 * (one [BrowserView], the device's System WebView) and the channel
 * "home_system/browser" for what is the same for all of them - the blocker's
 * filters and switches, clearing data.
 */
class BrowserPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private lateinit var appContext: Context
    private lateinit var messenger: BinaryMessenger
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        messenger = binding.binaryMessenger
        channel = MethodChannel(binding.binaryMessenger, "home_system/browser").also { it.setMethodCallHandler(this) }
        binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, Factory())
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadFilters" -> {
                val path = call.argument<String>("path") ?: return result.success(false)
                loader.execute {
                    val ok = AdblockEngine.load(path)
                    main.post { result.success(ok) }
                }
            }
            "unloadFilters" -> {
                AdblockEngine.unload()
                result.success(null)
            }
            "setBlocking" -> {
                blockingEnabled = call.argument<Boolean>("enabled") ?: true
                allowlist = (call.argument<List<String>>("allowlist") ?: emptyList()).map { it.lowercase() }.toHashSet()
                installServiceWorkerClient()
                result.success(null)
            }
            "clearData" -> {
                if (call.argument<Boolean>("cookies") == true) {
                    CookieManager.getInstance().removeAllCookies(null)
                    CookieManager.getInstance().flush()
                    WebStorage.getInstance().deleteAllData()
                }
                if (call.argument<Boolean>("cache") == true) {
                    // The cache belongs to all WebViews of the app - any one clears it.
                    try {
                        WebView(appContext).apply { clearCache(true); destroy() }
                    } catch (e: Exception) {
                        // No WebView installed.
                    }
                }
                result.success(null)
            }
            "flushCookies" -> {
                CookieManager.getInstance().flush()
                result.success(null)
            }
            "webViewVersion" -> {
                val pkg = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) WebView.getCurrentWebViewPackage() else null
                result.success(pkg?.let { "${it.packageName} ${it.versionName}" })
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Requests of a page's service worker don't pass the WebView's own
     * client - the blocker looks at them here (on the page last opened).
     */
    private fun installServiceWorkerClient() {
        if (swInstalled || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        swInstalled = true
        try {
            ServiceWorkerController.getInstance().setServiceWorkerClient(object : ServiceWorkerClient() {
                override fun shouldInterceptRequest(request: WebResourceRequest): WebResourceResponse? =
                    BrowserView.current?.interceptForServiceWorker(request)
            })
        } catch (e: Exception) {
            // No WebView installed.
        }
    }

    private inner class Factory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            @Suppress("UNCHECKED_CAST")
            val params = args as? Map<String, Any?> ?: emptyMap()
            installServiceWorkerClient()
            return BrowserView(context, messenger, viewId, params)
        }
    }

    companion object {
        const val VIEW_TYPE = "home_system/browser_view"

        /** The activity, for full-screen video over everything. */
        @Volatile
        var activity: Activity? = null

        /** The blocker as switched in the settings. */
        @Volatile
        var blockingEnabled = true

        /** Sites the blocker is off for (hosts; also covers their subdomains). */
        @Volatile
        var allowlist: Set<String> = emptySet()

        private var swInstalled = false
        private val loader = Executors.newSingleThreadExecutor()

        /** Whether the blocker works on the page [pageHost]. */
        fun blockingFor(pageHost: String): Boolean {
            if (!blockingEnabled) return false
            val list = allowlist
            if (list.isEmpty() || pageHost.isEmpty()) return true
            var h = pageHost
            while (true) {
                if (h in list) return false
                val dot = h.indexOf('.')
                if (dot < 0) return true
                h = h.substring(dot + 1)
            }
        }
    }
}
