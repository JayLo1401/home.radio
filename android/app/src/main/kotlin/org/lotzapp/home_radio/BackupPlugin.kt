package org.lotzapp.home_radio

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/**
 * Backup files for Dart's BackupService, kept in the public
 * Download/HomeRadio folder so they survive uninstalling the app.
 *
 * Writing is easy on every Android version (MediaStore from Android 10 on,
 * plain file + WRITE_EXTERNAL_STORAGE before). Reading back is the tricky
 * part: from Android 11 on, a reinstalled app no longer "owns" the backups
 * its previous installation wrote, so MediaStore only lists backups made by
 * the current installation. To get at older ones the user either grants
 * "All files access" (then the folder is listed directly) or picks the file
 * via the system document picker - which many Android TV builds lack, hence
 * both ways are offered.
 */
class BackupPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: android.content.Context
    private var binding: ActivityPluginBinding? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingPick: MethodChannel.Result? = null
    private var pendingPermission: (() -> Unit)? = null
    private var pendingPermissionDenied: (() -> Unit)? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "home_radio/backup")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "save" -> {
                val name = call.argument<String>("name")!!
                val content = call.argument<String>("content")!!
                // Below Android 10 there's no MediaStore.Downloads - plain
                // file access needs the legacy storage permission.
                withPermission(
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) Manifest.permission.WRITE_EXTERNAL_STORAGE else null,
                    result,
                ) { inBackground(result) { save(name, content) } }
            }
            "list" -> withPermission(
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) Manifest.permission.READ_EXTERNAL_STORAGE else null,
                result,
            ) { inBackground(result) { list() } }
            "read" -> {
                val id = call.argument<String>("id")!!
                inBackground(result) { read(id) }
            }
            "pick" -> pick(result)
            "canRequestAllFilesAccess" -> result.success(
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager(),
            )
            "requestAllFilesAccess" -> result.success(requestAllFilesAccess())
            "restartApp" -> restartApp(result)
            else -> result.notImplemented()
        }
    }

    private fun backupDir(): File =
        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), FOLDER)

    private fun save(name: String, content: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = appContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "application/json")
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            try {
                resolver.openOutputStream(uri)!!.use { it.write(content.toByteArray(Charsets.UTF_8)) }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        } else {
            val dir = backupDir()
            dir.mkdirs()
            File(dir, name).writeText(content, Charsets.UTF_8)
        }
        return "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/$name"
    }

    /** Newest first, as {id, name, modified (epoch ms)}. */
    private fun list(): List<Map<String, Any>> {
        val directAccess = Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()
        val entries = if (directAccess) {
            (backupDir().listFiles() ?: emptyArray())
                .filter { it.isFile && it.name.endsWith(".json") }
                .map { mapOf("id" to it.absolutePath, "name" to it.name, "modified" to it.lastModified()) }
        } else {
            listViaMediaStore()
        }
        return entries.sortedByDescending { it["modified"] as Long }
    }

    private fun listViaMediaStore(): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return emptyList()
        val out = mutableListOf<Map<String, Any>>()
        val projection = arrayOf(
            MediaStore.Downloads._ID,
            MediaStore.Downloads.DISPLAY_NAME,
            MediaStore.Downloads.DATE_MODIFIED,
        )
        appContext.contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            "${MediaStore.Downloads.RELATIVE_PATH} = ?",
            arrayOf("${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/"),
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                if (!name.endsWith(".json")) continue
                val uri = Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, c.getLong(0).toString())
                out += mapOf("id" to uri.toString(), "name" to name, "modified" to c.getLong(2) * 1000)
            }
        }
        return out
    }

    private fun read(id: String): String =
        if (id.startsWith("content://")) {
            appContext.contentResolver.openInputStream(Uri.parse(id))!!.use { it.readBytes().toString(Charsets.UTF_8) }
        } else {
            File(id).readText(Charsets.UTF_8)
        }

    private fun pick(result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "No activity", null)
            return
        }
        if (pendingPick != null) {
            result.error("BUSY", "Picker already open", null)
            return
        }
        val candidates = listOf(
            Intent(Intent.ACTION_OPEN_DOCUMENT),
            Intent(Intent.ACTION_GET_CONTENT),
        ).map { it.addCategory(Intent.CATEGORY_OPENABLE).setType("*/*") }
        for (intent in candidates) {
            try {
                pendingPick = result
                activity.startActivityForResult(intent, REQUEST_PICK)
                return
            } catch (_: ActivityNotFoundException) {
                pendingPick = null
            }
        }
        result.error("NO_PICKER", "No document picker available", null)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        inBackground(result) { read(uri.toString()) }
        return true
    }

    private fun requestAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val activity = binding?.activity ?: return false
        val intents = listOf(
            Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${activity.packageName}")),
            Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
        )
        for (intent in intents) {
            try {
                activity.startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
            }
        }
        return false
    }

    /**
     * A restored database is only picked up by everything that read its
     * settings at startup (UI scale, tiles, autostart, ...) after a fresh
     * start, so the whole process is restarted.
     */
    private fun restartApp(result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "No activity", null)
            return
        }
        val pm = activity.packageManager
        val launch = pm.getLaunchIntentForPackage(activity.packageName)
            ?: pm.getLeanbackLaunchIntentForPackage(activity.packageName)
        if (launch?.component == null) {
            result.error("NO_LAUNCH_INTENT", "No launch intent", null)
            return
        }
        result.success(true)
        activity.startActivity(Intent.makeRestartActivityTask(launch.component))
        activity.finishAffinity()
        Runtime.getRuntime().exit(0)
    }

    private fun withPermission(permission: String?, result: MethodChannel.Result, then: () -> Unit) {
        val activity = binding?.activity
        if (permission == null ||
            appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        ) {
            then()
            return
        }
        if (activity == null) {
            result.error("NO_ACTIVITY", "No activity", null)
            return
        }
        pendingPermission = then
        pendingPermissionDenied = { result.error("PERMISSION_DENIED", "Storage permission denied", null) }
        activity.requestPermissions(arrayOf(permission), REQUEST_PERMISSION)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_PERMISSION) return false
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        val action = if (granted) pendingPermission else pendingPermissionDenied
        pendingPermission = null
        pendingPermissionDenied = null
        action?.invoke()
        return true
    }

    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        Thread({
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                Log.w(TAG, "Backup operation failed", e)
                mainHandler.post { result.error("IO", e.message, null) }
            }
        }, "BackupPlugin").start()
    }

    companion object {
        private const val TAG = "BackupPlugin"
        private const val FOLDER = "HomeRadio"
        private const val REQUEST_PICK = 47101
        private const val REQUEST_PERMISSION = 47102
    }
}
