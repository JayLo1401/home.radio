package at.jaycloud.home.system

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The bits the permissions overview (Dart's PermissionsService) needs that
 * the feature plugins don't have: any runtime permission's state, asking for
 * one (the legacy storage permission below Android 11), whether Android
 * would still show its dialog, and the app's own system info page - where a
 * permission that Android no longer asks for can be allowed by hand.
 * Camera, "Audio aufnehmen", installing and all-files access are asked for
 * by DisplayPlugin, MusicVisualizerPlugin, UpdatePlugin and BackupPlugin.
 */
class PermissionsPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var binding: ActivityPluginBinding? = null
    private val activity: Activity? get() = binding?.activity
    private var pending: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "home_system/permissions")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "hasUsbHost" -> result.success(appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST))
            "check" -> result.success(granted(call.argument<String>("permission")!!))
            "shouldShowRationale" -> {
                val a = activity
                result.success(a != null && a.shouldShowRequestPermissionRationale(call.argument<String>("permission")!!))
            }
            "request" -> request(call.argument<String>("permission")!!, result)
            "openAppSettings" -> result.success(openAppSettings())
            else -> result.notImplemented()
        }
    }

    private fun granted(permission: String) =
        appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun request(permission: String, result: MethodChannel.Result) {
        val a = activity ?: return result.success(false)
        if (granted(permission)) return result.success(true)
        pending?.success(false)
        pending = result
        a.requestPermissions(arrayOf(permission), REQUEST_PERMISSION)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_PERMISSION) return false
        pending?.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        pending = null
        return true
    }

    private fun openAppSettings(): Boolean {
        val context: Context = activity ?: appContext
        val intents = listOf(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${appContext.packageName}")),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (intent in intents) {
            if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(intent)
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    companion object {
        private const val REQUEST_PERMISSION = 47131
    }
}
