package top.asdb.codexremote

import android.app.Application
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.asdb.codexremote.codex.CodexAppServerClient
import top.asdb.codexremote.codex.CodexConnectionManager
import top.asdb.codexremote.codex.CodexEventReducer
import top.asdb.codexremote.codex.ProfileOperationTracker
import top.asdb.codexremote.codex.ProfiledCodexApproval
import top.asdb.codexremote.codex.ProfiledCodexConnectionEvent
import top.asdb.codexremote.codex.ProfiledCodexNotification
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
import java.util.concurrent.ConcurrentHashMap

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val store = ProfileStore(application)
    private val connections = CodexConnectionManager(viewModelScope)
    private val loaded = store.load()
    private val saved = loaded.copy(profiles = loaded.profiles.map(::normalizeProfile))
    private val initialProfileId = saved.selectedProfileId
        ?.takeIf { selected -> saved.profiles.any { it.id == selected } }
        ?: saved.profiles.firstOrNull()?.id
    private val initialProfile = saved.profiles.firstOrNull { it.id == initialProfileId }
    private val fingerprintProfiles = mutableMapOf<String, ServerProfile>()
    private val setupProfiles = mutableMapOf<String, ServerProfile>()
    private val fingerprintJobs = mutableMapOf<String, Job>()
    private val connectionJobs = mutableMapOf<String, Job>()
    private val setupJobs = mutableMapOf<String, Job>()
    private val disconnectJobs = mutableMapOf<String, Job>()
    private val sessionSnapshots = mutableMapOf<String, SessionSnapshot>()
    private val pendingApprovalsByProfile = mutableMapOf<String, List<ApprovalPrompt>>()
    private val setupStates = ConcurrentHashMap<String, SetupUiState>()
    private val pendingFingerprints = mutableMapOf<String, String>()
    /** Resolved executable for a managed profile; keeps later saves from replacing its client. */
    private val effectiveProfiles = mutableMapOf<String, ServerProfile>()
    private val operations = ProfileOperationTracker()
    private var fingerprintDialogProfileId: String? = null

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
        if (saved != loaded) store.save(saved)
        saved.profiles.forEach { connections.register(it) }
        initialProfile?.let { connections.select(it) }
        viewModelScope.launch {
            connections.states.collect { states ->
                _state.update { current ->
                    val merged = current.connectionStates.toMutableMap()
                    states.forEach { (profileId, remoteState) ->
                        val localState = merged[profileId]
                        val keepLocalOperation = disconnectJobs[profileId]?.isActive == true ||
                            (remoteState.phase == ConnectionPhase.Disconnected &&
                                localState?.phase in setOf(
                                    ConnectionPhase.Probing,
                                    ConnectionPhase.Connecting,
                                    ConnectionPhase.Installing,
                                ))
                        if (!keepLocalOperation) merged[profileId] = remoteState
                    }
                    current.copy(
                        connectionStates = merged,
                        connection = merged[current.selectedProfileId] ?: current.connection,
                    )
                }
            }
        }
        viewModelScope.launch {
            connections.notifications.collect { event ->
                reduceProfileNotification(event)
            }
        }
        viewModelScope.launch {
            connections.approvals.collect { event ->
                receiveProfileApproval(event)
            }
        }
        viewModelScope.launch {
            connections.diagnostics.collect { event ->
                if (isActiveProfile(event.profileId)) {
                    _state.update { it.copy(diagnostic = event.value.message) }
                }
            }
        }
        viewModelScope.launch {
            connections.closed.collect { event ->
                handleProfileClosed(event)
            }
        }
    }

    override fun onCleared() {
        fingerprintJobs.values.forEach(Job::cancel)
        connectionJobs.values.forEach(Job::cancel)
        setupJobs.values.forEach(Job::cancel)
        disconnectJobs.values.forEach(Job::cancel)
        connections.close()
        super.onCleared()
    }

    fun saveProfile(profile: ServerProfile) {
        val normalized = normalizeProfile(profile)
        val before = _state.value
        val existing = before.profiles.firstOrNull { it.id == normalized.id }
        val identityChanged = existing != null && !sameConnectionIdentity(existing, normalized)
        val switching = before.selectedProfileId != normalized.id
        if (identityChanged) {
            invalidateProfile(normalized.id)
            fingerprintJobs.remove(normalized.id)?.cancel()
            connectionJobs.remove(normalized.id)?.cancel()
            setupJobs.remove(normalized.id)?.cancel()
            setupStates.remove(normalized.id)
            pendingFingerprints.remove(normalized.id)
            fingerprintProfiles.remove(normalized.id)
            pendingApprovalsByProfile.remove(normalized.id)
            sessionSnapshots.remove(normalized.id)
            effectiveProfiles.remove(normalized.id)
        }
        if (switching) {
            before.selectedProfileId?.let { sessionSnapshots[it] = SessionSnapshot.capture(before) }
        }
        // Registering a changed identity intentionally replaces the old client. The local state is
        // reset below so the UI cannot continue presenting a closed SSH session as connected.
        val connectionProfile = if (!identityChanged && normalized.remoteCommand == RemoteBootstrap.MANAGED_REMOTE_COMMAND) {
            effectiveProfiles[normalized.id]?.let { normalized.copy(remoteCommand = it.remoteCommand) } ?: normalized
        } else {
            normalized
        }
        connections.register(connectionProfile)
        connections.select(normalized.id)
        _state.update { current ->
            val profiles = current.profiles.toMutableList()
            val index = profiles.indexOfFirst { it.id == normalized.id }
            if (index >= 0) profiles[index] = normalized else profiles += normalized
            val connection = if (identityChanged) {
                ConnectionState()
            } else {
                current.connectionStates[normalized.id]
                    ?: connections.states.value[normalized.id]
                    ?: ConnectionState()
            }
            val base = current.copy(profiles = profiles, selectedProfileId = normalized.id)
            if (switching || identityChanged) {
                restoreProfileState(base, normalized, connection)
            } else {
                base.copy(
                    approvalMode = normalized.approvalMode,
                    sandbox = normalized.approvalMode.sandbox,
                    connection = if (current.selectedProfileId == normalized.id) connection else current.connection,
                )
            }
        }
        persistProfiles()
    }

    fun newProfile(): ServerProfile = ServerProfile(
        id = UUID.randomUUID().toString(),
        name = "新服务器",
        username = "root",
    )

    fun selectProfile(id: String) {
        val profile = _state.value.profiles.firstOrNull { it.id == id } ?: return
        val previousId = _state.value.selectedProfileId
        if (previousId != id) previousId?.let { sessionSnapshots[it] = SessionSnapshot.capture(_state.value) }
        // loadConnectedSession may have resolved the managed command to a concrete executable.
        // Select the already-connected entry by id; re-registering the original managed command
        // here would replace and close that client immediately after a successful connection.
        connections.select(profile.id)
        val connection = connections.states.value[id]
            ?: _state.value.connectionStates[id]
            ?: ConnectionState()
        _state.update { current ->
            restoreProfileState(current.copy(selectedProfileId = id), profile, connection)
        }
        persistProfiles()
        if (_state.value.connection.phase == ConnectionPhase.Connected) refreshThreads(silent = true)
    }

    fun deleteProfile(id: String) {
        val wasSelected = _state.value.selectedProfileId == id
        invalidateProfile(id)
        sessionSnapshots.remove(id)
        pendingApprovalsByProfile.remove(id)
        setupStates.remove(id)
        setupProfiles.remove(id)
        effectiveProfiles.remove(id)
        pendingFingerprints.remove(id)
        fingerprintProfiles.remove(id)
        if (fingerprintDialogProfileId == id) fingerprintDialogProfileId = null
        fingerprintJobs.remove(id)?.cancel()
        connectionJobs.remove(id)?.cancel()
        setupJobs.remove(id)?.cancel()
        disconnectJobs.remove(id)?.cancel()
        _state.update { current ->
            val profiles = current.profiles.filterNot { it.id == id }
            val selected = if (current.selectedProfileId == id) profiles.firstOrNull()?.id else current.selectedProfileId
            if (!wasSelected) return@update current.copy(
                profiles = profiles,
                connectionStates = current.connectionStates - id,
            )
            val nextProfile = profiles.firstOrNull { it.id == selected }
            if (nextProfile == null) {
                clearSessionState(current.copy(
                    profiles = profiles,
                    selectedProfileId = null,
                    connectionStates = current.connectionStates - id,
                ))
            } else {
                val connection = connections.states.value[selected]
                    ?: current.connectionStates[selected]
                    ?: ConnectionState()
                restoreProfileState(
                    current.copy(
                        profiles = profiles,
                        selectedProfileId = selected,
                        connectionStates = current.connectionStates - id,
                    ),
                    nextProfile,
                    connection,
                )
            }
        }
        viewModelScope.launch {
            // A delete/recreate with the same id must not remove the replacement entry.
            if (_state.value.profiles.none { it.id == id }) connections.remove(id)
        }
        _state.value.selectedProfileId?.let(connections::select)
        persistProfiles()
    }

    fun probeFingerprint(profile: ServerProfile) {
        if (fingerprintJobs[profile.id]?.isActive == true ||
            connectionJobs[profile.id]?.isActive == true || setupJobs[profile.id]?.isActive == true
        ) return
        val normalized = normalizeProfile(profile)
        if (_state.value.selectedProfileId != normalized.id ||
            _state.value.profiles.none { it.id == normalized.id } ||
            _state.value.profiles.firstOrNull { it.id == normalized.id }?.let {
                !sameConnectionIdentity(it, normalized)
            } == true
        ) {
            saveProfile(normalized)
        }
        val ticket = operations.begin(normalized.id, "fingerprint")
        fingerprintProfiles[normalized.id] = normalized
        pendingFingerprints.remove(normalized.id)
        fingerprintDialogProfileId = normalized.id
        updateProfileConnection(normalized.id, ConnectionState(ConnectionPhase.Probing, "正在读取 SSH 主机指纹"))
        _state.update { current ->
            if (current.selectedProfileId == normalized.id) {
                current.copy(error = null, pendingFingerprint = null)
            } else current
        }
        fingerprintJobs[normalized.id] = viewModelScope.launch {
            try {
                val fingerprint = connections.probeFingerprint(normalized)
                if (!operations.isCurrent(ticket)) return@launch
                pendingFingerprints[normalized.id] = fingerprint
                updateProfileConnection(
                    normalized.id,
                    ConnectionState(ConnectionPhase.Disconnected, "请核对服务器指纹"),
                )
                if (fingerprintDialogProfileId == normalized.id && isActiveProfile(normalized.id)) {
                    _state.update { current ->
                        if (current.selectedProfileId == normalized.id) {
                            current.copy(
                                pendingFingerprint = fingerprint,
                                connection = ConnectionState(ConnectionPhase.Disconnected, "请核对服务器指纹"),
                            )
                        } else current
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (operations.isCurrent(ticket)) showConnectionError(error, normalized.id)
            } finally {
                operations.finish(ticket)
                if (fingerprintJobs[normalized.id] === currentCoroutineContext()[Job]) {
                    fingerprintJobs.remove(normalized.id)
                }
            }
        }
    }

    fun trustFingerprint() {
        val profileId = fingerprintDialogProfileId ?: return
        val profile = fingerprintProfiles[profileId] ?: return
        val fingerprint = pendingFingerprints[profileId] ?: _state.value.pendingFingerprint ?: return
        val trusted = profile.copy(hostFingerprint = fingerprint)
        pendingFingerprints.remove(profileId)
        fingerprintProfiles.remove(profileId)
        fingerprintDialogProfileId = null
        _state.update { it.copy(pendingFingerprint = null) }
        saveProfile(trusted)
        connect(trusted)
    }

    fun rejectFingerprint() {
        val profileId = fingerprintDialogProfileId
        profileId?.let {
            fingerprintProfiles.remove(it)
            pendingFingerprints.remove(it)
            updateProfileConnection(it, ConnectionState(ConnectionPhase.Disconnected, "未连接"))
        }
        fingerprintDialogProfileId = null
        _state.update { it.copy(pendingFingerprint = null) }
    }

    fun connect(profile: ServerProfile) {
        connectProfile(profile, makeActive = true)
    }

    private fun connectProfile(profile: ServerProfile, makeActive: Boolean) {
        val normalized = normalizeProfile(profile)
        if (connectionJobs[normalized.id]?.isActive == true || setupJobs[normalized.id]?.isActive == true ||
            fingerprintJobs[normalized.id]?.isActive == true || disconnectJobs[normalized.id]?.isActive == true
        ) return
        invalidateProfile(normalized.id)
        if (makeActive) {
            saveProfile(normalized)
        } else {
            val connectionProfile = if (normalized.remoteCommand == RemoteBootstrap.MANAGED_REMOTE_COMMAND) {
                effectiveProfiles[normalized.id]?.let { normalized.copy(remoteCommand = it.remoteCommand) } ?: normalized
            } else normalized
            connections.register(connectionProfile)
        }
        if (normalized.hostFingerprint.isBlank()) {
            if (makeActive) probeFingerprint(normalized)
            return
        }
        if (makeActive) {
            _state.update {
                it.copy(
                    connection = ConnectionState(ConnectionPhase.Connecting, "正在检测远程 Codex"),
                    loading = true,
                    error = null,
                    remoteSetup = null,
                    setupProgress = "",
                    setupProgressPercent = 0,
                )
            }
        }
        updateProfileConnection(normalized.id, ConnectionState(ConnectionPhase.Connecting, "正在检测远程 Codex"))
        val ticket = operations.begin(normalized.id, "connect")
        val job = viewModelScope.launch {
            try {
                val effectiveProfile = prepareRemote(normalized) ?: return@launch
                if (isCurrent(ticket) && isActiveProfile(normalized.id)) {
                    _state.update {
                        it.copy(connection = ConnectionState(ConnectionPhase.Connecting, "正在启动 Codex app-server"))
                    }
                }
                val connected = loadConnectedSession(effectiveProfile)
                if (isCurrent(ticket)) showConnected(normalized, connected)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isCurrent(ticket)) {
                    val expectedClient = connections.client(normalized.id)
                    connections.disconnect(normalized.id, expectedClient)
                    if (isCurrent(ticket)) showConnectionError(error, normalized.id)
                }
            } finally {
                operations.finish(ticket)
                if (connectionJobs[normalized.id] === currentCoroutineContext()[Job]) {
                    connectionJobs.remove(normalized.id)
                }
            }
        }
        connectionJobs[normalized.id] = job
    }

    fun installRemoteSetup() {
        val profileId = _state.value.selectedProfileId ?: return
        if (setupJobs[profileId]?.isActive == true || connectionJobs[profileId]?.isActive == true ||
            fingerprintJobs[profileId]?.isActive == true || disconnectJobs[profileId]?.isActive == true
        ) return
        val profile = setupProfiles[profileId] ?: return
        val ticket = operations.begin(profileId, "setup")
        updateSetupState(profileId) { it.copy(inProgress = true, progress = "准备安装", percent = 0) }
        _state.update {
            it.copy(
                connection = ConnectionState(ConnectionPhase.Installing, "正在安装远程 Codex"),
                setupInProgress = true,
                setupProgress = "准备安装",
                setupProgressPercent = 0,
                loading = true,
                error = null,
            )
        }
        updateProfileConnection(profileId, ConnectionState(ConnectionPhase.Installing, "正在安装远程 Codex"))
        val job = viewModelScope.launch {
            try {
                connections.installRemoteDetailed(profile) { progress ->
                    if (operations.isCurrent(ticket)) {
                        updateSetupState(profileId) {
                            it.copy(inProgress = true, progress = progress.message, percent = progress.percent)
                        }
                        if (isActiveProfile(profileId)) {
                            _state.update {
                                it.copy(
                                    setupProgress = progress.message,
                                    setupProgressPercent = progress.percent,
                                )
                            }
                        }
                    }
                }
                val verified = connections.inspectRemote(profile)
                check(verified.compatibleCommand(BuildConfig.PINNED_CODEX_VERSION) != null) {
                    "安装完成，但未检测到 Codex ${BuildConfig.PINNED_CODEX_VERSION}"
                }
                if (!operations.isCurrent(ticket)) return@launch
                setupProfiles.remove(profileId)
                setupStates.remove(profileId)
                if (isActiveProfile(profileId)) {
                    _state.update {
                        it.copy(
                            remoteSetup = null,
                            setupInProgress = false,
                            setupProgress = "安装完成",
                            setupProgressPercent = 100,
                            loading = false,
                        )
                    }
                }
                setupJobs.remove(profileId)
                connectProfile(profile, makeActive = isActiveProfile(profileId))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (operations.isCurrent(ticket)) {
                    updateSetupState(profileId) {
                        it.copy(inProgress = false, progress = "安装失败", percent = it.percent)
                    }
                    updateProfileConnection(profileId, ConnectionState(ConnectionPhase.Failed, "远程 Codex 安装失败"))
                    if (isActiveProfile(profileId)) {
                        _state.update {
                            it.copy(
                                connection = ConnectionState(ConnectionPhase.Failed, "远程 Codex 安装失败"),
                                setupInProgress = false,
                                loading = false,
                                error = error.message ?: "远程 Codex 安装失败",
                            )
                        }
                    }
                }
            } finally {
                operations.finish(ticket)
                if (setupJobs[profileId] === currentCoroutineContext()[Job]) {
                    setupJobs.remove(profileId)
                }
            }
        }
        setupJobs[profileId] = job
    }

    fun cancelRemoteSetup() {
        val profileId = _state.value.selectedProfileId ?: return
        if (setupJobs[profileId]?.isActive == true) return
        invalidateProfile(profileId)
        setupProfiles.remove(profileId)
        setupStates.remove(profileId)
        updateProfileConnection(profileId, ConnectionState(ConnectionPhase.Disconnected, "未连接"))
        _state.update {
            it.copy(
                remoteSetup = null,
                setupProgress = "",
                setupProgressPercent = 0,
                loading = false,
                connection = ConnectionState(ConnectionPhase.Disconnected, "未连接"),
            )
        }
    }

    fun disconnect() {
        val profileId = _state.value.selectedProfileId ?: return
        startDisconnect(profileId)
    }

    /** Return to the server switcher without tearing down the active SSH session. */
    fun showServers() {
        _state.value.selectedProfileId?.let { id ->
            invalidateLane(id, "session-navigation")
            invalidateLane(id, "thread-mutation")
            invalidateLane(id, "thread-list")
            invalidateLane(id, "workspace")
            _state.value.activeThread?.let { thread ->
                activeClient()?.cacheThread(thread, _state.value.timeline)
            }
            sessionSnapshots[id] = SessionSnapshot.capture(_state.value)
        }
        _state.update {
            it.copy(
                screen = AppScreen.Servers,
                workspacePickerVisible = false,
                approval = null,
                loading = false,
                submitting = false,
                error = null,
                diagnostic = null,
            )
        }
    }

    fun disconnectProfile(profileId: String) {
        startDisconnect(profileId)
    }

    fun setThreadSearch(value: String) {
        _state.update { it.copy(threadSearch = value) }
    }

    fun refreshThreads(silent: Boolean = false) {
        val profileId = _state.value.selectedProfileId ?: return
        val client = connections.client(profileId)?.takeIf { it.isConnected() } ?: return
        val operation = beginClientOperation(profileId, "thread-list", client) ?: return
        val search = _state.value.threadSearch
        viewModelScope.launch {
            if (!silent && isOperationVisible(operation)) {
                applySessionState(profileId) { it.copy(loading = true, error = null) }
            }
            try {
                val threads = client.listThreads(search)
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(threads = threads, loading = false) }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    if (!silent) showError(error, profileId) else _state.update { it.copy(diagnostic = error.message) }
                }
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun createThread() {
        val profile = currentProfile() ?: return
        val client = connections.client(profile.id)?.takeIf { it.isConnected() } ?: return
        val operation = beginClientOperation(profile.id, "session-navigation", client) ?: return
        val model = _state.value.selectedModel
        val approvalMode = _state.value.approvalMode
        viewModelScope.launch {
            if (isOperationVisible(operation)) applySessionState(profile.id) { it.copy(loading = true, error = null) }
            try {
                val (thread, timeline) = client.startThread(profile, model, approvalMode)
                if (isOperationCurrent(operation)) {
                    applySessionState(profile.id) {
                        it.copy(
                        screen = AppScreen.Work,
                        activeThread = thread,
                        timeline = timeline,
                        activeTurnId = null,
                        running = false,
                        aggregateDiff = "",
                        tokenUsage = null,
                        loading = false,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profile.id)
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun openThread(thread: top.asdb.codexremote.data.CodexThread) {
        val profileId = _state.value.selectedProfileId ?: return
        val client = connections.client(profileId)?.takeIf { it.isConnected() } ?: return
        val operation = beginClientOperation(profileId, "session-navigation", client) ?: return
        val approvalMode = _state.value.approvalMode
        val cached = client.cachedThread(thread.id) ?: client.cachedThreadStale(thread.id)
        cached?.takeIf { isOperationVisible(operation) }?.let { (cachedThread, timeline) ->
            val activeTurn = timeline.lastOrNull { it.status == "inProgress" }?.turnId
            applySessionState(profileId) {
                it.copy(
                    screen = AppScreen.Work,
                    activeThread = cachedThread,
                    timeline = timeline,
                    activeTurnId = cachedThread.activeTurnId ?: activeTurn,
                    running = cachedThread.activeTurnId != null || activeTurn != null || cachedThread.status == "active",
                    aggregateDiff = "",
                    tokenUsage = null,
                    // The snapshot is display-only until thread/resume confirms the remote context.
                    loading = true,
                )
            }
        }
        viewModelScope.launch {
            if (isOperationVisible(operation)) {
                applySessionState(profileId) { it.copy(loading = true, error = null) }
            }
            // `thread/resume` establishes the app-server's active thread context. Do not silently
            // replace it with `thread/read`, which is a read-only payload and cannot safely accept
            // subsequent turns or steering.
            try {
                val (loaded, timeline) = client.openThread(thread.id, approvalMode)
                if (isOperationCurrent(operation)) {
                    val activeTurn = timeline.lastOrNull { it.status == "inProgress" }?.turnId
                    applySessionState(profileId) {
                        it.copy(
                            screen = AppScreen.Work,
                            activeThread = loaded,
                            timeline = timeline,
                            activeTurnId = loaded.activeTurnId ?: activeTurn,
                            running = loaded.activeTurnId != null || activeTurn != null || loaded.status == "active",
                            aggregateDiff = "",
                            tokenUsage = null,
                            loading = false,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    applySessionState(profileId) {
                        it.copy(loading = false, submitting = false, error = error.message ?: "无法恢复会话")
                    }
                }
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun backToThreads() {
        if (_state.value.approvalQueue.isNotEmpty()) {
            showError(IllegalStateException("请先处理当前审批请求"))
            return
        }
        val profileId = _state.value.selectedProfileId
        profileId?.let {
            invalidateLane(it, "session-navigation")
            invalidateLane(it, "thread-mutation")
        }
        _state.value.activeThread?.let { thread ->
            activeClient()?.cacheThread(thread, _state.value.timeline)
        }
        _state.update {
            it.copy(
                screen = AppScreen.Threads,
                approval = null,
                approvalQueue = emptyList(),
                loading = false,
                submitting = false,
            ).also { updated ->
                profileId?.let { id -> sessionSnapshots[id] = SessionSnapshot.capture(updated) }
            }
        }
        profileId?.let { pendingApprovalsByProfile[it] = emptyList() }
        refreshThreads(silent = true)
    }

    fun send(text: String) {
        val clean = text.trim()
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val thread = current.activeThread ?: return
        val client = activeClient() ?: return
        if (clean.isBlank() && current.attachments.isEmpty()) return
        if (current.submitting) return
        if (current.running && current.activeTurnId == null) {
            showError(IllegalStateException("当前回合仍在运行，尚未收到回合 ID，请稍后再试"))
            return
        }
        val operation = beginClientOperation(profileId, "send", client) ?: return
        applySessionState(profileId) { it.copy(submitting = true, error = null) }
        viewModelScope.launch {
            try {
                val activeTurn = current.activeTurnId
                val turnId = if (current.running && activeTurn != null) {
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
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) {
                        it.copy(
                        activeTurnId = turnId.ifBlank { it.activeTurnId },
                        running = true,
                        submitting = false,
                        attachments = emptyList(),
                        composerClearNonce = it.composerClearNonce + 1,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationCurrent(operation)) showError(error, profileId)
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun stopTurn() {
        val profileId = _state.value.selectedProfileId ?: return
        val threadId = _state.value.activeThread?.id ?: return
        val client = activeClient() ?: return
        val turnId = _state.value.activeTurnId ?: run {
            showError(IllegalStateException("当前回合 ID 尚未可用"))
            return
        }
        val operation = beginClientOperation(profileId, "stop-turn", client) ?: return
        viewModelScope.launch {
            try {
                client.interruptTurn(threadId, turnId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun reviewChanges() {
        val profileId = _state.value.selectedProfileId ?: return
        val threadId = _state.value.activeThread?.id ?: return
        val client = activeClient() ?: return
        val operation = beginClientOperation(profileId, "review", client) ?: return
        viewModelScope.launch {
            try {
                client.startReview(threadId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun rollbackActiveThread() {
        val profileId = _state.value.selectedProfileId ?: return
        val threadId = _state.value.activeThread?.id ?: return
        val client = activeClient() ?: return
        if (_state.value.running) {
            showError(IllegalStateException("回合运行中，完成或停止后才能回退会话历史"))
            return
        }
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        viewModelScope.launch {
            try {
                val (thread, timeline) = client.rollbackThread(threadId)
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) {
                        it.copy(
                            activeThread = thread,
                            timeline = timeline,
                            activeTurnId = thread.activeTurnId,
                            running = thread.status == "active" || thread.activeTurnId != null,
                            aggregateDiff = "",
                            tokenUsage = null,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun archiveActiveThread() {
        val profileId = _state.value.selectedProfileId ?: return
        val threadId = _state.value.activeThread?.id ?: return
        val client = activeClient() ?: return
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        viewModelScope.launch {
            try {
                client.archiveThread(threadId)
                if (isOperationCurrent(operation)) {
                    pendingApprovalsByProfile[profileId] = emptyList()
                    applySessionState(profileId) {
                        it.copy(
                            screen = AppScreen.Threads,
                            activeThread = null,
                            timeline = emptyList(),
                            activeTurnId = null,
                            running = false,
                            approval = null,
                            approvalQueue = emptyList(),
                            aggregateDiff = "",
                            tokenUsage = null,
                        )
                    }
                    if (isActiveProfile(profileId)) refreshThreads(silent = true)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun renameActiveThread(name: String) {
        val profileId = _state.value.selectedProfileId ?: return
        val thread = _state.value.activeThread ?: return
        val client = activeClient() ?: return
        val clean = name.trim()
        if (clean.isBlank()) return
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        viewModelScope.launch {
            try {
                client.setThreadName(thread.id, clean)
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) {
                        if (it.activeThread?.id == thread.id) {
                            it.copy(activeThread = it.activeThread.copy(title = clean))
                        } else it
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun answerApproval(accept: Boolean, answers: Map<String, String> = emptyMap()) {
        val profileId = _state.value.selectedProfileId ?: return
        val prompt = _state.value.approval ?: return
        val client = activeClient() ?: return
        val operation = beginClientOperation(profileId, "approval", client) ?: return
        viewModelScope.launch {
            try {
                client.answerApproval(prompt, accept, answers)
                val remaining = pendingApprovalsByProfile[profileId].orEmpty()
                    .filterNot { it.requestId == prompt.requestId }
                pendingApprovalsByProfile[profileId] = remaining
                if (isOperationVisible(operation)) {
                    _state.update { current ->
                        current.copy(approvalQueue = remaining, approval = remaining.firstOrNull())
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun dismissApproval() {
        answerApproval(false)
    }

    fun uploadAttachment(context: Context, uri: Uri) {
        val profileId = _state.value.selectedProfileId ?: return
        currentProfile() ?: return
        val client = activeClient() ?: return
        val operation = beginClientOperation(profileId, "upload", client, exclusive = false) ?: return
        viewModelScope.launch {
            if (isOperationVisible(operation)) applySessionState(profileId) { it.copy(loading = true, error = null) }
            try {
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
                val attachment = PendingAttachment(content.first, remotePath, content.second)
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) {
                        it.copy(attachments = it.attachments + attachment, loading = false)
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationCurrent(operation)) showError(error, profileId)
            } finally {
                finishClientOperation(operation)
            }
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
        val profileId = _state.value.selectedProfileId ?: return
        val client = activeClient()?.takeIf { it.isConnected() } ?: return
        val operation = beginClientOperation(profileId, "workspace", client) ?: return
        _state.update {
            it.copy(workspacePickerVisible = true, workspaceLoading = true, workspaceError = null)
        }
        viewModelScope.launch {
            try {
                val listing = client.listDirectories(path)
                if (isOperationVisible(operation)) {
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
                if (isOperationCurrent(operation) && !isActiveProfile(profileId)) {
                    sessionSnapshots[profileId] = (sessionSnapshots[profileId] ?: SessionSnapshot()).copy(
                        workspaceCurrentPath = listing.currentPath,
                        workspaceParentPath = listing.parentPath,
                        workspaceDirectories = listing.directories,
                        workspaceError = null,
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(workspaceLoading = false, workspaceError = error.message ?: "无法读取目录")
                    }
                }
            } finally {
                finishClientOperation(operation)
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

    private fun beginClientOperation(
        profileId: String,
        lane: String,
        client: CodexAppServerClient,
        exclusive: Boolean = true,
    ): ClientOperation? {
        val generation = client.currentGeneration() ?: return null
        return ClientOperation(
            ticket = operations.begin(profileId, lane, exclusive),
            client = client,
            generation = generation,
        )
    }

    private fun isCurrent(ticket: ProfileOperationTracker.Ticket): Boolean = operations.isCurrent(ticket)

    private fun isOperationCurrent(operation: ClientOperation): Boolean =
        operations.isCurrent(operation.ticket) &&
            connections.client(operation.ticket.profileId) === operation.client &&
            operation.client.isGenerationActive(operation.generation)

    private fun isOperationVisible(operation: ClientOperation): Boolean =
        isOperationCurrent(operation) && isActiveProfile(operation.ticket.profileId)

    private fun finishClientOperation(operation: ClientOperation) {
        operations.finish(operation.ticket)
    }

    private fun invalidateProfile(profileId: String) {
        operations.invalidateProfile(profileId)
    }

    private fun invalidateLane(profileId: String, lane: String) {
        operations.invalidateLane(profileId, lane)
    }

    private fun applySessionState(profileId: String, transform: (AppUiState) -> AppUiState) {
        if (isActiveProfile(profileId)) {
            _state.update { current ->
                if (current.selectedProfileId != profileId) return@update current
                transform(current).also { updated ->
                    sessionSnapshots[profileId] = SessionSnapshot.capture(updated)
                }
            }
            return
        }
        val profile = _state.value.profiles.firstOrNull { it.id == profileId }
        val base = (sessionSnapshots[profileId] ?: SessionSnapshot()).restore(
            AppUiState(
                selectedProfileId = profileId,
                approvalMode = profile?.approvalMode ?: ApprovalMode.RequestApproval,
                sandbox = (profile?.approvalMode ?: ApprovalMode.RequestApproval).sandbox,
            ),
        )
        sessionSnapshots[profileId] = SessionSnapshot.capture(transform(base))
    }

    private fun restoreProfileState(
        base: AppUiState,
        profile: ServerProfile,
        connection: ConnectionState,
    ): AppUiState {
        val setup = setupState(profile.id)
        val pendingFingerprint = pendingFingerprints[profile.id]
        fingerprintDialogProfileId = profile.id.takeIf { pendingFingerprint != null }
        val cleanBase = base.copy(
            approvalMode = profile.approvalMode,
            sandbox = profile.approvalMode.sandbox,
            connection = connection,
            connectionStates = base.connectionStates + (profile.id to connection),
        )
        val restored = sessionSnapshots[profile.id]?.restore(cleanBase) ?: clearSessionFields(cleanBase)
        val approvals = pendingApprovalsByProfile[profile.id].orEmpty()
        return restored.copy(
            selectedProfileId = profile.id,
            screen = if (connection.phase == ConnectionPhase.Connected) AppScreen.Threads else AppScreen.Servers,
            connection = connection,
            pendingFingerprint = pendingFingerprint,
            remoteSetup = setup?.prompt,
            setupInProgress = setup?.inProgress == true,
            setupProgress = setup?.progress.orEmpty(),
            setupProgressPercent = setup?.percent ?: 0,
            approvalMode = profile.approvalMode,
            sandbox = profile.approvalMode.sandbox,
            approvalQueue = approvals,
            approval = approvals.firstOrNull(),
            workspacePickerVisible = false,
            workspaceLoading = false,
            submitting = false,
            error = null,
            diagnostic = null,
            loading = setup?.inProgress == true ||
                connection.phase in setOf(
                    ConnectionPhase.Probing,
                    ConnectionPhase.Connecting,
                    ConnectionPhase.Installing,
                ),
        )
    }

    private fun clearSessionState(base: AppUiState): AppUiState = clearSessionFields(base).copy(
        screen = AppScreen.Servers,
        connection = ConnectionState(),
        pendingFingerprint = null,
        remoteSetup = null,
        setupInProgress = false,
        setupProgress = "",
        setupProgressPercent = 0,
        approvalMode = ApprovalMode.RequestApproval,
        sandbox = ApprovalMode.RequestApproval.sandbox,
    )

    private fun clearSessionFields(base: AppUiState): AppUiState = base.copy(
        threads = emptyList(),
        threadSearch = "",
        activeThread = null,
        timeline = emptyList(),
        activeTurnId = null,
        running = false,
        submitting = false,
        loading = false,
        models = emptyList(),
        selectedModel = null,
        selectedEffort = null,
        workspacePickerVisible = false,
        workspaceLoading = false,
        workspaceCurrentPath = "",
        workspaceParentPath = null,
        workspaceDirectories = emptyList(),
        workspaceError = null,
        approval = null,
        approvalQueue = emptyList(),
        attachments = emptyList(),
        aggregateDiff = "",
        tokenUsage = null,
        error = null,
        diagnostic = null,
    )

    private fun startDisconnect(profileId: String) {
        if (disconnectJobs[profileId]?.isActive == true) return
        val expectedClient = connections.client(profileId)
        invalidateProfile(profileId)
        fingerprintJobs[profileId]?.cancel()
        connectionJobs[profileId]?.cancel()
        setupJobs[profileId]?.cancel()
        sessionSnapshots.remove(profileId)
        effectiveProfiles.remove(profileId)
        pendingApprovalsByProfile.remove(profileId)
        setupProfiles.remove(profileId)
        setupStates.remove(profileId)
        pendingFingerprints.remove(profileId)
        fingerprintProfiles.remove(profileId)
        if (fingerprintDialogProfileId == profileId) fingerprintDialogProfileId = null

        val disconnecting = ConnectionState(ConnectionPhase.Connecting, "正在断开连接")
        updateProfileConnection(profileId, disconnecting)
        if (isActiveProfile(profileId)) {
            _state.update { current ->
                clearSessionFields(current).copy(
                    screen = AppScreen.Servers,
                    connection = disconnecting,
                    connectionStates = current.connectionStates + (profileId to disconnecting),
                    pendingFingerprint = null,
                    remoteSetup = null,
                    setupInProgress = false,
                    setupProgress = "",
                    setupProgressPercent = 0,
                )
            }
        }
        val job = viewModelScope.launch {
            try {
                connections.disconnect(profileId, expectedClient)
                if (_state.value.profiles.any { it.id == profileId }) {
                    updateProfileConnection(profileId, ConnectionState())
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (_state.value.profiles.any { it.id == profileId }) {
                    showConnectionError(error, profileId)
                }
            } finally {
                if (disconnectJobs[profileId] === currentCoroutineContext()[Job]) {
                    disconnectJobs.remove(profileId)
                }
            }
        }
        disconnectJobs[profileId] = job
    }

    private fun setupState(profileId: String): SetupUiState? = synchronized(setupStates) {
        setupStates[profileId]
    }

    private fun updateSetupState(profileId: String, transform: (SetupUiState) -> SetupUiState) {
        synchronized(setupStates) {
            val current = setupStates[profileId] ?: SetupUiState()
            setupStates[profileId] = transform(current)
        }
    }

    private fun sameConnectionIdentity(left: ServerProfile, right: ServerProfile): Boolean =
        left.host == right.host &&
            left.port == right.port &&
            left.username == right.username &&
            left.authMode == right.authMode &&
            left.password == right.password &&
            left.privateKeyPem == right.privateKeyPem &&
            left.privateKeyPassphrase == right.privateKeyPassphrase &&
            left.hostFingerprint == right.hostFingerprint &&
            left.remoteCommand == right.remoteCommand

    private fun activeClient(): CodexAppServerClient? =
        _state.value.selectedProfileId?.let(connections::client)

    private fun isActiveProfile(profileId: String): Boolean =
        _state.value.selectedProfileId == profileId

    private fun updateProfileConnection(profileId: String, connection: ConnectionState) {
        _state.update { current ->
            current.copy(
                connectionStates = current.connectionStates + (profileId to connection),
                connection = if (current.selectedProfileId == profileId) connection else current.connection,
            )
        }
    }

    private fun reduceProfileNotification(event: ProfiledCodexNotification) {
        val profileId = event.profileId
        val client = connections.client(profileId) ?: return
        val notification = event.value
        if (!client.isGenerationActive(notification.generation)) return
        applySessionState(profileId) { current ->
            CodexEventReducer.reduce(current, notification.method, notification.params)
        }
        if (notification.method == "turn/completed") {
            sessionSnapshots[profileId]?.activeThread?.let { thread ->
                client.cacheThread(thread, sessionSnapshots[profileId]?.timeline.orEmpty())
            }
            if (isActiveProfile(profileId)) refreshThreads(silent = true)
        }
    }

    private suspend fun receiveProfileApproval(event: ProfiledCodexApproval) {
        val profileId = event.profileId
        val client = connections.client(profileId) ?: return
        if (!client.isGenerationActive(event.value.generation)) return
        val approval = event.value.prompt
        val existing = pendingApprovalsByProfile[profileId].orEmpty()
        if (existing.any { it.requestId == approval.requestId }) return
        if (existing.size >= MAX_PENDING_APPROVALS) {
            // Keep an untrusted server from retaining an unbounded number of request payloads.
            runCatching { client.answerApproval(approval, accept = false) }
            if (isActiveProfile(profileId)) {
                _state.update { it.copy(diagnostic = "审批请求过多，已自动拒绝新的请求") }
            }
            return
        }
        val queue = existing + approval
        pendingApprovalsByProfile[profileId] = queue
        if (isActiveProfile(profileId)) {
            _state.update { current ->
                current.copy(approvalQueue = queue, approval = current.approval ?: queue.firstOrNull())
            }
        }
    }

    private fun handleProfileClosed(event: ProfiledCodexConnectionEvent) {
        val profileId = event.profileId
        invalidateProfile(profileId)
        val snapshot = sessionSnapshots[profileId]
        if (snapshot != null) {
            sessionSnapshots[profileId] = snapshot.copy(activeTurnId = null, running = false, loading = false, submitting = false)
        }
        pendingApprovalsByProfile.remove(profileId)
        setupStates.remove(profileId)
        if (!isActiveProfile(profileId)) return
        _state.update {
            it.copy(
                connectionStates = it.connectionStates + (profileId to ConnectionState(ConnectionPhase.Failed, event.value.message)),
                connection = ConnectionState(ConnectionPhase.Failed, event.value.message),
                running = false,
                loading = false,
                submitting = false,
                activeTurnId = null,
                approval = null,
                approvalQueue = emptyList(),
                workspacePickerVisible = false,
                workspaceLoading = false,
                remoteSetup = null,
                setupInProgress = false,
                setupProgress = "",
                setupProgressPercent = 0,
            )
        }
    }

    private suspend fun prepareRemote(profile: ServerProfile): ServerProfile? {
        if (profile.remoteCommand != RemoteBootstrap.MANAGED_REMOTE_COMMAND) return profile
        val environment = connections.inspectRemote(profile)
        environment.compatibleCommand(BuildConfig.PINNED_CODEX_VERSION)?.let { command ->
            return profile.copy(remoteCommand = command)
        }
        environment.installationProblem()?.let { problem ->
            throw IllegalStateException(problem)
        }
        setupProfiles[profile.id] = profile
        val detected = environment.detectedVersion()
        val detail = if (detected == null) {
            "服务器尚未安装可用的 Codex。将在当前 SSH 用户目录安装独立版本，不修改系统或 VS Code 插件。"
        } else {
            "检测到 $detected，与 App 固定版本 ${BuildConfig.PINNED_CODEX_VERSION} 不一致。"
        }
        val prompt = RemoteSetupPrompt(
            title = if (detected == null) "安装远程 Codex" else "安装兼容版本",
            detail = detail,
            os = environment.os,
            architecture = environment.architecture,
            home = environment.home,
            detectedVersion = detected,
        )
        updateProfileConnection(profile.id, ConnectionState(ConnectionPhase.Disconnected, "需要安装 Codex"))
        setupStates[profile.id] = SetupUiState(prompt = prompt)
        if (isActiveProfile(profile.id)) {
            _state.update {
                it.copy(
                    connection = ConnectionState(ConnectionPhase.Disconnected, "需要安装 Codex"),
                    remoteSetup = prompt,
                    setupInProgress = false,
                    setupProgress = "",
                    setupProgressPercent = 0,
                    loading = false,
                )
            }
        }
        return null
    }

    private suspend fun loadConnectedSession(profile: ServerProfile): ConnectedSession {
        effectiveProfiles[profile.id] = profile
        val client = connections.register(profile)
        val version = connections.connect(profile)
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
        setupStates.remove(profile.id)
        setupProfiles.remove(profile.id)
        pendingFingerprints.remove(profile.id)
        fingerprintProfiles.remove(profile.id)
        if (!isActiveProfile(profile.id)) {
            sessionSnapshots[profile.id] = SessionSnapshot(
                threads = connected.threads,
                models = connected.models,
                selectedModel = defaultModel?.model,
                selectedEffort = defaultModel?.defaultEffort,
                workspaceCurrentPath = connected.workspace?.currentPath ?: profile.workspace.ifBlank { "/" },
                workspaceParentPath = connected.workspace?.parentPath,
                workspaceDirectories = connected.workspace?.directories.orEmpty(),
                workspaceError = connected.workspaceError,
                loading = false,
            )
            return
        }
        // Keep the resolved command/client created by loadConnectedSession.
        connections.select(profile.id)
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
                activeThread = null,
                timeline = emptyList(),
                activeTurnId = null,
                running = false,
                submitting = false,
                attachments = emptyList(),
                aggregateDiff = "",
                tokenUsage = null,
                approvalQueue = pendingApprovalsByProfile[profile.id].orEmpty(),
                approval = pendingApprovalsByProfile[profile.id]?.firstOrNull(),
                loading = false,
                error = null,
                remoteSetup = null,
                setupInProgress = false,
                setupProgress = "",
                setupProgressPercent = 100,
                diagnostic = if (!pinned) {
                    "服务器 CLI 与客户端固定版本 ${BuildConfig.PINNED_CODEX_VERSION} 不一致"
                } else it.diagnostic,
            ).also { updated -> sessionSnapshots[profile.id] = SessionSnapshot.capture(updated) }
        }
    }

    private fun currentProfile(): ServerProfile? {
        val state = _state.value
        return state.profiles.firstOrNull { it.id == state.selectedProfileId }
    }

    private fun normalizeProfile(profile: ServerProfile): ServerProfile = profile.copy(
        name = profile.name.trim().ifBlank { profile.host.trim().ifBlank { "服务器" } },
        host = profile.host.trim(),
        username = profile.username.trim().ifBlank { "root" },
        workspace = profile.workspace.trim(),
        proxyUrl = profile.proxyUrl.trim(),
        hostFingerprint = profile.hostFingerprint.trim(),
        remoteCommand = profile.remoteCommand.trim().ifBlank { RemoteBootstrap.MANAGED_REMOTE_COMMAND },
    )

    private fun persistProfiles() {
        val state = _state.value
        store.save(StoredProfiles(state.profiles, state.selectedProfileId))
    }

    private fun showConnectionError(error: Throwable, profileId: String? = _state.value.selectedProfileId) {
        profileId ?: return
        updateProfileConnection(profileId, ConnectionState(ConnectionPhase.Failed, error.message ?: "连接失败"))
        applySessionState(profileId) {
            it.copy(
                connection = ConnectionState(ConnectionPhase.Failed, error.message ?: "连接失败"),
                loading = false,
                error = error.message ?: "连接失败",
            )
        }
    }

    private fun showError(error: Throwable, profileId: String? = _state.value.selectedProfileId) {
        profileId ?: return
        applySessionState(profileId) {
            it.copy(loading = false, submitting = false, error = error.message ?: "操作失败")
        }
    }

    private fun isPinnedVersion(userAgent: String): Boolean {
        val version = Regex.escape(BuildConfig.PINNED_CODEX_VERSION)
        return Regex("(^|[/\\s])$version(?=$|[\\s(])").containsMatchIn(userAgent)
    }

    companion object {
        private const val MAX_ATTACHMENT_BYTES = 20L * 1024 * 1024
        private const val MAX_PENDING_APPROVALS = 32
    }
}

private data class ConnectedSession(
    val version: String,
    val models: List<top.asdb.codexremote.data.CodexModel>,
    val threads: List<top.asdb.codexremote.data.CodexThread>,
    val workspace: RemoteDirectoryListing?,
    val workspaceError: String?,
)

private data class ClientOperation(
    val ticket: ProfileOperationTracker.Ticket,
    val client: CodexAppServerClient,
    val generation: Long,
)

private data class SetupUiState(
    val prompt: RemoteSetupPrompt? = null,
    val inProgress: Boolean = false,
    val progress: String = "",
    val percent: Int = 0,
)

private data class SessionSnapshot(
    val threads: List<top.asdb.codexremote.data.CodexThread> = emptyList(),
    val threadSearch: String = "",
    val models: List<top.asdb.codexremote.data.CodexModel> = emptyList(),
    val selectedModel: String? = null,
    val selectedEffort: String? = null,
    val activeThread: top.asdb.codexremote.data.CodexThread? = null,
    val timeline: List<top.asdb.codexremote.data.TimelineEntry> = emptyList(),
    val activeTurnId: String? = null,
    val running: Boolean = false,
    val submitting: Boolean = false,
    val loading: Boolean = false,
    val aggregateDiff: String = "",
    val tokenUsage: top.asdb.codexremote.data.TokenUsage? = null,
    val attachments: List<PendingAttachment> = emptyList(),
    val composerClearNonce: Int = 0,
    val workspaceCurrentPath: String = "",
    val workspaceParentPath: String? = null,
    val workspaceDirectories: List<top.asdb.codexremote.data.RemoteDirectory> = emptyList(),
    val workspaceError: String? = null,
    val error: String? = null,
    val diagnostic: String? = null,
) {
    fun restore(base: AppUiState): AppUiState = base.copy(
        threads = threads,
        threadSearch = threadSearch,
        models = models,
        selectedModel = selectedModel,
        selectedEffort = selectedEffort,
        activeThread = activeThread,
        timeline = timeline,
        activeTurnId = activeTurnId,
        running = running,
        submitting = submitting,
        loading = loading,
        aggregateDiff = aggregateDiff,
        tokenUsage = tokenUsage,
        attachments = attachments,
        composerClearNonce = composerClearNonce,
        workspaceCurrentPath = workspaceCurrentPath,
        workspaceParentPath = workspaceParentPath,
        workspaceDirectories = workspaceDirectories,
        workspaceError = workspaceError,
        error = error,
        diagnostic = diagnostic,
    )

    companion object {
        fun capture(state: AppUiState): SessionSnapshot = SessionSnapshot(
            threads = state.threads,
            threadSearch = state.threadSearch,
            models = state.models,
            selectedModel = state.selectedModel,
            selectedEffort = state.selectedEffort,
            activeThread = state.activeThread,
            timeline = state.timeline,
            activeTurnId = state.activeTurnId,
            running = state.running,
            submitting = state.submitting,
            loading = state.loading,
            aggregateDiff = state.aggregateDiff,
            tokenUsage = state.tokenUsage,
            attachments = state.attachments,
            composerClearNonce = state.composerClearNonce,
            workspaceCurrentPath = state.workspaceCurrentPath,
            workspaceParentPath = state.workspaceParentPath,
            workspaceDirectories = state.workspaceDirectories,
            workspaceError = state.workspaceError,
            error = state.error,
            diagnostic = state.diagnostic,
        )
    }
}
