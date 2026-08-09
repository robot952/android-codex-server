package top.asdb.agent

import android.app.Activity
import android.app.DownloadManager
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Bundle
import android.provider.Settings
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val exportExecutor = Executors.newSingleThreadExecutor()
    private val appUpdateExecutor = Executors.newSingleThreadExecutor()
    private val exportSessions = ConcurrentHashMap<String, ExportSession>()
    private val pendingAppUpdateOperations = ConcurrentHashMap.newKeySet<PendingAppUpdateOperation>()
    private var pendingExportResult: MethodChannel.Result? = null

    @Volatile
    private var exportDestroyed = false

    @Volatile
    private var appUpdateDestroyed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        DiagnosticLogBridge.initialize(applicationContext)
        super.onCreate(savedInstanceState)
    }

    /**
     * The foreground service keeps this process alive while SSH is connected.
     * Reusing the same engine keeps Dart-owned sockets alive if Android destroys
     * only the Activity, such as after root Back navigation or task removal.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(RETAINED_ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(RETAINED_ENGINE_ID, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LEGACY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readLegacyProfiles" -> runCatching { readLegacyProfiles() }
                        .onSuccess(result::success)
                        .onFailure {
                            result.error("legacy_profile_read_failed", "无法读取旧版服务器配置", null)
                        }

                    "clearLegacyProfiles" -> runCatching { clearLegacyProfiles() }
                        .onSuccess { result.success(null) }
                        .onFailure {
                            result.error("legacy_profile_clear_failed", "无法清理旧版服务器配置", null)
                        }

                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_EXPORT_CHANNEL)
            .setMethodCallHandler(::handleFileExportCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> runCatching { ConnectionForegroundService.start(this) }
                        .onSuccess { result.success(null) }
                        .onFailure {
                            result.error(
                                "background_service_start_failed",
                                it.message ?: "无法启动后台连接保护",
                                null,
                            )
                        }

                    "stop" -> runCatching { ConnectionForegroundService.stop(this) }
                        .onSuccess { result.success(null) }
                        .onFailure {
                            result.error(
                                "background_service_stop_failed",
                                it.message ?: "无法停止后台连接保护",
                                null,
                            )
                        }

                    "moveToBackground" -> runCatching { moveTaskToBack(true) }
                        .onSuccess(result::success)
                        .onFailure {
                            result.error(
                                "move_to_background_failed",
                                it.message ?: "无法将应用移到后台",
                                null,
                            )
                        }

                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enqueueDownload" -> enqueueUpdateDownload(call, result)
                    "queryDownload" -> queryUpdateDownload(call, result)
                    "installDownload" -> installUpdateDownload(call, result)
                    "removeDownload" -> removeUpdateDownload(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CREATE_EXPORT_FILE_REQUEST) return
        val result = pendingExportResult ?: return
        pendingExportResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        exportExecutor.execute {
            var openedOutput: OutputStream? = null
            runCatching {
                check(!exportDestroyed) { "保存操作已取消" }
                val output = contentResolver.openOutputStream(uri, "w")
                    ?: error("无法创建本地文件")
                openedOutput = output
                val token = UUID.randomUUID().toString()
                val response = mapOf("token" to token)
                exportSessions[token] = ExportSession(uri, output)
                openedOutput = null
                response
            }.onSuccess { response ->
                mainHandler.post {
                    if (exportDestroyed) result.success(null) else result.success(response)
                }
            }.onFailure { error ->
                runCatching { openedOutput?.close() }
                runCatching { contentResolver.delete(uri, null, null) }
                mainHandler.post {
                    if (exportDestroyed) {
                        result.success(null)
                    } else {
                        result.error(
                            "file_export_open_failed",
                            error.message ?: "无法创建本地文件",
                            null,
                        )
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        exportDestroyed = true
        appUpdateDestroyed = true
        val updateOperations = pendingAppUpdateOperations.toList()
        pendingAppUpdateOperations.clear()
        updateOperations.forEach(PendingAppUpdateOperation::cancelForActivityDestroy)
        runCatching { appUpdateExecutor.shutdownNow() }
        val pickerResult = pendingExportResult
        pendingExportResult = null
        runCatching { pickerResult?.success(null) }
        val cleanup = Runnable {
            val sessions = exportSessions.values.toList()
            exportSessions.clear()
            sessions.forEach(::discardExportSession)
        }
        runCatching { exportExecutor.execute(cleanup) }
            .onFailure { cleanup.run() }
        exportExecutor.shutdown()
        super.onDestroy()
    }

    private fun readLegacyProfiles(): String? = legacyPreferences().getString(LEGACY_KEY, null)

    private fun clearLegacyProfiles() {
        check(legacyPreferences().edit().remove(LEGACY_KEY).commit()) {
            "Legacy profile removal was not committed"
        }
    }

    private fun enqueueUpdateDownload(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")?.trim().orEmpty()
        val requestedFileName = call.argument<String>("fileName")?.trim().orEmpty()
        val fileName = uniqueUpdateFileName(
            safeExportFileName(requestedFileName),
        )
        if (!url.startsWith("https://") || requestedFileName.isBlank()) {
            result.error("app_update_invalid_request", "更新下载参数无效", null)
            return
        }
        runCatching {
            val manager = getSystemService(DownloadManager::class.java)
                ?: error("系统下载服务不可用")
            manager.enqueue(
                DownloadManager.Request(Uri.parse(url)).apply {
                    setTitle("Agent 更新")
                    setDescription("正在下载更新")
                    setMimeType(APK_MIME_TYPE)
                    setNotificationVisibility(
                        DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                    )
                    setVisibleInDownloadsUi(true)
                    setAllowedOverMetered(true)
                    setAllowedOverRoaming(false)
                    setDestinationInExternalFilesDir(
                        applicationContext,
                        Environment.DIRECTORY_DOWNLOADS,
                        fileName,
                    )
                },
            )
        }.onSuccess { result.success(it.toString()) }
            .onFailure { error ->
                result.error(
                    "app_update_download_failed",
                    error.message ?: "无法开始下载更新",
                    null,
                )
            }
    }

    private fun queryUpdateDownload(call: MethodCall, result: MethodChannel.Result) {
        val pending = PendingAppUpdateOperation(result)
        val id = call.argument<String>("downloadId")?.toLongOrNull()
        if (id == null) {
            pending.error("app_update_invalid_id", "下载任务编号无效")
            return
        }
        if (appUpdateDestroyed) {
            pending.cancelForActivityDestroy()
            return
        }
        pendingAppUpdateOperations.add(pending)
        runCatching {
            appUpdateExecutor.execute {
                val outcome = runCatching { readUpdateDownload(id) }
                val posted = mainHandler.post {
                    pendingAppUpdateOperations.remove(pending)
                    if (appUpdateDestroyed) {
                        pending.cancelForActivityDestroy()
                    } else {
                        outcome.onSuccess(pending::success)
                            .onFailure { error ->
                                pending.error(
                                    "app_update_query_failed",
                                    error.message ?: "无法查询下载进度",
                                )
                            }
                    }
                }
                if (!posted) {
                    pendingAppUpdateOperations.remove(pending)
                    pending.cancelForActivityDestroy()
                }
            }
        }.onFailure { error ->
            pendingAppUpdateOperations.remove(pending)
            if (appUpdateDestroyed) {
                pending.cancelForActivityDestroy()
            } else {
                pending.error(
                    "app_update_query_failed",
                    error.message ?: "无法查询下载进度",
                )
            }
        }
    }

    private fun readUpdateDownload(id: Long): Map<String, Any?>? {
        val manager = applicationContext.getSystemService(DownloadManager::class.java)
            ?: error("系统下载服务不可用")
        val cursor = manager.query(DownloadManager.Query().setFilterById(id)) ?: return null
        cursor.use {
            if (!it.moveToFirst()) return null
            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val reason = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
            val total = it.getLong(
                it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
            ).takeIf { value -> value > 0L }
            return mapOf(
                "status" to downloadStatus(status),
                "downloadedBytes" to it.getLong(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                ).coerceAtLeast(0L),
                "totalBytes" to total,
                "errorMessage" to if (status == DownloadManager.STATUS_FAILED) {
                    downloadFailureMessage(reason)
                } else {
                    null
                },
            )
        }
    }

    private fun installUpdateDownload(call: MethodCall, result: MethodChannel.Result) {
        val pending = PendingAppUpdateOperation(result)
        val id = call.argument<String>("downloadId")?.toLongOrNull()
        if (id == null) {
            pending.error("app_update_invalid_id", "下载任务编号无效")
            return
        }
        if (appUpdateDestroyed) {
            pending.cancelForActivityDestroy()
            return
        }
        pendingAppUpdateOperations.add(pending)
        runCatching {
            appUpdateExecutor.execute {
                val outcome = runCatching { validateDownloadedUpdate(id) }
                val posted = mainHandler.post {
                    pendingAppUpdateOperations.remove(pending)
                    if (appUpdateDestroyed) {
                        pending.cancelForActivityDestroy()
                        return@post
                    }
                    outcome.onSuccess { apkUri -> openUpdateInstaller(apkUri, pending) }
                        .onFailure { error ->
                            pending.error(
                                "app_update_install_failed",
                                error.message ?: "无法安装更新",
                            )
                        }
                }
                if (!posted) {
                    pendingAppUpdateOperations.remove(pending)
                    pending.cancelForActivityDestroy()
                }
            }
        }.onFailure { error ->
            pendingAppUpdateOperations.remove(pending)
            if (appUpdateDestroyed) {
                pending.cancelForActivityDestroy()
            } else {
                pending.error(
                    "app_update_install_failed",
                    error.message ?: "无法安装更新",
                )
            }
        }
    }

    private fun removeUpdateDownload(call: MethodCall, result: MethodChannel.Result) {
        val pending = PendingAppUpdateOperation(result)
        val id = call.argument<String>("downloadId")?.toLongOrNull()
        if (id == null) {
            pending.error("app_update_invalid_id", "下载任务编号无效")
            return
        }
        if (appUpdateDestroyed) {
            pending.cancelForActivityDestroy()
            return
        }
        pendingAppUpdateOperations.add(pending)
        runCatching {
            appUpdateExecutor.execute {
                val outcome = runCatching { removeUpdateDownloadById(id) }
                val posted = mainHandler.post {
                    pendingAppUpdateOperations.remove(pending)
                    if (appUpdateDestroyed) {
                        pending.cancelForActivityDestroy()
                    } else {
                        outcome.onSuccess { pending.success(null) }
                            .onFailure { error ->
                                pending.error(
                                    "app_update_remove_failed",
                                    error.message ?: "无法清理更新下载",
                                )
                            }
                    }
                }
                if (!posted) {
                    pendingAppUpdateOperations.remove(pending)
                    pending.cancelForActivityDestroy()
                }
            }
        }.onFailure { error ->
            pendingAppUpdateOperations.remove(pending)
            if (appUpdateDestroyed) {
                pending.cancelForActivityDestroy()
            } else {
                pending.error(
                    "app_update_remove_failed",
                    error.message ?: "无法清理更新下载",
                )
            }
        }
    }

    private fun removeUpdateDownloadById(id: Long) {
        val manager = applicationContext.getSystemService(DownloadManager::class.java)
            ?: error("系统下载服务不可用")
        // DownloadManager.remove is idempotent for a missing row and also removes
        // the APK stored in the app-specific external downloads directory.
        manager.remove(id)
    }

    private fun validateDownloadedUpdate(id: Long): Uri {
        val manager = applicationContext.getSystemService(DownloadManager::class.java)
            ?: error("系统下载服务不可用")
        val cursor = manager.query(DownloadManager.Query().setFilterById(id))
            ?: error("找不到下载任务")
        val apkFile = cursor.use {
            check(it.moveToFirst()) { "找不到下载任务" }
            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            check(status == DownloadManager.STATUS_SUCCESSFUL) { "安装包尚未准备完成" }
            val localUri = it.getString(
                it.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI),
            )?.let(Uri::parse) ?: error("无法读取安装包位置")
            check(localUri.scheme == "file") { "安装包位置无效" }
            File(localUri.path ?: error("安装包位置无效")).canonicalFile
        }
        val downloadDirectory = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?.canonicalFile ?: error("下载目录不可用")
        check(
            apkFile.parentFile == downloadDirectory && apkFile.isFile && apkFile.length() > 0L,
        ) { "安装包文件无效" }

        val archive = readArchivePackageInfo(apkFile) ?: error("无法解析安装包")
        val installed = readInstalledPackageInfo()
        check(archive.packageName == packageName) { "更新包的应用标识不匹配" }
        check(packageVersionCode(archive) > packageVersionCode(installed)) {
            "更新包版本必须高于当前版本"
        }
        val currentCertificates = signingCertificateDigests(installed)
        val updateCertificates = signingCertificateDigests(archive)
        check(
            currentCertificates.isNotEmpty() && currentCertificates == updateCertificates,
        ) { "更新包签名与当前应用不一致" }
        return manager.getUriForDownloadedFile(id) ?: error("安装包尚未准备完成")
    }

    private fun openUpdateInstaller(apkUri: Uri, pending: PendingAppUpdateOperation) {
        runCatching {
            if (!packageManager.canRequestPackageInstalls()) {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ),
                )
                mapOf("status" to "awaitingInstallPermission")
            } else {
                startActivity(Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(apkUri, APK_MIME_TYPE)
                    clipData = ClipData.newRawUri("Agent update", apkUri)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                })
                mapOf("status" to "installing")
            }
        }.onSuccess(pending::success)
            .onFailure { error ->
                pending.error(
                    "app_update_install_failed",
                    error.message ?: "无法安装更新",
                )
            }
    }

    @Suppress("DEPRECATION")
    private fun readInstalledPackageInfo(): PackageInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(
                    PackageManager.GET_SIGNING_CERTIFICATES.toLong(),
                ),
            )
        } else {
            packageManager.getPackageInfo(packageName, signingPackageInfoFlags())
        }

    @Suppress("DEPRECATION")
    private fun readArchivePackageInfo(apkFile: File): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageArchiveInfo(
                apkFile.path,
                PackageManager.PackageInfoFlags.of(
                    PackageManager.GET_SIGNING_CERTIFICATES.toLong(),
                ),
            )
        } else {
            packageManager.getPackageArchiveInfo(apkFile.path, signingPackageInfoFlags())
        }

    @Suppress("DEPRECATION")
    private fun signingPackageInfoFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    @Suppress("DEPRECATION")
    private fun signingCertificateDigests(info: PackageInfo): Set<String> {
        val signatures: Array<out Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners.orEmpty()
        } else {
            info.signatures.orEmpty()
        }
        return signatures.mapTo(linkedSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { byte ->
                    (byte.toInt() and 0xff).toString(16).padStart(2, '0')
                }
        }
    }

    @Suppress("DEPRECATION")
    private fun packageVersionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }

    private fun handleFileExportCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "beginExport" -> beginExport(call, result)
            "writeExportChunk" -> writeExportChunk(call, result)
            "finishExport" -> finishExport(call, result)
            else -> result.notImplemented()
        }
    }

    private fun beginExport(call: MethodCall, result: MethodChannel.Result) {
        if (pendingExportResult != null) {
            result.error("file_export_busy", "已有文件正在选择保存位置", null)
            return
        }
        val fileName = safeExportFileName(call.argument<String>("fileName").orEmpty())
        val mimeType = call.argument<String>("mimeType")
            ?.takeIf { it.length <= 128 && '/' in it }
            ?: "application/octet-stream"
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        pendingExportResult = result
        runCatching { startActivityForResult(intent, CREATE_EXPORT_FILE_REQUEST) }
            .onFailure { error ->
                pendingExportResult = null
                result.error(
                    "file_export_picker_failed",
                    error.message ?: "无法打开系统保存页面",
                    null,
                )
            }
    }

    private fun writeExportChunk(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token").orEmpty()
        val bytes = call.argument<ByteArray>("bytes")
        if (token.isEmpty() || bytes == null || bytes.size > MAX_EXPORT_CHUNK_BYTES) {
            result.error("file_export_invalid_chunk", "本地文件写入参数无效", null)
            return
        }
        val session = exportSessions[token]
        if (session == null) {
            result.error("file_export_closed", "本地文件已经关闭", null)
            return
        }
        exportExecutor.execute {
            runCatching { session.output.write(bytes) }
                .onSuccess { mainHandler.post { result.success(null) } }
                .onFailure { error ->
                    exportSessions.remove(token, session)
                    discardExportSession(session)
                    mainHandler.post {
                        result.error(
                            "file_export_write_failed",
                            error.message ?: "写入本地文件失败",
                            null,
                        )
                    }
                }
        }
    }

    private fun finishExport(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token").orEmpty()
        val successful = call.argument<Boolean>("successful") == true
        val session = exportSessions.remove(token)
        if (session == null) {
            result.error("file_export_closed", "本地文件已经关闭", null)
            return
        }
        exportExecutor.execute {
            runCatching {
                if (successful) session.output.flush()
                session.output.close()
                if (!successful) contentResolver.delete(session.uri, null, null)
            }.onSuccess {
                mainHandler.post { result.success(null) }
            }.onFailure { error ->
                discardExportSession(session)
                mainHandler.post {
                    result.error(
                        "file_export_finish_failed",
                        error.message ?: "关闭本地文件失败",
                        null,
                    )
                }
            }
        }
    }

    private fun discardExportSession(session: ExportSession) {
        runCatching { session.output.close() }
        runCatching { contentResolver.delete(session.uri, null, null) }
    }

    private fun safeExportFileName(value: String): String {
        val safe = value.trim().map { character ->
            if (character.code < 32 || character in "\\/:*?\"<>|") '_' else character
        }.joinToString("").take(MAX_EXPORT_FILE_NAME_CHARS)
        return safe.ifBlank { "download" }
    }

    private fun uniqueUpdateFileName(value: String): String {
        val base = value.removeSuffix(".apk").take(MAX_EXPORT_FILE_NAME_CHARS - 24)
        return "$base-${System.currentTimeMillis()}.apk"
    }

    private fun legacyPreferences() = run {
        val masterKey = MasterKey.Builder(this)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            this,
            LEGACY_PREFERENCES,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    private companion object {
        const val LEGACY_CHANNEL = "top.asdb.agent/legacy"
        const val FILE_EXPORT_CHANNEL = "top.asdb.agent/file_export"
        const val BACKGROUND_CHANNEL = "top.asdb.agent/background"
        const val RETAINED_ENGINE_ID = "agent_connection_engine"
        const val APP_UPDATE_CHANNEL = "top.asdb.agent/app_update"
        const val APP_UPDATE_ACTIVITY_DESTROYED = "app_update_activity_destroyed"
        const val LEGACY_PREFERENCES = "codex_remote_profiles"
        const val LEGACY_KEY = "profiles_v1"
        const val CREATE_EXPORT_FILE_REQUEST = 47_231
        const val MAX_EXPORT_CHUNK_BYTES = 256 * 1024
        const val MAX_EXPORT_FILE_NAME_CHARS = 160
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }

    private data class ExportSession(val uri: Uri, val output: OutputStream)

    private class PendingAppUpdateOperation(private val result: MethodChannel.Result) {
        private val completed = AtomicBoolean(false)

        fun success(value: Any?) {
            if (completed.compareAndSet(false, true)) {
                runCatching { result.success(value) }
            }
        }

        fun error(code: String, message: String) {
            if (completed.compareAndSet(false, true)) {
                runCatching { result.error(code, message, null) }
            }
        }

        fun cancelForActivityDestroy() {
            if (completed.compareAndSet(false, true)) {
                runCatching {
                    result.error(
                        APP_UPDATE_ACTIVITY_DESTROYED,
                        "Activity 已销毁，系统下载任务仍在继续",
                        null,
                    )
                }
            }
        }
    }

}

private fun downloadStatus(status: Int): String = when (status) {
    DownloadManager.STATUS_SUCCESSFUL -> "downloaded"
    DownloadManager.STATUS_FAILED -> "failed"
    else -> "downloading"
}

private fun downloadFailureMessage(reason: Int): String = when (reason) {
    DownloadManager.ERROR_INSUFFICIENT_SPACE -> "存储空间不足"
    DownloadManager.ERROR_DEVICE_NOT_FOUND -> "存储设备不可用"
    DownloadManager.ERROR_TOO_MANY_REDIRECTS -> "下载地址重定向过多"
    DownloadManager.ERROR_UNHANDLED_HTTP_CODE -> "下载服务器响应异常"
    else -> "下载失败（错误码 $reason）"
}
