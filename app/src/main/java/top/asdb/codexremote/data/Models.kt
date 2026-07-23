package top.asdb.codexremote.data

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
enum class AuthMode { Password, PrivateKey }

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
    /** Per-server model preferences restored after reconnecting or restarting the app. */
    val preferredModel: String = "",
    val preferredEffort: String = "",
)

@Serializable
data class StoredProfiles(
    val profiles: List<ServerProfile> = emptyList(),
    val selectedProfileId: String? = null,
    /** Unsent composer text keyed by server id and thread id. */
    val composerDrafts: Map<String, String> = emptyMap(),
    /** Model and reasoning effort selected independently for each server thread. */
    val threadModelPreferences: Map<String, ThreadModelPreference> = emptyMap(),
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

data class CodexThread(
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

data class CodexModel(
    val id: String,
    val model: String,
    val displayName: String,
    val description: String,
    val isDefault: Boolean,
    val defaultEffort: String,
    val efforts: List<String>,
)

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
    val turnId: String = "",
    val subAgentPath: String = "",
    val subAgentThreadId: String = "",
    val subAgentActivity: String = "",
    val reasoningSummary: List<String> = emptyList(),
    val reasoningContent: List<String> = emptyList(),
)

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
)

enum class AppScreen { Servers, Threads, Work, AgentWork }

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

data class RemoteSetupPrompt(
    val title: String,
    val detail: String,
    val os: String,
    val architecture: String,
    val home: String,
    val detectedVersion: String? = null,
)

data class AppUiState(
    val screen: AppScreen = AppScreen.Servers,
    val debugModeEnabled: Boolean = false,
    val profiles: List<ServerProfile> = emptyList(),
    val selectedProfileId: String? = null,
    val connection: ConnectionState = ConnectionState(),
    val connectionStates: Map<String, ConnectionState> = emptyMap(),
    val pendingFingerprint: String? = null,
    val remoteSetup: RemoteSetupPrompt? = null,
    val setupInProgress: Boolean = false,
    val setupProgress: String = "",
    val setupProgressPercent: Int = 0,
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
    val submitting: Boolean = false,
    val loading: Boolean = false,
    val models: List<CodexModel> = emptyList(),
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
