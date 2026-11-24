package at.jaycloud.home.system

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Home System must not just disappear: an exception nobody caught - in our
 * code or in a plugin (e.g. video_player on a film the device can't decode) -
 * used to kill the whole app, and with it HomeButtonService. Android then
 * counts the service as crashed and doesn't start it again: the Home key is
 * gone until someone switches it on by hand.
 *
 * So:
 * - on the main thread, the message loop is run inside a try/catch - an
 *   exception ends that one message, not the app;
 * - on other threads, the thread ends, the app goes on.
 * Either way it is logged and shown in the app as an error message (Dart:
 * lib/core/native_errors.dart). Out of memory still ends the app - nothing
 * sensible can go on then.
 */
object CrashGuard {
    private const val TAG = "CrashGuard"

    @Volatile
    private var installed = false
    private val main = Handler(Looper.getMainLooper())

    /** Errors before Flutter listens - handed over once it does. */
    private val pending = ArrayDeque<String>()
    private var channel: MethodChannel? = null

    fun install() {
        if (installed) return
        installed = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            if (e is OutOfMemoryError || thread === Looper.getMainLooper().thread) {
                // The main thread only gets here if the loop below couldn't
                // catch it (or out of memory): as before.
                previous?.uncaughtException(thread, e)
                return@setDefaultUncaughtExceptionHandler
            }
            Log.e(TAG, "uncaught on ${thread.name}", e)
            report(e)
        }
        main.post {
            while (true) {
                try {
                    Looper.loop()
                } catch (e: Throwable) {
                    if (e is OutOfMemoryError) throw e
                    Log.e(TAG, "uncaught on the main thread", e)
                    report(e)
                }
            }
        }
    }

    private fun describe(e: Throwable): String {
        val root = generateSequence(e) { it.cause }.last()
        val text = root.message?.takeIf { it.isNotBlank() } ?: root.javaClass.simpleName
        return text.take(300)
    }

    private fun report(e: Throwable) {
        val text = describe(e)
        main.post {
            val c = channel
            if (c == null) {
                if (pending.size < 5) pending.addLast(text)
            } else {
                try {
                    c.invokeMethod("nativeError", text)
                } catch (_: Throwable) {
                }
            }
        }
    }

    /** The channel to Flutter (registered in MainActivity). */
    class Plugin : FlutterPlugin {
        override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
            val c = MethodChannel(binding.binaryMessenger, "home_system/errors")
            channel = c
            // Errors from before: handed over a moment later, once Dart listens.
            main.postDelayed({
                while (pending.isNotEmpty()) {
                    try {
                        c.invokeMethod("nativeError", pending.removeFirst())
                    } catch (_: Throwable) {
                    }
                }
            }, 3_000)
        }

        override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
            channel = null
        }
    }
}
