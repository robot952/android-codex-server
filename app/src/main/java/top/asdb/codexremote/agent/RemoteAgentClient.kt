package top.asdb.codexremote.agent

import java.io.InputStream
import java.io.OutputStream
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.serialization.json.JsonObject
import top.asdb.codexremote.data.AgentConnectionTestResult
import top.asdb.codexremote.data.AgentGlobalSettings
import top.asdb.codexremote.data.AgentModel
import top.asdb.codexremote.data.AgentThread
import top.asdb.codexremote.data.AgentCapabilities
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.data.ApiModelOption
import top.asdb.codexremote.data.ApprovalMode
import top.asdb.codexremote.data.ApprovalPrompt
import top.asdb.codexremote.data.CustomModelDefinition
import top.asdb.codexremote.data.PendingAttachment
import top.asdb.codexremote.data.RemoteDirectoryListing
import top.asdb.codexremote.data.RemoteFileListing
import top.asdb.codexremote.data.RemoteFileTransferMode
import top.asdb.codexremote.data.ServerMetrics
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.data.ThreadGoal
import top.asdb.codexremote.data.ThreadGoalStatus
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.ssh.RemoteInstallProgress

/** Protocol-neutral notification consumed by the shared conversation reducer. */
data class AgentNotification(
    val generation: Long,
    val method: String,
    val params: JsonObject,
    val sequence: Long = 0,
)

data class AgentApproval(val generation: Long, val prompt: ApprovalPrompt)

data class AgentConnectionEvent(val generation: Long, val message: String)

/** Result of probing one agent runtime on an SSH host. */
data class AgentRuntimeInspection(
    val os: String,
    val architecture: String,
    val home: String,
    val detectedVersion: String? = null,
    val compatibleCommand: String? = null,
    val installationProblem: String? = null,
)

class UnsupportedAgentCapabilityException(
    agent: AgentKind,
    capability: String,
) : UnsupportedOperationException("${agent.label} 暂不支持$capability")

/**
 * Contract between shared app state/UI and a concrete remote coding agent.
 *
 * Adapters own protocol mapping and runtime startup. The ViewModel depends only on this contract,
 * so a future agent can be added without another profile/session/connection implementation.
 */
interface RemoteAgentClient {
    val kind: AgentKind
    val capabilities: AgentCapabilities

    val notifications: SharedFlow<AgentNotification>
    val approvals: SharedFlow<AgentApproval>
    val diagnostics: SharedFlow<AgentConnectionEvent>
    val closed: SharedFlow<AgentConnectionEvent>

    suspend fun probeFingerprint(profile: ServerProfile): String
    suspend fun inspectRuntime(profile: ServerProfile): AgentRuntimeInspection
    suspend fun installRuntime(
        profile: ServerProfile,
        onProgress: (RemoteInstallProgress) -> Unit,
    )
    suspend fun uninstallRuntime(profile: ServerProfile)

    suspend fun connect(profile: ServerProfile): String
    suspend fun disconnect()
    fun close()
    fun isConnected(): Boolean
    fun currentGeneration(): Long?
    fun isGenerationActive(generation: Long): Boolean
    fun isClosedGenerationCurrent(generation: Long): Boolean

    suspend fun listThreads(search: String = "", archived: Boolean = false): List<AgentThread>
    suspend fun listModels(): List<AgentModel>
    suspend fun openThread(threadId: String, approvalMode: ApprovalMode): AgentSession
    suspend fun listThreadTurnsPage(
        threadId: String,
        cursor: String,
        subAgentCreatedAt: Long? = null,
    ): AgentThreadPage
    suspend fun readThread(threadId: String): Pair<AgentThread, List<TimelineEntry>>
    fun cachedThread(threadId: String): AgentThreadCacheSnapshot?
    fun cachedThreadStale(threadId: String): AgentThreadCacheSnapshot?
    fun cachedContextUsage(threadId: String): TokenUsage?
    fun cacheThread(
        thread: AgentThread,
        timeline: List<TimelineEntry>,
        nextTurnsCursor: String? = null,
        tokenUsage: TokenUsage? = null,
    )

    suspend fun startThread(
        profile: ServerProfile,
        model: String?,
        approvalMode: ApprovalMode,
    ): Pair<AgentThread, List<TimelineEntry>>
    suspend fun startTurn(
        threadId: String,
        text: String,
        attachments: List<PendingAttachment>,
        model: String?,
        effort: String?,
        approvalMode: ApprovalMode,
        cwd: String?,
    ): String

    /**
     * Makes a locally-added model available to the remote Agent before it is selected.
     * Adapters that do not need provider-side model registration can keep the no-op default.
     */
    suspend fun ensureCustomModel(
        profile: ServerProfile,
        definition: CustomModelDefinition,
    ): Unit = Unit

    /**
     * Reconciles locally-managed models with the remote Agent configuration. Removed IDs are
     * explicit so an adapter never has to infer ownership from the provider's complete catalog.
     */
    suspend fun syncCustomModels(
        profile: ServerProfile,
        definitions: List<CustomModelDefinition>,
        removedModelIds: List<String>,
    ) {
        definitions.forEach { ensureCustomModel(profile, it) }
    }

    suspend fun steerTurn(
        threadId: String,
        turnId: String,
        text: String,
        attachments: List<PendingAttachment>,
    ): Unit = unsupported("回合引导")
    suspend fun interruptTurn(threadId: String, turnId: String)

    suspend fun compactThread(threadId: String): Unit = unsupported("上下文压缩")
    suspend fun getThreadGoal(threadId: String): ThreadGoal? = null
    suspend fun setThreadGoal(
        threadId: String,
        objective: String? = null,
        status: ThreadGoalStatus? = null,
        tokenBudget: Long? = null,
    ): ThreadGoal = unsupported("会话目标")
    suspend fun clearThreadGoal(threadId: String): Unit = unsupported("会话目标")
    suspend fun archiveThread(threadId: String)
    suspend fun rollbackThread(
        threadId: String,
        approvalMode: ApprovalMode,
        turns: Int = 1,
    ): AgentSession = unsupported("回滚")
    suspend fun setThreadName(threadId: String, name: String)
    suspend fun startReview(threadId: String): Unit = unsupported("代码审查")

    suspend fun listDirectories(path: String?): RemoteDirectoryListing
    suspend fun listFiles(path: String?): RemoteFileListing
    suspend fun readServerMetrics(profile: ServerProfile): ServerMetrics
    suspend fun upload(name: String, bytes: ByteArray): String
    suspend fun uploadFile(directory: String, name: String, input: InputStream)
    suspend fun downloadFile(path: String, output: OutputStream)
    suspend fun renameFile(path: String, newName: String)
    suspend fun deleteFiles(paths: List<String>)
    suspend fun transferFiles(
        paths: List<String>,
        destinationDirectory: String,
        mode: RemoteFileTransferMode,
    )
    suspend fun downloadImage(path: String): ByteArray

    suspend fun readGlobalSettings(profile: ServerProfile): AgentGlobalSettings =
        unsupported("全局设置")
    suspend fun writeGlobalSettings(
        profile: ServerProfile,
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
        defaultModel: String,
        defaultReasoningEffort: String,
        preserveCurrentProvider: Boolean,
    ): Unit = unsupported("全局设置")
    suspend fun testGlobalSettings(
        profile: ServerProfile,
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
        testModel: String,
    ): AgentConnectionTestResult = unsupported("全局设置")
    suspend fun fetchApiModels(
        profile: ServerProfile,
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
    ): List<ApiModelOption> = unsupported("模型 API")
    suspend fun answerApproval(
        prompt: ApprovalPrompt,
        accept: Boolean,
        answers: Map<String, String> = emptyMap(),
    ): Unit = unsupported("操作审批")

    private fun unsupported(capability: String): Nothing =
        throw UnsupportedAgentCapabilityException(kind, capability)
}
