package com.green.music

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/** File IO remains attached to the engine while background audio outlives the activity. */
class MusicFilesPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var binding: ActivityPluginBinding? = null
    private var picker: MethodChannel.Result? = null
    private var notification: MethodChannel.Result? = null
    private val pickCode = 4701
    private val notificationCode = 4702

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.green.music/files")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = detach(false)
    override fun onDetachedFromActivity() = detach(true)
    private fun detach(cancel: Boolean) {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        if (cancel) {
            picker?.success(null); picker = null
            notification?.success(enabled()); notification = null
        }
    }
    private fun enabled(): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        return manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel("com.green.music.playback")?.importance != NotificationManager.IMPORTANCE_NONE)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "notificationsEnabled" -> result.success(enabled())
            "requestNotifications" -> {
                val activity = binding?.activity
                if (enabled()) { result.success(true); return }
                if (activity == null) { result.error("no_activity", "请回到应用后授权通知", null); return }
                val prefs = context.getSharedPreferences("music_permissions", Context.MODE_PRIVATE)
                if (Build.VERSION.SDK_INT >= 33 &&
                    activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                    (!prefs.getBoolean("asked", false) || activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))) {
                    if (notification != null) { result.error("busy", "正在申请通知权限", null); return }
                    notification = result
                    prefs.edit().putBoolean("asked", true).apply()
                    activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationCode)
                } else {
                    val channelBlocked = Build.VERSION.SDK_INT >= 26 && context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
                    val settings = if (channelBlocked)
                        Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            .putExtra(Settings.EXTRA_CHANNEL_ID, "com.green.music.playback")
                    else if (Build.VERSION.SDK_INT >= 26)
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                    if (call.argument<Boolean>("openSettings") != false) activity.startActivity(settings)
                    result.success(false)
                }
            }
            "chooseDirectory" -> {
                val activity = binding?.activity
                if (activity == null || picker != null) { result.error("busy", "请回到应用后选择文件夹", null); return }
                picker = result
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION), pickCode)
                } catch (_: Exception) { picker = null; result.error("picker_failed", "系统文件夹选择器不可用", null) }
            }
            "writeFile", "exists", "deleteFile" -> worker.execute {
                try {
                    val value: Any? = when (call.method) {
                        "writeFile" -> write(call)
                        "exists" -> {
                            val uri = checkedUri(call.argument<String>("uri")!!)
                            try { context.contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { it.moveToFirst() } ?: false }
                            catch (_: FileNotFoundException) { false }
                        }
                        else -> {
                            val uri = checkedUri(call.argument<String>("uri")!!)
                            if (!DocumentsContract.deleteDocument(context.contentResolver, uri)) throw IllegalStateException()
                            null
                        }
                    }
                    main.post { result.success(value) }
                } catch (_: SecurityException) {
                    main.post { result.error("storage_permission", "下载文件夹授权已失效，请在下载设置中重新选择", null) }
                } catch (_: Exception) {
                    main.post { result.error("storage_failed", "无法访问下载文件夹，请检查文件是否存在、目录授权及剩余空间", null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun checkedUri(raw: String): Uri {
        val uri = Uri.parse(raw)
        require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri))
        val tree = DocumentsContract.buildTreeDocumentUri(uri.authority!!, DocumentsContract.getTreeDocumentId(uri))
        if (context.contentResolver.persistedUriPermissions.none { it.uri == tree && it.isReadPermission && it.isWritePermission }) throw SecurityException()
        return uri
    }
    private fun write(call: MethodCall): String {
        val tree = checkedUri(call.argument<String>("tree")!!)
        val name = call.argument<String>("name")!!
        require(name.codePointCount(0, name.length) in 1..180 && name.none { it == '/' || it == '\\' || it.code < 32 })
        val mime = call.argument<String>("mime")!!
        require(mime in setOf("audio/mpeg", "audio/flac", "text/plain"))
        val source = File(call.argument<String>("path")!!).canonicalFile
        require(source.path.startsWith(context.dataDir.canonicalPath + File.separator) && source.isFile)
        require(source.parentFile?.name == "music_downloads" &&
            Regex("^[a-f0-9]{16}-[1-9]\\d*-(standard|exhigh|lossless)\\.(mp3|flac)(\\.lrc)?\\.part$").matches(source.name))
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val document = DocumentsContract.createDocument(context.contentResolver, parent, mime, "$name.greenmusic.part") ?: throw IllegalStateException()
        try {
            context.contentResolver.openOutputStream(document, "w")!!.use { output -> source.inputStream().use { it.copyTo(output, 65536) } }
            return (DocumentsContract.renameDocument(context.contentResolver, document, name) ?: throw IllegalStateException()).toString()
        } catch (e: Exception) {
            try { DocumentsContract.deleteDocument(context.contentResolver, document) } catch (_: Exception) { }
            throw e
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != pickCode) return false
        val result = picker ?: return true
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        val flags = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        worker.execute { try {
            require(flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0 && flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            context.contentResolver.takePersistableUriPermission(uri, flags)
            val document = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            val label = context.contentResolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: "所选文件夹"
            main.post { result.success(mapOf("uri" to uri.toString(), "label" to label)) }
        } catch (_: Exception) { main.post { result.error("permission_failed", "未能获得文件夹读写授权，请重新选择", null) } } }
        return true
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != notificationCode) return false
        notification?.success(enabled()); notification = null
        return true
    }
}
