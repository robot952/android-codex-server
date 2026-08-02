package top.asdb.codexremote.update

import android.app.DownloadManager
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.Settings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import top.asdb.codexremote.BuildConfig
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import kotlin.coroutines.coroutineContext

data class AppUpdateReleaseNote(
    val versionName: String,
    val gitCommit: String,
    val message: String,
)

data class AppUpdateInfo(
    val versionName: String,
    val changes: List<AppUpdateReleaseNote>,
)

enum class AppUpdateDownloadStatus {
    Idle,
    Downloading,
    Downloaded,
    AwaitingInstallPermission,
    Installing,
    Failed,
}

data class AppUpdateDownloadState(
    val versionName: String? = null,
    val downloadId: Long? = null,
    val downloadedBytes: Long = 0L,
    val totalBytes: Long? = null,
    val status: AppUpdateDownloadStatus = AppUpdateDownloadStatus.Idle,
    val errorMessage: String? = null,
)

data class AppUpdateState(
    val checking: Boolean = false,
    val availableUpdate: AppUpdateInfo? = null,
    val shouldPromptUpdate: Boolean = false,
    val download: AppUpdateDownloadState = AppUpdateDownloadState(),
)

/** Fetches stable Gitee Releases and downloads an APK through Android's system download service. */
object AppUpdateManager {
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private val _state = MutableStateFlow(AppUpdateState())

    private lateinit var preferences: android.content.SharedPreferences
    private var checkJob: Job? = null
    private var downloadJob: Job? = null
    private var initialized = false

    val state: StateFlow<AppUpdateState> = _state.asStateFlow()

    fun initialize(context: Context) {
        val shouldCheck = synchronized(lock) {
            if (initialized) {
                false
            } else {
                preferences = context.applicationContext.getSharedPreferences(
                    PREFERENCES_NAME,
                    Context.MODE_PRIVATE,
                )
                initialized = true
                true
            }
        }
        if (shouldCheck) checkForUpdates()
    }

    fun checkForUpdates() {
        synchronized(lock) {
            checkJob?.takeIf(Job::isActive)?.let { return }
            if (!initialized) return
            checkJob = scope.launch {
                _state.update { it.copy(checking = true) }
                runCatching(::fetchUpdateInfo)
                    .onSuccess { update ->
                        val ignoredVersion = preferences.getString(KEY_IGNORED_VERSION_NAME, null)
                        val available = availableUpdateFor(update, BuildConfig.VERSION_NAME)
                        _state.update {
                            it.copy(
                                checking = false,
                                availableUpdate = available,
                                shouldPromptUpdate = shouldPromptUpdate(available, ignoredVersion),
                                download = it.download.takeIf { download ->
                                    download.versionName == available?.versionName
                                } ?: AppUpdateDownloadState(),
                            )
                        }
                        if (available != null) {
                            DiagnosticLogger.info(
                                "Update",
                                "available version=${available.versionName}",
                            )
                        }
                    }
                    .onFailure { error ->
                        _state.update { it.copy(checking = false) }
                        DiagnosticLogger.warn("Update", "check_failed reason=${error.message.orEmpty().take(160)}")
                    }
            }
        }
    }

    fun ignoreVersion(versionName: String) {
        if (versionName.isBlank() || !initialized) return
        preferences.edit().putString(KEY_IGNORED_VERSION_NAME, versionName).apply()
        _state.update { current ->
            if (current.availableUpdate?.versionName == versionName) {
                current.copy(shouldPromptUpdate = false)
            } else {
                current
            }
        }
        DiagnosticLogger.info("Update", "ignored version=$versionName")
    }

    fun startDownload(context: Context, update: AppUpdateInfo): Boolean {
        if (!initialized) return false
        val current = _state.value.download
        if (
            current.status == AppUpdateDownloadStatus.Downloading &&
            current.versionName == update.versionName
        ) {
            return true
        }

        val appContext = context.applicationContext
        return runCatching {
            val downloadManager = appContext.getSystemService(DownloadManager::class.java)
                ?: error("系统下载服务不可用")
            val downloadId = downloadManager.enqueue(
                DownloadManager.Request(Uri.parse(apkDownloadUrl(update))).apply {
                    setTitle("Codex v${update.versionName}")
                    setDescription("正在下载更新")
                    setMimeType(APK_MIME_TYPE)
                    setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    setVisibleInDownloadsUi(true)
                    setAllowedOverMetered(true)
                    setAllowedOverRoaming(false)
                    setDestinationInExternalFilesDir(
                        appContext,
                        Environment.DIRECTORY_DOWNLOADS,
                        "CodexRemote-${update.versionName}-${System.currentTimeMillis()}.apk",
                    )
                },
            )
            _state.update {
                it.copy(
                    download = AppUpdateDownloadState(
                        versionName = update.versionName,
                        downloadId = downloadId,
                        status = AppUpdateDownloadStatus.Downloading,
                    ),
                )
            }
            synchronized(lock) {
                downloadJob?.cancel()
                downloadJob = scope.launch {
                    monitorDownload(downloadManager, downloadId, update.versionName)
                }
            }
            DiagnosticLogger.info("Update", "download_started version=${update.versionName}")
            true
        }.getOrElse { error ->
            _state.update {
                it.copy(
                    download = AppUpdateDownloadState(
                        versionName = update.versionName,
                        status = AppUpdateDownloadStatus.Failed,
                        errorMessage = updateErrorMessage(error),
                    ),
                )
            }
            DiagnosticLogger.warn("Update", "download_start_failed reason=${error.message.orEmpty().take(160)}")
            false
        }
    }

    fun installDownloadedUpdate(context: Context): Boolean {
        val download = _state.value.download
        val downloadId = download.downloadId ?: return false
        if (download.status !in setOf(
                AppUpdateDownloadStatus.Downloaded,
                AppUpdateDownloadStatus.AwaitingInstallPermission,
            )
        ) {
            return false
        }

        val appContext = context.applicationContext
        return runCatching {
            val downloadManager = appContext.getSystemService(DownloadManager::class.java)
                ?: error("系统下载服务不可用")
            val apkUri = downloadManager.getUriForDownloadedFile(downloadId)
                ?: error("安装包尚未准备完成")
            if (!appContext.packageManager.canRequestPackageInstalls()) {
                updateDownload(downloadId) {
                    it.copy(status = AppUpdateDownloadStatus.AwaitingInstallPermission)
                }
                appContext.startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${appContext.packageName}"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } else {
                val installIntent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(apkUri, APK_MIME_TYPE)
                    clipData = ClipData.newRawUri("Codex update", apkUri)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                appContext.startActivity(installIntent)
                updateDownload(downloadId) {
                    it.copy(status = AppUpdateDownloadStatus.Installing, errorMessage = null)
                }
                DiagnosticLogger.info("Update", "install_requested version=${download.versionName.orEmpty()}")
            }
            true
        }.getOrElse { error ->
            updateDownload(downloadId) {
                it.copy(
                    status = AppUpdateDownloadStatus.Failed,
                    errorMessage = updateErrorMessage(error),
                )
            }
            DiagnosticLogger.warn("Update", "install_failed reason=${error.message.orEmpty().take(160)}")
            false
        }
    }

    private suspend fun monitorDownload(
        downloadManager: DownloadManager,
        downloadId: Long,
        versionName: String,
    ) {
        while (coroutineContext.isActive) {
            val snapshot = readDownloadSnapshot(downloadManager, downloadId)
            if (snapshot == null) {
                updateDownload(downloadId) {
                    it.copy(
                        status = AppUpdateDownloadStatus.Failed,
                        errorMessage = "找不到下载任务",
                    )
                }
                return
            }
            when (snapshot.status) {
                DownloadManager.STATUS_SUCCESSFUL -> {
                    updateDownload(downloadId) {
                        it.copy(
                            downloadedBytes = snapshot.downloadedBytes,
                            totalBytes = snapshot.totalBytes ?: snapshot.downloadedBytes,
                            status = AppUpdateDownloadStatus.Downloaded,
                            errorMessage = null,
                        )
                    }
                    DiagnosticLogger.info("Update", "download_completed version=$versionName")
                    return
                }

                DownloadManager.STATUS_FAILED -> {
                    updateDownload(downloadId) {
                        it.copy(
                            downloadedBytes = snapshot.downloadedBytes,
                            totalBytes = snapshot.totalBytes,
                            status = AppUpdateDownloadStatus.Failed,
                            errorMessage = downloadFailureMessage(snapshot.reason),
                        )
                    }
                    DiagnosticLogger.warn("Update", "download_failed version=$versionName reason=${snapshot.reason}")
                    return
                }

                else -> updateDownload(downloadId) {
                    it.copy(
                        downloadedBytes = snapshot.downloadedBytes,
                        totalBytes = snapshot.totalBytes,
                        status = AppUpdateDownloadStatus.Downloading,
                        errorMessage = null,
                    )
                }
            }
            delay(DOWNLOAD_PROGRESS_POLL_MILLIS)
        }
    }

    private fun readDownloadSnapshot(
        downloadManager: DownloadManager,
        downloadId: Long,
    ): DownloadSnapshot? {
        val cursor = downloadManager.query(DownloadManager.Query().setFilterById(downloadId)) ?: return null
        cursor.use {
            if (!it.moveToFirst()) return null
            val totalBytes = it.getLong(
                it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
            ).takeIf { value -> value > 0L }
            return DownloadSnapshot(
                status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),
                reason = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                downloadedBytes = it.getLong(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                ).coerceAtLeast(0L),
                totalBytes = totalBytes,
            )
        }
    }

    private fun updateDownload(
        downloadId: Long,
        transform: (AppUpdateDownloadState) -> AppUpdateDownloadState,
    ) {
        _state.update { current ->
            if (current.download.downloadId != downloadId) {
                current
            } else {
                current.copy(download = transform(current.download))
            }
        }
    }

    private fun fetchUpdateInfo(): AppUpdateInfo? {
        val connection = (URL(GITEE_RELEASES_URL).openConnection() as? HttpURLConnection)
            ?: throw IllegalStateException("更新服务器连接不可用")
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = NETWORK_TIMEOUT_MILLIS
            connection.readTimeout = NETWORK_TIMEOUT_MILLIS
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("Accept", "application/json")
            connection.connect()
            check(connection.responseCode == HttpURLConnection.HTTP_OK) {
                "更新服务器返回 HTTP ${connection.responseCode}"
            }
            val length = connection.contentLengthLong
            check(length < 0L || length <= MAX_RELEASE_RESPONSE_BYTES) { "更新信息过大" }
            val body = connection.inputStream.use { input ->
                input.readUtf8AtMost(MAX_RELEASE_RESPONSE_BYTES.toInt())
            }
            return parseGiteeReleases(body, json)
        } finally {
            connection.disconnect()
        }
    }

    private const val PREFERENCES_NAME = "app_update_settings"
    private const val KEY_IGNORED_VERSION_NAME = "ignored_version_name"
    private const val NETWORK_TIMEOUT_MILLIS = 5_000
    private const val MAX_RELEASE_RESPONSE_BYTES = 256L * 1024L
    private const val DOWNLOAD_PROGRESS_POLL_MILLIS = 350L
    private const val APK_MIME_TYPE = "application/vnd.android.package-archive"

    private const val GITEE_REPOSITORY_URL = "https://gitee.com/YanGanYuan/android-codex-server"
    private const val GITEE_RELEASES_URL =
        "https://gitee.com/api/v5/repos/YanGanYuan/android-codex-server/releases?page=1&per_page=30"

    private fun apkDownloadUrl(update: AppUpdateInfo): String =
        "$GITEE_REPOSITORY_URL/releases/download/v${update.versionName}/CodexRemote-${update.versionName}.apk"
}

private data class DownloadSnapshot(
    val status: Int,
    val reason: Int,
    val downloadedBytes: Long,
    val totalBytes: Long?,
)

/** Returns the newest stable release which has the expected APK attachment. */
internal fun parseGiteeReleases(value: String, json: Json = Json { ignoreUnknownKeys = true }): AppUpdateInfo? =
    json.parseToJsonElement(value).jsonArray
        .mapNotNull { (it as? JsonObject)?.toAppUpdateInfo() }
        .maxWithOrNull(Comparator { left, right -> compareSemanticVersions(left.versionName, right.versionName) })

internal fun isVersionNewer(candidate: String, current: String): Boolean =
    compareSemanticVersions(candidate, current) > 0

internal fun availableUpdateFor(latestRelease: AppUpdateInfo?, installedVersion: String): AppUpdateInfo? =
    latestRelease?.takeIf { isVersionNewer(it.versionName, installedVersion) }

internal fun shouldPromptUpdate(update: AppUpdateInfo?, ignoredVersion: String?): Boolean =
    update != null && update.versionName != ignoredVersion

internal fun updateDownloadProgressFraction(downloadedBytes: Long, totalBytes: Long?): Float? =
    totalBytes?.takeIf { it > 0L }?.let { total ->
        (downloadedBytes.coerceAtLeast(0L).toDouble() / total.toDouble())
            .toFloat()
            .coerceIn(0f, 1f)
    }

internal fun formatUpdateByteSize(bytes: Long): String {
    if (bytes < 0L) return "未知大小"
    if (bytes < 1024L) return "$bytes B"
    val kibibytes = bytes / 1024.0
    if (kibibytes < 1024.0) return String.format(Locale.ROOT, "%.1f KB", kibibytes)
    val mebibytes = kibibytes / 1024.0
    if (mebibytes < 1024.0) return String.format(Locale.ROOT, "%.1f MB", mebibytes)
    return String.format(Locale.ROOT, "%.1f GB", mebibytes / 1024.0)
}

internal fun compareSemanticVersions(left: String, right: String): Int {
    val leftVersion = parseSemanticVersion(left) ?: return 0
    val rightVersion = parseSemanticVersion(right) ?: return 0
    listOf(
        leftVersion.major.compareTo(rightVersion.major),
        leftVersion.minor.compareTo(rightVersion.minor),
        leftVersion.patch.compareTo(rightVersion.patch),
    ).firstOrNull { it != 0 }?.let { return it }
    return comparePreRelease(leftVersion.preRelease, rightVersion.preRelease)
}

private fun JsonObject.toAppUpdateInfo(): AppUpdateInfo? {
    if ((this["prerelease"] as? JsonPrimitive)?.booleanOrNull == true) return null
    val versionName = optionalText("tag_name", MAX_TAG_NAME_CHARS)
        ?.removePrefix("v")
        ?.takeIf { parseSemanticVersion(it) != null }
        ?: return null
    val expectedAssetName = "CodexRemote-$versionName.apk"
    val hasExpectedAsset = (this["assets"] as? JsonArray)
        .orEmpty()
        .mapNotNull { it as? JsonObject }
        .any { it.optionalText("name", MAX_ASSET_NAME_CHARS) == expectedAssetName }
    if (!hasExpectedAsset) return null

    val body = optionalText("body", MAX_RELEASE_BODY_CHARS).orEmpty()
    return AppUpdateInfo(
        versionName = versionName,
        changes = parseReleaseNotes(body, versionName),
    )
}

private fun JsonObject.optionalText(name: String, maxLength: Int): String? =
    (this[name] as? JsonPrimitive)?.contentOrNull
        ?.replace('\u0000', ' ')
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.take(maxLength)

private fun parseReleaseNotes(body: String, versionName: String): List<AppUpdateReleaseNote> =
    RELEASE_NOTE_PATTERN.findAll(body)
        .mapNotNull { match ->
            val gitCommit = match.groupValues[1].lowercase()
            val message = match.groupValues[2]
                .replace('\u0000', ' ')
                .trim()
                .take(MAX_CHANGE_MESSAGE_CHARS)
                .takeIf { it.isNotEmpty() }
                ?: return@mapNotNull null
            AppUpdateReleaseNote(versionName, gitCommit, message)
        }
        .take(MAX_RELEASE_NOTES)
        .toList()

private data class SemanticVersion(
    val major: Long,
    val minor: Long,
    val patch: Long,
    val preRelease: List<String>?,
)

private fun parseSemanticVersion(value: String): SemanticVersion? {
    val match = SEMANTIC_VERSION_PATTERN.matchEntire(value.trim()) ?: return null
    val major = match.groupValues[1].toLongOrNull() ?: return null
    val minor = match.groupValues[2].toLongOrNull() ?: return null
    val patch = match.groupValues[3].toLongOrNull() ?: return null
    val preRelease = match.groupValues[4].takeIf { it.isNotEmpty() }?.split('.')
    return SemanticVersion(major, minor, patch, preRelease)
}

private fun comparePreRelease(left: List<String>?, right: List<String>?): Int {
    if (left == null) return if (right == null) 0 else 1
    if (right == null) return -1
    val longest = maxOf(left.size, right.size)
    for (index in 0 until longest) {
        val leftIdentifier = left.getOrNull(index) ?: return -1
        val rightIdentifier = right.getOrNull(index) ?: return 1
        val leftNumeric = leftIdentifier.toLongOrNull()
        val rightNumeric = rightIdentifier.toLongOrNull()
        val comparison = when {
            leftNumeric != null && rightNumeric != null -> leftNumeric.compareTo(rightNumeric)
            leftNumeric != null -> -1
            rightNumeric != null -> 1
            else -> leftIdentifier.compareTo(rightIdentifier)
        }
        if (comparison != 0) return comparison
    }
    return 0
}

private fun updateErrorMessage(error: Throwable): String =
    error.message?.replace('\n', ' ')?.trim()?.take(120)?.takeIf { it.isNotEmpty() } ?: "操作失败"

private fun downloadFailureMessage(reason: Int): String = when (reason) {
    DownloadManager.ERROR_INSUFFICIENT_SPACE -> "存储空间不足"
    DownloadManager.ERROR_DEVICE_NOT_FOUND -> "存储设备不可用"
    DownloadManager.ERROR_TOO_MANY_REDIRECTS -> "下载地址重定向过多"
    DownloadManager.ERROR_UNHANDLED_HTTP_CODE -> "下载服务器响应异常"
    else -> "下载失败（错误码 $reason）"
}

private fun InputStream.readUtf8AtMost(maxBytes: Int): String {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(4 * 1024)
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        check(output.size() + count <= maxBytes) { "更新清单过大" }
        output.write(buffer, 0, count)
    }
    return output.toString(Charsets.UTF_8.name())
}

private const val MAX_TAG_NAME_CHARS = 64
private const val MAX_ASSET_NAME_CHARS = 128
private const val MAX_RELEASE_BODY_CHARS = 16 * 1024
private const val MAX_CHANGE_MESSAGE_CHARS = 240
private const val MAX_RELEASE_NOTES = 12
private val SEMANTIC_VERSION_PATTERN =
    Regex("""^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$""")
private val RELEASE_NOTE_PATTERN =
    Regex("""(?m)^\s*[-*]\s+`?([0-9a-fA-F]{7,64})`?\s+(.+?)\s*$""")
