package top.asdb.codexremote.diagnostics

import android.app.ActivityManager
import android.app.ApplicationExitInfo
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
import java.time.ZoneId
import java.time.format.DateTimeFormatter

data class DiagnosticLogSnapshot(
    val enabled: Boolean,
    val bytes: Long,
    val updatedAtMillis: Long?,
    val preview: String,
)

/** A single on-disk diagnostic log segment, newest first when returned by [DiagnosticLogger.listLogs]. */
data class DiagnosticLogEntry(
    val id: String,
    val fileName: String,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val sizeBytes: Long,
    val isActive: Boolean,
    val hasCrash: Boolean,
)

object DiagnosticLogger {
    private val lock = Any()
    private var appContext: Context? = null
    private var previousExceptionHandler: Thread.UncaughtExceptionHandler? = null
    private var activeSession: ActiveSession? = null
    private var lastSessionStartedAtMillis = 0L

    @Volatile
    private var enabled = false

    /**
     * Initializes one process-local logging session. When diagnostic logging was persisted as enabled,
     * every new app process starts with a fresh log file instead of resuming the prior file.
     */
    fun initialize(context: Context) {
        val shouldRecordProcessStart = synchronized(lock) {
            if (appContext != null) return
            appContext = context.applicationContext
            migrateLegacyLogsLocked()
            enabled = preferences().getBoolean(KEY_ENABLED, false)
            if (enabled) startNewSessionLocked()
            installCrashHandler()
            enabled
        }
        if (shouldRecordProcessStart) {
            info("App", "process_started version=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE})")
        }
        collectPreviousProcessExitsAsync()
    }

    fun isEnabled(): Boolean = enabled

    internal fun formatTimestamp(instant: Instant): String = LOG_TIMESTAMP_FORMATTER.format(instant)

    /**
     * Enabling diagnostic logging always begins a fresh session. Disabling leaves existing sessions
     * intact so they can still be attached or shared later.
     */
    fun setEnabled(value: Boolean) {
        checkNotNull(appContext) { "DiagnosticLogger is not initialized" }
        if (value) {
            val enabledNow = synchronized(lock) {
                if (enabled) return
                startNewSessionLocked()
                enabled = true
                preferences().edit().putBoolean(KEY_ENABLED, true).apply()
                true
            }
            if (enabledNow) info("Debug", "diagnostic_logging_enabled")
        } else {
            synchronized(lock) {
                if (!enabled) return
                // Keep the transition in the session that is being closed.
                append("INFO", "Debug", "diagnostic_logging_disabled", null)
                enabled = false
                activeSession = null
                preferences().edit().putBoolean(KEY_ENABLED, false).apply()
            }
        }
    }

    fun info(tag: String, message: String) = append("INFO", tag, message, null)

    fun warn(tag: String, message: String) = append("WARN", tag, message, null)

    fun error(tag: String, message: String, throwable: Throwable? = null) =
        append("ERROR", tag, message, throwable)

    /** Deletes every persisted session and diagnostic share export. */
    fun clear() {
        synchronized(lock) {
            logDirectory()?.listFiles()?.forEach { file ->
                if (parseSessionFileName(file.name) != null || file.name in LEGACY_LOG_FILE_NAMES) {
                    file.delete()
                }
            }
            exportDirectory()?.listFiles()?.forEach { it.delete() }
            activeSession = null
        }
    }

    /**
     * Returns retained sessions newest first. [DiagnosticLogEntry.id] is the only value callers need
     * to pass back to [readLog], [attachmentText], or [createShareIntent].
     */
    fun listLogs(): List<DiagnosticLogEntry> = synchronized(lock) {
        val activeFileName = activeLogFileNameLocked()
        sessionLogFilesLocked()
            .mapNotNull { entryForFileLocked(it, activeFileName) }
            .asReversed()
    }

    /** Whether this device still has any retained diagnostic logs, including logs from disabled sessions. */
    fun hasLogs(): Boolean = synchronized(lock) {
        sessionLogFilesLocked().isNotEmpty()
    }

    fun snapshot(maxPreviewChars: Int = 8_000): DiagnosticLogSnapshot = synchronized(lock) {
        val files = sessionLogFilesLocked()
        val bytes = files.sumOf(File::length)
        val updated = files.maxOfOrNull(File::lastModified)?.takeIf { it > 0L }
        val preview = readLogs(files).takeLast(maxPreviewChars)
        DiagnosticLogSnapshot(enabled, bytes, updated, preview)
    }

    /** Reads one retained log without exposing its private filesystem path. */
    fun readLog(id: String): String? = synchronized(lock) {
        resolveLogFileLocked(id)?.let(::readLogFile)
    }

    /**
     * Returns one selected log for an in-app text attachment, capped by UTF-8 byte size. The result
     * is null if the selected id is no longer retained.
     */
    fun attachmentText(id: String, maxBytes: Int): String? {
        require(maxBytes > 0) { "maxBytes must be positive" }
        return synchronized(lock) {
            resolveLogFileLocked(id)?.let { limitAttachmentText(readLogFile(it), maxBytes) }
        }
    }

    /**
     * Returns several selected logs as one attachment body, capped by UTF-8 byte size. This is useful
     * for clients that accept a single text attachment rather than one attachment per selected log.
     */
    fun attachmentText(ids: Collection<String>, maxBytes: Int): String {
        require(maxBytes > 0) { "maxBytes must be positive" }
        return synchronized(lock) {
            limitAttachmentText(readLogs(resolveLogFilesLocked(ids)), maxBytes)
        }
    }

    /**
     * Backward-compatible shortcut for the newest retained log. New UI should call the id overload
     * after the user has selected entries from [listLogs].
     */
    fun attachmentText(maxBytes: Int): String {
        require(maxBytes > 0) { "maxBytes must be positive" }
        return synchronized(lock) {
            val newest = sessionLogFilesLocked().lastOrNull() ?: return@synchronized ""
            limitAttachmentText(readLogFile(newest), maxBytes)
        }
    }

    /** Backward-compatible shortcut that shares the newest retained log. */
    fun createShareIntent(context: Context): Intent {
        val newestId = synchronized(lock) { sessionLogFilesLocked().lastOrNull()?.name }
        return createShareIntent(context, newestId?.let(::listOf).orEmpty())
    }

    /**
     * Builds a one- or multi-file share intent for selected retained logs. Creating or sharing an
     * export never deletes recorded sessions. Invalid or expired ids are ignored.
     */
    fun createShareIntent(context: Context, ids: Collection<String>): Intent {
        val uris = synchronized(lock) {
            val selected = resolveLogFilesLocked(ids)
            if (selected.isEmpty()) {
                listOf(createExportLocked(context, null))
            } else {
                selected.map { createExportLocked(context, it) }
            }
        }
        val title = if (uris.size == 1) "Codex diagnostic log" else "Codex diagnostic logs"
        return if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, "Codex Android ${BuildConfig.VERSION_NAME} diagnostic log")
                putExtra(Intent.EXTRA_STREAM, uris.single())
                clipData = ClipData.newRawUri(title, uris.single())
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } else {
            val clip = ClipData.newRawUri(title, uris.first())
            uris.drop(1).forEach { uri -> clip.addItem(ClipData.Item(uri)) }
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, "Codex Android ${BuildConfig.VERSION_NAME} diagnostic logs")
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
                clipData = clip
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
    }

    private fun createExportLocked(context: Context, logFile: File?): Uri {
        val directory = checkNotNull(exportDirectory()).apply { mkdirs() }
        val output = File.createTempFile("codex-diagnostic-", ".txt", directory)
        val entry = logFile?.let { entryForFileLocked(it, activeLogFileNameLocked()) }
        FileOutputStream(output).bufferedWriter(Charsets.UTF_8).use { writer ->
            writer.appendLine("Codex Android diagnostic log")
            writer.appendLine("Exported: ${formatTimestamp(Instant.now())}")
            writer.appendLine("App: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            writer.appendLine("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
            writer.appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL}")
            writer.appendLine("Logging enabled: $enabled")
            writer.appendLine("Sensitive values and user content are intentionally omitted/redacted.")
            if (entry == null) {
                writer.appendLine("No retained diagnostic log was selected.")
            } else {
                writer.appendLine("Log: ${entry.fileName}")
                writer.appendLine("Started: ${formatTimestamp(Instant.ofEpochMilli(entry.createdAtMillis))}")
                writer.appendLine("Size: ${entry.sizeBytes} bytes")
                writer.appendLine()
                writer.append(readLogFile(logFile))
            }
        }
        return FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", output)
    }

    private fun append(
        level: String,
        tag: String,
        message: String,
        throwable: Throwable?,
        force: Boolean = false,
    ) {
        if (!enabled && !force) return
        val safeTag = sanitizeDiagnosticText(tag).replace('\n', ' ').take(48)
        val safeMessage = sanitizeDiagnosticText(message).take(MAX_MESSAGE_CHARS)
        val stack = throwable?.let(::safeStackTrace).orEmpty()
        val entry = boundEntry(
            buildString {
                append(formatTimestamp(Instant.now())).append(' ')
                append(level).append(' ')
                append(safeTag.ifBlank { "App" }).append(' ')
                append(safeMessage.ifBlank { "(empty)" }).append('\n')
                if (stack.isNotBlank()) append(stack).append('\n')
            },
        )
        synchronized(lock) {
            if (!enabled && !force) return
            var file = currentLogLocked() ?: return
            file.parentFile?.mkdirs()
            if (file.length() + entry.toByteArray(Charsets.UTF_8).size > MAX_LOG_BYTES) {
                file = rotateWithinSessionLocked() ?: return
            }
            runCatching { file.appendText(entry, Charsets.UTF_8) }
                .onFailure { Log.e(LOGCAT_TAG, "Unable to write diagnostic log", it) }
        }
        Log.println(
            when (level) {
                "FATAL" -> Log.ASSERT
                "ERROR" -> Log.ERROR
                "WARN" -> Log.WARN
                else -> Log.INFO
            },
            LOGCAT_TAG,
            "$safeTag: $safeMessage",
        )
    }

    private fun currentLogLocked(): File? {
        val session = activeSession ?: startNewSessionLocked() ?: return null
        val directory = logDirectory() ?: return null
        return File(directory, sessionFileName(session.startedAtMillis, session.segment))
    }

    private fun activeLogFileNameLocked(): String? {
        val session = activeSession ?: return null
        return sessionFileName(session.startedAtMillis, session.segment)
    }

    private fun startNewSessionLocked(preferredStartedAtMillis: Long = Instant.now().toEpochMilli()): ActiveSession? {
        val directory = logDirectory() ?: return null
        if (!directory.exists() && !directory.mkdirs()) {
            Log.e(LOGCAT_TAG, "Unable to create diagnostic log directory")
            return null
        }
        val session = ActiveSession(allocateSessionStartMillisLocked(preferredStartedAtMillis), 0L)
        val file = File(directory, sessionFileName(session.startedAtMillis, session.segment))
        val created = runCatching {
            if (!file.exists()) file.createNewFile()
            file.isFile
        }.getOrElse {
            Log.e(LOGCAT_TAG, "Unable to create diagnostic log session", it)
            false
        }
        if (!created) return null
        activeSession = session
        pruneSessionsLocked()
        return session
    }

    private fun rotateWithinSessionLocked(): File? {
        val session = activeSession ?: return startNewSessionLocked()?.let { currentLogLocked() }
        session.segment += 1L
        val directory = logDirectory() ?: return null
        val file = File(directory, sessionFileName(session.startedAtMillis, session.segment))
        val created = runCatching {
            if (!file.exists()) file.createNewFile()
            file.isFile
        }.getOrElse {
            Log.e(LOGCAT_TAG, "Unable to rotate diagnostic log session", it)
            false
        }
        if (!created) return null
        pruneSessionsLocked()
        return file
    }

    private fun allocateSessionStartMillisLocked(preferredStartedAtMillis: Long): Long {
        val latestPersisted = sessionLogFilesLocked()
            .mapNotNull { parseSessionFileName(it.name)?.startedAtMillis }
            .maxOrNull()
            ?: 0L
        val candidate = maxOf(
            preferredStartedAtMillis.coerceAtLeast(1L),
            nextMillis(lastSessionStartedAtMillis),
            nextMillis(latestPersisted),
        )
        lastSessionStartedAtMillis = candidate
        return candidate
    }

    private fun migrateLegacyLogsLocked() {
        val directory = logDirectory() ?: return
        val legacyFiles = LEGACY_LOG_FILE_NAMES
            .map { File(directory, it) }
            .filter(File::isFile)
            .sortedWith(compareBy<File> { it.lastModified() }.thenBy { it.name })
        legacyFiles.forEach { legacy ->
            val text = runCatching { sanitizeDiagnosticText(legacy.readText(Charsets.UTF_8)) }
                .getOrElse {
                    Log.w(LOGCAT_TAG, "Unable to migrate legacy diagnostic log", it)
                    return@forEach
                }
            if (archiveLegacyTextLocked(text, legacy.lastModified())) legacy.delete()
        }
        pruneSessionsLocked()
    }

    private fun archiveLegacyTextLocked(text: String, modifiedAtMillis: Long): Boolean {
        if (text.isEmpty()) return true
        val startedAtMillis = allocateSessionStartMillisLocked(
            modifiedAtMillis.takeIf { it > 0L } ?: Instant.now().toEpochMilli(),
        )
        val directory = logDirectory() ?: return false
        val createdFiles = mutableListOf<File>()
        var remaining = text
        var segment = 0L
        while (remaining.isNotEmpty()) {
            val chunk = takeFirstUtf8Bytes(remaining, MAX_LOG_BYTES.toInt())
            if (chunk.isEmpty()) {
                createdFiles.forEach(File::delete)
                return false
            }
            val file = File(directory, sessionFileName(startedAtMillis, segment))
            val written = runCatching {
                FileOutputStream(file).bufferedWriter(Charsets.UTF_8).use { writer -> writer.write(chunk) }
            }.isSuccess
            if (!written) {
                createdFiles.forEach(File::delete)
                file.delete()
                return false
            }
            createdFiles += file
            remaining = remaining.substring(chunk.length)
            segment += 1L
        }
        return true
    }

    private fun pruneSessionsLocked() {
        val files = sessionLogFilesLocked()
        val overflow = files.size - MAX_SESSION_COUNT
        if (overflow > 0) files.take(overflow).forEach(File::delete)
    }

    private fun sessionLogFilesLocked(): List<File> {
        val directory = logDirectory() ?: return emptyList()
        return directory.listFiles()
            ?.filter { file -> file.isFile && parseSessionFileName(file.name) != null }
            ?.sortedBy(File::getName)
            .orEmpty()
    }

    private fun resolveLogFilesLocked(ids: Collection<String>): List<File> {
        if (ids.isEmpty()) return emptyList()
        val selectedIds = ids.toSet()
        return sessionLogFilesLocked().filter { it.name in selectedIds }
    }

    private fun resolveLogFileLocked(id: String): File? =
        if (parseSessionFileName(id) == null) {
            null
        } else {
            sessionLogFilesLocked().firstOrNull { it.name == id }
        }

    private fun entryForFileLocked(file: File, activeFileName: String?): DiagnosticLogEntry? {
        val parsed = parseSessionFileName(file.name) ?: return null
        val updatedAtMillis = file.lastModified().takeIf { it > 0L } ?: parsed.startedAtMillis
        return DiagnosticLogEntry(
            id = file.name,
            fileName = file.name,
            createdAtMillis = parsed.startedAtMillis,
            updatedAtMillis = updatedAtMillis,
            sizeBytes = file.length(),
            isActive = enabled && file.name == activeFileName,
            hasCrash = containsCrashRecord(readLogFile(file)),
        )
    }

    private fun readLogs(files: List<File>): String =
        files.joinToString(separator = "", transform = ::readLogFile)

    private fun readLogFile(file: File): String =
        runCatching { sanitizeDiagnosticText(file.readText(Charsets.UTF_8)) }.getOrDefault("")

    private fun limitAttachmentText(text: String, maxBytes: Int): String {
        if (text.toByteArray(Charsets.UTF_8).size <= maxBytes) return text
        val notice = "[诊断日志过大，仅附带最新记录]\n"
        val noticeBytes = notice.toByteArray(Charsets.UTF_8).size
        val availableBytes = (maxBytes - noticeBytes).coerceAtLeast(0)
        if (availableBytes == 0) return takeLastUtf8Bytes(notice, maxBytes)
        return notice + takeLastUtf8Bytes(text, availableBytes)
    }

    private fun boundEntry(entry: String): String {
        if (entry.toByteArray(Charsets.UTF_8).size <= MAX_LOG_BYTES) return entry
        val suffix = "\n[诊断日志单条记录过大，已截断]\n"
        val availableBytes = (MAX_LOG_BYTES - suffix.toByteArray(Charsets.UTF_8).size).toInt()
        return if (availableBytes <= 0) {
            takeFirstUtf8Bytes(suffix, MAX_LOG_BYTES.toInt())
        } else {
            takeFirstUtf8Bytes(entry, availableBytes) + suffix
        }
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
            append(
                level = "FATAL",
                tag = "Crash",
                message = "uncaught_exception thread=${thread.name} " +
                    "version=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE}) " +
                    "android=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT}",
                throwable = throwable,
                force = true,
            )
            previousExceptionHandler?.uncaughtException(thread, throwable) ?: run {
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }

    private fun collectPreviousProcessExitsAsync() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        Thread(
            {
                runCatching { collectPreviousProcessExits() }
                    .onFailure { Log.w(LOGCAT_TAG, "Unable to collect previous process exits", it) }
            },
            "diagnostic-exit-history",
        ).apply {
            isDaemon = true
            start()
        }
    }

    private fun collectPreviousProcessExits() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val context = appContext ?: return
        val activityManager = context.getSystemService(ActivityManager::class.java) ?: return
        val previousTimestamp = preferences().getLong(KEY_LAST_EXIT_TIMESTAMP, 0L)
        val exits = activityManager.getHistoricalProcessExitReasons(context.packageName, 0, 8)
            .filter { it.timestamp > previousTimestamp }
            .sortedBy(ApplicationExitInfo::getTimestamp)
        exits.filter { isCrashExitReason(it.reason) }.forEach { exit ->
            val trace = runCatching {
                exit.traceInputStream?.bufferedReader(Charsets.UTF_8)?.use { reader ->
                    val buffer = CharArray(MAX_STACK_CHARS)
                    val count = reader.read(buffer)
                    if (count > 0) String(buffer, 0, count) else ""
                }.orEmpty()
            }.getOrDefault("")
            append(
                level = "FATAL",
                tag = "Crash",
                message = "previous_process_exit reason=${processExitReasonName(exit.reason)} " +
                    "timestamp=${exit.timestamp} status=${exit.status} " +
                    "importance=${exit.importance} description=${exit.description.orEmpty()}",
                throwable = trace.takeIf(String::isNotBlank)?.let(::PreviousProcessExitException),
                force = true,
            )
        }
        exits.maxOfOrNull(ApplicationExitInfo::getTimestamp)?.let { newestTimestamp ->
            preferences().edit().putLong(KEY_LAST_EXIT_TIMESTAMP, newestTimestamp).apply()
        }
    }

    private fun preferences() = checkNotNull(appContext)
        .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private fun logDirectory(): File? = appContext?.let { File(it.filesDir, "diagnostics") }
    private fun exportDirectory(): File? = appContext?.let { File(it.cacheDir, "diagnostics") }

    private data class ActiveSession(
        val startedAtMillis: Long,
        var segment: Long,
    )

    private data class SessionFileName(
        val startedAtMillis: Long,
        val segment: Long,
    )

    private const val PREFERENCES_NAME = "diagnostic_settings"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_LAST_EXIT_TIMESTAMP = "last_exit_timestamp"
    private const val LOGCAT_TAG = "CodexRemote"
    private const val MAX_SESSION_COUNT = 100
    private const val MAX_LOG_BYTES = 100L * 1024L
    private const val MAX_MESSAGE_CHARS = 4_000
    private const val MAX_STACK_CHARS = 24_000
    private val LEGACY_LOG_FILE_NAMES = setOf("app.log", "app.previous.log")
    private val SESSION_FILE_NAME = Regex("session-(\\d+)-(\\d+)\\.txt")
    private val CHINA_STANDARD_TIME = ZoneId.of("Asia/Shanghai")
    private val LOG_TIMESTAMP_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS XXX")
        .withZone(CHINA_STANDARD_TIME)

    private fun sessionFileName(startedAtMillis: Long, segment: Long): String =
        "session-${startedAtMillis.toString().padStart(13, '0')}-${segment.toString().padStart(12, '0')}.txt"

    private fun parseSessionFileName(name: String): SessionFileName? {
        val match = SESSION_FILE_NAME.matchEntire(name) ?: return null
        return SessionFileName(
            startedAtMillis = match.groupValues[1].toLongOrNull() ?: return null,
            segment = match.groupValues[2].toLongOrNull() ?: return null,
        )
    }

    private fun nextMillis(value: Long): Long = if (value == Long.MAX_VALUE) Long.MAX_VALUE else value + 1L
}

private class PreviousProcessExitException(trace: String) : RuntimeException(trace) {
    override fun fillInStackTrace(): Throwable = this
}

internal fun isCrashExitReason(reason: Int): Boolean = reason == ApplicationExitInfo.REASON_CRASH ||
    reason == ApplicationExitInfo.REASON_CRASH_NATIVE || reason == ApplicationExitInfo.REASON_ANR

internal fun processExitReasonName(reason: Int): String = when (reason) {
    ApplicationExitInfo.REASON_CRASH -> "crash"
    ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
    ApplicationExitInfo.REASON_ANR -> "anr"
    else -> "other_$reason"
}

internal fun containsCrashRecord(value: String): Boolean =
    CRASH_RECORD_PATTERN.containsMatchIn(value)

private val CRASH_RECORD_PATTERN = Regex(
    "(?:ERROR|FATAL)\\s+Crash\\s+(?:uncaught_exception|previous_process_exit)\\b",
)

internal fun takeFirstUtf8Bytes(value: String, maxBytes: Int): String {
    if (maxBytes <= 0 || value.isEmpty()) return ""
    if (value.toByteArray(Charsets.UTF_8).size <= maxBytes) return value
    var end = 0
    var usedBytes = 0
    while (end < value.length) {
        val codePoint = value.codePointAt(end)
        val byteCount = when {
            codePoint <= 0x7f -> 1
            codePoint <= 0x7ff -> 2
            codePoint <= 0xffff -> 3
            else -> 4
        }
        if (usedBytes + byteCount > maxBytes) break
        usedBytes += byteCount
        end += Character.charCount(codePoint)
    }
    return value.substring(0, end)
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
