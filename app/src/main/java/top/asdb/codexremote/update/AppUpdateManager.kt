package top.asdb.codexremote.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import top.asdb.codexremote.BuildConfig
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

data class AppUpdateReleaseNote(
    val versionName: String,
    val gitCommit: String,
    val message: String,
)

data class AppUpdateInfo(
    val versionCode: Int,
    val versionName: String,
    val changes: List<AppUpdateReleaseNote>,
)

data class AppUpdateState(
    val checking: Boolean = false,
    val availableUpdate: AppUpdateInfo? = null,
)

/**
 * Fetches a small release manifest on application startup. The APK address is intentionally fixed
 * in the client for this initial release so an untrusted manifest cannot redirect users elsewhere.
 */
object AppUpdateManager {
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private val _state = MutableStateFlow(AppUpdateState())

    private lateinit var preferences: android.content.SharedPreferences
    private var checkJob: Job? = null
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
                        val ignoredVersion = preferences.getInt(KEY_IGNORED_VERSION_CODE, NO_IGNORED_VERSION)
                        val available = update.takeIf {
                            it.versionCode > BuildConfig.VERSION_CODE && it.versionCode != ignoredVersion
                        }
                        _state.update { it.copy(checking = false, availableUpdate = available) }
                        if (available != null) {
                            DiagnosticLogger.info(
                                "Update",
                                "available version=${available.versionName}(${available.versionCode})",
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

    fun ignoreVersion(versionCode: Int) {
        if (versionCode <= 0 || !initialized) return
        preferences.edit().putInt(KEY_IGNORED_VERSION_CODE, versionCode).apply()
        _state.update { current ->
            if (current.availableUpdate?.versionCode == versionCode) {
                current.copy(availableUpdate = null)
            } else {
                current
            }
        }
        DiagnosticLogger.info("Update", "ignored versionCode=$versionCode")
    }

    fun openDownload(context: Context, update: AppUpdateInfo): Boolean = runCatching {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(apkDownloadUrl(update))).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(Intent.createChooser(intent, "下载 ${update.versionName}"))
    }.isSuccess

    private fun fetchUpdateInfo(): AppUpdateInfo {
        val connection = (URL(UPDATE_MANIFEST_URL).openConnection() as? HttpURLConnection)
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
            check(length < 0L || length <= MAX_MANIFEST_BYTES) { "更新清单过大" }
            val body = connection.inputStream.use { input ->
                input.readUtf8AtMost(MAX_MANIFEST_BYTES.toInt())
            }
            return parseAppUpdateManifest(body, json)
        } finally {
            connection.disconnect()
        }
    }

    private const val PREFERENCES_NAME = "app_update_settings"
    private const val KEY_IGNORED_VERSION_CODE = "ignored_version_code"
    private const val NO_IGNORED_VERSION = -1
    private const val NETWORK_TIMEOUT_MILLIS = 5_000
    private const val MAX_MANIFEST_BYTES = 64L * 1024L

    private const val GITEE_REPOSITORY_URL = "https://gitee.com/YanGanYuan/android-codex-server"
    private const val UPDATE_MANIFEST_URL = "$GITEE_REPOSITORY_URL/raw/apk-release/update.json"

    private fun apkDownloadUrl(update: AppUpdateInfo): String =
        "$GITEE_REPOSITORY_URL/raw/apk-release/CodexRemote-${update.versionName}.apk"
}

internal fun parseAppUpdateManifest(value: String, json: Json = Json { ignoreUnknownKeys = true }): AppUpdateInfo {
    val root = json.parseToJsonElement(value).jsonObject
    val versionCode = root.requiredInt("versionCode")
    val versionName = root.requiredText("versionName", MAX_VERSION_NAME_CHARS)
    require(versionCode > 0) { "更新版本号无效" }
    require(VERSION_NAME_PATTERN.matches(versionName)) { "更新版本名无效" }
    val changes = (root["changes"] as? JsonArray)
        .orEmpty()
        .mapNotNull { entry ->
            val change = entry as? JsonObject ?: return@mapNotNull null
            val changeVersion = change.optionalText("versionName", MAX_VERSION_NAME_CHARS) ?: return@mapNotNull null
            val gitCommit = change.optionalText("gitCommit", MAX_GIT_COMMIT_CHARS) ?: return@mapNotNull null
            val message = change.optionalText("message", MAX_CHANGE_MESSAGE_CHARS) ?: return@mapNotNull null
            AppUpdateReleaseNote(changeVersion, gitCommit, message)
        }
        .take(MAX_RELEASE_NOTES)
    return AppUpdateInfo(versionCode, versionName, changes)
}

private fun JsonObject.requiredInt(name: String): Int =
    this[name]?.jsonPrimitive?.intOrNull ?: throw IllegalArgumentException("缺少 $name")

private fun JsonObject.requiredText(name: String, maxLength: Int): String =
    optionalText(name, maxLength) ?: throw IllegalArgumentException("缺少 $name")

private fun JsonObject.optionalText(name: String, maxLength: Int): String? =
    this[name]?.jsonPrimitive?.contentOrNull
        ?.replace('\u0000', ' ')
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.take(maxLength)

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

private const val MAX_VERSION_NAME_CHARS = 48
private const val MAX_GIT_COMMIT_CHARS = 64
private const val MAX_CHANGE_MESSAGE_CHARS = 240
private const val MAX_RELEASE_NOTES = 12
private val VERSION_NAME_PATTERN = Regex("[0-9]+(?:\\.[0-9]+){2}(?:[-+][0-9A-Za-z.-]+)?")
