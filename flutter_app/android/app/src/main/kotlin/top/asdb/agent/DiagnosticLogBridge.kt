package top.asdb.agent

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import java.io.File
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Best-effort Android-side diagnostics for failures that do not reach Dart.
 * The Flutter logger uses the same application-support `diagnostics` folder,
 * so native crash/ANR entries appear in the regular log picker on next launch.
 */
object DiagnosticLogBridge {
    private const val MAX_FILE_BYTES = 100 * 1024L
    private const val MAX_FILES = 100
    private const val MAX_TOTAL_BYTES = 10 * 1024 * 1024L
    private const val MAX_STACK_CHARS = 24_000
    private const val MAX_MESSAGE_CHARS = 4_000
    private const val ANR_THRESHOLD_MILLIS = 15_000L
    private const val HEARTBEAT_MILLIS = 1_000L
    private const val PROCESS_MARKER = ".agent-process-marker"
    private const val CLEAN_MARKER = ".agent-process-clean"
    private const val LAST_EXIT_MARKER = ".agent-last-exit"

    private val lock = Any()
    private val initialized = AtomicBoolean(false)
    private val lastHeartbeat = AtomicLong(System.currentTimeMillis())
    private val anrRecorded = AtomicBoolean(false)
    private var directory: File? = null
    private var currentFile: File? = null
    private var processToken = ""
    private var previousHandler: Thread.UncaughtExceptionHandler? = null
    private var ordinaryLoggingEnabled = false

    fun initialize(context: Context) {
        if (!initialized.compareAndSet(false, true)) return
        synchronized(lock) {
            directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
            recoverHistoricalProcessExitsLocked(context)
            recoverPreviousProcessLocked()
            processToken = UUID.randomUUID().toString()
            markerFileLocked(PROCESS_MARKER).writeText(
                "$processToken ${System.currentTimeMillis()} ${Process.myPid()}",
            )
            markerFileLocked(CLEAN_MARKER).delete()
            ordinaryLoggingEnabled = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            ).getBoolean("diagnostic_logging_enabled", false)
            if (ordinaryLoggingEnabled) {
                currentFile = newSessionFileLocked()
                appendLocked("INFO", "Android", "native_diagnostics_initialized")
            }
            previousHandler = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                append(
                    "FATAL",
                    "Crash",
                    "java_uncaught_exception thread=${thread.name}",
                    throwable,
                )
                previousHandler?.uncaughtException(thread, throwable)
            }
        }
        startAnrWatchdog()
        Runtime.getRuntime().addShutdownHook(
            Thread {
                synchronized(lock) {
                    if (processToken.isNotEmpty()) {
                        runCatching { markerFileLocked(CLEAN_MARKER).writeText(processToken) }
                    }
                }
            },
        )
    }

    private fun startAnrWatchdog() {
        val handler = Handler(Looper.getMainLooper())
        val heartbeat = object : Runnable {
            override fun run() {
                lastHeartbeat.set(System.currentTimeMillis())
                anrRecorded.set(false)
                handler.postDelayed(this, HEARTBEAT_MILLIS)
            }
        }
        handler.post(heartbeat)
        Thread {
            while (initialized.get()) {
                try {
                    Thread.sleep(HEARTBEAT_MILLIS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                val stalledFor = System.currentTimeMillis() - lastHeartbeat.get()
                if (stalledFor >= ANR_THRESHOLD_MILLIS && anrRecorded.compareAndSet(false, true)) {
                    append("FATAL", "Crash", "anr_main_thread_stalled durationMs=$stalledFor")
                }
            }
        }.apply {
            name = "agent-anr-watchdog"
            isDaemon = true
            start()
        }
    }

    private fun recoverPreviousProcessLocked() {
        val marker = markerFileLocked(PROCESS_MARKER)
        val token = marker.takeIf { it.isFile }?.readText()?.substringBefore(' ').orEmpty()
        val clean = markerFileLocked(CLEAN_MARKER).takeIf { it.isFile }?.readText()?.trim()
        if (token.isNotEmpty() && clean != token) {
            // Android normally kills app processes without running JVM shutdown hooks.
            // ApplicationExitInfo above is the authoritative crash/ANR source; this
            // marker only proves that the previous process did not shut down cleanly.
            appendLocked("WARN", "Process", "previous_process_exit_unclean token=$token")
        }
        markerFileLocked(CLEAN_MARKER).delete()
    }

    private fun recoverHistoricalProcessExitsLocked(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val checkpoint = markerFileLocked(LAST_EXIT_MARKER)
        val lastSeen = checkpoint.takeIf { it.isFile }?.readText()?.trim()?.toLongOrNull() ?: 0L
        val exits = runCatching {
            context.getSystemService(ActivityManager::class.java)
                ?.getHistoricalProcessExitReasons(context.packageName, 0, 20)
                .orEmpty()
        }.getOrDefault(emptyList())
        exits.asSequence()
            .filter { it.timestamp > lastSeen }
            .sortedBy { it.timestamp }
            .forEach { exit ->
                val reason = applicationExitReason(exit.reason)
                val crash = exit.reason == ApplicationExitInfo.REASON_CRASH ||
                    exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
                    exit.reason == ApplicationExitInfo.REASON_ANR
                if (crash) {
                    appendLocked(
                        "FATAL",
                        "Crash",
                        "previous_android_exit reason=$reason timestamp=${exit.timestamp} " +
                            "status=${exit.status} importance=${exit.importance} " +
                            "pssKb=${exit.pss} rssKb=${exit.rss} " +
                            "description=${exit.description.orEmpty()}",
                        stackText = readExitTrace(exit),
                    )
                } else {
                    appendLocked(
                        if (exit.reason == ApplicationExitInfo.REASON_EXIT_SELF) "INFO" else "WARN",
                        "Process",
                        "previous_android_exit reason=$reason timestamp=${exit.timestamp} " +
                            "status=${exit.status} importance=${exit.importance} " +
                            "pssKb=${exit.pss} rssKb=${exit.rss} " +
                            "description=${exit.description.orEmpty()}",
                    )
                }
            }
        exits.maxOfOrNull { it.timestamp }?.let { latest ->
            if (latest > lastSeen) runCatching { checkpoint.writeText(latest.toString()) }
        }
    }

    private fun applicationExitReason(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "exit_self"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_CRASH -> "java_crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
        ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
        ApplicationExitInfo.REASON_OTHER -> "other"
        ApplicationExitInfo.REASON_FREEZER -> "freezer"
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "package_state_change"
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "package_updated"
        else -> "unknown_$reason"
    }

    private fun readExitTrace(exit: ApplicationExitInfo): String? = runCatching {
        exit.traceInputStream?.bufferedReader(StandardCharsets.UTF_8)?.use { reader ->
            val output = StringBuilder()
            val buffer = CharArray(2_048)
            while (output.length < MAX_STACK_CHARS) {
                val count = reader.read(buffer, 0, minOf(buffer.size, MAX_STACK_CHARS - output.length))
                if (count < 0) break
                output.append(buffer, 0, count)
            }
            output.toString().takeIf { it.isNotBlank() }
        }
    }.getOrNull()

    fun append(level: String, tag: String, message: String, throwable: Throwable? = null) {
        synchronized(lock) { appendLocked(level, tag, message, throwable) }
    }

    private fun appendLocked(
        level: String,
        tag: String,
        message: String,
        throwable: Throwable? = null,
        stackText: String? = null,
    ) {
        val dir = directory ?: return
        dir.mkdirs()
        var file = currentFile ?: newSessionFileLocked().also { currentFile = it }
        val body = buildString {
            append(timestamp())
            append(' ')
            append(level)
            append(' ')
            append(sanitize(tag).replace(Regex("[\\r\\n]+"), " ").take(48).ifBlank { "Android" })
            append(' ')
            append(sanitize(message).trim().ifBlank { "(empty)" }.take(MAX_MESSAGE_CHARS))
            append('\n')
            if (throwable != null) {
                append(sanitize(throwable.toString()).take(MAX_MESSAGE_CHARS))
                append('\n')
                append(sanitize(throwable.stackTraceToString()).take(MAX_STACK_CHARS))
                append('\n')
            } else if (!stackText.isNullOrBlank()) {
                append(sanitize(stackText).take(MAX_STACK_CHARS))
                append('\n')
            }
        }.let(::sanitize)
        val bytes = body.toByteArray(StandardCharsets.UTF_8)
        if (file.length() + bytes.size > MAX_FILE_BYTES) {
            file = newSessionFileLocked()
            currentFile = file
        }
        runCatching { file.appendBytes(bytes) }
        pruneLocked(dir)
    }

    private fun newSessionFileLocked(): File {
        val dir = checkNotNull(directory)
        var started = System.currentTimeMillis()
        while (dir.listFiles()?.any { it.name.startsWith("session-${started.toString().padStart(13, '0')}-") } == true) {
            started++
        }
        return File(dir, "session-${started.toString().padStart(13, '0')}-000000.log")
            .apply { parentFile?.mkdirs(); createNewFile() }
    }

    private fun pruneLocked(dir: File) {
        val files = dir.listFiles()
            ?.filter { it.isFile && it.name.matches(Regex("^session-\\d+-\\d+\\.log$")) }
            ?.sortedBy { it.name }
            ?: return
        var total = files.sumOf { it.length() }
        var count = files.size
        for (file in files) {
            if (count <= MAX_FILES && total <= MAX_TOTAL_BYTES) break
            val size = file.length()
            if (runCatching { file.delete() }.getOrDefault(false)) {
                count--
                total -= size
            }
        }
    }

    private fun markerFileLocked(name: String): File = File(checkNotNull(directory), name)

    private fun timestamp(): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)
        .format(Date())

    private fun sanitize(value: String): String {
        var result = value.replace(Regex("\\u001B\\[[0-9;]*[A-Za-z]"), "")
        result = result.replace(
            Regex(
                "-----BEGIN[^-]*PRIVATE KEY-----.*?-----END[^-]*PRIVATE KEY-----",
                setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
            ),
            "[REDACTED_PRIVATE_KEY]",
        )
        result = result.replace(Regex("([a-z][a-z0-9+.-]*://)[^/@\\s]+@", RegexOption.IGNORE_CASE), "$1[REDACTED]@")
        result = result.replace(Regex("(bearer\\s+)[a-z0-9._~+/=-]+", RegexOption.IGNORE_CASE), "$1[REDACTED]")
        result = result.replace(Regex("\\bsk-[a-zA-Z0-9_-]{16,}\\b"), "[REDACTED_API_KEY]")
        result = result.replace(
            Regex("\\b(password|passphrase|token|api[_-]?key|authorization|secret)(\\s*[:=]\\s*)(?:\"[^\"]*\"|'[^']*'|[^\\s,;]+)", RegexOption.IGNORE_CASE),
            "$1$2[REDACTED]",
        )
        return result.replace(Regex("[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\u007F]"), "")
    }
}
