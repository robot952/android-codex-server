package top.asdb.codexremote

import android.app.Application
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.asdb.codexremote.codex.CodexAppServerClient
import top.asdb.codexremote.codex.CodexEventReducer
import top.asdb.codexremote.data.AppScreen
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.ApprovalMode
import top.asdb.codexremote.data.ApprovalPrompt
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState
import top.asdb.codexremote.data.PendingAttachment
import top.asdb.codexremote.data.ProfileStore
import top.asdb.codexremote.data.RemoteDirectoryListing
import top.asdb.codexremote.data.RemoteSetupPrompt
import top.asdb.codexremote.data.SandboxChoice
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.data.StoredProfiles
import top.asdb.codexremote.ssh.RemoteBootstrap
import top.asdb.codexremote.ssh.RemoteEnvironment
import java.io.ByteArrayOutputStream
import java.util.UUID

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val store = ProfileStore(application)
    private val client = CodexAppServerClient(viewModelScope)
    private val saved = store.load()
    private val initialProfileId = saved.selectedProfileId ?: saved.profiles.firstOrNull()?.id
    private val initialProfile = saved.profiles.firstOrNull { it.id == initialProfileId }
    private var fingerprintProfile: ServerProfile? = null
    private var setupProfile: ServerProfile? = null
    private var fingerprintJob: Job? = null
    private var connectionJob: Job? = null
    private var setupJob: Job? = null

    private val _state = MutableStateFlow(
        AppUiState(
            profiles = saved.profiles,
            selectedProfileId = initialProfileId,
            approvalMode = initialProfile?.approvalMode ?: ApprovalMode.RequestApproval,
            sandbox = (initialProfile?.approvalMode ?: ApprovalMode.RequestApproval).sandbox,
        ),
    )
    val state: StateFlow<AppUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            client.notifications.collect { notification ->
                if (!client.isGenerationActive(notification.generation)) return@collect
                _state.update { CodexEventReducer.reduce(it, notification.method, notification.params) }
                if (notification.method == "turn/completed") refreshThreads(silent = true)
            }
        }
        viewModelScope.launch {
            client.approvals.collect { event ->
                if (!client.isGenerationActive(event.generation)) return@collect
                val approval = event.prompt
                _state.update { current ->
                    if (current.approvalQueue.any { it.requestId == approval.requestId }) {
                        return@update current
                    }
                    val queue = current.approvalQueue + approval
                    current.copy(
                        approvalQueue = queue,
                        approval = current.approval ?: queue.firstOrNull(),
                    )
                }
            }
        }
        viewModelScope.launch {
            client.diagnostics.collect { event ->
                if (!client.isGenerationActive(event.generation)) return@collect
                _state.update { it.copy(diagnostic = event.message) }
            }
        }
        viewModelScope.launch {
            client.closed.collect { event ->
                if (!client.isClosedGenerationCurrent(event.generation)) return@collect
                _state.update {
                    it.copy(
                        connection = ConnectionState(ConnectionPhase.Failed, event.message),
                        running = false,
                        activeTurnId = null,
                        approval = null,
                        approvalQueue = emptyList(),
                        workspacePickerVisible = false,
                        workspaceLoading = false,
                    )
                }
            }
        }
    }

    override fun onCleared() {
        fingerprintJob?.cancel()
        connectionJob?.cancel()
        setupJob?.cancel()
        client.close()
        super.onCleared()
    }

    fun saveProfile(profile: ServerProfile) {
        val normalized = profile.copy(
            name = profile.name.trim().ifBlank { profile.host.trim().ifBlank { "服务器" } },
            host = profile.host.trim(),
            username = profile.username.trim(),
            workspace = profile.workspace.trim(),
            hostFingerprint = profile.hostFingerprint.trim(),
            remoteCommand = profile.remoteCommand.trim(),
        )
        _state.update { current ->
            val profiles = current.profiles.toMutableList()
            val index = profiles.indexOfFirst { it.id == normalized.id }
            if (index >= 0) profiles[index] = normalized else profiles += normalized
            current.copy(profiles = profiles, selectedProfileId = normalized.id)
        }
        persistProfiles()
    }

    fun newProfile(): ServerProfile = ServerProfile(
        id = UUID.randomUUID().toString(),
        name = "新服务器",
        username = "codex-remote",
    )

    fun selectProfile(id: String) {
        _state.update { current ->
            val profile = current.profiles.firstOrNull { it.id == id }
            val mode = profile?.approvalMode ?: ApprovalMode.RequestApproval
            current.copy(selectedProfileId = id, approvalMode = mode, sandbox = mode.sandbox)
        }
        persistProfiles()
    }

    fun deleteProfile(id: String) {
        _state.update { current ->
            val profiles = current.profiles.filterNot { it.id == id }
            current.copy(
                profiles = profiles,
                selectedProfileId = profiles.firstOrNull()?.id,
            )
        }
        persistProfiles()
    }

    fun probeFingerprint(profile: ServerProfile) {
        if (fingerprintJob?.isActive == true || connectionJob?.isActive == true || setupJob?.isActive == true) return
        fingerprintProfile = profile
        _state.update {
            it.copy(
                connection = ConnectionState(ConnectionPhase.Probing, "正在读取 SSH 主机指纹"),
                error = null,
            )
        }
        fingerprintJob = viewModelScope.launch {
            try {
                runCatching { client.probeFingerprint(profile) }
                    .onSuccess { fingerprint ->
                        _state.update {
                            it.copy(
                                pendingFingerprint = fingerprint,
                                connection = ConnectionState(ConnectionPhase.Disconnected, "请核对服务器指纹"),
                            )
                        }
                    }
                    .onFailure { error -> showConnectionError(error) }
            } finally {
                fingerprintJob = null
            }
        }
    }

    fun trustFingerprint() {
        val profile = fingerprintProfile ?: return
        val fingerprint = _state.value.pendingFingerprint ?: return
        val trusted = profile.copy(hostFingerprint = fingerprint)
        saveProfile(trusted)
        fingerprintProfile = null
        _state.update { it.copy(pendingFingerprint = null) }
        connect(trusted)
    }

    fun rejectFingerprint() {
        fingerprintProfile = null
        _state.update {
            it.copy(
                pendingFingerprint = null,
                connection = ConnectionState(ConnectionPhase.Disconnected, "未连接"),
            )
        }
    }

    fun connect(profile: ServerProfile) {
        if (connectionJob?.isActive == true || setupJob?.isActive == true || fingerprintJob?.isActive == true) return
        saveProfile(profile)
        if (profile.hostFingerprint.isBlank()) {
            probeFingerprint(profile)
            return
        }
        _state.update {
            it.copy(
                connection = ConnectionState(ConnectionPhase.Connecting, "正在检测远程 Codex"),
                loading = true,
                error = null,
                remoteSetup = null,
                setupProgress = "",
            )
        }
        connectionJob = viewModelScope.launch {
            try {
                val effectiveProfile = prepareRemote(profile) ?: return@launch
                _state.update {
                    it.copy(connection = ConnectionState(ConnectionPhase.Connecting, "正在启动 Codex app-server"))
                }
                showConnected(profile, loadConnectedSession(effectiveProfile))
            } catch (error: Throwable) {
                client.disconnect()
                showConnectionError(error)
            } finally {
                connectionJob = null
            }
        }
    }

    fun installRemoteSetup() {
        if (setupJob?.isActive == true || connectionJob?.isActive == true || fingerprintJob?.isActive == true) return
        val profile = setupProfile ?: return
        _state.update {
            it.copy(
                connection = ConnectionState(ConnectionPhase.Installing, "正在安装远程 Codex"),
                setupInProgress = true,
                setupProgress = "准备安装",
                loading = true,
                error = null,
            )
        }
        setupJob = viewModelScope.launch {
            runCatching {
                client.installRemote(profile) { progress ->
                    _state.update { it.copy(setupProgress = progress) }
                }
                val verified = client.inspectRemote(profile)
                check(verified.compatibleCommand(BuildConfig.PINNED_CODEX_VERSION) != null) {
                    "安装完成，但未检测到 Codex ${BuildConfig.PINNED_CODEX_VERSION}"
                }
            }.onSuccess {
                setupProfile = null
                _state.update {
                    it.copy(
                        remoteSetup = null,
                        setupInProgress = false,
                        setupProgress = "安装完成",
                        loading = false,
                    )
                }
                setupJob = null
                connect(profile)
            }.onFailure { error ->
                _state.update {
                    it.copy(
                        connection = ConnectionState(ConnectionPhase.Failed, "远程 Codex 安装失败"),
                        setupInProgress = false,
                        loading = false,
                        error = error.message ?: "远程 Codex 安装失败",
                    )
                }
            }
            setupJob = null
        }
    }

    fun cancelRemoteSetup() {
        if (_state.value.setupInProgress) return
        setupProfile = null
        _state.update {
            it.copy(
                remoteSetup = null,
                setupProgress = "",
                loading = false,
                connection = ConnectionState(ConnectionPhase.Disconnected, "未连接"),
            )
        }
    }

    fun disconnect() {
        fingerprintJob?.cancel()
        connectionJob?.cancel()
        setupJob?.cancel()
        viewModelScope.launch {
            client.disconnect()
            _state.update {
                it.copy(
                    screen = AppScreen.Servers,
                    connection = ConnectionState(),
                    threads = emptyList(),
                    activeThread = null,
                    timeline = emptyList(),
                    activeTurnId = null,
                    running = false,
                    submitting = false,
                    approval = null,
                    approvalQueue = emptyList(),
                    workspacePickerVisible = false,
                    workspaceLoading = false,
                    remoteSetup = null,
                    setupInProgress = false,
                    setupProgress = "",
                    aggregateDiff = "",
                )
            }
        }
    }

    fun setThreadSearch(value: String) {
        _state.update { it.copy(threadSearch = value) }
    }

    fun refreshThreads(silent: Boolean = false) {
        if (!client.isConnected()) return
        viewModelScope.launch {
            if (!silent) _state.update { it.copy(loading = true, error = null) }
            runCatching { client.listThreads(_state.value.threadSearch) }
                .onSuccess { threads -> _state.update { it.copy(threads = threads, loading = false) } }
                .onFailure { error ->
                    if (!silent) showError(error) else _state.update { it.copy(diagnostic = error.message) }
                }
        }
    }

    fun createThread() {
        val profile = currentProfile() ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching {
                client.startThread(profile, _state.value.selectedModel, _state.value.approvalMode)
            }.onSuccess { (thread, timeline) ->
                _state.update {
                    it.copy(
                        screen = AppScreen.Work,
                        activeThread = thread,
                        timeline = timeline,
                        activeTurnId = null,
                        running = false,
                        aggregateDiff = "",
                        loading = false,
                    )
                }
            }.onFailure(::showError)
        }
    }

    fun openThread(thread: top.asdb.codexremote.data.CodexThread) {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            // `thread/resume` establishes the app-server's active thread context. Do not silently
            // replace it with `thread/read`, which is a read-only payload and cannot safely accept
            // subsequent turns or steering.
            runCatching { client.openThread(thread.id, _state.value.approvalMode) }
                .onSuccess { (loaded, timeline) ->
                    val activeTurn = timeline.lastOrNull { it.status == "inProgress" }?.turnId
                    _state.update {
                        it.copy(
                            screen = AppScreen.Work,
                            activeThread = loaded,
                            timeline = timeline,
                            activeTurnId = loaded.activeTurnId ?: activeTurn,
                            running = loaded.activeTurnId != null || activeTurn != null || loaded.status == "active",
                            aggregateDiff = "",
                            loading = false,
                        )
                    }
                }.onFailure(::showError)
        }
    }

    fun backToThreads() {
        if (_state.value.approvalQueue.isNotEmpty()) {
            showError(IllegalStateException("请先处理当前审批请求"))
            return
        }
        _state.update { it.copy(screen = AppScreen.Threads, approval = null, approvalQueue = emptyList()) }
        refreshThreads(silent = true)
    }

    fun send(text: String) {
        val clean = text.trim()
        val current = _state.value
        val thread = current.activeThread ?: return
        if (clean.isBlank() && current.attachments.isEmpty()) return
        if (current.submitting) return
        if (current.running && current.activeTurnId == null) {
            showError(IllegalStateException("当前回合仍在运行，尚未收到回合 ID，请稍后再试"))
            return
        }
        _state.update { it.copy(submitting = true, error = null) }
        viewModelScope.launch {
            runCatching {
                val activeTurn = current.activeTurnId
                if (current.running && activeTurn != null) {
                    client.steerTurn(thread.id, activeTurn, clean, current.attachments)
                    activeTurn
                } else {
                    client.startTurn(
                        threadId = thread.id,
                        text = clean,
                        attachments = current.attachments,
                        model = current.selectedModel,
                        effort = current.selectedEffort,
                        approvalMode = current.approvalMode,
                        cwd = thread.cwd,
                    )
                }
            }.onSuccess { turnId ->
                _state.update {
                    it.copy(
                        activeTurnId = turnId.ifBlank { it.activeTurnId },
                        running = true,
                        submitting = false,
                        attachments = emptyList(),
                        composerClearNonce = it.composerClearNonce + 1,
                    )
                }
            }.onFailure(::showError)
        }
    }

    fun stopTurn() {
        val threadId = _state.value.activeThread?.id ?: return
        val turnId = _state.value.activeTurnId ?: run {
            showError(IllegalStateException("当前回合 ID 尚未可用"))
            return
        }
        viewModelScope.launch {
            runCatching { client.interruptTurn(threadId, turnId) }
                .onFailure(::showError)
        }
    }

    fun reviewChanges() {
        val threadId = _state.value.activeThread?.id ?: return
        viewModelScope.launch {
            runCatching { client.startReview(threadId) }
                .onFailure(::showError)
        }
    }

    fun rollbackActiveThread() {
        val threadId = _state.value.activeThread?.id ?: return
        if (_state.value.running) {
            showError(IllegalStateException("回合运行中，完成或停止后才能回退会话历史"))
            return
        }
        viewModelScope.launch {
            runCatching { client.rollbackThread(threadId) }
                .onSuccess { (thread, timeline) ->
                    _state.update {
                        it.copy(
                            activeThread = thread,
                            timeline = timeline,
                            activeTurnId = thread.activeTurnId,
                            running = thread.status == "active" || thread.activeTurnId != null,
                            aggregateDiff = "",
                        )
                    }
                }
                .onFailure(::showError)
        }
    }

    fun archiveActiveThread() {
        val threadId = _state.value.activeThread?.id ?: return
        viewModelScope.launch {
            runCatching { client.archiveThread(threadId) }
                .onSuccess { backToThreads() }
                .onFailure(::showError)
        }
    }

    fun renameActiveThread(name: String) {
        val thread = _state.value.activeThread ?: return
        val clean = name.trim()
        if (clean.isBlank()) return
        viewModelScope.launch {
            runCatching { client.setThreadName(thread.id, clean) }
                .onSuccess {
                    _state.update { it.copy(activeThread = it.activeThread?.copy(title = clean)) }
                }.onFailure(::showError)
        }
    }

    fun answerApproval(accept: Boolean, answers: Map<String, String> = emptyMap()) {
        val prompt = _state.value.approval ?: return
        viewModelScope.launch {
            runCatching { client.answerApproval(prompt, accept, answers) }
                .onSuccess {
                    _state.update { current ->
                        val remaining = current.approvalQueue.filterNot { it.requestId == prompt.requestId }
                        current.copy(
                            approvalQueue = remaining,
                            approval = remaining.firstOrNull(),
                        )
                    }
                }
                .onFailure(::showError)
        }
    }

    fun dismissApproval() {
        answerApproval(false)
    }

    fun uploadAttachment(context: Context, uri: Uri) {
        currentProfile() ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching {
                val content = withContext(Dispatchers.IO) {
                    var name = "attachment"
                    var size = -1L
                    context.contentResolver.query(
                        uri,
                        arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                        null,
                        null,
                        null,
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }
                                ?.let { name = cursor.getString(it) ?: name }
                            cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }
                                ?.let { size = cursor.getLong(it) }
                        }
                    }
                    require(size < 20L * 1024 * 1024 || size < 0) { "附件不能超过 20 MB" }
                    val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(8 * 1024)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= MAX_ATTACHMENT_BYTES) { "附件不能超过 20 MB" }
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    } ?: throw IllegalStateException("无法读取附件")
                    Triple(name, context.contentResolver.getType(uri) ?: "application/octet-stream", bytes)
                }
                val remotePath = client.upload(content.first, content.third)
                PendingAttachment(content.first, remotePath, content.second)
            }.onSuccess { attachment ->
                _state.update { it.copy(attachments = it.attachments + attachment, loading = false) }
            }.onFailure(::showError)
        }
    }

    fun removeAttachment(path: String) {
        _state.update { it.copy(attachments = it.attachments.filterNot { file -> file.remotePath == path }) }
    }

    fun selectModel(model: String, effort: String?) {
        _state.update { it.copy(selectedModel = model, selectedEffort = effort) }
    }

    fun selectEffort(effort: String) {
        _state.update { it.copy(selectedEffort = effort) }
    }

    fun selectApprovalMode(mode: ApprovalMode) {
        _state.update { current ->
            val profiles = current.profiles.map { profile ->
                if (profile.id == current.selectedProfileId) profile.copy(approvalMode = mode) else profile
            }
            current.copy(
                profiles = profiles,
                approvalMode = mode,
                sandbox = mode.sandbox,
            )
        }
        persistProfiles()
    }

    fun selectSandbox(sandbox: SandboxChoice) {
        val mode = when (sandbox) {
            SandboxChoice.FullAccess -> ApprovalMode.FullAccess
            SandboxChoice.ReadOnly -> ApprovalMode.RequestApproval
            SandboxChoice.WorkspaceWrite -> ApprovalMode.AutoApprove
        }
        selectApprovalMode(mode)
    }

    fun browseWorkspace(path: String) {
        if (!client.isConnected()) return
        _state.update {
            it.copy(workspacePickerVisible = true, workspaceLoading = true, workspaceError = null)
        }
        viewModelScope.launch {
            runCatching { client.listDirectories(path) }
                .onSuccess { listing ->
                    _state.update {
                        it.copy(
                            workspaceLoading = false,
                            workspaceCurrentPath = listing.currentPath,
                            workspaceParentPath = listing.parentPath,
                            workspaceDirectories = listing.directories,
                            workspaceError = null,
                        )
                    }
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(workspaceLoading = false, workspaceError = error.message ?: "无法读取目录")
                    }
                }
        }
    }

    fun showWorkspacePicker() {
        val profile = currentProfile() ?: return
        val path = profile.workspace.ifBlank {
            _state.value.workspaceCurrentPath.ifBlank { "/" }
        }
        browseWorkspace(path)
    }

    fun confirmWorkspace() {
        val path = _state.value.workspaceCurrentPath.trim()
        val profile = currentProfile() ?: return
        if (path.isNotBlank()) saveProfile(profile.copy(workspace = path))
        _state.update { it.copy(workspacePickerVisible = false, workspaceError = null) }
    }

    fun dismissWorkspacePicker() {
        _state.update { it.copy(workspacePickerVisible = false, workspaceError = null) }
    }

    fun clearError() {
        _state.update { it.copy(error = null) }
    }

    fun clearDiagnostic() {
        _state.update { it.copy(diagnostic = null) }
    }

    private suspend fun prepareRemote(profile: ServerProfile): ServerProfile? {
        if (profile.remoteCommand != RemoteBootstrap.MANAGED_REMOTE_COMMAND) return profile
        val environment = client.inspectRemote(profile)
        environment.compatibleCommand(BuildConfig.PINNED_CODEX_VERSION)?.let { command ->
            return profile.copy(remoteCommand = command)
        }
        environment.installationProblem()?.let { problem ->
            throw IllegalStateException(problem)
        }
        setupProfile = profile
        val detected = environment.detectedVersion()
        val detail = if (detected == null) {
            "服务器尚未安装可用的 Codex。将在当前 SSH 用户目录安装独立版本，不修改系统或 VS Code 插件。"
        } else {
            "检测到 $detected，与 App 固定版本 ${BuildConfig.PINNED_CODEX_VERSION} 不一致。"
        }
        _state.update {
            it.copy(
                connection = ConnectionState(ConnectionPhase.Disconnected, "需要安装 Codex"),
                remoteSetup = RemoteSetupPrompt(
                    title = if (detected == null) "安装远程 Codex" else "安装兼容版本",
                    detail = detail,
                    os = environment.os,
                    architecture = environment.architecture,
                    home = environment.home,
                    detectedVersion = detected,
                ),
                setupInProgress = false,
                setupProgress = "",
                loading = false,
            )
        }
        return null
    }

    private suspend fun loadConnectedSession(profile: ServerProfile): ConnectedSession {
        val version = client.connect(profile)
        val models = client.listModels()
        val threads = client.listThreads()
        val preferredListing = runCatching {
            client.listDirectories(profile.workspace.takeIf { it.isNotBlank() })
        }
        val fallbackListing = if (preferredListing.isFailure && profile.workspace.isNotBlank()) {
            runCatching { client.listDirectories(null) }
        } else {
            preferredListing
        }
        return ConnectedSession(
            version = version,
            models = models,
            threads = threads,
            workspace = fallbackListing.getOrNull(),
            workspaceError = preferredListing.exceptionOrNull()?.message,
        )
    }

    private fun showConnected(profile: ServerProfile, connected: ConnectedSession) {
        val defaultModel = connected.models.firstOrNull { it.isDefault } ?: connected.models.firstOrNull()
        val pinned = isPinnedVersion(connected.version)
        val versionMessage = if (pinned) {
            "已连接 · Codex ${BuildConfig.PINNED_CODEX_VERSION}"
        } else {
            "已连接 · ${connected.version}"
        }
        _state.update {
            it.copy(
                screen = AppScreen.Threads,
                connection = ConnectionState(ConnectionPhase.Connected, versionMessage, connected.version),
                threads = connected.threads,
                models = connected.models,
                selectedModel = it.selectedModel ?: defaultModel?.model,
                selectedEffort = it.selectedEffort ?: defaultModel?.defaultEffort,
                approvalMode = profile.approvalMode,
                sandbox = profile.approvalMode.sandbox,
                workspacePickerVisible = true,
                workspaceLoading = false,
                workspaceCurrentPath = connected.workspace?.currentPath
                    ?: profile.workspace.ifBlank { "/" },
                workspaceParentPath = connected.workspace?.parentPath,
                workspaceDirectories = connected.workspace?.directories.orEmpty(),
                workspaceError = connected.workspaceError,
                loading = false,
                remoteSetup = null,
                setupInProgress = false,
                diagnostic = if (!pinned) {
                    "服务器 CLI 与客户端固定版本 ${BuildConfig.PINNED_CODEX_VERSION} 不一致"
                } else it.diagnostic,
            )
        }
    }

    private fun currentProfile(): ServerProfile? {
        val state = _state.value
        return state.profiles.firstOrNull { it.id == state.selectedProfileId }
    }

    private fun persistProfiles() {
        val state = _state.value
        store.save(StoredProfiles(state.profiles, state.selectedProfileId))
    }

    private fun showConnectionError(error: Throwable) {
        _state.update {
            it.copy(
                connection = ConnectionState(ConnectionPhase.Failed, error.message ?: "连接失败"),
                loading = false,
                error = error.message ?: "连接失败",
            )
        }
    }

    private fun showError(error: Throwable) {
        _state.update {
            it.copy(loading = false, submitting = false, error = error.message ?: "操作失败")
        }
    }

    private fun isPinnedVersion(userAgent: String): Boolean {
        val version = Regex.escape(BuildConfig.PINNED_CODEX_VERSION)
        return Regex("(^|[/\\s])$version(?=$|[\\s(])").containsMatchIn(userAgent)
    }

    companion object {
        private const val MAX_ATTACHMENT_BYTES = 20L * 1024 * 1024
    }
}

private data class ConnectedSession(
    val version: String,
    val models: List<top.asdb.codexremote.data.CodexModel>,
    val threads: List<top.asdb.codexremote.data.CodexThread>,
    val workspace: RemoteDirectoryListing?,
    val workspaceError: String?,
)
