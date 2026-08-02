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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.asdb.codexremote.codex.CodexAppServerClient
import top.asdb.codexremote.codex.CodexConnectionManager
import top.asdb.codexremote.codex.CodexEventReducer
import top.asdb.codexremote.codex.ResumeNotificationBuffer
import top.asdb.codexremote.codex.estimateTimelineWeightChars
import top.asdb.codexremote.codex.ProfileOperationTracker
import top.asdb.codexremote.codex.ProfiledCodexApproval
import top.asdb.codexremote.codex.ProfiledCodexConnectionEvent
import top.asdb.codexremote.codex.ProfiledCodexNotification
import top.asdb.codexremote.codex.string
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
import top.asdb.codexremote.data.ServerMetrics
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.data.StoredProfiles
import top.asdb.codexremote.data.ThreadGoal
import top.asdb.codexremote.data.ThreadGoalStatus
import top.asdb.codexremote.data.ThreadModelPreference
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.data.TurnTiming
import top.asdb.codexremote.data.hasKnownContextWindow
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import top.asdb.codexremote.ssh.RemoteBootstrap
import top.asdb.codexremote.ssh.RemoteCodexSettings
import top.asdb.codexremote.ssh.RemoteEnvironment
import top.asdb.codexremote.ssh.SshTerminalManager
import top.asdb.codexremote.ssh.SshTerminalOutputBatch
import java.io.ByteArrayOutputStream
import java.util.LinkedHashMap
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val store = ProfileStore(application)
    private val connections = CodexConnectionManager(viewModelScope)
    private val terminals = SshTerminalManager(viewModelScope)
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
    private val uninstallJobs = mutableMapOf<String, Job>()
    private val serverMetricsJobs = mutableMapOf<String, Job>()
    private val sessionNavigationJobs = mutableMapOf<String, Job>()
    private val threadHistoryJobs = mutableMapOf<String, Job>()
    private val threadMutationJobs = mutableMapOf<String, Job>()
    private var draftPersistJob: Job? = null
    private val sessionSnapshots = object : LinkedHashMap<String, SessionSnapshot>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, SessionSnapshot>?): Boolean =
            size > MAX_PROFILE_SESSION_SNAPSHOTS
    }
    private val contextUsageFallbacks = ProfileScopedContextUsageCache()
    private val subAgentNavigationStacks = ProfileScopedBackStack<SubAgentNavigationFrame>()
    private val pendingApprovalsByProfile = mutableMapOf<String, List<ApprovalPrompt>>()
    private val resumeNotificationBuffers = mutableMapOf<String, ResumeNotificationBuffer>()
    private val unsupportedGoalProfiles = mutableSetOf<String>()
    private val goalNotificationVersions = LinkedHashMap<String, Long>()
    private val setupStates = ConcurrentHashMap<String, SetupUiState>()
    private val composerDrafts = LinkedHashMap<String, String>().apply {
        loaded.composerDrafts.entries.toList().takeLast(MAX_COMPOSER_DRAFTS).forEach { (key, value) ->
            if (key.isNotBlank() && value.isNotBlank()) put(key, value.take(MAX_COMPOSER_DRAFT_CHARS))
        }
    }
    private val threadModelPreferences = LinkedHashMap<String, ThreadModelPreference>().apply {
        loaded.threadModelPreferences.entries.toList().takeLast(MAX_THREAD_MODEL_PREFERENCES)
            .forEach { (key, preference) ->
                if (key.isNotBlank() && preference.model.isNotBlank()) put(key, preference)
            }
    }
    private val completedTurnTimings = LinkedHashMap<String, TurnTiming>().apply {
        loaded.completedTurnTimings.entries.toList().takeLast(MAX_COMPLETED_TURN_TIMINGS)
            .forEach { (key, timing) ->
                if (key.isNotBlank() && timing.threadId.isNotBlank() && timing.completedAtMillis != null) {
                    put(key, timing)
                }
            }
    }
    private val pendingFingerprints = mutableMapOf<String, String>()
    /** Resolved executable for a managed profile; keeps later saves from replacing its client. */
    private val effectiveProfiles = mutableMapOf<String, ServerProfile>()
    private val operations = ProfileOperationTracker()
    private val surfacedDiagnostics = LinkedHashMap<String, Long>()
    private var fingerprintDialogProfileId: String? = null

    private val _state = MutableStateFlow(
        AppUiState(
            debugModeEnabled = DiagnosticLogger.isEnabled(),
            profiles = saved.profiles,
            selectedProfileId = initialProfileId,
            approvalMode = initialProfile?.approvalMode ?: ApprovalMode.RequestApproval,
            sandbox = (initialProfile?.approvalMode ?: ApprovalMode.RequestApproval).sandbox,
        ),
    )
    val state: StateFlow<AppUiState> = _state.asStateFlow()
    private val _turnCompletions = MutableSharedFlow<TurnCompletion>(extraBufferCapacity = 16)
    val turnCompletions: SharedFlow<TurnCompletion> = _turnCompletions.asSharedFlow()
    internal val terminalState = terminals.state
    internal val terminalOutputSignals = terminals.outputSignals

    init {
        DiagnosticLogger.info("ViewModel", "initialized profiles=${saved.profiles.size}")
        if (saved != loaded) store.save(saved)
        saved.profiles.forEach { connections.register(it) }
        initialProfile?.let { connections.select(it) }
        viewModelScope.launch {
            connections.states.collect { states ->
                _state.update { current ->
                    val merged = current.connectionStates.toMutableMap()
                    val metrics = current.serverMetrics.toMutableMap()
                    states.forEach { (profileId, remoteState) ->
                        val localState = merged[profileId]
                        val keepLocalOperation = disconnectJobs[profileId]?.isActive == true ||
                            (remoteState.phase == ConnectionPhase.Disconnected &&
                                localState?.phase in setOf(
                                    ConnectionPhase.Probing,
                                    ConnectionPhase.Connecting,
                                    ConnectionPhase.Installing,
                                )) ||
                            shouldHoldConnectedUntilSessionReady(
                                local = localState,
                                remote = remoteState,
                                preparingActiveConnection = connectionJobs[profileId]?.isActive == true &&
                                    current.selectedProfileId == profileId,
                            )
                        if (!keepLocalOperation) merged[profileId] = remoteState
                        if (remoteState.phase != ConnectionPhase.Connected) metrics.remove(profileId)
                    }
                    current.copy(
                        connectionStates = merged,
                        serverMetrics = metrics,
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
                DiagnosticLogger.warn(
                    "Remote",
                    "diagnostic profile=${profileRef(event.profileId)} ${event.value.message}",
                )
                if (isActiveProfile(event.profileId)) {
                    val diagnostic = sanitizeCodexDiagnostic(event.value.message)
                    if (shouldSurfaceCodexDiagnostic(diagnostic)) {
                        val phase = _state.value.connectionStates[event.profileId]?.phase
                            ?: _state.value.connection.phase
                        val userMessage = presentCodexDiagnostic(diagnostic, phase)
                        if (userMessage.isNotBlank() &&
                            shouldPublishDiagnostic(event.profileId, userMessage)
                        ) {
                            _state.update { it.copy(diagnostic = userMessage) }
                        }
                    }
                }
            }
        }
        viewModelScope.launch {
            connections.closed.collect { event ->
                DiagnosticLogger.warn(
                    "Connection",
                    "closed profile=${profileRef(event.profileId)} ${event.value.message}",
                )
                handleProfileClosed(event)
            }
        }
    }

    override fun onCleared() {
        persistProfiles()
        draftPersistJob?.cancel()
        fingerprintJobs.values.forEach(Job::cancel)
        connectionJobs.values.forEach(Job::cancel)
        setupJobs.values.forEach(Job::cancel)
        disconnectJobs.values.forEach(Job::cancel)
        uninstallJobs.values.forEach(Job::cancel)
        serverMetricsJobs.values.forEach(Job::cancel)
        sessionNavigationJobs.values.forEach(Job::cancel)
        threadHistoryJobs.values.forEach(Job::cancel)
        threadMutationJobs.values.forEach(Job::cancel)
        terminals.closeAll()
        connections.close()
        super.onCleared()
    }

    fun saveProfile(profile: ServerProfile) {
        val before = _state.value
        val input = normalizeProfile(profile)
        val existing = before.profiles.firstOrNull { it.id == input.id }
        val identityChanged = existing != null && !sameConnectionIdentity(existing, input)
        // These fields are managed outside the server form. Preserve them when an older form
        // draft is saved, but reset them when the profile is repointed at a different server.
        val normalized = if (existing != null && !identityChanged) {
            input.copy(
                workspacePromptShown = input.workspacePromptShown || existing.workspacePromptShown,
                preferredModel = input.preferredModel.ifBlank { existing.preferredModel },
                preferredEffort = input.preferredEffort.ifBlank { existing.preferredEffort },
                testModel = input.testModel.ifBlank { existing.testModel },
            )
        } else input
        val switching = before.selectedProfileId != normalized.id
        DiagnosticLogger.info(
            "Profile",
            "save profile=${profileRef(normalized.id)} new=${existing == null} identity_changed=$identityChanged",
        )
        if (identityChanged) {
            terminals.closeProfile(normalized.id)
            invalidateProfile(normalized.id)
            fingerprintJobs.remove(normalized.id)?.cancel()
            connectionJobs.remove(normalized.id)?.cancel()
            setupJobs.remove(normalized.id)?.cancel()
            uninstallJobs.remove(normalized.id)?.cancel()
            serverMetricsJobs.remove(normalized.id)?.cancel()
            setupStates.remove(normalized.id)
            pendingFingerprints.remove(normalized.id)
            fingerprintProfiles.remove(normalized.id)
            pendingApprovalsByProfile.remove(normalized.id)
            sessionSnapshots.remove(normalized.id)
            effectiveProfiles.remove(normalized.id)
            removeComposerDrafts(normalized.id)
            removeThreadModelPreferences(normalized.id)
            removeCompletedTurnTimings(normalized.id)
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
            val base = current.copy(
                profiles = profiles,
                selectedProfileId = normalized.id,
                serverMetrics = if (identityChanged) current.serverMetrics - normalized.id else current.serverMetrics,
            )
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
        DiagnosticLogger.info("Profile", "select profile=${profileRef(id)}")
        val previousId = _state.value.selectedProfileId
        if (previousId != id) previousId?.let {
            // A stale resume can otherwise complete after A -> B -> A and mutate A's
            // sub-agent stack after the user has started a new navigation there.
            invalidateLane(it, "session-navigation")
            sessionSnapshots[it] = SessionSnapshot.capture(_state.value)
            subAgentNavigationStacks.clear(it)
        }
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

    fun openCompletedThread(profileId: String, threadId: String) {
        if (profileId.isBlank() || threadId.isBlank()) return
        val before = _state.value
        val profile = before.profiles.firstOrNull { it.id == profileId } ?: return
        if (before.selectedProfileId == profileId && before.activeThread?.id == threadId &&
            (before.screen == AppScreen.Work || before.screen == AppScreen.AgentWork)
        ) return
        val connection = connections.states.value[profileId]
            ?: before.connectionStates[profileId]
            ?: ConnectionState()
        selectProfile(profileId)
        if (connection.phase != ConnectionPhase.Connected) {
            showError(IllegalStateException("服务器连接已断开，请重新连接后打开会话"), profileId)
            return
        }
        val current = _state.value
        val thread = current.threads.firstOrNull { it.id == threadId }
            ?: current.activeThread?.takeIf { it.id == threadId }
            ?: connections.client(profileId)?.cachedThread(threadId)?.thread
            ?: top.asdb.codexremote.data.CodexThread(
                id = threadId,
                title = "已完成的会话",
                preview = "",
                cwd = profile.workspace,
                source = "appServer",
                status = "idle",
                createdAt = 0L,
                updatedAt = 0L,
                cliVersion = connection.cliVersion.orEmpty(),
            )
        openThread(thread)
    }

    fun deleteProfile(id: String) {
        DiagnosticLogger.info("Profile", "delete profile=${profileRef(id)}")
        terminals.closeProfile(id)
        val wasSelected = _state.value.selectedProfileId == id
        invalidateProfile(id)
        sessionSnapshots.remove(id)
        contextUsageFallbacks.clear(id)
        subAgentNavigationStacks.clear(id)
        pendingApprovalsByProfile.remove(id)
        setupStates.remove(id)
        setupProfiles.remove(id)
        effectiveProfiles.remove(id)
        pendingFingerprints.remove(id)
        fingerprintProfiles.remove(id)
        removeComposerDrafts(id)
        removeThreadModelPreferences(id)
        removeCompletedTurnTimings(id)
        if (fingerprintDialogProfileId == id) fingerprintDialogProfileId = null
        fingerprintJobs.remove(id)?.cancel()
        connectionJobs.remove(id)?.cancel()
        setupJobs.remove(id)?.cancel()
        uninstallJobs.remove(id)?.cancel()
        serverMetricsJobs.remove(id)?.cancel()
        disconnectJobs.remove(id)?.cancel()
        _state.update { current ->
            val profiles = current.profiles.filterNot { it.id == id }
            val selected = if (current.selectedProfileId == id) profiles.firstOrNull()?.id else current.selectedProfileId
            if (!wasSelected) return@update current.copy(
                profiles = profiles,
                connectionStates = current.connectionStates - id,
                serverMetrics = current.serverMetrics - id,
            )
            val nextProfile = profiles.firstOrNull { it.id == selected }
            if (nextProfile == null) {
                clearSessionState(current.copy(
                    profiles = profiles,
                    selectedProfileId = null,
                    connectionStates = current.connectionStates - id,
                    serverMetrics = current.serverMetrics - id,
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
                        serverMetrics = current.serverMetrics - id,
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
            fingerprintJobs[normalized.id]?.isActive == true || disconnectJobs[normalized.id]?.isActive == true ||
            uninstallJobs[normalized.id]?.isActive == true
        ) return
        DiagnosticLogger.info(
            "Connection",
            "connect_start profile=${profileRef(normalized.id)} active=$makeActive fingerprint=${normalized.hostFingerprint.isNotBlank()}",
        )
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

    fun installRemoteSetup(proxyUrl: String = currentProfile()?.proxyUrl.orEmpty()) {
        val profileId = _state.value.selectedProfileId ?: return
        if (setupJobs[profileId]?.isActive == true || connectionJobs[profileId]?.isActive == true ||
            fingerprintJobs[profileId]?.isActive == true || disconnectJobs[profileId]?.isActive == true ||
            uninstallJobs[profileId]?.isActive == true
        ) return
        DiagnosticLogger.info("Setup", "install_start profile=${profileRef(profileId)}")
        val normalizedProxy = try {
            RemoteBootstrap.validateProxyUrl(proxyUrl)
        } catch (error: IllegalArgumentException) {
            showError(error, profileId)
            return
        }
        val profile = setupProfiles[profileId]?.copy(proxyUrl = normalizedProxy) ?: return
        setupProfiles[profileId] = profile
        connections.register(profile)
        _state.update { current ->
            current.copy(
                profiles = current.profiles.map { stored ->
                    if (stored.id == profileId) stored.copy(proxyUrl = normalizedProxy) else stored
                },
            )
        }
        persistProfiles()
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
                rememberContextUsage(id, thread.id, _state.value.tokenUsage)
                activeClient()?.cacheThread(
                    thread,
                    _state.value.timeline,
                    _state.value.olderTurnsCursor,
                    _state.value.tokenUsage,
                )
            }
            sessionSnapshots[id] = SessionSnapshot.capture(_state.value)
            subAgentNavigationStacks.clear(id)
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
        persistProfiles()
    }

    internal fun openTerminal() {
        val profileId = _state.value.selectedProfileId ?: return
        val profile = _state.value.profiles.firstOrNull { it.id == profileId } ?: return
        terminals.open(profile)
    }

    internal fun retryTerminal(profileId: String) {
        val profile = _state.value.profiles.firstOrNull { it.id == profileId } ?: return
        terminals.open(profile)
    }

    internal fun hideTerminal() = terminals.hide()

    internal fun closeTerminal() = terminals.closeVisible()

    internal fun sendTerminalInput(profileId: String, value: ByteArray): Boolean =
        terminals.send(profileId, value)

    internal fun resizeTerminal(profileId: String, columns: Int, rows: Int) {
        terminals.resize(profileId, columns, rows)
    }

    internal fun terminalOutputAfter(
        profileId: String,
        generation: Long,
        sequence: Long,
    ): SshTerminalOutputBatch = terminals.outputAfter(profileId, generation, sequence)

    fun disconnectProfile(profileId: String) {
        startDisconnect(profileId)
    }

    fun uninstallRemote(profileId: String) {
        if (uninstallJobs[profileId]?.isActive == true) return
        val storedProfile = _state.value.profiles.firstOrNull { it.id == profileId } ?: return
        val profile = effectiveProfiles[profileId] ?: storedProfile
        if (_state.value.connectionStates[profileId]?.phase == ConnectionPhase.Installing) {
            showError(IllegalStateException("远程安装正在进行，请完成或取消后再卸载"), profileId)
            return
        }
        val job = viewModelScope.launch {
            try {
                updateProfileConnection(
                    profileId,
                    ConnectionState(ConnectionPhase.Installing, "正在卸载远端 App Service"),
                )
                connections.uninstallRemote(profile)
                if (_state.value.profiles.any { it.id == profileId }) {
                    startDisconnect(profileId)
                    if (isActiveProfile(profileId)) {
                        _state.update { it.copy(diagnostic = "远端 App Service 已卸载") }
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                showError(error, profileId)
            } finally {
                if (uninstallJobs[profileId] === currentCoroutineContext()[Job]) {
                    uninstallJobs.remove(profileId)
                }
            }
        }
        uninstallJobs[profileId] = job
    }

    fun setThreadSearch(value: String) {
        _state.update { it.copy(threadSearch = value) }
    }

    /** Refreshes one connected server without surfacing transient metrics errors as app errors. */
    fun refreshServerMetrics(profileId: String) {
        if (serverMetricsJobs[profileId]?.isActive == true) return
        val current = _state.value
        val profile = current.profiles.firstOrNull { it.id == profileId } ?: return
        val connection = current.connectionStates[profileId]
            ?: if (current.selectedProfileId == profileId) current.connection else ConnectionState()
        if (connection.phase != ConnectionPhase.Connected) return
        val client = connections.client(profileId)?.takeIf { it.isConnected() } ?: return
        val job = viewModelScope.launch(Dispatchers.IO) {
            try {
                val effectiveProfile = connections.profile(profileId) ?: profile
                val metrics = client.readServerMetrics(effectiveProfile)
                _state.update { state ->
                    val stateConnection = state.connectionStates[profileId]
                        ?: if (state.selectedProfileId == profileId) state.connection else ConnectionState()
                    if (connections.client(profileId) !== client ||
                        stateConnection.phase != ConnectionPhase.Connected
                    ) {
                        state
                    } else {
                        state.copy(serverMetrics = state.serverMetrics + (profileId to metrics))
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                DiagnosticLogger.warn(
                    "Metrics",
                    "read_failed profile=${profileRef(profileId)} ${error.message.orEmpty()}",
                )
                _state.update { state ->
                    val stateConnection = state.connectionStates[profileId]
                        ?: if (state.selectedProfileId == profileId) state.connection else ConnectionState()
                    if (stateConnection.phase != ConnectionPhase.Connected) {
                        state
                    } else {
                        state.copy(
                            serverMetrics = state.serverMetrics + (
                                profileId to ServerMetrics(
                                    sampledAtEpochMillis = System.currentTimeMillis(),
                                    error = error.message ?: "读取失败",
                                )
                            ),
                        )
                    }
                }
            } finally {
                if (serverMetricsJobs[profileId] === currentCoroutineContext()[Job]) {
                    serverMetricsJobs.remove(profileId)
                }
            }
        }
        serverMetricsJobs[profileId] = job
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
                    applySessionState(profileId) { current ->
                        current.copy(
                            threads = threads,
                            activeThread = current.activeThread?.let { active ->
                                threads.firstOrNull { it.id == active.id } ?: active
                            },
                            loading = false,
                        )
                    }
                    sessionSnapshots[profileId]?.let { snapshot ->
                        snapshot.activeThread?.let { active ->
                            client.cacheThread(
                                active,
                                snapshot.timeline,
                                snapshot.olderTurnsCursor,
                                snapshot.tokenUsage,
                            )
                        }
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    if (!silent) {
                        showError(error, profileId)
                    } else {
                        val message = userFacingErrorMessage(error, profileId, "刷新会话失败")
                        _state.update { it.copy(diagnostic = message) }
                    }
                }
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun createThread() {
        val profile = currentProfile() ?: return
        subAgentNavigationStacks.clear(profile.id)
        DiagnosticLogger.info("Thread", "create_start profile=${profileRef(profile.id)}")
        val client = connections.client(profile.id)?.takeIf { it.isConnected() } ?: return
        invalidateLane(profile.id, "session-navigation")
        invalidateLane(profile.id, "thread-history")
        val operation = beginClientOperation(profile.id, "session-navigation", client) ?: return
        val selection = resolveModelSelection(
            models = _state.value.models,
            preferredModel = profile.preferredModel,
            preferredEffort = profile.preferredEffort,
        )
        val model = selection.model
        val approvalMode = _state.value.approvalMode
        val job = viewModelScope.launch {
            if (isOperationVisible(operation)) applySessionState(profile.id) { it.copy(loading = true, error = null) }
            try {
                val (thread, timeline) = client.startThread(profile, model, approvalMode)
                if (isOperationCurrent(operation)) {
                    DiagnosticLogger.info(
                        "Thread",
                        "create_success profile=${profileRef(profile.id)} thread=${profileRef(thread.id)}",
                    )
                    rememberThreadModelPreference(profile.id, thread.id, selection)
                    applySessionState(profile.id) {
                        it.copy(
                        screen = AppScreen.Work,
                        activeThread = thread,
                        activeAgentName = null,
                        activeGoal = null,
                        timeline = timeline,
                        olderTurnsCursor = null,
                        olderTurnsLoading = false,
                        activeTurnId = null,
                        running = false,
                        aggregateDiff = "",
                        tokenUsage = null,
                        composerDraft = composerDraft(profile.id, thread.id),
                        selectedModel = selection.model,
                        selectedEffort = selection.effort,
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
                if (sessionNavigationJobs[profile.id] === currentCoroutineContext()[Job]) {
                    sessionNavigationJobs.remove(profile.id)
                }
            }
        }
        sessionNavigationJobs[profile.id] = job
    }

    fun openThread(thread: top.asdb.codexremote.data.CodexThread) {
        val profileId = _state.value.selectedProfileId ?: return
        subAgentNavigationStacks.clear(profileId)
        openThreadInternal(thread, AppScreen.Work, agentName = null)
    }

    fun openSubAgentThread(threadId: String, agentName: String) {
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        if (threadId.isBlank() || current.loading || threadId == current.activeThread?.id) return
        if (current.submitting) {
            showError(IllegalStateException("当前操作尚未完成，请稍后打开智能体"))
            return
        }
        if (current.approvalQueue.isNotEmpty()) {
            showError(IllegalStateException("请先处理当前审批请求"))
            return
        }
        if (current.screen !in setOf(AppScreen.Work, AppScreen.AgentWork)) return
        if (subAgentNavigationStacks.size(profileId) >= MAX_SUB_AGENT_NAVIGATION_DEPTH) {
            showError(IllegalStateException("智能体嵌套层级过深，请先返回上一级"))
            return
        }
        val parentThread = current.activeThread ?: return
        val client = connections.client(profileId)?.takeIf { it.isConnected() } ?: return

        // Returning must resume this parent remotely, but presenting its cached snapshot first
        // keeps navigation immediate even for a large transcript.
        client.cacheThread(
            parentThread,
            current.timeline,
            current.olderTurnsCursor,
            current.tokenUsage,
        )
        rememberContextUsage(profileId, parentThread.id, current.tokenUsage)
        subAgentNavigationStacks.push(
            profileId,
            SubAgentNavigationFrame(
                snapshot = SessionSnapshot.capture(current),
                screen = current.screen,
            ),
        )
        val childSnapshot = client.cachedThread(threadId)?.takeIf { it.thread.id == threadId }
            ?: client.cachedThreadStale(threadId)?.takeIf { it.thread.id == threadId }
        val child = childSnapshot?.thread
            ?: top.asdb.codexremote.data.CodexThread(
                id = threadId,
                title = agentName.ifBlank { "智能体" },
                preview = "",
                cwd = parentThread.cwd,
                source = "appServer",
                status = "idle",
                createdAt = 0L,
                updatedAt = 0L,
                cliVersion = current.connection.cliVersion.orEmpty(),
            )
        if (!openThreadInternal(child, AppScreen.AgentWork, agentName.ifBlank { null })) {
            subAgentNavigationStacks.pop(profileId)
        }
    }

    fun backFromSubAgentThread() {
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        if (current.submitting) {
            showError(IllegalStateException("当前操作尚未完成，请稍后返回"))
            return
        }
        if (current.approvalQueue.isNotEmpty()) {
            showError(IllegalStateException("请先处理当前审批请求"))
            return
        }
        // A child can still be loading when the user decides to leave it. Do not block that
        // first back action, but never start two parent resumes for the same stack frame.
        if (subAgentNavigationStacks.isPopPending(profileId)) return
        val frame = subAgentNavigationStacks.beginPendingPop(profileId) ?: run {
            backToThreads()
            return
        }
        val parentThread = frame.snapshot.activeThread ?: run {
            subAgentNavigationStacks.completePendingPop(profileId, frame)
            backToThreads()
            return
        }
        val childSnapshot = SessionSnapshot.capture(current)
        connections.client(profileId)?.takeIf { it.isConnected() }?.let { client ->
            current.activeThread?.let { child ->
                client.cacheThread(
                    child,
                    current.timeline,
                    current.olderTurnsCursor,
                    current.tokenUsage,
                )
                rememberContextUsage(profileId, child.id, current.tokenUsage)
            }
        }
        val accepted = openThreadInternal(
            thread = parentThread,
            targetScreen = frame.screen,
            agentName = frame.snapshot.activeAgentName,
            initialSnapshot = frame.snapshot,
            subAgentBackNavigation = true,
            onResumed = { subAgentNavigationStacks.completePendingPop(profileId, frame) },
            onResumeFailure = { error ->
                // A newer navigation owns the screen and stack. Do not let an older failed
                // resume replace it with a stale child snapshot.
                if (subAgentNavigationStacks.cancelPendingPop(profileId, frame)) {
                    applySessionState(profileId) { childSnapshot.restore(it).copy(
                        screen = AppScreen.AgentWork,
                        subAgentBackNavigation = false,
                        loading = false,
                        submitting = false,
                        error = error.message ?: "无法返回上级智能体",
                    ) }
                }
                true
            },
        )
        if (!accepted && subAgentNavigationStacks.completePendingPop(profileId, frame) != null) {
            // The server cannot receive a new `thread/resume` while disconnected, but navigation
            // must not trap the user on a child page. Remote actions will report the disconnected
            // state until the profile reconnects and the user resumes the parent again.
            applySessionState(profileId) {
                frame.snapshot.restore(it).copy(
                    screen = frame.screen,
                    subAgentBackNavigation = true,
                    loading = false,
                    submitting = false,
                    error = "服务器连接已断开，已返回上级会话；重连后请重新打开会话",
                )
            }
        }
    }

    private fun openThreadInternal(
        thread: top.asdb.codexremote.data.CodexThread,
        targetScreen: AppScreen,
        agentName: String?,
        initialSnapshot: SessionSnapshot? = null,
        subAgentBackNavigation: Boolean = false,
        onResumed: () -> Unit = {},
        onResumeFailure: (Throwable) -> Boolean = { false },
    ): Boolean {
        val profileId = _state.value.selectedProfileId ?: return false
        DiagnosticLogger.info(
            "Thread",
            "open_start profile=${profileRef(profileId)} thread=${profileRef(thread.id)}",
        )
        val client = connections.client(profileId)?.takeIf { it.isConnected() } ?: return false
        invalidateLane(profileId, "session-navigation")
        invalidateLane(profileId, "thread-history")
        val operation = beginClientOperation(profileId, "session-navigation", client) ?: return false
        val resumeBuffer = ResumeNotificationBuffer(thread.id, operation.generation)
        resumeNotificationBuffers[profileId] = resumeBuffer
        val approvalMode = _state.value.approvalMode
        val threadSelection = resolveThreadModelSelection(profileId, thread.id, _state.value.models)
        val cached = (client.cachedThread(thread.id) ?: client.cachedThreadStale(thread.id))
            ?.takeIf { it.thread.id == thread.id }
        val rememberedTokenUsage = client.cachedContextUsage(thread.id)
            ?: contextUsageFallbacks.get(profileId, thread.id)
            ?: cached?.tokenUsage?.takeIf { it.hasKnownContextWindow() }
            ?: initialSnapshot?.tokenUsage?.takeIf { it.hasKnownContextWindow() }
            ?: sessionSnapshots[profileId]
                ?.takeIf { it.activeThread?.id == thread.id }
                ?.tokenUsage
                ?.takeIf { it.hasKnownContextWindow() }
        cached?.takeIf { isOperationVisible(operation) }?.let { snapshot ->
            val cachedThread = snapshot.thread
            val timeline = snapshot.timeline
            val activeTurn = timeline.lastOrNull { it.status == "inProgress" }?.turnId
            val running = cachedThread.activeTurnId != null || activeTurn != null || cachedThread.status == "active"
            applySessionState(profileId) {
                it.copy(
                    screen = targetScreen,
                    subAgentBackNavigation = subAgentBackNavigation,
                    activeThread = cachedThread,
                    activeAgentName = agentName,
                    activeGoal = null,
                    composerDraft = composerDraft(profileId, cachedThread.id),
                    selectedModel = threadSelection.model,
                    selectedEffort = threadSelection.effort,
                    timeline = timeline,
                    olderTurnsCursor = snapshot.nextTurnsCursor,
                    olderTurnsLoading = false,
                    activeTurnId = cachedThread.activeTurnId ?: activeTurn,
                    running = running,
                    turnTiming = restoredTurnTiming(profileId, cachedThread.id, running),
                    aggregateDiff = "",
                    tokenUsage = rememberedTokenUsage,
                    attachments = if (initialSnapshot?.activeThread?.id == cachedThread.id) {
                        initialSnapshot.attachments
                    } else {
                        emptyList()
                    },
                    // The snapshot is display-only until thread/resume confirms the remote context.
                    loading = true,
                )
            }
        }
        if (cached == null) {
            initialSnapshot?.takeIf { isOperationVisible(operation) }?.let { snapshot ->
                val snapshotThread = snapshot.activeThread ?: thread
                val activeTurn = snapshot.timeline.lastOrNull { it.status == "inProgress" }?.turnId
                val running = snapshotThread.activeTurnId != null || activeTurn != null || snapshotThread.status == "active"
                applySessionState(profileId) { state ->
                    snapshot.restore(state).copy(
                        screen = targetScreen,
                        subAgentBackNavigation = subAgentBackNavigation,
                        activeThread = snapshotThread,
                        activeAgentName = agentName,
                        activeGoal = snapshot.activeGoal,
                        composerDraft = composerDraft(profileId, snapshotThread.id),
                        selectedModel = threadSelection.model,
                        selectedEffort = threadSelection.effort,
                        activeTurnId = snapshotThread.activeTurnId ?: activeTurn,
                        running = running,
                        turnTiming = restoredTurnTiming(profileId, snapshotThread.id, running, snapshot.turnTiming),
                        tokenUsage = rememberedTokenUsage,
                        loading = true,
                        error = null,
                    )
                }
            } ?: applySessionState(profileId) {
                val running = thread.activeTurnId != null || thread.status == "active"
                it.copy(
                    screen = targetScreen,
                    subAgentBackNavigation = subAgentBackNavigation,
                    activeThread = thread,
                    activeAgentName = agentName,
                    activeGoal = null,
                    timeline = emptyList(),
                    olderTurnsCursor = null,
                    olderTurnsLoading = false,
                    activeTurnId = thread.activeTurnId,
                    running = running,
                    turnTiming = restoredTurnTiming(profileId, thread.id, running),
                    aggregateDiff = "",
                    tokenUsage = rememberedTokenUsage,
                    attachments = emptyList(),
                    composerDraft = composerDraft(profileId, thread.id),
                    selectedModel = threadSelection.model,
                    selectedEffort = threadSelection.effort,
                    loading = true,
                    error = null,
                )
            }
        }
        val job = viewModelScope.launch {
            if (isOperationVisible(operation)) {
                applySessionState(profileId) { it.copy(loading = true, error = null) }
            }
            // `thread/resume` establishes the app-server's active thread context. Do not silently
            // replace it with `thread/read`, which is a read-only payload and cannot safely accept
            // subsequent turns or steering.
            try {
                val resumed = resumeExpectedThread(client, profileId, thread.id, approvalMode)
                val loaded = resumed.thread
                val reconciled = reconcileResumedTimeline(
                    cachedTimeline = cached?.timeline,
                    cachedNextCursor = cached?.nextTurnsCursor,
                    refreshedTimeline = resumed.timeline,
                    refreshedNextCursor = resumed.nextTurnsCursor,
                    refreshedTurnIds = resumed.turnIds,
                    cachedThreadUpdatedAt = cached?.thread?.updatedAt,
                    refreshedThreadUpdatedAt = loaded.updatedAt,
                    refreshedItemsView = resumed.itemsView,
                )
                val timeline = reconciled.timeline
                val nextTurnsCursor = reconciled.nextCursor
                val responseSequence = resumed.responseSequence
                if (isOperationCurrent(operation)) {
                    DiagnosticLogger.info(
                        "Thread",
                        "open_success profile=${profileRef(profileId)} thread=${profileRef(loaded.id)} items=${timeline.size}",
                    )
                    val activeTurn = timeline.lastOrNull { it.status == "inProgress" }?.turnId
                    val running = loaded.activeTurnId != null || activeTurn != null || loaded.status == "active"
                    // Re-read the preference in case the user changed it while resume was loading.
                    val latestThreadSelection = resolveThreadModelSelection(
                        profileId,
                        loaded.id,
                        _state.value.models,
                    )
                    applySessionState(profileId) { current ->
                        // A usage notification without a thread id can be delivered while the
                        // resume RPC is still in flight. Do not let this older resume snapshot
                        // replace that newer value with the empty value captured at request time.
                        val latestTokenUsage = current.tokenUsage?.takeIf {
                            current.activeThread?.id == loaded.id && it.hasKnownContextWindow()
                        } ?: client.cachedContextUsage(loaded.id)
                            ?: contextUsageFallbacks.get(profileId, loaded.id)
                            ?: rememberedTokenUsage
                        current.copy(
                            screen = targetScreen,
                            subAgentBackNavigation = subAgentBackNavigation,
                            activeThread = loaded,
                            activeAgentName = agentName,
                            activeGoal = null,
                            composerDraft = composerDraft(profileId, loaded.id),
                            selectedModel = latestThreadSelection.model,
                            selectedEffort = latestThreadSelection.effort,
                            timeline = timeline,
                            olderTurnsCursor = nextTurnsCursor,
                            olderTurnsLoading = false,
                            activeTurnId = loaded.activeTurnId ?: activeTurn,
                            running = running,
                            turnTiming = restoredTurnTiming(profileId, loaded.id, running, current.turnTiming),
                            aggregateDiff = "",
                            tokenUsage = latestTokenUsage,
                            attachments = if (initialSnapshot?.activeThread?.id == loaded.id) {
                                initialSnapshot.attachments
                            } else {
                                emptyList()
                            },
                            loading = false,
                            diagnostic = if (resumed.itemsView == "notLoaded") {
                                "最近一个回合内容过大，已跳过详情；会话仍可继续使用"
                            } else {
                                current.diagnostic
                            },
                        )
                    }
                    releaseResumeNotifications(
                        profileId,
                        resumeBuffer,
                        timeline,
                        replay = true,
                        snapshotSequence = responseSequence,
                    )
                    sessionSnapshots[profileId]?.let { snapshot ->
                        snapshot.activeThread?.let { active ->
                            client.cacheThread(
                                active,
                                snapshot.timeline,
                                snapshot.olderTurnsCursor,
                                snapshot.tokenUsage,
                            )
                        }
                    }
                    onResumed()
                    // Goal hydration is deliberately outside the resume path. A slow or older
                    // app-server must not delay the transcript or hold its notification buffer.
                    loadActiveGoalAfterResume(profileId, loaded.id, client, operation)
                } else {
                    releaseResumeNotifications(profileId, resumeBuffer, timeline, replay = false)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationCurrent(operation)) {
                    val baseline = if (isActiveProfile(profileId)) {
                        _state.value.timeline
                    } else {
                        sessionSnapshots[profileId]?.timeline.orEmpty()
                    }
                    releaseResumeNotifications(
                        profileId,
                        resumeBuffer,
                        baseline,
                        replay = true,
                        snapshotSequence = Long.MIN_VALUE,
                    )
                    if (!onResumeFailure(error)) {
                        applySessionState(profileId) {
                            it.copy(loading = false, submitting = false, error = error.message ?: "无法恢复会话")
                        }
                    }
                } else {
                    releaseResumeNotifications(profileId, resumeBuffer, emptyList(), replay = false)
                }
            } finally {
                releaseResumeNotifications(profileId, resumeBuffer, emptyList(), replay = false)
                finishClientOperation(operation)
                if (sessionNavigationJobs[profileId] === currentCoroutineContext()[Job]) {
                    sessionNavigationJobs.remove(profileId)
                }
            }
        }
        sessionNavigationJobs[profileId] = job
        return true
    }

    private suspend fun resumeExpectedThread(
        client: CodexAppServerClient,
        profileId: String,
        threadId: String,
        approvalMode: ApprovalMode,
    ): top.asdb.codexremote.codex.ResumedThread {
        val first = client.openThread(threadId, approvalMode)
        if (first.thread.id == threadId) return first

        // A late resume response for the parent can otherwise make a child page display the
        // parent's transcript while retaining the child's display name in the app bar.
        DiagnosticLogger.warn(
            "Thread",
            "resume_mismatch profile=${profileRef(profileId)} requested=${profileRef(threadId)} " +
                "returned=${profileRef(first.thread.id)} retrying",
        )
        val retried = client.openThread(threadId, approvalMode)
        if (retried.thread.id == threadId) return retried

        DiagnosticLogger.warn(
            "Thread",
            "resume_mismatch_final profile=${profileRef(profileId)} requested=${profileRef(threadId)} " +
                "returned=${profileRef(retried.thread.id)}",
        )
        throw IllegalStateException("服务器返回了其他会话，已阻止显示父会话内容")
    }

    /** Fetches one bounded page on demand so opening a large thread remains fast. */
    fun loadOlderThreadHistory() {
        val current = _state.value
        if (current.loading) return
        val profileId = current.selectedProfileId ?: return
        val activeThread = current.activeThread ?: return
        val threadId = activeThread.id
        val cursor = current.olderTurnsCursor ?: return
        val subAgentCreatedAt = activeThread
            .takeIf { it.source == "subAgent" }
            ?.createdAt
            ?.takeIf { it > 0L }
        if (current.olderTurnsLoading) return
        val client = connections.client(profileId)?.takeIf { it.isConnected() } ?: return
        val operation = beginClientOperation(profileId, "thread-history", client) ?: return
        applySessionState(profileId) { state ->
            if (state.activeThread?.id == threadId && state.olderTurnsCursor == cursor) {
                state.copy(olderTurnsLoading = true)
            } else state
        }
        val job = viewModelScope.launch {
            try {
                val page = client.listThreadTurnsPage(
                    threadId = threadId,
                    cursor = cursor,
                    subAgentCreatedAt = subAgentCreatedAt,
                )
                if (!isOperationCurrent(operation)) return@launch
                applySessionState(profileId) { state ->
                    if (state.activeThread?.id != threadId || state.olderTurnsCursor != cursor) {
                        return@applySessionState state
                    }
                    val merged = prependOlderTimeline(state.timeline, page.timeline)
                    if (merged.accepted) {
                        state.copy(
                            timeline = merged.timeline,
                            olderTurnsCursor = page.nextCursor?.takeUnless { it == cursor },
                            olderTurnsLoading = false,
                            diagnostic = if (page.itemsView == "notLoaded") {
                                "一个较早回合内容过大，已跳过详情"
                            } else {
                                state.diagnostic
                            },
                        )
                    } else {
                        state.copy(
                            olderTurnsCursor = null,
                            olderTurnsLoading = false,
                            diagnostic = "会话记录过多，已停止加载更早内容以避免内存不足",
                        )
                    }
                }
                sessionSnapshots[profileId]?.let { snapshot ->
                    snapshot.activeThread?.let { thread ->
                        client.cacheThread(
                            thread,
                            snapshot.timeline,
                            snapshot.olderTurnsCursor,
                            snapshot.tokenUsage,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationCurrent(operation)) {
                    val invalidCursor = error.message?.contains("invalid cursor", ignoreCase = true) == true
                    applySessionState(profileId) {
                        it.copy(
                            olderTurnsCursor = if (invalidCursor) null else it.olderTurnsCursor,
                            olderTurnsLoading = false,
                            diagnostic = if (invalidCursor) {
                                "服务器上的会话历史已变化，请返回列表后重新进入"
                            } else {
                                "较早的会话记录加载失败：${error.message.orEmpty()}"
                            },
                        )
                    }
                }
            } finally {
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(olderTurnsLoading = false) }
                }
                finishClientOperation(operation)
                if (threadHistoryJobs[profileId] === currentCoroutineContext()[Job]) {
                    threadHistoryJobs.remove(profileId)
                }
            }
        }
        threadHistoryJobs[profileId] = job
    }

    fun backToThreads() {
        if (_state.value.approvalQueue.isNotEmpty()) {
            showError(IllegalStateException("请先处理当前审批请求"))
            return
        }
        if (_state.value.submitting) {
            showError(IllegalStateException("当前操作尚未完成，请稍后返回"))
            return
        }
        val profileId = _state.value.selectedProfileId
        profileId?.let(subAgentNavigationStacks::clear)
        profileId?.let {
            invalidateLane(it, "session-navigation")
            invalidateLane(it, "thread-mutation")
            invalidateLane(it, "thread-history")
        }
        _state.value.activeThread?.let { thread ->
            profileId?.let { rememberContextUsage(it, thread.id, _state.value.tokenUsage) }
            activeClient()?.cacheThread(
                thread,
                _state.value.timeline,
                _state.value.olderTurnsCursor,
                _state.value.tokenUsage,
            )
        }
        _state.update {
            it.copy(
                screen = AppScreen.Threads,
                approval = null,
                approvalQueue = emptyList(),
                loading = false,
                submitting = false,
                olderTurnsLoading = false,
            ).also { updated ->
                profileId?.let { id -> sessionSnapshots[id] = SessionSnapshot.capture(updated) }
            }
        }
        profileId?.let { pendingApprovalsByProfile[it] = emptyList() }
        persistProfiles()
        refreshThreads(silent = true)
    }

    fun send(text: String) {
        val clean = text.trim()
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val thread = current.activeThread ?: return
        val client = activeClient() ?: return
        if (clean.isBlank() && current.attachments.isEmpty()) return
        if (current.loading || current.submitting) return
        if (current.running && current.activeTurnId == null) {
            showError(IllegalStateException("当前回合仍在运行，尚未收到回合 ID，请稍后再试"))
            return
        }
        val requestedAtMillis = System.currentTimeMillis()
        DiagnosticLogger.info(
            "Turn",
            "send_start profile=${profileRef(profileId)} thread=${profileRef(thread.id)} steering=${current.running} attachments=${current.attachments.size}",
        )
        invalidateLane(profileId, "session-navigation")
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
                    DiagnosticLogger.info(
                        "Turn",
                        "send_accepted profile=${profileRef(profileId)} thread=${profileRef(thread.id)}",
                    )
                    composerDrafts.remove(composerDraftKey(profileId, thread.id))
                    completedTurnTimings.remove(threadStorageKey(profileId, thread.id))
                    applySessionState(profileId) { state ->
                        // Session navigation can race with a sent request. Never attach this
                        // thread's turn state or draft cleanup to whichever thread is now visible.
                        if (state.activeThread?.id != thread.id) {
                            state
                        } else {
                            state.copy(
                                activeTurnId = turnId.ifBlank { state.activeTurnId },
                                running = true,
                                turnTiming = state.turnTiming
                                    ?.takeIf {
                                        it.threadId == thread.id && it.completedAtMillis == null
                                    }
                                    ?.let { timing ->
                                        timing.copy(
                                            turnId = timing.turnId ?: turnId.takeIf { value -> value.isNotBlank() },
                                        )
                                    }
                                    ?: TurnTiming(
                                        threadId = thread.id,
                                        turnId = turnId.takeIf { value -> value.isNotBlank() } ?: activeTurn,
                                        startedAtMillis = requestedAtMillis,
                                    ),
                                submitting = false,
                                attachments = emptyList(),
                                composerClearNonce = state.composerClearNonce + 1,
                                composerDraft = "",
                            )
                        }
                    }
                    persistProfiles()
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
        val current = _state.value
        if (current.loading) return
        val profileId = current.selectedProfileId ?: return
        val threadId = current.activeThread?.id ?: return
        val client = activeClient() ?: return
        val turnId = current.activeTurnId ?: run {
            showError(IllegalStateException("当前回合 ID 尚未可用"))
            return
        }
        invalidateLane(profileId, "session-navigation")
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

    fun compactActiveThread() {
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val threadId = current.activeThread?.id ?: return
        val client = activeClient() ?: return
        if (current.loading || current.running || current.submitting) {
            showError(IllegalStateException("当前回合运行中，完成或停止后才能压缩会话"))
            return
        }
        if (threadMutationJobs[profileId]?.isActive == true) return
        invalidateLane(profileId, "session-navigation")
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        applySessionState(profileId) { it.copy(submitting = true, error = null) }
        val job = viewModelScope.launch {
            try {
                client.compactThread(threadId)
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) {
                        it.copy(submitting = false, diagnostic = "已开始压缩会话上下文")
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(submitting = false) }
                }
                finishClientOperation(operation)
                if (threadMutationJobs[profileId] === currentCoroutineContext()[Job]) {
                    threadMutationJobs.remove(profileId)
                }
            }
        }
        threadMutationJobs[profileId] = job
    }

    fun setActiveGoal(objective: String) {
        val clean = objective.trim().take(MAX_GOAL_OBJECTIVE_CHARS)
        if (clean.isBlank()) {
            clearActiveGoal()
            return
        }
        val currentStatus = _state.value.activeGoal?.status
        val status = currentStatus.takeIf {
            it == ThreadGoalStatus.Active || it == ThreadGoalStatus.Paused
        } ?: ThreadGoalStatus.Active
        mutateActiveGoal { client, threadId ->
            client.setThreadGoal(threadId = threadId, objective = clean, status = status)
        }
    }

    fun toggleActiveGoalPause() {
        val nextStatus = when (_state.value.activeGoal?.status) {
            ThreadGoalStatus.Active -> ThreadGoalStatus.Paused
            ThreadGoalStatus.Paused -> ThreadGoalStatus.Active
            else -> return
        }
        mutateActiveGoal { client, threadId ->
            client.setThreadGoal(threadId = threadId, status = nextStatus)
        }
    }

    fun clearActiveGoal() {
        if (_state.value.activeGoal == null) return
        mutateActiveGoal { client, threadId ->
            client.clearThreadGoal(threadId)
            null
        }
    }

    private fun mutateActiveGoal(
        mutation: suspend (CodexAppServerClient, String) -> ThreadGoal?,
    ) {
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val thread = current.activeThread ?: return
        val client = activeClient() ?: return
        if (current.loading || current.submitting || threadMutationJobs[profileId]?.isActive == true) return
        invalidateLane(profileId, "session-navigation")
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        applySessionState(profileId) { it.copy(submitting = true, error = null) }
        val job = viewModelScope.launch {
            try {
                val goal = mutation(client, thread.id)
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) {
                        if (it.activeThread?.id == thread.id) {
                            it.copy(activeGoal = goal, submitting = false)
                        } else {
                            it
                        }
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    val displayError = if (error.message?.contains("method not found", ignoreCase = true) == true) {
                        IllegalStateException("远程 Codex 版本不支持目标模式，请升级 Codex CLI 后重试", error)
                    } else {
                        error
                    }
                    showError(displayError, profileId)
                }
            } finally {
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(submitting = false) }
                }
                finishClientOperation(operation)
                if (threadMutationJobs[profileId] === currentCoroutineContext()[Job]) {
                    threadMutationJobs.remove(profileId)
                }
            }
        }
        threadMutationJobs[profileId] = job
    }

    fun reviewChanges() {
        val current = _state.value
        if (current.loading || current.running || current.submitting) return
        val profileId = current.selectedProfileId ?: return
        val threadId = current.activeThread?.id ?: return
        val client = activeClient() ?: return
        if (threadMutationJobs[profileId]?.isActive == true) return
        invalidateLane(profileId, "session-navigation")
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        applySessionState(profileId) { it.copy(submitting = true, error = null) }
        val job = viewModelScope.launch {
            try {
                client.startReview(threadId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(submitting = false) }
                }
                finishClientOperation(operation)
                if (threadMutationJobs[profileId] === currentCoroutineContext()[Job]) {
                    threadMutationJobs.remove(profileId)
                }
            }
        }
        threadMutationJobs[profileId] = job
    }

    fun rollbackActiveThread() {
        val current = _state.value
        if (current.loading) return
        val profileId = current.selectedProfileId ?: return
        val threadId = current.activeThread?.id ?: return
        val client = activeClient() ?: return
        if (current.running) {
            showError(IllegalStateException("回合运行中，完成或停止后才能回退会话历史"))
            return
        }
        if (current.submitting || threadMutationJobs[profileId]?.isActive == true) return
        invalidateLane(profileId, "session-navigation")
        invalidateLane(profileId, "thread-history")
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        val approvalMode = _state.value.approvalMode
        applySessionState(profileId) { it.copy(submitting = true, error = null) }
        val job = viewModelScope.launch {
            try {
                val rolledBack = client.rollbackThread(threadId, approvalMode)
                val thread = rolledBack.thread
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) {
                        it.copy(
                            activeThread = thread,
                            timeline = rolledBack.timeline,
                            olderTurnsCursor = rolledBack.nextTurnsCursor,
                            olderTurnsLoading = false,
                            activeTurnId = thread.activeTurnId,
                            running = thread.status == "active" || thread.activeTurnId != null,
                            aggregateDiff = "",
                            tokenUsage = null,
                            submitting = false,
                            diagnostic = if (rolledBack.itemsView == "notLoaded") {
                                "回退已完成，但最近回合内容过大，已跳过详情"
                            } else {
                                it.diagnostic
                            },
                        )
                    }
                    sessionSnapshots[profileId]?.let { snapshot ->
                        snapshot.activeThread?.let { active ->
                            client.cacheThread(
                                active,
                                snapshot.timeline,
                                snapshot.olderTurnsCursor,
                                snapshot.tokenUsage,
                            )
                        }
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(submitting = false) }
                }
                finishClientOperation(operation)
                if (threadMutationJobs[profileId] === currentCoroutineContext()[Job]) {
                    threadMutationJobs.remove(profileId)
                }
            }
        }
        threadMutationJobs[profileId] = job
    }

    fun archiveActiveThread() {
        val current = _state.value
        if (current.loading) return
        val profileId = current.selectedProfileId ?: return
        val threadId = current.activeThread?.id ?: return
        val client = activeClient() ?: return
        if (current.running) {
            showError(IllegalStateException("回合运行中，完成或停止后才能归档"))
            return
        }
        if (current.submitting || threadMutationJobs[profileId]?.isActive == true) return
        invalidateLane(profileId, "session-navigation")
        invalidateLane(profileId, "thread-history")
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        applySessionState(profileId) { it.copy(submitting = true, error = null) }
        val job = viewModelScope.launch {
            try {
                client.archiveThread(threadId)
                if (isOperationCurrent(operation)) {
                    composerDrafts.remove(composerDraftKey(profileId, threadId))
                    threadModelPreferences.remove(threadStorageKey(profileId, threadId))
                    completedTurnTimings.remove(threadStorageKey(profileId, threadId))
                    contextUsageFallbacks.remove(profileId, threadId)
                    pendingApprovalsByProfile[profileId] = emptyList()
                    applySessionState(profileId) {
                        it.copy(
                            screen = AppScreen.Threads,
                            activeThread = null,
                            activeGoal = null,
                            timeline = emptyList(),
                            olderTurnsCursor = null,
                            olderTurnsLoading = false,
                            activeTurnId = null,
                            running = false,
                            approval = null,
                            approvalQueue = emptyList(),
                            aggregateDiff = "",
                            tokenUsage = null,
                            composerDraft = "",
                            submitting = false,
                        )
                    }
                    persistProfiles()
                    if (isActiveProfile(profileId)) refreshThreads(silent = true)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(submitting = false) }
                }
                finishClientOperation(operation)
                if (threadMutationJobs[profileId] === currentCoroutineContext()[Job]) {
                    threadMutationJobs.remove(profileId)
                }
            }
        }
        threadMutationJobs[profileId] = job
    }

    fun renameActiveThread(name: String) {
        val current = _state.value
        if (current.loading) return
        val profileId = current.selectedProfileId ?: return
        val thread = current.activeThread ?: return
        val client = activeClient() ?: return
        val clean = name.trim()
        if (clean.isBlank()) return
        if (current.submitting || threadMutationJobs[profileId]?.isActive == true) return
        invalidateLane(profileId, "session-navigation")
        val operation = beginClientOperation(profileId, "thread-mutation", client) ?: return
        applySessionState(profileId) { it.copy(submitting = true, error = null) }
        val job = viewModelScope.launch {
            try {
                client.setThreadName(thread.id, clean)
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) {
                        if (it.activeThread?.id == thread.id) {
                            it.copy(activeThread = it.activeThread.copy(title = clean), submitting = false)
                        } else it
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) showError(error, profileId)
            } finally {
                if (isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(submitting = false) }
                }
                finishClientOperation(operation)
                if (threadMutationJobs[profileId] === currentCoroutineContext()[Job]) {
                    threadMutationJobs.remove(profileId)
                }
            }
        }
        threadMutationJobs[profileId] = job
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
                    val mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"
                    val isText = isTextAttachment(name, mimeType)
                    val maximumBytes = if (isText) MAX_INLINE_TEXT_ATTACHMENT_BYTES else MAX_ATTACHMENT_BYTES
                    val sizeError = if (isText) "文本附件不能超过 512 KB" else "附件不能超过 20 MB"
                    require(size <= maximumBytes || size < 0) { sizeError }
                    val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(8 * 1024)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= maximumBytes) { sizeError }
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    } ?: throw IllegalStateException("无法读取附件")
                    AttachmentUploadContent(
                        name = name,
                        mimeType = mimeType,
                        bytes = bytes,
                        textContent = if (isText) String(bytes, Charsets.UTF_8) else null,
                    )
                }
                val remotePath = client.upload(content.name, content.bytes)
                val attachment = PendingAttachment(
                    name = content.name,
                    remotePath = remotePath,
                    mimeType = content.mimeType,
                    textContent = content.textContent,
                )
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

    suspend fun loadImagePreview(path: String): ByteArray {
        currentProfile() ?: throw IllegalStateException("未选择服务器")
        val client = activeClient() ?: throw IllegalStateException("服务器尚未连接")
        check(client.isConnected()) { "服务器尚未连接" }
        return client.downloadImage(path)
    }

    fun removeAttachment(path: String) {
        _state.update { it.copy(attachments = it.attachments.filterNot { file -> file.remotePath == path }) }
    }

    fun updateComposerDraft(value: String) {
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val threadId = current.activeThread?.id ?: return
        val bounded = value.take(MAX_COMPOSER_DRAFT_CHARS)
        val key = composerDraftKey(profileId, threadId)
        if (bounded.isBlank()) composerDrafts.remove(key) else composerDrafts[key] = bounded
        trimComposerDrafts()
        applySessionState(profileId) { state ->
            if (state.activeThread?.id == threadId) state.copy(composerDraft = bounded) else state
        }
        draftPersistJob?.cancel()
        draftPersistJob = viewModelScope.launch {
            delay(500)
            persistProfiles()
            if (draftPersistJob === currentCoroutineContext()[Job]) draftPersistJob = null
        }
    }

    fun selectModel(model: String, effort: String?) {
        persistThreadModelPreference(model, effort.orEmpty())
    }

    fun selectEffort(effort: String) {
        val model = _state.value.selectedModel ?: return
        persistThreadModelPreference(model, effort)
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

    fun showCodexSettings() {
        val profileId = _state.value.selectedProfileId ?: return
        val profile = currentProfile() ?: return
        val client = activeClient()?.takeIf { it.isConnected() } ?: run {
            _state.update { it.copy(error = "服务器未连接，无法读取 Codex 配置") }
            return
        }
        val operation = beginClientOperation(profileId, "codex-settings", client) ?: return
        _state.update {
            it.copy(
                codexSettingsVisible = true,
                codexSettingsLoading = true,
                codexSettingsSaving = false,
                codexSettingsTesting = false,
                codexSettings = null,
                codexSettingsTestResult = null,
                codexSettingsError = null,
            )
        }
        viewModelScope.launch {
            try {
                val settings = client.readCodexGlobalSettings(profile)
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            codexSettingsLoading = false,
                            codexSettings = settings,
                            codexSettingsError = null,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            codexSettingsLoading = false,
                            codexSettingsError = error.message ?: "无法读取 Codex 全局配置",
                        )
                    }
                }
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun dismissCodexSettings() {
        _state.update { current ->
            if (current.codexSettingsSaving || current.codexSettingsTesting) current else {
                current.copy(
                    codexSettingsVisible = false,
                    codexSettingsLoading = false,
                    codexSettingsTesting = false,
                    codexSettings = null,
                    codexSettingsTestResult = null,
                    codexSettingsError = null,
                )
            }
        }
    }

    fun testCodexSettings(baseUrl: String, apiKey: String, proxyUrl: String, testModel: String) {
        val profileId = _state.value.selectedProfileId ?: return
        val profile = currentProfile() ?: return
        val current = _state.value
        if (current.codexSettingsLoading || current.codexSettingsSaving || current.codexSettingsTesting) return
        val client = activeClient()?.takeIf { it.isConnected() } ?: run {
            _state.update { it.copy(codexSettingsError = "服务器未连接，无法测试 Codex API") }
            return
        }
        val operation = beginClientOperation(profileId, "codex-settings", client) ?: return
        _state.update {
            it.copy(
                codexSettingsTesting = true,
                codexSettingsTestResult = null,
                codexSettingsError = null,
            )
        }
        viewModelScope.launch {
            try {
                val result = client.testCodexGlobalSettings(profile, baseUrl, apiKey, proxyUrl, testModel)
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            codexSettingsTesting = false,
                            codexSettingsTestResult = result,
                            codexSettingsError = null,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            codexSettingsTesting = false,
                            codexSettingsTestResult = null,
                            codexSettingsError = error.message ?: "无法测试 Codex API 连接",
                        )
                    }
                }
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun saveCodexSettings(baseUrl: String, apiKey: String, proxyUrl: String, testModel: String) {
        val profileId = _state.value.selectedProfileId ?: return
        val profile = currentProfile() ?: return
        if (_state.value.codexSettingsTesting) return
        val normalizedTestModel = runCatching { RemoteCodexSettings.normalizeTestModel(testModel) }
            .getOrElse { error ->
                _state.update {
                    it.copy(codexSettingsError = error.message ?: "测试模型格式错误")
                }
                return
            }
        val client = activeClient()?.takeIf { it.isConnected() } ?: run {
            _state.update { it.copy(codexSettingsError = "服务器未连接，无法保存 Codex 配置") }
            return
        }
        val operation = beginClientOperation(profileId, "codex-settings", client) ?: return
        _state.update {
            it.copy(
                codexSettingsSaving = true,
                codexSettingsTestResult = null,
                codexSettingsError = null,
            )
        }
        viewModelScope.launch {
            var saved = false
            try {
                client.writeCodexGlobalSettings(profile, baseUrl, apiKey, proxyUrl)
                saved = true
                updateProfileTestModel(profileId, normalizedTestModel)
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            codexSettingsVisible = false,
                            codexSettingsLoading = false,
                            codexSettingsSaving = false,
                            codexSettingsTesting = false,
                            codexSettings = null,
                            codexSettingsTestResult = null,
                            codexSettingsError = null,
                        )
                    }
                }
                DiagnosticLogger.info("CodexSettings", "updated global configuration profile=${profileRef(profileId)}")
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            codexSettingsSaving = false,
                            codexSettingsError = error.message ?: "无法保存 Codex 全局配置",
                        )
                    }
                }
            } finally {
                finishClientOperation(operation)
            }
            if (saved) startDisconnect(profileId)
        }
    }

    fun clearError() {
        _state.update { it.copy(error = null) }
    }

    fun clearDiagnostic() {
        _state.update { it.copy(diagnostic = null) }
    }

    private fun shouldPublishDiagnostic(profileId: String, message: String): Boolean {
        val now = System.currentTimeMillis()
        val key = "$profileId\u0000$message"
        synchronized(surfacedDiagnostics) {
            surfacedDiagnostics.entries.removeIf {
                now - it.value >= DIAGNOSTIC_REPEAT_WINDOW_MS
            }
            if (surfacedDiagnostics.containsKey(key)) return false
            surfacedDiagnostics[key] = now
            while (surfacedDiagnostics.size > MAX_SURFACED_DIAGNOSTICS) {
                surfacedDiagnostics.remove(surfacedDiagnostics.keys.first())
            }
            return true
        }
    }

    fun enableDebugMode() {
        DiagnosticLogger.setEnabled(true)
        _state.update { it.copy(debugModeEnabled = true, diagnostic = "Debug 模式已启用") }
    }

    fun disableDebugMode() {
        DiagnosticLogger.setEnabled(false)
        _state.update { it.copy(debugModeEnabled = false, diagnostic = "Debug 模式已关闭") }
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
        sessionNavigationJobs.remove(profileId)?.cancel()
        threadHistoryJobs.remove(profileId)?.cancel()
        threadMutationJobs.remove(profileId)?.cancel()
        resumeNotificationBuffers.remove(profileId)
        unsupportedGoalProfiles.remove(profileId)
        removeGoalNotificationVersions(profileId)
    }

    private fun invalidateLane(profileId: String, lane: String) {
        if (lane == "session-navigation") {
            sessionNavigationJobs.remove(profileId)?.cancel()
            releasePendingResumeNotifications(profileId)
        } else if (lane == "thread-history") {
            threadHistoryJobs.remove(profileId)?.cancel()
        } else if (lane == "thread-mutation") {
            threadMutationJobs.remove(profileId)?.cancel()
        }
        operations.invalidateLane(profileId, lane)
    }

    private fun releasePendingResumeNotifications(profileId: String) {
        val buffer = resumeNotificationBuffers[profileId] ?: return
        val timeline = if (isActiveProfile(profileId)) {
            _state.value.timeline
        } else {
            sessionSnapshots[profileId]?.timeline.orEmpty()
        }
        releaseResumeNotifications(
            profileId = profileId,
            buffer = buffer,
            snapshot = timeline,
            replay = true,
            snapshotSequence = Long.MIN_VALUE,
        )
    }

    private fun applySessionState(profileId: String, transform: (AppUiState) -> AppUiState) {
        if (isActiveProfile(profileId)) {
            _state.update { current ->
                if (current.selectedProfileId != profileId) return@update current
                enforceActiveTimelineBounds(transform(current)).also { updated ->
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
        sessionSnapshots[profileId] = SessionSnapshot.capture(enforceActiveTimelineBounds(transform(base)))
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
            codexSettingsVisible = false,
            codexSettingsLoading = false,
            codexSettingsSaving = false,
            codexSettingsTesting = false,
            codexSettings = null,
            codexSettingsTestResult = null,
            codexSettingsError = null,
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
        activeAgentName = null,
        activeGoal = null,
        timeline = emptyList(),
        olderTurnsCursor = null,
        olderTurnsLoading = false,
        activeTurnId = null,
        running = false,
        turnTiming = null,
        submitting = false,
        loading = false,
        models = emptyList(),
        selectedModel = null,
        selectedEffort = null,
        composerDraft = "",
        workspacePickerVisible = false,
        workspaceLoading = false,
        workspaceCurrentPath = "",
        workspaceParentPath = null,
        workspaceDirectories = emptyList(),
        workspaceError = null,
        codexSettingsVisible = false,
        codexSettingsLoading = false,
        codexSettingsSaving = false,
        codexSettingsTesting = false,
        codexSettings = null,
        codexSettingsTestResult = null,
        codexSettingsError = null,
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
        terminals.closeProfile(profileId)
        DiagnosticLogger.info("Connection", "disconnect_start profile=${profileRef(profileId)}")
        val expectedClient = connections.client(profileId)
        invalidateProfile(profileId)
        fingerprintJobs[profileId]?.cancel()
        connectionJobs[profileId]?.cancel()
        setupJobs[profileId]?.cancel()
        serverMetricsJobs.remove(profileId)?.cancel()
        sessionSnapshots.remove(profileId)
        contextUsageFallbacks.clear(profileId)
        subAgentNavigationStacks.clear(profileId)
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
                    serverMetrics = current.serverMetrics - profileId,
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
                DiagnosticLogger.info("Connection", "disconnect_success profile=${profileRef(profileId)}")
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

    private suspend fun loadActiveGoalAfterResume(
        profileId: String,
        threadId: String,
        client: CodexAppServerClient,
        operation: ClientOperation,
    ) {
        if (profileId in unsupportedGoalProfiles) return
        val key = threadStorageKey(profileId, threadId)
        val notificationVersion = goalNotificationVersions[key] ?: 0L
        val goal = try {
            client.getThreadGoal(threadId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (isUnsupportedGoalMethod(error)) unsupportedGoalProfiles += profileId
            DiagnosticLogger.warn(
                "Goal",
                "read_failed profile=${profileRef(profileId)} thread=${profileRef(threadId)} ${error.message.orEmpty()}",
            )
            return
        }
        if (!isOperationCurrent(operation) || goalNotificationVersions[key] != notificationVersion) return
        applySessionState(profileId) { current ->
            if (current.activeThread?.id == threadId) current.copy(activeGoal = goal) else current
        }
    }

    private fun markGoalNotification(profileId: String, threadId: String) {
        if (threadId.isBlank()) return
        val key = threadStorageKey(profileId, threadId)
        goalNotificationVersions[key] = (goalNotificationVersions[key] ?: 0L) + 1L
        while (goalNotificationVersions.size > MAX_GOAL_NOTIFICATION_VERSIONS) {
            goalNotificationVersions.remove(goalNotificationVersions.keys.first())
        }
    }

    private fun removeGoalNotificationVersions(profileId: String) {
        val prefix = "$profileId\u0000"
        goalNotificationVersions.keys.removeAll { it.startsWith(prefix) }
    }

    private fun isUnsupportedGoalMethod(error: Throwable): Boolean {
        val message = error.message.orEmpty()
        return message.contains("method not found", ignoreCase = true) ||
            message.contains("unknown method", ignoreCase = true)
    }

    private fun reduceProfileNotification(event: ProfiledCodexNotification) {
        val profileId = event.profileId
        val client = connections.client(profileId) ?: return
        val notification = event.value
        if (!client.isGenerationActive(notification.generation)) return
        if (notification.method == "thread/goal/updated" || notification.method == "thread/goal/cleared") {
            markGoalNotification(profileId, notification.params.string("threadId"))
        }
        if (notification.method == "turn/completed") {
            publishTurnCompletion(profileId, notification.params.string("threadId"))
        }
        resumeNotificationBuffers[profileId]?.let { buffer ->
            if (buffer.offer(notification)) return
        }
        applySessionState(profileId) { current ->
            CodexEventReducer.reduce(current, notification.method, notification.params)
        }
        syncCompletedTurnTiming(profileId, notification.method, notification.params)
        if (notification.method == "turn/completed" || notification.method == "thread/tokenUsage/updated") {
            sessionSnapshots[profileId]?.activeThread?.let { thread ->
                val snapshot = sessionSnapshots[profileId]
                rememberContextUsage(profileId, thread.id, snapshot?.tokenUsage)
                client.cacheThread(
                    thread,
                    snapshot?.timeline.orEmpty(),
                    snapshot?.olderTurnsCursor,
                    snapshot?.tokenUsage,
                )
            }
        }
        if (notification.method == "turn/completed") {
            if (isActiveProfile(profileId)) refreshThreads(silent = true)
        }
    }

    private fun publishTurnCompletion(profileId: String, reportedThreadId: String) {
        val current = _state.value
        val snapshot = sessionSnapshots[profileId]
        val activeThread = if (current.selectedProfileId == profileId) current.activeThread else snapshot?.activeThread
        val threadId = reportedThreadId.ifBlank { activeThread?.id.orEmpty() }
        if (threadId.isBlank()) return
        val thread = if (current.selectedProfileId == profileId) {
            current.threads.firstOrNull { it.id == threadId }
        } else {
            snapshot?.threads?.firstOrNull { it.id == threadId }
        } ?: activeThread?.takeIf { it.id == threadId }
        val profile = current.profiles.firstOrNull { it.id == profileId } ?: return
        _turnCompletions.tryEmit(
            TurnCompletion(
                profileId = profileId,
                profileName = profile.name.ifBlank { profile.host },
                threadId = threadId,
                threadTitle = thread?.title.orEmpty(),
                threadPreview = thread?.preview.orEmpty(),
            ),
        )
    }

    private fun releaseResumeNotifications(
        profileId: String,
        buffer: ResumeNotificationBuffer,
        snapshot: List<top.asdb.codexremote.data.TimelineEntry>,
        replay: Boolean,
        snapshotSequence: Long = Long.MAX_VALUE,
    ) {
        if (resumeNotificationBuffers[profileId] !== buffer) return
        resumeNotificationBuffers.remove(profileId)
        if (!replay) return
        val client = connections.client(profileId) ?: return
        val notifications = buffer.drain(snapshot, snapshotSequence).filter { notification ->
            client.isGenerationActive(notification.generation)
        }
        var reducedState: AppUiState? = null
        if (notifications.isNotEmpty()) {
            applySessionState(profileId) { current ->
                notifications.fold(current) { state, notification ->
                    CodexEventReducer.reduce(state, notification.method, notification.params)
                }.also { reducedState = it }
            }
        }
        if (notifications.any {
            it.method == "turn/completed" || it.method == "thread/tokenUsage/updated"
        }) {
            val snapshotState = reducedState ?: if (isActiveProfile(profileId)) {
                _state.value
            } else {
                sessionSnapshots[profileId]?.restore(AppUiState(selectedProfileId = profileId))
            }
            snapshotState?.activeThread?.let { thread ->
                rememberContextUsage(profileId, thread.id, snapshotState.tokenUsage)
                client.cacheThread(
                    thread,
                    snapshotState.timeline,
                    snapshotState.olderTurnsCursor,
                    snapshotState.tokenUsage,
                )
            }
        }
        if (notifications.any { it.method == "turn/completed" }) {
            if (isActiveProfile(profileId)) refreshThreads(silent = true)
        }
        if (buffer.overflowed && isActiveProfile(profileId)) {
            _state.update { it.copy(diagnostic = "恢复会话期间输出过多，部分流式内容已截断") }
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
        subAgentNavigationStacks.clear(profileId)
        val failureMessage = presentCodexDiagnostic(
            event.value.message,
            ConnectionPhase.Failed,
        ).ifBlank { "Codex SSH 通道已关闭" }
        val snapshot = sessionSnapshots[profileId]
        if (snapshot != null) {
            sessionSnapshots[profileId] = snapshot.copy(
                activeTurnId = null,
                running = false,
                loading = false,
                submitting = false,
                olderTurnsLoading = false,
            )
        }
        pendingApprovalsByProfile.remove(profileId)
        setupStates.remove(profileId)
        if (!isActiveProfile(profileId)) return
        _state.update {
            it.copy(
                connectionStates = it.connectionStates + (
                    profileId to ConnectionState(ConnectionPhase.Failed, failureMessage)
                ),
                connection = ConnectionState(ConnectionPhase.Failed, failureMessage),
                running = false,
                loading = false,
                submitting = false,
                olderTurnsLoading = false,
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
        DiagnosticLogger.info(
            "Connection",
            "connect_success profile=${profileRef(profile.id)} version=${connected.version} threads=${connected.threads.size} models=${connected.models.size}",
        )
        val defaultModel = connected.models.firstOrNull { it.isDefault } ?: connected.models.firstOrNull()
        val preferredSelection = resolveModelSelection(
            models = connected.models,
            preferredModel = profile.preferredModel,
            preferredEffort = profile.preferredEffort,
        )
        val pinned = isPinnedVersion(connected.version)
        val versionMessage = if (pinned) {
            "已连接 · Codex ${BuildConfig.PINNED_CODEX_VERSION}"
        } else {
            "已连接 · ${connected.version}"
        }
        val connectedState = ConnectionState(ConnectionPhase.Connected, versionMessage, connected.version)
        setupStates.remove(profile.id)
        setupProfiles.remove(profile.id)
        pendingFingerprints.remove(profile.id)
        fingerprintProfiles.remove(profile.id)
        subAgentNavigationStacks.clear(profile.id)
        if (!isActiveProfile(profile.id)) {
            sessionSnapshots[profile.id] = SessionSnapshot(
                threads = connected.threads,
                models = connected.models,
                selectedModel = preferredSelection.model ?: defaultModel?.model,
                selectedEffort = preferredSelection.effort ?: defaultModel?.defaultEffort,
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
        val showInitialWorkspacePrompt = profile.workspace.isBlank() && !profile.workspacePromptShown
        _state.update {
            val profiles = it.profiles.map { stored ->
                if (stored.id == profile.id && !stored.workspacePromptShown) {
                    stored.copy(workspacePromptShown = true)
                } else stored
            }
            it.copy(
                profiles = profiles,
                screen = AppScreen.Threads,
                connection = connectedState,
                connectionStates = it.connectionStates + (profile.id to connectedState),
                threads = connected.threads,
                models = connected.models,
                selectedModel = preferredSelection.model ?: defaultModel?.model,
                selectedEffort = preferredSelection.effort ?: defaultModel?.defaultEffort,
                approvalMode = profile.approvalMode,
                sandbox = profile.approvalMode.sandbox,
                workspacePickerVisible = showInitialWorkspacePrompt,
                workspaceLoading = false,
                workspaceCurrentPath = connected.workspace?.currentPath
                    ?: profile.workspace.ifBlank { "/" },
                workspaceParentPath = connected.workspace?.parentPath,
                workspaceDirectories = connected.workspace?.directories.orEmpty(),
                workspaceError = connected.workspaceError,
                activeThread = null,
                activeAgentName = null,
                activeGoal = null,
                timeline = emptyList(),
                olderTurnsCursor = null,
                olderTurnsLoading = false,
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
        persistProfiles()
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
        testModel = profile.testModel.trim(),
    )

    private fun updateProfileTestModel(profileId: String, testModel: String) {
        _state.update { current ->
            current.copy(
                profiles = current.profiles.map { profile ->
                    if (profile.id == profileId) profile.copy(testModel = testModel) else profile
                },
            )
        }
        persistProfiles()
    }

    private fun persistProfiles() {
        val state = _state.value
        store.save(
            StoredProfiles(
                profiles = state.profiles,
                selectedProfileId = state.selectedProfileId,
                composerDrafts = composerDrafts.toMap(),
                threadModelPreferences = threadModelPreferences.toMap(),
                completedTurnTimings = completedTurnTimings.toMap(),
            ),
        )
    }

    private fun persistThreadModelPreference(model: String, effort: String) {
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val threadId = current.activeThread?.id ?: return
        threadModelPreferences[threadStorageKey(profileId, threadId)] =
            ThreadModelPreference(model = model, effort = effort)
        trimThreadModelPreferences()
        applySessionState(profileId) { state ->
            if (state.activeThread?.id == threadId) {
                state.copy(selectedModel = model, selectedEffort = effort.ifBlank { null })
            } else state
        }
        persistProfiles()
    }

    private fun resolveThreadModelSelection(
        profileId: String,
        threadId: String,
        models: List<top.asdb.codexremote.data.CodexModel>,
    ): ResolvedModelSelection {
        val stored = threadModelPreferences[threadStorageKey(profileId, threadId)]
        val profile = _state.value.profiles.firstOrNull { it.id == profileId }
        return resolveThreadModelSelection(
            models = models,
            preference = stored,
            fallbackModel = profile?.preferredModel.orEmpty(),
            fallbackEffort = profile?.preferredEffort.orEmpty(),
        )
    }

    private fun rememberThreadModelPreference(
        profileId: String,
        threadId: String,
        selection: ResolvedModelSelection,
    ) {
        val model = selection.model ?: return
        threadModelPreferences[threadStorageKey(profileId, threadId)] =
            ThreadModelPreference(model, selection.effort.orEmpty())
        trimThreadModelPreferences()
        persistProfiles()
    }

    private fun composerDraft(profileId: String, threadId: String): String =
        composerDrafts[composerDraftKey(profileId, threadId)].orEmpty()

    private fun removeComposerDrafts(profileId: String) {
        val prefix = "$profileId\u0000"
        composerDrafts.keys.removeAll { it.startsWith(prefix) }
    }

    private fun removeThreadModelPreferences(profileId: String) {
        val prefix = "$profileId\u0000"
        threadModelPreferences.keys.removeAll { it.startsWith(prefix) }
    }

    private fun restoredTurnTiming(
        profileId: String,
        threadId: String,
        running: Boolean,
        current: TurnTiming? = null,
    ): TurnTiming? {
        if (running || threadId.isBlank()) return null
        return current?.takeIf { it.threadId == threadId && it.completedAtMillis != null }
            ?: completedTurnTimings[threadStorageKey(profileId, threadId)]
                ?.takeIf { it.threadId == threadId && it.completedAtMillis != null }
    }

    private fun syncCompletedTurnTiming(
        profileId: String,
        method: String,
        params: kotlinx.serialization.json.JsonObject,
    ) {
        if (method !in TURN_TIMING_EVENT_METHODS) return
        val snapshot = sessionSnapshots[profileId]
        val timing = snapshot?.turnTiming
        val threadId = params.string("threadId").ifBlank { timing?.threadId.orEmpty() }
        if (threadId.isBlank()) return
        val key = threadStorageKey(profileId, threadId)
        val completed = timing?.takeIf { it.threadId == threadId && it.completedAtMillis != null }
        val changed = when {
            completed != null && completedTurnTimings[key] != completed -> {
                completedTurnTimings[key] = completed
                trimCompletedTurnTimings()
                true
            }

            method == "turn/started" ||
                (method == "thread/status/changed" &&
                    snapshot?.activeThread?.id == threadId && snapshot.running) -> {
                completedTurnTimings.remove(key) != null
            }

            else -> false
        }
        if (changed) persistProfiles()
    }

    private fun removeCompletedTurnTimings(profileId: String) {
        val prefix = "$profileId\u0000"
        completedTurnTimings.keys.removeAll { it.startsWith(prefix) }
    }

    private fun rememberContextUsage(profileId: String, threadId: String, usage: TokenUsage?) {
        usage?.let { contextUsageFallbacks.remember(profileId, threadId, it) }
    }

    private fun trimComposerDrafts() {
        while (composerDrafts.size > MAX_COMPOSER_DRAFTS) {
            composerDrafts.remove(composerDrafts.keys.first())
        }
    }

    private fun trimThreadModelPreferences() {
        while (threadModelPreferences.size > MAX_THREAD_MODEL_PREFERENCES) {
            threadModelPreferences.remove(threadModelPreferences.keys.first())
        }
    }

    private fun trimCompletedTurnTimings() {
        while (completedTurnTimings.size > MAX_COMPLETED_TURN_TIMINGS) {
            completedTurnTimings.remove(completedTurnTimings.keys.first())
        }
    }

    private fun showConnectionError(error: Throwable, profileId: String? = _state.value.selectedProfileId) {
        profileId ?: return
        val message = presentCodexDiagnostic(error.message.orEmpty(), ConnectionPhase.Failed)
            .ifBlank { "连接失败" }
        DiagnosticLogger.error(
            "Connection",
            "connect_failed profile=${profileRef(profileId)}",
            error,
        )
        updateProfileConnection(profileId, ConnectionState(ConnectionPhase.Failed, message))
        applySessionState(profileId) {
            it.copy(
                connection = ConnectionState(ConnectionPhase.Failed, message),
                loading = false,
                error = message,
            )
        }
    }

    private fun showError(error: Throwable, profileId: String? = _state.value.selectedProfileId) {
        profileId ?: return
        val message = userFacingErrorMessage(error, profileId, "操作失败")
        DiagnosticLogger.error("Operation", "failed profile=${profileRef(profileId)}", error)
        applySessionState(profileId) {
            it.copy(loading = false, submitting = false, error = message)
        }
    }

    private fun userFacingErrorMessage(
        error: Throwable,
        profileId: String,
        fallback: String,
    ): String {
        val phase = _state.value.connectionStates[profileId]?.phase
            ?: _state.value.connection.phase.takeIf { isActiveProfile(profileId) }
        return presentCodexDiagnostic(error.message.orEmpty(), phase).ifBlank { fallback }
    }

    private fun isPinnedVersion(userAgent: String): Boolean {
        val version = Regex.escape(BuildConfig.PINNED_CODEX_VERSION)
        return Regex("(^|[/\\s])$version(?=$|[\\s(])").containsMatchIn(userAgent)
    }

    companion object {
        private const val MAX_ATTACHMENT_BYTES = 20L * 1024 * 1024
        private const val MAX_INLINE_TEXT_ATTACHMENT_BYTES = 512L * 1024
        private const val MAX_PENDING_APPROVALS = 8
        private const val MAX_COMPOSER_DRAFTS = 64
        private const val MAX_COMPOSER_DRAFT_CHARS = 100_000
        private const val MAX_THREAD_MODEL_PREFERENCES = 512
        private const val MAX_COMPLETED_TURN_TIMINGS = 512
        private const val MAX_GOAL_OBJECTIVE_CHARS = 4_000
        private val TURN_TIMING_EVENT_METHODS = setOf(
            "turn/started",
            "turn/completed",
            "thread/status/changed",
        )
        private const val DIAGNOSTIC_REPEAT_WINDOW_MS = 30_000L
        private const val MAX_SURFACED_DIAGNOSTICS = 64
    }
}

private data class AttachmentUploadContent(
    val name: String,
    val mimeType: String,
    val bytes: ByteArray,
    val textContent: String?,
)

private fun isTextAttachment(name: String, mimeType: String): Boolean {
    if (mimeType.substringBefore(';').trim().lowercase(Locale.ROOT).startsWith("text/")) return true
    val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
    return extension in TEXT_ATTACHMENT_EXTENSIONS
}

private val TEXT_ATTACHMENT_EXTENSIONS = setOf(
    "cfg", "conf", "csv", "css", "env", "gradle", "html", "ini", "java", "js", "json", "jsonl",
    "kt", "kts", "log", "markdown", "md", "properties", "py", "sh", "sql", "toml", "ts", "tsx",
    "txt", "xml", "yaml", "yml",
)

private fun profileRef(value: String): String = value.take(8).ifBlank { "unknown" }

internal fun shouldHoldConnectedUntilSessionReady(
    local: ConnectionState?,
    remote: ConnectionState,
    preparingActiveConnection: Boolean,
): Boolean = preparingActiveConnection &&
    local?.phase == ConnectionPhase.Connecting &&
    remote.phase == ConnectionPhase.Connected

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

private fun TimelineEntry.sessionIdentity(): String = "$turnId\u0000$kind\u0000$id"

internal data class ResolvedModelSelection(val model: String?, val effort: String?)

internal fun resolveModelSelection(
    models: List<top.asdb.codexremote.data.CodexModel>,
    preferredModel: String,
    preferredEffort: String,
): ResolvedModelSelection {
    val selected = models.firstOrNull { it.model == preferredModel }
        ?: models.firstOrNull { it.isDefault }
        ?: models.firstOrNull()
        ?: return ResolvedModelSelection(null, null)
    val effort = preferredEffort.takeIf {
        it.isNotBlank() && (selected.efforts.isEmpty() || it in selected.efforts)
    } ?: selected.defaultEffort.takeIf(String::isNotBlank)
    return ResolvedModelSelection(selected.model, effort)
}

internal fun resolveThreadModelSelection(
    models: List<top.asdb.codexremote.data.CodexModel>,
    preference: ThreadModelPreference?,
    fallbackModel: String,
    fallbackEffort: String,
): ResolvedModelSelection = resolveModelSelection(
    models = models,
    preferredModel = preference?.model ?: fallbackModel,
    preferredEffort = preference?.effort ?: fallbackEffort,
)

internal fun sanitizeCodexDiagnostic(message: String): String =
    ANSI_ESCAPE_REGEX.replace(message, "").trim()

internal fun shouldSurfaceCodexDiagnostic(message: String): Boolean {
    if (message.isBlank()) return false
    return !message.contains("could not find bubblewrap", ignoreCase = true) &&
        !message.contains("sandboxing#prerequisites", ignoreCase = true) &&
        !message.contains("will use the bun", ignoreCase = true)
}

/**
 * Converts remote stderr into a short message suitable for a transient UI surface.
 *
 * Codex can keep its app-server session alive while an optional MCP/rmcp worker is rejected by an
 * upstream gateway. The raw worker line is useful for diagnostics, but showing its nested JSON in a
 * Snackbar makes a healthy session look broken.
 */
internal fun presentCodexDiagnostic(
    message: String,
    connectionPhase: ConnectionPhase? = null,
): String {
    val cleaned = sanitizeCodexDiagnostic(message)
    if (cleaned.isBlank()) return ""
    val normalized = cleaned
        .replace(CODEX_ESCAPED_QUOTE_REGEX, "\"")
        .replace(CODEX_ESCAPED_NEWLINE_REGEX, " ")
        .replace(CODEX_DIAGNOSTIC_WHITESPACE_REGEX, " ")
        .replaceFirst(CODEX_LOG_PREFIX_REGEX, "")
        .trim()
    val isForbidden = normalized.contains("HTTP 403", ignoreCase = true) ||
        normalized.contains("Forbidden", ignoreCase = true)
    val isRmcpWorker = normalized.contains("rmcp::transport::worker", ignoreCase = true)
    if (isForbidden && isRmcpWorker) {
        return if (connectionPhase == ConnectionPhase.Connected) {
            "远端工具服务返回 403，但当前会话仍正常；相关工具可能暂时不可用"
        } else {
            "远端工具服务返回 403，请检查服务器登录、代理或权限"
        }
    }
    if (isForbidden) {
        return if (connectionPhase == ConnectionPhase.Connected) {
            "远端服务返回 403，但当前会话仍正常；可能是权限或代理限制"
        } else {
            "远端服务返回 403，请检查登录状态、权限或代理设置"
        }
    }
    if (normalized.contains("HTTP 503", ignoreCase = true)) {
        return "远端服务暂时不可用（503），当前连接仍在工作；请稍后重试"
    }
    if (normalized.contains("transport channel closed", ignoreCase = true) &&
        connectionPhase == ConnectionPhase.Connected
    ) {
        return "远端工具通道已关闭，但当前会话仍连接；相关工具可能暂时不可用"
    }
    return normalized.take(MAX_SURFACED_DIAGNOSTIC_CHARS)
}

private fun composerDraftKey(profileId: String, threadId: String): String =
    "$profileId\u0000$threadId"

private fun threadStorageKey(profileId: String, threadId: String): String =
    "$profileId\u0000$threadId"

private val ANSI_ESCAPE_REGEX = Regex("\\u001B\\[[0-9;]*[A-Za-z]")
private val CODEX_ESCAPED_QUOTE_REGEX = Regex("\\\\\"")
private val CODEX_ESCAPED_NEWLINE_REGEX = Regex("\\\\r?\\\\n")
private val CODEX_DIAGNOSTIC_WHITESPACE_REGEX = Regex("\\s+")
private val CODEX_LOG_PREFIX_REGEX = Regex("^\\S+\\s+(?:ERROR|WARN|WARNING|INFO)\\s+")
private const val MAX_SURFACED_DIAGNOSTIC_CHARS = 180

internal data class OlderTimelineMerge(
    val timeline: List<TimelineEntry>,
    val accepted: Boolean,
)

internal data class BoundedTimeline(
    val timeline: List<TimelineEntry>,
    val truncated: Boolean,
)

internal fun boundActiveTimeline(
    timeline: List<TimelineEntry>,
    maxWeightChars: Int = MAX_ACTIVE_TIMELINE_WEIGHT_CHARS,
    maxEntries: Int = MAX_ACTIVE_TIMELINE_ENTRIES,
): BoundedTimeline {
    require(maxWeightChars > 0)
    require(maxEntries > 0)
    if (timeline.size <= maxEntries && estimateTimelineWeightChars(timeline) <= maxWeightChars) {
        return BoundedTimeline(timeline, truncated = false)
    }
    val newest = ArrayList<TimelineEntry>(minOf(timeline.size, maxEntries))
    var weight = 0
    for (index in timeline.indices.reversed()) {
        val entry = timeline[index]
        val entryWeight = estimateTimelineWeightChars(listOf(entry))
        if (newest.size >= maxEntries || entryWeight > maxWeightChars - weight) break
        newest += entry
        weight += entryWeight
    }
    newest.reverse()
    return BoundedTimeline(newest, truncated = true)
}

private fun enforceActiveTimelineBounds(state: AppUiState): AppUiState {
    val bounded = boundActiveTimeline(state.timeline)
    if (!bounded.truncated) return state
    return state.copy(
        timeline = bounded.timeline,
        olderTurnsCursor = null,
        olderTurnsLoading = false,
        diagnostic = state.diagnostic
            ?: "会话内容过多，已仅保留最近内容以避免内存不足；重新进入可按页查看历史",
    )
}

internal fun prependOlderTimeline(
    existing: List<TimelineEntry>,
    older: List<TimelineEntry>,
    maxWeightChars: Int = MAX_ACTIVE_TIMELINE_WEIGHT_CHARS,
    maxEntries: Int = MAX_ACTIVE_TIMELINE_ENTRIES,
): OlderTimelineMerge {
    val identities = existing.mapTo(HashSet()) { it.sessionIdentity() }
    val uniqueOlder = older.filter { identities.add(it.sessionIdentity()) }
    if (uniqueOlder.isEmpty()) return OlderTimelineMerge(existing, accepted = true)
    val merged = uniqueOlder + existing
    val accepted = merged.size <= maxEntries && estimateTimelineWeightChars(merged) <= maxWeightChars
    return OlderTimelineMerge(if (accepted) merged else existing, accepted)
}

internal data class ResumedTimelineMerge(
    val timeline: List<TimelineEntry>,
    val nextCursor: String?,
)

internal fun reconcileResumedTimeline(
    cachedTimeline: List<TimelineEntry>?,
    cachedNextCursor: String?,
    refreshedTimeline: List<TimelineEntry>,
    refreshedNextCursor: String?,
    refreshedTurnIds: List<String> = refreshedTimeline.mapNotNull { it.turnId.takeIf(String::isNotBlank) },
    cachedThreadUpdatedAt: Long? = null,
    refreshedThreadUpdatedAt: Long? = null,
    refreshedItemsView: String = "full",
): ResumedTimelineMerge {
    val refreshedTurns = refreshedTurnIds.toHashSet()
    val overlapIndex = cachedTimeline?.indexOfFirst { it.turnId in refreshedTurns } ?: -1
    val retainedPrefix = cachedTimeline?.take(overlapIndex.coerceAtLeast(0)).orEmpty()
    val revisionUnchanged = cachedThreadUpdatedAt != null &&
        refreshedThreadUpdatedAt != null &&
        cachedThreadUpdatedAt == refreshedThreadUpdatedAt
    val cachedBoundaryUsable = cachedNextCursor != null || refreshedNextCursor == null
    val hasVerifiedOverlap = overlapIndex >= 0 && revisionUnchanged && cachedBoundaryUsable
    val unchangedSummary = cachedTimeline != null && revisionUnchanged && cachedBoundaryUsable &&
        refreshedItemsView == "summary"
    val unchangedNotLoaded = cachedTimeline != null && revisionUnchanged && cachedBoundaryUsable &&
        refreshedItemsView == "notLoaded"
    val unchangedEmptyPage = cachedTimeline != null && refreshedTimeline.isEmpty() &&
        cachedNextCursor == refreshedNextCursor && revisionUnchanged
    return ResumedTimelineMerge(
        timeline = if (unchangedNotLoaded || unchangedEmptyPage) {
            cachedTimeline.orEmpty()
        } else if (unchangedSummary) {
            mergeSummaryTimeline(cachedTimeline.orEmpty(), refreshedTimeline)
        } else if (hasVerifiedOverlap) {
            retainedPrefix + refreshedTimeline
        } else {
            refreshedTimeline
        },
        nextCursor = if (hasVerifiedOverlap || unchangedSummary || unchangedNotLoaded || unchangedEmptyPage) {
            cachedNextCursor
        } else {
            refreshedNextCursor
        },
    )
}

private fun mergeSummaryTimeline(
    cached: List<TimelineEntry>,
    summary: List<TimelineEntry>,
): List<TimelineEntry> {
    val replacements = summary.associateBy(TimelineEntry::sessionIdentity)
    val cachedIdentities = cached.mapTo(HashSet(), TimelineEntry::sessionIdentity)
    return cached.map { replacements[it.sessionIdentity()] ?: it } +
        summary.filter { it.sessionIdentity() !in cachedIdentities }
}

private const val MAX_ACTIVE_TIMELINE_WEIGHT_CHARS = 8 * 1024 * 1024
private const val MAX_ACTIVE_TIMELINE_ENTRIES = 1_024
private const val MAX_GOAL_NOTIFICATION_VERSIONS = 512
private const val MAX_SUB_AGENT_NAVIGATION_DEPTH = 8

private data class SubAgentNavigationFrame(
    val snapshot: SessionSnapshot,
    val screen: AppScreen,
)

private data class SessionSnapshot(
    val threads: List<top.asdb.codexremote.data.CodexThread> = emptyList(),
    val threadSearch: String = "",
    val models: List<top.asdb.codexremote.data.CodexModel> = emptyList(),
    val selectedModel: String? = null,
    val selectedEffort: String? = null,
    val activeThread: top.asdb.codexremote.data.CodexThread? = null,
    val activeAgentName: String? = null,
    val activeGoal: ThreadGoal? = null,
    val timeline: List<top.asdb.codexremote.data.TimelineEntry> = emptyList(),
    val olderTurnsCursor: String? = null,
    val olderTurnsLoading: Boolean = false,
    val activeTurnId: String? = null,
    val running: Boolean = false,
    val turnTiming: TurnTiming? = null,
    val submitting: Boolean = false,
    val loading: Boolean = false,
    val aggregateDiff: String = "",
    val tokenUsage: top.asdb.codexremote.data.TokenUsage? = null,
    val attachments: List<PendingAttachment> = emptyList(),
    val composerClearNonce: Int = 0,
    val composerDraft: String = "",
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
        activeAgentName = activeAgentName,
        activeGoal = activeGoal,
        timeline = timeline,
        olderTurnsCursor = olderTurnsCursor,
        // Loading is tied to a live request and cannot safely survive a profile/session restore.
        olderTurnsLoading = false,
        activeTurnId = activeTurnId,
        running = running,
        turnTiming = turnTiming,
        submitting = submitting,
        loading = loading,
        aggregateDiff = aggregateDiff,
        tokenUsage = tokenUsage,
        attachments = attachments,
        composerClearNonce = composerClearNonce,
        composerDraft = composerDraft,
        workspaceCurrentPath = workspaceCurrentPath,
        workspaceParentPath = workspaceParentPath,
        workspaceDirectories = workspaceDirectories,
        workspaceError = workspaceError,
        error = error,
        diagnostic = diagnostic,
    )

    companion object {
        fun capture(state: AppUiState): SessionSnapshot {
            val bounded = boundActiveTimeline(
                state.timeline,
                maxWeightChars = MAX_SESSION_SNAPSHOT_WEIGHT_CHARS,
                maxEntries = MAX_SESSION_SNAPSHOT_ENTRIES,
            )
            return SessionSnapshot(
                threads = state.threads,
                threadSearch = state.threadSearch,
                models = state.models,
                selectedModel = state.selectedModel,
                selectedEffort = state.selectedEffort,
                activeThread = state.activeThread,
                activeAgentName = state.activeAgentName,
                activeGoal = state.activeGoal,
                timeline = bounded.timeline,
                olderTurnsCursor = state.olderTurnsCursor.takeUnless { bounded.truncated },
                // Do not cache transient request state. A restored loading flag would leave the
                // pull indicator visible even though its original request no longer exists.
                olderTurnsLoading = false,
                activeTurnId = state.activeTurnId,
                running = state.running,
                turnTiming = state.turnTiming,
                submitting = state.submitting,
                loading = state.loading,
                aggregateDiff = state.aggregateDiff,
                tokenUsage = state.tokenUsage,
                attachments = state.attachments,
                composerClearNonce = state.composerClearNonce,
                composerDraft = state.composerDraft,
                workspaceCurrentPath = state.workspaceCurrentPath,
                workspaceParentPath = state.workspaceParentPath,
                workspaceDirectories = state.workspaceDirectories,
                workspaceError = state.workspaceError,
                error = state.error,
                diagnostic = state.diagnostic,
            )
        }
    }
}

private const val MAX_PROFILE_SESSION_SNAPSHOTS = 6
private const val MAX_SESSION_SNAPSHOT_WEIGHT_CHARS = 2 * 1024 * 1024
private const val MAX_SESSION_SNAPSHOT_ENTRIES = 512
