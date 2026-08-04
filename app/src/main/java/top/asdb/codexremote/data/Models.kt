package top.asdb.codexremote.data

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
enum class AuthMode { Password, PrivateKey }

/** Remote coding agents that have a concrete adapter in the Android client. */
@Serializable
enum class AgentKind(val label: String) {
    Codex("Codex"),
    OpenCode("OpenCode"),
}

/** Legacy persisted selector retained so profiles written by older app versions still decode. */
@Serializable
enum class AgentMode(val label: String) {
    Codex("Codex"),
    OpenCode("OpenCode"),
    Both("两者"),
    ;

    val agents: List<AgentKind>
        get() = when (this) {
            Codex -> listOf(AgentKind.Codex)
            OpenCode -> listOf(AgentKind.OpenCode)
            Both -> AgentKind.entries
        }

    fun contains(agent: AgentKind): Boolean = agent in agents
}

@Serializable
data class ServerProfile(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "我的服务器",
    val host: String = "",
    val port: Int = 22,
    val username: String = "root",
    val authMode: AuthMode = AuthMode.PrivateKey,
    val password: String = "",
    val privateKeyPem: String = "",
    val privateKeyPassphrase: String = "",
    val hostFingerprint: String = "",
    val workspace: String = "",
    /** Optional proxy used only while downloading the managed Node/Codex runtime. */
    val proxyUrl: String = "",
    val approvalMode: ApprovalMode = ApprovalMode.RequestApproval,
    val remoteCommand: String = "~/.local/bin/codex-remote app-server --listen stdio://",
    /** Whether the automatic first-connection workspace prompt has already been presented. */
    val workspacePromptShown: Boolean = false,
    /** Per-server defaults mirrored from the user's remote Codex configuration for new threads. */
    val preferredModel: String = "",
    val preferredEffort: String = "",
    /** Model used only by the non-mutating API settings connection check. */
    val testModel: String = "",
    /** User-defined models shown alongside the remote Codex App Server model list. */
    val customModels: List<CustomModelDefinition> = emptyList(),
    /** Remote model IDs hidden only from this server profile's picker. */
    val hiddenModelIds: List<String> = emptyList(),
    /** Legacy field; current versions expose every registered Agent after SSH login. */
    val agentMode: AgentMode = AgentMode.Codex,
    /** Last Agent lane selected on the connected server page. */
    val activeAgent: AgentKind = AgentKind.Codex,
    /** Model picker and provider defaults isolated per Agent adapter. */
    val agentModelSettings: Map<AgentKind, AgentModelSettings> = emptyMap(),
)

@Serializable
data class CustomModelDefinition(
    /** Exact identifier sent to Codex in thread/start and turn/start. */
    val modelId: String = "",
    /** Optional label used only by the Android picker. */
    val displayName: String = "",
    /** Informational context window size in tokens; zero means unknown. */
    val contextWindowTokens: Long = 0,
    /** Informational maximum output size in tokens; zero means unknown. */
    val maxOutputTokens: Long = 0,
)

@Serializable
data class AgentModelSettings(
    val preferredModel: String = "",
    val preferredEffort: String = "",
    val testModel: String = "",
    val customModels: List<CustomModelDefinition> = emptyList(),
    val hiddenModelIds: List<String> = emptyList(),
    /** Model IDs previously managed by the app, including tombstones awaiting remote removal. */
    val managedModelIds: List<String> = emptyList(),
)

/** Reads the selected Agent lane while retaining compatibility with profiles saved before v2. */
fun ServerProfile.modelSettings(agent: AgentKind): AgentModelSettings =
    agentModelSettings[agent] ?: if (agent == AgentKind.Codex) {
        AgentModelSettings(
            preferredModel = preferredModel,
            preferredEffort = preferredEffort,
            testModel = testModel,
            customModels = customModels,
            hiddenModelIds = hiddenModelIds,
            managedModelIds = customModels.map(CustomModelDefinition::modelId),
        )
    } else {
        AgentModelSettings()
    }

fun ServerProfile.withModelSettings(
    agent: AgentKind,
    settings: AgentModelSettings,
): ServerProfile = copy(
    agentModelSettings = agentModelSettings + (agent to settings),
    // Continue writing legacy Codex fields so older app versions can still open the profile.
    preferredModel = if (agent == AgentKind.Codex) settings.preferredModel else preferredModel,
    preferredEffort = if (agent == AgentKind.Codex) settings.preferredEffort else preferredEffort,
    testModel = if (agent == AgentKind.Codex) settings.testModel else testModel,
    customModels = if (agent == AgentKind.Codex) settings.customModels else customModels,
    hiddenModelIds = if (agent == AgentKind.Codex) settings.hiddenModelIds else hiddenModelIds,
)

/** A model returned by the configured OpenAI-compatible API's /models endpoint. */
data class ApiModelOption(
    val modelId: String,
    val displayName: String = "",
    val contextWindowTokens: Long = 0,
    val maxOutputTokens: Long = 0,
)

@Serializable
data class StoredProfiles(
    val profiles: List<ServerProfile> = emptyList(),
    val selectedProfileId: String? = null,
    /** Unsent composer text keyed by server id and thread id. */
    val composerDrafts: Map<String, String> = emptyMap(),
    /** Model and reasoning effort selected independently for each server thread. */
    val threadModelPreferences: Map<String, ThreadModelPreference> = emptyMap(),
    /** Latest completed turn timing keyed by server id and thread id. */
    val completedTurnTimings: Map<String, TurnTiming> = emptyMap(),
)

@Serializable
data class ThreadModelPreference(
    val model: String = "",
    val effort: String = "",
)

enum class ConnectionPhase { Disconnected, Probing, Connecting, Installing, Connected, Failed }

data class ConnectionState(
    val phase: ConnectionPhase = ConnectionPhase.Disconnected,
    val message: String = "未连接",
    val cliVersion: String? = null,
)

/** Stable key for an independent agent connection and its session state. */
data class AgentConnectionKey(
    val profileId: String,
    val agent: AgentKind,
)

/** Feature gates supplied by an adapter instead of hard-coded agent-name checks in the UI. */
data class AgentCapabilities(
    val models: Boolean = true,
    val reasoningEffort: Boolean = false,
    val approvals: Boolean = false,
    val archiveThread: Boolean = true,
    val renameThread: Boolean = true,
    val interruptTurn: Boolean = true,
    val steerTurn: Boolean = false,
    val rollbackThread: Boolean = false,
    val reviewChanges: Boolean = false,
    val compactThread: Boolean = false,
    val threadGoals: Boolean = false,
    val subAgents: Boolean = false,
    val globalSettings: Boolean = false,
) {
    companion object {
        val None = AgentCapabilities(
            models = false,
            archiveThread = false,
            renameThread = false,
            interruptTurn = false,
        )

        val Codex = AgentCapabilities(
            reasoningEffort = true,
            approvals = true,
            steerTurn = true,
            rollbackThread = true,
            reviewChanges = true,
            compactThread = true,
            threadGoals = true,
            subAgents = true,
            globalSettings = true,
        )

        val OpenCode = AgentCapabilities(
            reasoningEffort = true,
            approvals = true,
            archiveThread = false,
            steerTurn = true,
            globalSettings = true,
        )
    }
}

/** Lightweight read-only resource usage sampled over the active SSH connection. */
data class ServerMetrics(
    val cpuPercent: Int? = null,
    val cpuCoreCount: Int? = null,
    val memoryPercent: Int? = null,
    /** Values come from /proc/meminfo, whose kB unit is 1024 bytes. */
    val memoryTotalKiB: Long? = null,
    val memoryUsedKiB: Long? = null,
    val diskPercent: Int? = null,
    val diskTotalKiB: Long? = null,
    val diskUsedKiB: Long? = null,
    val networkDownloadBytesPerSecond: Long? = null,
    val networkUploadBytesPerSecond: Long? = null,
    val sampledAtEpochMillis: Long = 0L,
    val error: String? = null,
)

data class AgentThread(
    val id: String,
    val title: String,
    val preview: String,
    val cwd: String,
    val source: String,
    val status: String,
    val createdAt: Long,
    val updatedAt: Long,
    val cliVersion: String,
    /** The in-progress turn id when the server included turns in this payload. */
    val activeTurnId: String? = null,
)

/** Compatibility name retained while older UI and parser code migrates to Agent terminology. */
typealias CodexThread = AgentThread

data class AgentModel(
    val id: String,
    val model: String,
    val displayName: String,
    val description: String,
    val isDefault: Boolean,
    val defaultEffort: String,
    val efforts: List<String>,
    /** Informational metadata from a custom model or a provider model list. */
    val contextWindowTokens: Long = 0,
    val maxOutputTokens: Long = 0,
    val isCustom: Boolean = false,
)

/** Compatibility name retained while older UI and parser code migrates to Agent terminology. */
typealias CodexModel = AgentModel

/** A durable objective owned by the remote Codex thread. */
data class ThreadGoal(
    val threadId: String,
    val objective: String,
    val status: ThreadGoalStatus,
    val createdAt: Long,
    val updatedAt: Long,
    val timeUsedSeconds: Long,
    val tokensUsed: Long,
    val tokenBudget: Long? = null,
)

enum class ThreadGoalStatus(val wireValue: String) {
    Active("active"),
    Paused("paused"),
    Blocked("blocked"),
    UsageLimited("usageLimited"),
    BudgetLimited("budgetLimited"),
    Complete("complete"),
    Unknown("unknown"),
    ;

    companion object {
        fun fromWire(value: String): ThreadGoalStatus =
            entries.firstOrNull { it.wireValue == value } ?: Unknown
    }
}

data class TokenUsage(
    val last: TokenUsageBreakdown = TokenUsageBreakdown(),
    val total: TokenUsageBreakdown = TokenUsageBreakdown(),
    val modelContextWindow: Long = 0,
)

/** A context ring is meaningful only after the server has supplied its window size. */
fun TokenUsage.hasKnownContextWindow(): Boolean = modelContextWindow > 0L

data class TokenUsageBreakdown(
    val cachedInputTokens: Long = 0,
    val inputTokens: Long = 0,
    val outputTokens: Long = 0,
    val reasoningOutputTokens: Long = 0,
    val totalTokens: Long = 0,
)

enum class TimelineKind {
    UserMessage,
    AgentMessage,
    Reasoning,
    Plan,
    Command,
    FileChange,
    Tool,
    SubAgent,
    Review,
    Notice,
}

data class FileChange(
    val path: String,
    val kind: String,
    val diff: String,
) {
    val additions: Int get() = diff.lineSequence().count { it.startsWith("+") && !it.startsWith("+++") }
    val deletions: Int get() = diff.lineSequence().count { it.startsWith("-") && !it.startsWith("---") }
}

/** An attachment included with a user message after it has been sent to Codex. */
data class MessageAttachment(
    val name: String,
    val remotePath: String = "",
    val mimeType: String = "application/octet-stream",
)

data class TimelineEntry(
    val id: String,
    val kind: TimelineKind,
    val title: String = "",
    val text: String = "",
    val status: String = "",
    val command: String = "",
    val cwd: String = "",
    val output: String = "",
    val changes: List<FileChange> = emptyList(),
    val attachments: List<MessageAttachment> = emptyList(),
    val turnId: String = "",
    val subAgentPath: String = "",
    val subAgentThreadId: String = "",
    val subAgentActivity: String = "",
    val reasoningSummary: List<String> = emptyList(),
    val reasoningContent: List<String> = emptyList(),
)

/** Local timing for the latest turn in a thread; the app-server does not emit a completion time. */
@Serializable
data class TurnTiming(
    val threadId: String,
    val turnId: String? = null,
    val startedAtMillis: Long,
    val completedAtMillis: Long? = null,
    val stopped: Boolean = false,
)

/** Accept app-server Unix seconds and the milliseconds already used by local UI state. */
internal fun normalizeEpochMillis(timestamp: Long): Long? = when {
    timestamp <= 0L -> null
    timestamp < EPOCH_MILLIS_THRESHOLD -> timestamp * 1_000L
    else -> timestamp
}

private const val EPOCH_MILLIS_THRESHOLD = 100_000_000_000L

enum class ApprovalKind { Command, FileChange, Permission, UserInput }

data class InputOption(
    val label: String,
    val description: String = "",
)

data class InputQuestion(
    val id: String,
    val header: String,
    val question: String,
    val options: List<InputOption> = emptyList(),
    val isSecret: Boolean = false,
)

data class ApprovalPrompt(
    val requestId: String,
    val requestIdIsString: Boolean,
    val kind: ApprovalKind,
    val threadId: String,
    val turnId: String,
    val itemId: String,
    val title: String,
    val detail: String,
    val command: String = "",
    val cwd: String = "",
    val questions: List<InputQuestion> = emptyList(),
)

data class PendingAttachment(
    val name: String,
    val remotePath: String,
    val mimeType: String,
    /** Text attachments are sent inline so the remote model can read their contents directly. */
    val textContent: String? = null,
)

enum class AppScreen { Servers, Threads, Work, AgentWork, FileManager }

enum class SandboxChoice(val wireValue: String, val policyType: String, val label: String) {
    ReadOnly("read-only", "readOnly", "只读"),
    WorkspaceWrite("workspace-write", "workspaceWrite", "工作区"),
    FullAccess("danger-full-access", "dangerFullAccess", "完全访问"),
}

@Serializable
enum class ApprovalMode(
    val approvalPolicy: String,
    val sandbox: SandboxChoice,
    val label: String,
    val menuLabel: String,
    val description: String,
) {
    RequestApproval(
        "untrusted",
        SandboxChoice.WorkspaceWrite,
        "请求批准",
        "请求批准",
        "编辑外部文件和使用互联网时始终询问",
    ),
    AutoApprove(
        "on-request",
        SandboxChoice.WorkspaceWrite,
        "替我审批",
        "替我审批",
        "仅对检测到的风险操作请求批准",
    ),
    FullAccess(
        "never",
        SandboxChoice.FullAccess,
        "完全访问",
        "完全访问权限",
        "可不受限制地访问互联网和服务器上的任何文件",
    ),
}

data class RemoteDirectory(
    val name: String,
    val path: String,
)

data class RemoteDirectoryListing(
    val currentPath: String,
    val parentPath: String?,
    val directories: List<RemoteDirectory>,
)

enum class RemoteFileKind { Directory, File, SymbolicLink, Other }

/** A single entry returned from the remote server through the authenticated SFTP channel. */
data class RemoteFileEntry(
    val name: String,
    val path: String,
    val kind: RemoteFileKind,
    val sizeBytes: Long = 0L,
    val modifiedAtEpochMillis: Long? = null,
    val permissions: String = "",
)

data class RemoteFileListing(
    val currentPath: String,
    val parentPath: String?,
    val entries: List<RemoteFileEntry>,
)

enum class RemoteFileTransferMode { Copy, Move }

/** In-memory remote file clipboard. It is scoped to the currently selected server. */
data class RemoteFileClipboard(
    val entries: List<RemoteFileEntry>,
    val mode: RemoteFileTransferMode,
)

data class RemoteSetupPrompt(
    val title: String,
    val detail: String,
    val os: String,
    val architecture: String,
    val home: String,
    val detectedVersion: String? = null,
    /** Agent whose managed runtime is being installed; defaults preserve older in-memory callers. */
    val agent: AgentKind = AgentKind.Codex,
)

/** User-level provider configuration exposed by an Agent settings adapter. */
data class AgentGlobalSettings(
    val baseUrl: String = "",
    /** Default model selected by the remote user's global Codex configuration. */
    val model: String = "",
    /** Default reasoning effort selected by the remote user's global Codex configuration. */
    val reasoningEffort: String = "",
    /** Active built-in or custom provider id from the remote global configuration. */
    val modelProvider: String = "openai",
    /** The remote account has a stored Codex credential. */
    val hasStoredAuthentication: Boolean = false,
    /**
     * API-key authentication read only while the settings dialog is open. It is never persisted
     * on the device or written to diagnostic output. OAuth authentication has no displayable key.
     */
    val apiKey: String = "",
    val proxyUrl: String = "",
)

typealias CodexGlobalSettings = AgentGlobalSettings

/** Result of a non-mutating API request started from the remote server. */
data class AgentConnectionTestResult(
    val successful: Boolean,
    val message: String,
)

typealias CodexConnectionTestResult = AgentConnectionTestResult

data class AppUiState(
    val screen: AppScreen = AppScreen.Servers,
    /** Lets nested collaborator pages animate B -> A as a back navigation. */
    val subAgentBackNavigation: Boolean = false,
    val debugModeEnabled: Boolean = false,
    val profiles: List<ServerProfile> = emptyList(),
    val selectedProfileId: String? = null,
    /** Host-level SSH state for [selectedProfileId]. */
    val connection: ConnectionState = ConnectionState(),
    /** Host-level SSH states used by server cards, terminal, metrics, and file management. */
    val connectionStates: Map<String, ConnectionState> = emptyMap(),
    /** Optional Agent-lane states, independent from [connectionStates]. */
    val agentConnectionStates: Map<AgentConnectionKey, ConnectionState> = emptyMap(),
    val activeAgent: AgentKind = AgentKind.Codex,
    val activeAgentCapabilities: AgentCapabilities = AgentCapabilities.None,
    val serverMetrics: Map<String, ServerMetrics> = emptyMap(),
    val pendingFingerprint: String? = null,
    val remoteSetup: RemoteSetupPrompt? = null,
    val setupInProgress: Boolean = false,
    val setupProgress: String = "",
    val setupProgressPercent: Int = 0,
    /** Detail from the current remote install step, such as downloaded bytes or component count. */
    val setupProgressDetail: String = "",
    /** Progress within the active download, separate from the full installation percentage. */
    val setupDownloadPercent: Int? = null,
    val threads: List<CodexThread> = emptyList(),
    val threadSearch: String = "",
    val activeThread: CodexThread? = null,
    /** Human-readable name supplied by the parent thread while viewing a collaborator thread. */
    val activeAgentName: String? = null,
    /** Native durable objective fetched from and mutated through the active remote thread. */
    val activeGoal: ThreadGoal? = null,
    val timeline: List<TimelineEntry> = emptyList(),
    val olderTurnsCursor: String? = null,
    val olderTurnsLoading: Boolean = false,
    val activeTurnId: String? = null,
    val running: Boolean = false,
    val turnTiming: TurnTiming? = null,
    val submitting: Boolean = false,
    val loading: Boolean = false,
    val models: List<CodexModel> = emptyList(),
    /** Fresh results from the configured API /models endpoint for the model editor. */
    val apiModelOptions: List<ApiModelOption> = emptyList(),
    val apiModelOptionsProfileId: String? = null,
    val apiModelOptionsLoading: Boolean = false,
    val apiModelOptionsError: String? = null,
    val selectedModel: String? = null,
    val selectedEffort: String? = null,
    val approvalMode: ApprovalMode = ApprovalMode.RequestApproval,
    val sandbox: SandboxChoice = SandboxChoice.WorkspaceWrite,
    val workspacePickerVisible: Boolean = false,
    val workspaceLoading: Boolean = false,
    val workspaceCurrentPath: String = "",
    val workspaceParentPath: String? = null,
    val workspaceDirectories: List<RemoteDirectory> = emptyList(),
    val workspaceError: String? = null,
    val fileManagerProfileId: String? = null,
    val fileManagerLoading: Boolean = false,
    val fileManagerCurrentPath: String = "",
    val fileManagerParentPath: String? = null,
    val fileManagerEntries: List<RemoteFileEntry> = emptyList(),
    val fileManagerClipboard: RemoteFileClipboard? = null,
    /** A transfer or destructive operation currently running through SFTP. */
    val fileManagerOperation: String? = null,
    val fileManagerError: String? = null,
    val agentSettingsVisible: Boolean = false,
    val agentSettingsLoading: Boolean = false,
    val agentSettingsSaving: Boolean = false,
    val agentSettingsTesting: Boolean = false,
    val agentSettings: AgentGlobalSettings? = null,
    val agentSettingsTestResult: AgentConnectionTestResult? = null,
    val agentSettingsError: String? = null,
    val approval: ApprovalPrompt? = null,
    /** Pending server requests are kept in arrival order; the first one is shown in the dialog. */
    val approvalQueue: List<ApprovalPrompt> = emptyList(),
    val attachments: List<PendingAttachment> = emptyList(),
    val composerClearNonce: Int = 0,
    val composerDraft: String = "",
    val aggregateDiff: String = "",
    val tokenUsage: TokenUsage? = null,
    val error: String? = null,
    val diagnostic: String? = null,
)
