package at.jaycloud.home.system.browser

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.concurrent.atomic.AtomicInteger

/**
 * One browser page: the device's System WebView (Chromium; Amazon WebView on
 * Fire OS) with
 * - the blocker in [WebViewClient.shouldInterceptRequest] (AdblockEngine,
 *   an empty answer instead of the ad), cosmetic filters and the lists'
 *   scriptlets by a document-start script (the scripts in assets/browser),
 * - the remote: Dart moves its pointer and sends taps ([tap], a touch at
 *   that point), hover moves and wheel scrolling as a mouse would,
 * - text fields: the page says when one has focus (Bridge.editing) - after
 *   a tap the keyboard comes up; Dart can also put text in ([insertText]),
 * - HTML5 full screen (YouTube) as a native view over the whole app, with
 *   its own keys (Back leaves, OK plays/pauses, left/right seek).
 *
 * Channel "home_system/browser_view_<id>": Dart's commands, and events back
 * ("page", "blocked", "editing", "media", "fullscreen", "download").
 */
@SuppressLint("SetJavaScriptEnabled")
class BrowserView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    params: Map<String, Any?>,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "home_system/browser_view_$viewId")
    private val webView = WebView(context)
    private val bridgeName = "hs" + java.lang.Long.toString(System.nanoTime() xor (Math.random() * 1e15).toLong(), 36).replace("-", "")
    private val defaultUserAgent: String = webView.settings.userAgentString
    private var desktop = params["desktop"] as? Boolean ?: false
    private val documentStart: Boolean

    /** The page's host - what the blocker's per-site switches and $domain= go by. */
    @Volatile
    private var pageHost = ""

    private val blockedCount = AtomicInteger()
    private var blockedPosted = false
    private var lastTapAt = 0L
    private var hoverStarted = false

    /** Text field kinds per frame (Bridge.editing), the one shown last wins. */
    private var editingFrame: String? = null
    private var editingKind = ""

    /** Frames playing audible media. */
    private val playingFrames = HashSet<String>()

    /** The page script for evaluateJavascript where WebView can't add it at document start. */
    private var fallbackScript: String? = null

    private var fullscreenHolder: FrameLayout? = null
    private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null

    init {
        current = this
        channel.setMethodCallHandler(this)
        webView.setBackgroundColor(Color.WHITE)
        webView.isFocusable = true
        webView.isFocusableInTouchMode = true
        with(webView.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            @Suppress("DEPRECATION")
            databaseEnabled = true
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            setSupportZoom(true)
            // Links that want a new window open in this one.
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            mediaPlaybackRequiresUserGesture = true
            textZoom = (params["textZoom"] as? Int) ?: 100
            userAgentString = userAgent(desktop)
        }
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
        WebKitCompat.hideRequestedWithHeader(webView)
        webView.addJavascriptInterface(Bridge(), bridgeName)
        documentStart = WebKitCompat.addDocumentStartScript(webView, pageScript(context))
        webView.webViewClient = Client()
        webView.webChromeClient = Chrome()
        webView.setDownloadListener { url, _, _, mimeType, _ ->
            main.post { channel.invokeMethod("download", mapOf("url" to url, "mimeType" to mimeType)) }
        }
        (params["url"] as? String)?.takeIf { it.isNotEmpty() }?.let { webView.loadUrl(it) }
    }

    override fun getView(): View = webView

    override fun dispose() {
        exitFullscreen()
        channel.setMethodCallHandler(null)
        if (current === this) current = null
        CookieManager.getInstance().flush()
        try {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.stopLoading()
            webView.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "dispose: $e")
        }
    }

    // --- Dart's commands -----------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadUrl" -> {
                webView.loadUrl(call.argument<String>("url") ?: "")
                result.success(null)
            }
            "goBack" -> {
                val can = webView.canGoBack()
                if (can) webView.goBack()
                result.success(can)
            }
            "goForward" -> {
                val can = webView.canGoForward()
                if (can) webView.goForward()
                result.success(can)
            }
            "reload" -> {
                webView.reload()
                result.success(null)
            }
            "stop" -> {
                webView.stopLoading()
                result.success(null)
            }
            "setDesktop" -> {
                val on = call.argument<Boolean>("on") ?: false
                if (on != desktop) {
                    desktop = on
                    webView.settings.userAgentString = userAgent(on)
                    webView.settings.loadWithOverviewMode = true
                    webView.reload()
                }
                result.success(null)
            }
            "setTextZoom" -> {
                webView.settings.textZoom = call.argument<Int>("percent") ?: 100
                result.success(null)
            }
            "hover" -> {
                hover(call.argument<Double>("x")!!.toFloat(), call.argument<Double>("y")!!.toFloat())
                result.success(null)
            }
            "tap" -> {
                tap(call.argument<Double>("x")!!.toFloat(), call.argument<Double>("y")!!.toFloat())
                result.success(null)
            }
            "scroll" -> {
                scroll(
                    call.argument<Double>("x")!!.toFloat(), call.argument<Double>("y")!!.toFloat(),
                    call.argument<Double>("dx")!!.toFloat(), call.argument<Double>("dy")!!.toFloat(),
                )
                result.success(null)
            }
            "focus" -> {
                webView.requestFocus()
                result.success(null)
            }
            "showKeyboard" -> {
                showKeyboard()
                result.success(null)
            }
            "hideKeyboard" -> {
                hideKeyboard()
                result.success(null)
            }
            "keyboardShown" -> result.success(keyboardShown())
            "media" -> {
                val action = call.argument<String>("action") ?: "toggle"
                val seconds = call.argument<Double>("seconds") ?: 0.0
                media(action, seconds) { result.success(it) }
            }
            "field" -> js("$control.field()") { raw ->
                result.success(unquote(raw))
            }
            "insertText" -> insertText(call.argument<String>("text") ?: "", call.argument<Boolean>("submit") ?: false) {
                result.success(it)
            }
            "blurField" -> {
                hideKeyboard()
                js("$control.blur()") { result.success(null) }
            }
            "exitFullscreen" -> {
                exitFullscreen()
                result.success(null)
            }
            "pause" -> {
                media("pause", 0.0) {}
                webView.onPause()
                result.success(null)
            }
            "resume" -> {
                webView.onResume()
                result.success(null)
            }
            "state" -> result.success(state())
            else -> result.notImplemented()
        }
    }

    private val control get() = "window['${bridgeName}c']"

    private fun js(code: String, done: (String?) -> Unit) {
        webView.evaluateJavascript("(function(){try{var c=$control;return c?(" +
            code.replace(control, "c") + "):null}catch(e){return null}})()") { done(it) }
    }

    private fun unquote(raw: String?): String? {
        if (raw == null || raw == "null") return null
        return try {
            org.json.JSONTokener(raw).nextValue() as? String
        } catch (e: Exception) {
            null
        }
    }

    private fun userAgent(desktop: Boolean): String {
        // No "; wv" and "Version/4.0": sites (YouTube, Google) serve their
        // normal pages instead of the embedded-browser ones.
        var ua = defaultUserAgent.replace("; wv)", ")").replace(Regex(" Version/[\\d.]+"), "")
        if (desktop) {
            ua = ua.replace(Regex("\\(Linux; Android[^)]*\\)"), "(X11; Linux x86_64)").replace(" Mobile Safari", " Safari")
        }
        return ua
    }

    // --- the remote's pointer: a mouse for the page -----------------------------------

    private fun hover(x: Float, y: Float) {
        val now = SystemClock.uptimeMillis()
        val action = if (hoverStarted) MotionEvent.ACTION_HOVER_MOVE else MotionEvent.ACTION_HOVER_ENTER
        hoverStarted = true
        val ev = mouseEvent(now, action, x, y)
        webView.dispatchGenericMotionEvent(ev)
        ev.recycle()
    }

    private fun mouseEvent(time: Long, action: Int, x: Float, y: Float, vScroll: Float = 0f, hScroll: Float = 0f): MotionEvent {
        val props = MotionEvent.PointerProperties().apply {
            id = 0
            toolType = MotionEvent.TOOL_TYPE_MOUSE
        }
        val coords = MotionEvent.PointerCoords().apply {
            this.x = x
            this.y = y
            pressure = 0f
            size = 1f
            if (vScroll != 0f) setAxisValue(MotionEvent.AXIS_VSCROLL, vScroll)
            if (hScroll != 0f) setAxisValue(MotionEvent.AXIS_HSCROLL, hScroll)
        }
        return MotionEvent.obtain(time, time, action, 1, arrayOf(props), arrayOf(coords), 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0)
    }

    /** A finger tap at (x, y) - what a page understands everywhere (also mobile sites). */
    private fun tap(x: Float, y: Float) {
        lastTapAt = SystemClock.uptimeMillis()
        val down = SystemClock.uptimeMillis()
        val ev = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0)
        ev.source = InputDevice.SOURCE_TOUCHSCREEN
        webView.dispatchTouchEvent(ev)
        ev.recycle()
        main.postDelayed({
            val up = MotionEvent.obtain(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y, 0)
            up.source = InputDevice.SOURCE_TOUCHSCREEN
            webView.dispatchTouchEvent(up)
            up.recycle()
        }, 40)
    }

    /** A mouse wheel at (x, y): scrolls whatever is under the pointer by (dx, dy) pixels. */
    private fun scroll(x: Float, y: Float, dx: Float, dy: Float) {
        val config = ViewConfiguration.get(webView.context)
        val vFactor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) config.scaledVerticalScrollFactor else 64f * webView.resources.displayMetrics.density
        val hFactor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) config.scaledHorizontalScrollFactor else vFactor
        // Wheel axes: positive vertical = up, positive horizontal = right.
        val ev = mouseEvent(SystemClock.uptimeMillis(), MotionEvent.ACTION_SCROLL, x, y, -dy / vFactor, dx / hFactor)
        webView.dispatchGenericMotionEvent(ev)
        ev.recycle()
    }

    // --- keyboard and text ---------------------------------------------------------

    private fun imm() = webView.context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager

    private fun showKeyboard() {
        webView.requestFocus()
        main.postDelayed({
            val shown = imm().showSoftInput(webView, 0)
            if (!shown) {
                main.postDelayed({
                    @Suppress("DEPRECATION")
                    imm().showSoftInput(webView, InputMethodManager.SHOW_FORCED)
                }, 150)
            }
        }, 80)
    }

    private fun hideKeyboard() {
        imm().hideSoftInputFromWindow(webView.windowToken, 0)
    }

    private fun keyboardShown(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return webView.rootWindowInsets?.isVisible(android.view.WindowInsets.Type.ime()) ?: false
        }
        return false
    }

    /**
     * Puts [text] into the focused field: by script where it can reach the
     * field, else as the keyboard would (InputConnection: select all, type).
     */
    private fun insertText(text: String, submit: Boolean, done: (Boolean) -> Unit) {
        webView.requestFocus()
        js("$control.setText(${JSONObject.quote(text)}, $submit)") { raw ->
            if (raw == "true") return@js done(true)
            main.postDelayed({
                val ic = webView.onCreateInputConnection(EditorInfo())
                if (ic == null) {
                    done(false)
                    return@postDelayed
                }
                ic.performContextMenuAction(android.R.id.selectAll)
                ic.commitText(text, 1)
                if (submit) {
                    val t = SystemClock.uptimeMillis()
                    webView.dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER, 0))
                    webView.dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER, 0))
                }
                done(true)
            }, 60)
        }
    }

    private fun media(action: String, seconds: Double, done: (Boolean) -> Unit) {
        js("$control.media('$action', $seconds)") { done(it == "true") }
    }

    // --- events to Dart ----------------------------------------------------------

    private fun state(): Map<String, Any?> = mapOf(
        "url" to (webView.url ?: ""),
        "title" to (webView.title ?: ""),
        "progress" to webView.progress,
        "canGoBack" to webView.canGoBack(),
        "canGoForward" to webView.canGoForward(),
        "blocked" to blockedCount.get(),
        "documentStart" to documentStart,
    )

    private fun sendPage(loading: Boolean? = null) {
        val m = HashMap(state())
        if (loading != null) m["loading"] = loading
        channel.invokeMethod("page", m)
    }

    private fun countBlocked() {
        blockedCount.incrementAndGet()
        main.post {
            if (blockedPosted) return@post
            blockedPosted = true
            main.postDelayed({
                blockedPosted = false
                channel.invokeMethod("blocked", blockedCount.get())
            }, 300)
        }
    }

    private fun newPage(url: String) {
        pageHost = AdblockEngine.hostOf(url)
        blockedCount.set(0)
        main.post {
            channel.invokeMethod("blocked", 0)
            if (editingKind.isNotEmpty()) {
                editingKind = ""
                editingFrame = null
                channel.invokeMethod("editing", "")
            }
            if (playingFrames.isNotEmpty()) {
                playingFrames.clear()
                mediaChanged()
            }
        }
    }

    private fun mediaChanged() {
        val playing = playingFrames.isNotEmpty()
        webView.keepScreenOn = playing
        channel.invokeMethod("media", playing)
    }

    // --- blocking ---------------------------------------------------------------

    private fun intercept(request: WebResourceRequest, pageHost: String): WebResourceResponse? {
        if (!BrowserPlugin.blockingFor(pageHost) || !AdblockEngine.loaded) return null
        val url = request.url.toString()
        if (!url.startsWith("http")) return null
        val headers = request.requestHeaders
        var accept: String? = null
        var range = false
        var origin: String? = null
        for ((k, v) in headers) {
            when (k.lowercase()) {
                "accept" -> accept = v
                "range" -> range = true
                "origin" -> origin = v
            }
        }
        val type = AdblockEngine.requestType(url, accept, range)
        if (!AdblockEngine.shouldBlock(url, pageHost, type)) return null
        countBlocked()
        return emptyResponse(type, origin)
    }

    fun interceptForServiceWorker(request: WebResourceRequest): WebResourceResponse? =
        try {
            intercept(request, pageHost)
        } catch (e: Exception) {
            null
        }

    private fun emptyResponse(type: Int, origin: String?): WebResourceResponse {
        val headers = HashMap<String, String>()
        if (origin != null) {
            headers["Access-Control-Allow-Origin"] = origin
            headers["Access-Control-Allow-Credentials"] = "true"
        } else {
            headers["Access-Control-Allow-Origin"] = "*"
        }
        headers["Cache-Control"] = "no-store"
        val (mime, body) = when (type) {
            AdblockEngine.IMAGE -> "image/gif" to TRANSPARENT_GIF
            AdblockEngine.SCRIPT -> "application/javascript" to ByteArray(0)
            AdblockEngine.STYLESHEET -> "text/css" to ByteArray(0)
            AdblockEngine.SUBDOCUMENT -> "text/html" to ByteArray(0)
            else -> "text/plain" to ByteArray(0)
        }
        return WebResourceResponse(mime, "utf-8", 200, "OK", headers, ByteArrayInputStream(body))
    }

    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            if (request.isForMainFrame) {
                // Never block the page itself; it is the new page for the rules.
                newPage(request.url.toString())
                return null
            }
            return try {
                intercept(request, pageHost)
            } catch (e: Exception) {
                Log.w(TAG, "intercept: $e")
                null
            }
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val scheme = request.url.scheme ?: return false
            // intent:, market:, mailto: ... can't be opened here.
            return scheme != "http" && scheme != "https" && scheme != "about" && scheme != "data" && scheme != "blob"
        }

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            pageHost = AdblockEngine.hostOf(url)
            if (!documentStart) view.evaluateJavascript(fallbackScript ?: "", null)
            sendPage(loading = true)
        }

        override fun onPageCommitVisible(view: WebView, url: String) {
            if (!documentStart) view.evaluateJavascript(fallbackScript ?: "", null)
        }

        override fun onPageFinished(view: WebView, url: String) {
            CookieManager.getInstance().flush()
            sendPage(loading = false)
        }

        override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
            sendPage()
        }
    }

    private inner class Chrome : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            channel.invokeMethod("progress", newProgress)
        }

        override fun onReceivedTitle(view: WebView, title: String?) {
            sendPage()
        }

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            showFullscreen(view, callback)
        }

        override fun onHideCustomView() {
            exitFullscreen()
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            // Camera / microphone: not on a TV box.
            request.deny()
        }

        override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) {
            callback.invoke(origin, false, false)
        }

        override fun onShowFileChooser(
            webView: WebView,
            filePathCallback: ValueCallback<Array<android.net.Uri>>,
            fileChooserParams: FileChooserParams,
        ): Boolean = false

        override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean = true
    }

    // --- HTML5 full screen ----------------------------------------------------------

    private fun showFullscreen(view: View, callback: WebChromeClient.CustomViewCallback) {
        val activity: Activity = BrowserPlugin.activity ?: run {
            callback.onCustomViewHidden()
            return
        }
        exitFullscreen()
        val holder = FullscreenHolder(activity)
        holder.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        (activity.window.decorView as ViewGroup).addView(
            holder,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        holder.requestFocus()
        fullscreenHolder = holder
        fullscreenCallback = callback
        channel.invokeMethod("fullscreen", true)
    }

    private fun exitFullscreen() {
        val holder = fullscreenHolder ?: return
        val callback = fullscreenCallback
        fullscreenHolder = null
        fullscreenCallback = null
        (holder.parent as? ViewGroup)?.removeView(holder)
        holder.removeAllViews()
        try {
            callback?.onCustomViewHidden()
        } catch (e: Exception) {
            // Already gone.
        }
        webView.requestFocus()
        channel.invokeMethod("fullscreen", false)
    }

    /** Full-screen video: over the whole app, with the remote's keys. */
    private inner class FullscreenHolder(context: Context) : FrameLayout(context) {
        init {
            setBackgroundColor(Color.BLACK)
            isFocusable = true
            isFocusableInTouchMode = true
            keepScreenOn = true
        }

        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            val down = event.action == KeyEvent.ACTION_DOWN
            when (event.keyCode) {
                KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_ESCAPE -> {
                    if (!down) main.post { exitFullscreen() }
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_SPACE,
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK -> {
                    if (down && event.repeatCount == 0) media("toggle", 0.0) {}
                    return true
                }
                KeyEvent.KEYCODE_MEDIA_PLAY -> {
                    if (down) media("play", 0.0) {}
                    return true
                }
                KeyEvent.KEYCODE_MEDIA_PAUSE, KeyEvent.KEYCODE_MEDIA_STOP -> {
                    if (down) media("pause", 0.0) {}
                    return true
                }
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> {
                    if (down) media("seek", -10.0) {}
                    return true
                }
                KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                    if (down) media("seek", 10.0) {}
                    return true
                }
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> return true
            }
            return super.dispatchKeyEvent(event)
        }
    }

    // --- the page's side ---------------------------------------------------------

    /** Called by the page's script (hs_page.js) - on a background thread. */
    private inner class Bridge {
        @JavascriptInterface
        fun config(href: String, top: Boolean): String {
            return try {
                if (!BrowserPlugin.blockingFor(pageHost)) return "{\"on\":false}"
                val host = AdblockEngine.hostOf(href)
                val yt = host == "youtube.com" || host.endsWith(".youtube.com") ||
                    host == "youtube-nocookie.com" || host.endsWith(".youtube-nocookie.com")
                "{\"on\":true,\"yt\":$yt," + AdblockEngine.pageConfig(host).substring(1)
            } catch (e: Exception) {
                Log.w(TAG, "config: $e")
                "{\"on\":false}"
            }
        }

        @JavascriptInterface
        fun generic(href: String, keys: String): String = try {
            AdblockEngine.genericCss(AdblockEngine.hostOf(href), keys.split(' '))
        } catch (e: Exception) {
            ""
        }

        @JavascriptInterface
        fun editing(frame: String, kind: String) {
            main.post {
                if (kind.isNotEmpty()) {
                    editingFrame = frame
                } else if (editingFrame != null && editingFrame != frame) {
                    return@post // another frame's field still has focus
                }
                if (kind == editingKind) return@post
                editingKind = kind
                if (kind.isEmpty()) editingFrame = null
                channel.invokeMethod("editing", kind)
                // Right after a tap from the remote: up with the keyboard.
                if (kind.isNotEmpty() && SystemClock.uptimeMillis() - lastTapAt < 2000) showKeyboard()
            }
        }

        @JavascriptInterface
        fun media(frame: String, playing: Boolean) {
            main.post {
                val changed = if (playing) playingFrames.add(frame) else playingFrames.remove(frame)
                if (changed) mediaChanged()
            }
        }
    }

    /** hs_scriptlets.js + hs_youtube.js + hs_page.js in one function, with the bridge's name. */
    private fun pageScript(context: Context): String {
        val script = assembled ?: synchronized(BrowserView::class.java) {
            assembled ?: run {
                fun read(name: String) = context.assets.open("browser/$name").bufferedReader().use { it.readText() }
                listOf("hs_scriptlets.js", "hs_youtube.js", "hs_page.js").joinToString("\n") { read(it) }.also { assembled = it }
            }
        }
        return "(function(){var HSN='$bridgeName';\n$script\n})();".also { fallbackScript = it }
    }

    companion object {
        private const val TAG = "BrowserView"

        /** The page opened last (for service-worker requests). */
        @Volatile
        var current: BrowserView? = null

        @Volatile
        private var assembled: String? = null

        private val TRANSPARENT_GIF = byteArrayOf(
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80.toByte(), 0x00, 0x00, 0x00, 0x00, 0x00,
            0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0x21, 0xf9.toByte(), 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2c,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b,
        )
    }
}
