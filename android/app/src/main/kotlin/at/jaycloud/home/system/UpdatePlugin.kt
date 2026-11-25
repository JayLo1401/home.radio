package at.jaycloud.home.system

import android.app.ActivityManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.zip.ZipFile

/**
 * In-place app updates for Dart's UpdateService: the downloaded APK goes to
 * the system PackageInstaller, which shows its "Update?" confirmation (an
 * ordinary app can't update itself silently). The app must be allowed to
 * "install unknown apps" once - [canInstall]/openInstallPermission.
 */
class UpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "home_system/update")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
            "deviceInfo" -> Thread {
                try {
                    result.successOnMain(deviceInfo())
                } catch (e: Exception) {
                    Log.w(TAG, "deviceInfo failed", e)
                    result.errorOnMain("DEVICE_INFO", e.message)
                }
            }.start()
            "canInstall" -> result.success(canInstall())
            "openInstallPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${appContext.packageName}"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        appContext.startActivity(intent)
                    } catch (e: Exception) {
                        Log.w(TAG, "no unknown-sources settings page", e)
                    }
                }
                result.success(null)
            }
            "install" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("ARGS", "path missing", null)
                    return
                }
                Thread {
                    try {
                        install(File(path))
                        result.successOnMain(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "install failed", e)
                        result.errorOnMain("INSTALL", e.message)
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    /**
     * What decides which APK fits: Android version, the system's ABIs (a
     * 64-bit chip often runs a 32-bit system on TV boxes - then only
     * armeabi-v7a works), the ABIs inside the installed APK (several:
     * universal), chip and memory.
     */
    private fun deviceInfo(): Map<String, Any?> {
        val apkAbis = try {
            ZipFile(appContext.applicationInfo.sourceDir).use { zip ->
                zip.entries().asSequence()
                    .map { it.name }
                    .filter { it.startsWith("lib/") && it.endsWith(".so") }
                    .mapNotNull { it.split('/').getOrNull(1) }
                    .toSortedSet()
                    .toList()
            }
        } catch (e: Exception) {
            Log.w(TAG, "APK not readable", e)
            emptyList()
        }
        // "CPU architecture: 8" - an ARMv8 (64-bit) core, also under a
        // 32-bit system.
        val cpu64 = try {
            File("/proc/cpuinfo").readLines()
                .mapNotNull { Regex("""^CPU architecture\s*:\s*(\d+)""").find(it)?.groupValues?.get(1)?.toIntOrNull() }
                .any { it >= 8 }
        } catch (_: Exception) {
            false
        } || Build.SUPPORTED_64_BIT_ABIS.isNotEmpty()
        val chip = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(Build.SOC_MANUFACTURER, Build.SOC_MODEL)
                .filter { it.isNotBlank() && it != Build.UNKNOWN }
                .joinToString(" ")
                .ifBlank { Build.HARDWARE }
        } else {
            Build.HARDWARE
        }
        val ram = try {
            val memory = ActivityManager.MemoryInfo()
            (appContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
            memory.totalMem
        } catch (_: Exception) {
            null
        }
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "chip" to chip,
            "ram" to ram,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "abis64" to Build.SUPPORTED_64_BIT_ABIS.toList(),
            "apkAbis" to apkAbis,
            "cpu64" to cpu64,
        )
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || appContext.packageManager.canRequestPackageInstalls()

    private fun install(apk: File) {
        val installer = appContext.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(appContext.packageName)
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            session.openWrite("home_system.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            val pending = PendingIntent.getBroadcast(
                appContext,
                sessionId,
                Intent(appContext, UpdateInstallReceiver::class.java),
                flags,
            )
            session.commit(pending.intentSender)
        }
    }

    private fun MethodChannel.Result.successOnMain(value: Any?) =
        android.os.Handler(android.os.Looper.getMainLooper()).post { success(value) }

    private fun MethodChannel.Result.errorOnMain(code: String, message: String?) =
        android.os.Handler(android.os.Looper.getMainLooper()).post { error(code, message, null) }

    companion object {
        const val TAG = "UpdatePlugin"
    }
}

/**
 * PackageInstaller's answers: shows the system confirmation when it asks for
 * it; after the update (MY_PACKAGE_REPLACED) starts the app again - where
 * the system allows it.
 */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            // The update switched the Home key service off.
            HomeButtonService.ensureRunning(context)
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ?.let { runCatching { context.startActivity(it) } }
            return
        }
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(confirm)
            }
            PackageInstaller.STATUS_SUCCESS -> Unit
            else -> Log.w(
                UpdatePlugin.TAG,
                "install status $status: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}",
            )
        }
    }
}
