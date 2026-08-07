package top.asdb.agent

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val exportExecutor = Executors.newSingleThreadExecutor()
    private val exportSessions = ConcurrentHashMap<String, ExportSession>()
    private var pendingExportResult: MethodChannel.Result? = null

    @Volatile
    private var exportDestroyed = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        const val LEGACY_PREFERENCES = "codex_remote_profiles"
        const val LEGACY_KEY = "profiles_v1"
        const val CREATE_EXPORT_FILE_REQUEST = 47_231
        const val MAX_EXPORT_CHUNK_BYTES = 256 * 1024
        const val MAX_EXPORT_FILE_NAME_CHARS = 160
    }

    private data class ExportSession(val uri: Uri, val output: OutputStream)
}
