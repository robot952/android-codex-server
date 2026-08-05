package top.asdb.codexremote.agent

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import top.asdb.codexremote.BuildConfig
import top.asdb.codexremote.codex.CodexAppServerClient
import top.asdb.codexremote.codex.string
import top.asdb.codexremote.data.AgentConnectionTestResult
import top.asdb.codexremote.data.AgentCapabilities
import top.asdb.codexremote.data.AgentGlobalSettings
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.data.AgentMode
import top.asdb.codexremote.data.ApiModelOption
import top.asdb.codexremote.data.CustomModelDefinition
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.data.modelSettings
import top.asdb.codexremote.ssh.RemoteBootstrap
import top.asdb.codexremote.ssh.RemoteCodexSettings
import top.asdb.codexremote.ssh.RemoteInstallProgress
import top.asdb.codexremote.ssh.SshCodexTransport

internal const val OPENCODE_MANAGED_PROVIDER_ID = "custom-api"
internal const val OPENCODE_LEGACY_MANAGED_PROVIDER_ID = "codex-remote"
internal val OPENCODE_REASONING_EFFORTS = listOf("minimal", "low", "medium", "high", "xhigh")
private val OPENCODE_REASONING_MODEL_PATTERN =
    Regex("(^|/)gpt-5(?:[._-]|$)|(^|/)o(?:1|3|4)(?:[._-]|$)", RegexOption.IGNORE_CASE)

internal fun openCodeReasoningEfforts(modelId: String): List<String> =
    OPENCODE_REASONING_EFFORTS.takeIf { OPENCODE_REASONING_MODEL_PATTERN.containsMatchIn(modelId.trim()) }
        .orEmpty()

internal fun normalizeOpenCodeModelId(value: String): String {
    val normalized = RemoteCodexSettings.normalizeDefaultModel(value)
    return when {
        normalized.isBlank() -> normalized
        normalized.startsWith("$OPENCODE_LEGACY_MANAGED_PROVIDER_ID/") ->
            "$OPENCODE_MANAGED_PROVIDER_ID/${normalized.substringAfter('/')}"
        '/' in normalized -> normalized
        else -> "$OPENCODE_MANAGED_PROVIDER_ID/$normalized"
    }
}

private fun apiModelId(value: String): String = value.substringAfter('/', value)

private fun providerModelId(providerId: String, value: String): String {
    val normalized = RemoteCodexSettings.normalizeDefaultModel(value)
    return normalized.takeIf(String::isNotBlank)?.let { id ->
        if (id.startsWith("$providerId/")) id else "$providerId/$id"
    }.orEmpty()
}

/**
 * OpenCode adapter. Its REST/SSE translation runs in the managed remote bridge, while the
 * hardened SSH JSONL, SFTP, cache, cancellation, and event plumbing are shared with Codex.
 */
class OpenCodeAgentClient(
    scope: CoroutineScope,
    private val bridgeSource: () -> String,
    private val delegate: CodexAppServerClient = CodexAppServerClient(scope),
    private val bootstrapTransport: SshCodexTransport = SshCodexTransport(),
) : RemoteAgentClient by delegate {
    override val kind: AgentKind = AgentKind.OpenCode
    override val capabilities: AgentCapabilities = AgentCapabilities.OpenCode
    @Volatile
    private var settingsProviderId: String = OPENCODE_MANAGED_PROVIDER_ID
    /** Models added through the app are stable for one bridge generation. */
    private val ensuredCustomModels = ConcurrentHashMap<String, Long>()

    override suspend fun inspectRuntime(profile: ServerProfile): AgentRuntimeInspection {
        val host = delegate.inspectRuntime(profile)
        if (host.installationProblem != null) return host.copy(compatibleCommand = null)
        val values = bootstrapTransport.runBootstrapScript(
            profile = profile,
            script = OpenCodeBootstrap.probeScript,
            timeoutMs = PROBE_TIMEOUT_MS,
            operationName = "检测 OpenCode 运行时",
        ).let(OpenCodeBootstrap::parseProbe)
        val version = values["VERSION"]?.takeIf(String::isNotBlank)
        val bridge = values["BRIDGE"]?.takeIf(String::isNotBlank)
        val bridgeMatches = values["BRIDGE_SHA256"] == OpenCodeBootstrap.bridgeSha256(bridgeSource())
        val compatible = version?.contains(BuildConfig.PINNED_OPENCODE_VERSION) == true &&
            bridge != null && bridgeMatches
        return AgentRuntimeInspection(
            os = host.os,
            architecture = host.architecture,
            home = host.home,
            detectedVersion = version,
            compatibleCommand = bridge?.takeIf { compatible }?.let(::quoteShellArgument),
            installationProblem = host.installationProblem,
        )
    }

    override suspend fun installRuntime(
        profile: ServerProfile,
        onProgress: (RemoteInstallProgress) -> Unit,
    ) {
        bootstrapTransport.installNodeRuntimeDetailed(
            profile = profile,
            nodeVersion = BuildConfig.PINNED_NODE_VERSION,
        ) { progress ->
            onProgress(
                progress.copy(
                    percent = (progress.percent * SHARED_RUNTIME_PERCENT / 100)
                        .coerceIn(0, SHARED_RUNTIME_PERCENT),
                    message = "准备 OpenCode 运行时 · ${progress.message}",
                ),
            )
        }
        bootstrapTransport.runBootstrapScript(
            profile = profile,
            script = OpenCodeBootstrap.installScript(
                openCodeVersion = BuildConfig.PINNED_OPENCODE_VERSION,
                proxyUrl = profile.proxyUrl,
                bridgeSource = bridgeSource(),
            ),
            timeoutMs = INSTALL_TIMEOUT_MS,
            operationName = "安装 OpenCode",
        ) { line ->
            parseProgress(line)?.let(onProgress)
        }
    }

    override suspend fun uninstallRuntime(profile: ServerProfile) {
        ensuredCustomModels.clear()
        delegate.disconnect()
        bootstrapTransport.runBootstrapScript(
            profile = profile,
            script = OpenCodeBootstrap.uninstallScript,
            timeoutMs = UNINSTALL_TIMEOUT_MS,
            operationName = "卸载 OpenCode",
        )
        if (profile.agentMode == AgentMode.OpenCode) {
            delegate.uninstallRuntime(profile)
        }
    }

    override suspend fun connect(profile: ServerProfile): String {
        ensuredCustomModels.clear()
        val command = buildString {
            append(MANAGED_OPENCODE_BRIDGE_COMMAND)
            profile.workspace.takeIf(String::isNotBlank)?.let { workspace ->
                append(" --directory ").append(quoteShellArgument(workspace))
            }
        }
        return delegate.connect(profile.copy(remoteCommand = command))
    }

    override suspend fun disconnect() {
        ensuredCustomModels.clear()
        delegate.disconnect()
    }

    override suspend fun readGlobalSettings(profile: ServerProfile): AgentGlobalSettings {
        val result = delegate.requestAdapterExtension(
            method = "agent/settings/read",
            timeoutMs = SETTINGS_TIMEOUT_MS,
        ) as? JsonObject ?: error("OpenCode 设置返回格式错误")
        settingsProviderId = result.string("modelProvider").ifBlank { OPENCODE_MANAGED_PROVIDER_ID }
        return AgentGlobalSettings(
            baseUrl = result.string("baseUrl"),
            model = result.string("model"),
            reasoningEffort = result.string("reasoningEffort"),
            modelProvider = settingsProviderId,
            hasStoredAuthentication = (result["hasStoredAuthentication"] as? JsonPrimitive)
                ?.booleanOrNull == true,
            apiKey = result.string("apiKey"),
            proxyUrl = result.string("proxyUrl"),
        )
    }

    override suspend fun writeGlobalSettings(
        profile: ServerProfile,
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
        defaultModel: String,
        defaultReasoningEffort: String,
        preserveCurrentProvider: Boolean,
    ) {
        val normalizedBaseUrl = RemoteCodexSettings.validateBaseUrl(baseUrl)
        val normalizedProxy = RemoteBootstrap.validateProxyUrl(proxyUrl)
        val normalizedApiKey = apiKey.trim().also { key ->
            require(key.none { it.isWhitespace() || it.code !in 0x20..0x7e }) {
                "API 密钥不能包含空格、换行或控制字符"
            }
        }
        val normalizedDefaultModel = normalizeOpenCodeModelId(defaultModel)
        val normalizedDefaultReasoningEffort =
            RemoteCodexSettings.normalizeDefaultReasoningEffort(defaultReasoningEffort)
        val effectivePreserveCurrentProvider = preserveCurrentProvider &&
            (normalizedDefaultModel.isBlank() || normalizedDefaultModel.startsWith("$settingsProviderId/"))
        val result = delegate.requestAdapterExtension(
            method = "agent/settings/write",
            params = buildJsonObject {
                put("baseUrl", normalizedBaseUrl)
                put("apiKey", normalizedApiKey)
                put("proxyUrl", normalizedProxy)
                put("defaultModel", normalizedDefaultModel)
                put("defaultReasoningEffort", normalizedDefaultReasoningEffort)
                put("preserveCurrentProvider", effectivePreserveCurrentProvider)
                put("customModels", buildJsonArray {
                    profile.modelSettings(AgentKind.OpenCode).customModels.forEach { definition ->
                        add(buildJsonObject {
                            put("modelId", definition.modelId)
                            put("displayName", definition.displayName)
                            put("contextWindowTokens", definition.contextWindowTokens)
                            put("maxOutputTokens", definition.maxOutputTokens)
                        })
                    }
                })
            },
            timeoutMs = SETTINGS_TIMEOUT_MS,
        ) as? JsonObject
        settingsProviderId = result?.string("modelProvider")
            ?.ifBlank { OPENCODE_MANAGED_PROVIDER_ID }
            ?: OPENCODE_MANAGED_PROVIDER_ID
        ensuredCustomModels.clear()
    }

    override suspend fun testGlobalSettings(
        profile: ServerProfile,
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
        testModel: String,
    ): AgentConnectionTestResult = bootstrapTransport.testCodexGlobalSettings(
        profile = profile,
        baseUrl = baseUrl,
        apiKey = apiKey,
        proxyUrl = proxyUrl,
        testModel = apiModelId(testModel),
    )

    override suspend fun fetchApiModels(
        profile: ServerProfile,
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
    ): List<ApiModelOption> = bootstrapTransport.fetchApiModels(
        profile = profile,
        baseUrl = baseUrl,
        apiKey = apiKey,
        proxyUrl = proxyUrl,
    ).map { option ->
        option.copy(modelId = providerModelId(settingsProviderId, option.modelId))
    }

    override suspend fun ensureCustomModel(
        profile: ServerProfile,
        definition: CustomModelDefinition,
    ) {
        val generation = delegate.currentGeneration() ?: return
        val key = customModelKey(definition)
        if (ensuredCustomModels[key] == generation) return
        syncCustomModels(profile, listOf(definition), emptyList())
    }

    override suspend fun syncCustomModels(
        profile: ServerProfile,
        definitions: List<CustomModelDefinition>,
        removedModelIds: List<String>,
    ) {
        val generation = delegate.currentGeneration() ?: return
        val normalizedDefinitions = definitions.map { definition ->
            definition.copy(modelId = normalizeOpenCodeModelId(definition.modelId))
        }.distinctBy { customModelKey(it) }
        val normalizedRemovedIds = removedModelIds.asSequence()
            .map(::normalizeOpenCodeModelId)
            .filter(String::isNotBlank)
            .distinct()
            .toList()
        val pendingDefinitions = normalizedDefinitions.filter { definition ->
            ensuredCustomModels[customModelKey(definition)] != generation
        }
        if (pendingDefinitions.isEmpty() && normalizedRemovedIds.isEmpty()) return
        delegate.requestAdapterExtension(
            method = "agent/models/sync",
            params = buildJsonObject {
                put("models", buildJsonArray {
                    pendingDefinitions.forEach { definition ->
                        add(buildJsonObject {
                            put("modelId", definition.modelId)
                            put("displayName", definition.displayName)
                            put("contextWindowTokens", definition.contextWindowTokens)
                            put("maxOutputTokens", definition.maxOutputTokens)
                        })
                    }
                })
                put("removeModelIds", buildJsonArray {
                    normalizedRemovedIds.forEach(::add)
                })
            },
            timeoutMs = SETTINGS_TIMEOUT_MS,
        )
        if (delegate.isGenerationActive(generation)) {
            normalizedRemovedIds.forEach(::removeCachedModel)
            pendingDefinitions.forEach { definition ->
                removeCachedModel(definition.modelId)
                ensuredCustomModels[customModelKey(definition)] = generation
            }
        }
    }

    override fun close() {
        ensuredCustomModels.clear()
        delegate.close()
        bootstrapTransport.close()
    }

    companion object {
        const val MANAGED_OPENCODE_BRIDGE_COMMAND = "~/.local/bin/codex-remote-opencode-bridge"
        private const val SHARED_RUNTIME_PERCENT = 68
        private const val PROBE_TIMEOUT_MS = 30_000L
        private const val INSTALL_TIMEOUT_MS = 20 * 60_000L
        private const val UNINSTALL_TIMEOUT_MS = 60_000L
        private const val SETTINGS_TIMEOUT_MS = 30_000L

        private fun customModelKey(definition: CustomModelDefinition): String = listOf(
            normalizeOpenCodeModelId(definition.modelId),
            definition.displayName.trim(),
            definition.contextWindowTokens.toString(),
            definition.maxOutputTokens.toString(),
        ).joinToString("\u0000")

        private fun modelIdFromCustomModelKey(key: String): String = key.substringBefore('\u0000')

        private fun parseProgress(line: String): RemoteInstallProgress? {
            if (!line.startsWith("::progress::")) return null
            val fields = line.removePrefix("::progress::").split('|', limit = 4)
            if (fields.size < 3) return null
            return RemoteInstallProgress(
                percent = fields[0].toIntOrNull()?.coerceIn(0, 100) ?: 0,
                downloadPercent = fields[1].toIntOrNull()?.coerceIn(0, 100),
                message = fields[2],
                detail = fields.getOrElse(3) { "" },
            )
        }
    }

    private fun removeCachedModel(modelId: String) {
        ensuredCustomModels.keys.removeIf { key -> modelIdFromCustomModelKey(key) == modelId }
    }
}
