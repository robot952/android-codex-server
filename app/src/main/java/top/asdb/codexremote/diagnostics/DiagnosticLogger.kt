package top.asdb.codexremote.diagnostics

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import top.asdb.codexremote.BuildConfig
import java.io.File
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

data class DiagnosticLogSnapshot(
    val enabled: Boolean,
    val bytes: Long,
    val updatedAtMillis: Long?,
    val preview: String,
)

object DiagnosticLogger {
    private val lock = Any()
    private var appContext: Context? = null
    private var previousExceptionHandler: Thread.UncaughtExceptionHandler? = null

    @Volatile
    private var enabled = false

    fun initialize(context: Context) {
        synchronized(lock) {
            if (appContext != null) return
            appContext = context.applicationContext
            enabled = preferences().getBoolean(KEY_ENABLED, false)
            installCrashHandler()
        }
        info("App", "process_started version=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE})")
    }

    fun isEnabled(): Boolean = enabled

    fun setEnabled(value: Boolean) {
        checkNotNull(appContext) { "DiagnosticLogger is not initialized" }
        if (value == enabled) return
        if (value) {
            enabled = true
            preferences().edit().putBoolean(KEY_ENABLED, true).apply()
            info("Debug", "diagnostic_logging_enabled")
        } else {
            info("Debug", "diagnostic_logging_disabled")
            enabled = false
            preferences().edit().putBoolean(KEY_ENABLED, false).apply()
        }
    }

    fun info(tag: String, message: String) = append("INFO", tag, message, null)

    fun warn(tag: String, message: String) = append("WARN", tag, message, null)

    fun error(tag: String, message: String, throwable: Throwable? = null) =
        append("ERROR", tag, message, throwable)

    fun clear() {
        synchronized(lock) {
            currentLog()?.delete()
            previousLog()?.delete()
            exportDirectory()?.listFiles()?.forEach { it.delete() }
        }
    }

    fun snapshot(maxPreviewChars: Int = 8_000): DiagnosticLogSnapshot = synchronized(lock) {
        val files = listOfNotNull(previousLog(), currentLog()).filter(File::isFile)
        val bytes = files.sumOf(File::length)
        val updated = files.maxOfOrNull(File::lastModified)?.takeIf { it > 0L }
        val preview = readLogs(files).takeLast(maxPreviewChars)
        DiagnosticLogSnapshot(enabled, bytes, updated, preview)
    }

    /** Returns the newest diagnostic records without ever exceeding a text-attachment byte limit. */
    fun attachmentText(maxBytes: Int): String {
        require(maxBytes > 0) { "maxBytes must be positive" }
        return synchronized(lock) {
            val logs = readLogs(listOfNotNull(previousLog(), currentLog()).filter(File::isFile))
            if (logs.toByteArray(Charsets.UTF_8).size <= maxBytes) return@synchronized logs
            val notice = "[诊断日志过大，仅附带最新记录]\n"
            val availableBytes = (maxBytes - notice.toByteArray(Charsets.UTF_8).size).coerceAtLeast(0)
            if (availableBytes == 0) return@synchronized takeLastUtf8Bytes(notice, maxBytes)
            notice + takeLastUtf8Bytes(logs, availableBytes)
        }
    }

    fun createShareIntent(context: Context): Intent {
        val uri = createExport(context)
        return Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "Codex Android ${BuildConfig.VERSION_NAME} 诊断日志")
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("Codex diagnostic log", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun createExport(context: Context): Uri = synchronized(lock) {
        val directory = checkNotNull(exportDirectory()).apply { mkdirs() }
        directory.listFiles()?.forEach { it.delete() }
        val timestamp = FILE_TIMESTAMP_FORMATTER.format(Instant.now())
        val output = File(directory, "codex-diagnostics-$timestamp.txt")
        FileOutputStream(output).bufferedWriter(Charsets.UTF_8).use { writer ->
            writer.appendLine("Codex Android diagnostic log")
            writer.appendLine("Exported: ${Instant.now()}")
            writer.appendLine("App: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            writer.appendLine("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
            writer.appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL}")
            writer.appendLine("Logging enabled: $enabled")
            writer.appendLine("Sensitive values and user content are intentionally omitted/redacted.")
            writer.appendLine()
            listOfNotNull(previousLog(), currentLog()).filter(File::isFile).forEach { file ->
                file.bufferedReader(Charsets.UTF_8).useLines { lines ->
                    lines.forEach { writer.appendLine(it) }
                }
            }
        }
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", output)
    }

    private fun readLogs(files: List<File>): String = files.joinToString(separator = "") { file ->
        runCatching { file.readText(Charsets.UTF_8) }.getOrDefault("")
    }

    private fun append(level: String, tag: String, message: String, throwable: Throwable?) {
        if (!enabled) return
        val safeTag = sanitizeDiagnosticText(tag).replace('\n', ' ').take(48)
        val safeMessage = sanitizeDiagnosticText(message).take(MAX_MESSAGE_CHARS)
        val stack = throwable?.let(::safeStackTrace).orEmpty()
        val entry = buildString {
            append(Instant.now()).append(' ')
            append(level).append(' ')
            append(safeTag.ifBlank { "App" }).append(' ')
            append(safeMessage.ifBlank { "(empty)" }).append('\n')
            if (stack.isNotBlank()) append(stack).append('\n')
        }
        synchronized(lock) {
            val file = currentLog() ?: return
            file.parentFile?.mkdirs()
            rotateIfNeeded(file, entry.toByteArray(Charsets.UTF_8).size)
            runCatching { file.appendText(entry, Charsets.UTF_8) }
                .onFailure { Log.e(LOGCAT_TAG, "Unable to write diagnostic log", it) }
        }
        Log.println(
            when (level) {
                "ERROR" -> Log.ERROR
                "WARN" -> Log.WARN
                else -> Log.INFO
            },
            LOGCAT_TAG,
            "$safeTag: $safeMessage",
        )
    }

    private fun rotateIfNeeded(current: File, incomingBytes: Int) {
        if (current.length() + incomingBytes <= MAX_LOG_BYTES) return
        val previous = previousLog() ?: return
        previous.delete()
        if (!current.renameTo(previous)) current.delete()
    }

    private fun safeStackTrace(throwable: Throwable): String {
        val writer = StringWriter()
        throwable.printStackTrace(PrintWriter(writer))
        return sanitizeDiagnosticText(writer.toString()).take(MAX_STACK_CHARS)
    }

    private fun installCrashHandler() {
        if (previousExceptionHandler != null) return
        previousExceptionHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            error("Crash", "uncaught_exception thread=${thread.name}", throwable)
            previousExceptionHandler?.uncaughtException(thread, throwable) ?: run {
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }

    private fun preferences() = checkNotNull(appContext)
        .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private fun logDirectory(): File? = appContext?.let { File(it.filesDir, "diagnostics") }
    private fun currentLog(): File? = logDirectory()?.let { File(it, "app.log") }
    private fun previousLog(): File? = logDirectory()?.let { File(it, "app.previous.log") }
    private fun exportDirectory(): File? = appContext?.let { File(it.cacheDir, "diagnostics") }

    private const val PREFERENCES_NAME = "diagnostic_settings"
    private const val KEY_ENABLED = "enabled"
    private const val LOGCAT_TAG = "CodexRemote"
    private const val MAX_LOG_BYTES = 2L * 1024L * 1024L
    private const val MAX_MESSAGE_CHARS = 4_000
    private const val MAX_STACK_CHARS = 24_000
    private val FILE_TIMESTAMP_FORMATTER = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss")
        .withZone(ZoneOffset.UTC)
}

internal fun takeLastUtf8Bytes(value: String, maxBytes: Int): String {
    if (maxBytes <= 0 || value.isEmpty()) return ""
    if (value.toByteArray(Charsets.UTF_8).size <= maxBytes) return value
    var start = value.length
    var usedBytes = 0
    while (start > 0) {
        val codePoint = value.codePointBefore(start)
        val byteCount = when {
            codePoint <= 0x7f -> 1
            codePoint <= 0x7ff -> 2
            codePoint <= 0xffff -> 3
            else -> 4
        }
        if (usedBytes + byteCount > maxBytes) break
        usedBytes += byteCount
        start -= Character.charCount(codePoint)
    }
    return value.substring(start)
}

internal fun sanitizeDiagnosticText(value: String): String {
    var result = ANSI_ESCAPE_REGEX.replace(value, "")
    result = PRIVATE_KEY_REGEX.replace(result, "[REDACTED_PRIVATE_KEY]")
    result = URL_CREDENTIAL_REGEX.replace(result) { match -> "${match.groupValues[1]}[REDACTED]@" }
    result = BEARER_REGEX.replace(result) { match -> "${match.groupValues[1]}[REDACTED]" }
    result = OPENAI_KEY_REGEX.replace(result, "[REDACTED_API_KEY]")
    result = NAMED_SECRET_REGEX.replace(result) { match ->
        "${match.groupValues[1]}${match.groupValues[2]}[REDACTED]"
    }
    return CONTROL_CHARACTER_REGEX.replace(result, "")
}

internal class DebugTapCounter(
    private val requiredTaps: Int = 10,
    private val maximumGapMillis: Long = 1_500L,
) {
    private var count = 0
    private var previousTapMillis = Long.MIN_VALUE

    fun registerTap(nowMillis: Long): Boolean {
        if (previousTapMillis == Long.MIN_VALUE || nowMillis - previousTapMillis > maximumGapMillis) {
            count = 0
        }
        previousTapMillis = nowMillis
        count += 1
        if (count < requiredTaps) return false
        count = 0
        previousTapMillis = Long.MIN_VALUE
        return true
    }
}

private val ANSI_ESCAPE_REGEX = Regex("\\u001B\\[[0-9;]*[A-Za-z]")
private val PRIVATE_KEY_REGEX = Regex(
    "-----BEGIN[^-]*PRIVATE KEY-----.*?-----END[^-]*PRIVATE KEY-----",
    setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
)
private val URL_CREDENTIAL_REGEX = Regex("(?i)([a-z][a-z0-9+.-]*://)[^/@\\s]+@")
private val BEARER_REGEX = Regex("(?i)(bearer\\s+)[a-z0-9._~+/=-]+")
private val OPENAI_KEY_REGEX = Regex("\\bsk-[a-zA-Z0-9_-]{16,}\\b")
private val NAMED_SECRET_REGEX = Regex(
    "(?i)\\b(password|passphrase|token|api[_-]?key|authorization|secret)" +
        "(\\s*[:=]\\s*)(?:\"[^\"]*\"|'[^']*'|[^\\s,;]+)",
)
private val CONTROL_CHARACTER_REGEX = Regex("[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\u007F]")
