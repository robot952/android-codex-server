package top.asdb.codexremote

import android.app.Application
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import top.asdb.codexremote.agent.AgentConnectionManager
import top.asdb.codexremote.agent.AgentClientRegistry
import top.asdb.codexremote.agent.ProfiledAgentApproval
import top.asdb.codexremote.agent.ProfiledAgentConnectionEvent
import top.asdb.codexremote.agent.ProfiledAgentNotification
import top.asdb.codexremote.agent.RemoteAgentClient
import top.asdb.codexremote.agent.normalizeOpenCodeModelId
import top.asdb.codexremote.agent.openCodeReasoningEfforts
import top.asdb.codexremote.codex.CodexEventReducer
import top.asdb.codexremote.codex.ResumeNotificationBuffer
import top.asdb.codexremote.codex.estimateTimelineWeightChars
import top.asdb.codexremote.codex.ProfileOperationTracker
import top.asdb.codexremote.codex.string
import top.asdb.codexremote.data.ApiModelOption
import top.asdb.codexremote.data.AgentCapabilities
import top.asdb.codexremote.data.AgentConnectionKey
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.data.AgentModelSettings
import top.asdb.codexremote.data.AgentSetupState
import top.asdb.codexremote.data.AppScreen
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.ApprovalMode
import top.asdb.codexremote.data.ApprovalPrompt
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState
import top.asdb.codexremote.data.CodexModel
import top.asdb.codexremote.data.CustomModelDefinition
import top.asdb.codexremote.data.PendingAttachment
import top.asdb.codexremote.data.ProfileStore
import top.asdb.codexremote.data.RemoteDirectoryListing
import top.asdb.codexremote.data.RemoteFileClipboard
import top.asdb.codexremote.data.RemoteFileEntry
import top.asdb.codexremote.data.RemoteFileListing
import top.asdb.codexremote.data.RemoteFileTransferMode
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
import top.asdb.codexremote.data.normalizeEpochMillis
import top.asdb.codexremote.data.modelSettings
import top.asdb.codexremote.data.withModelSettings
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import top.asdb.codexremote.diagnostics.recordConnectionTiming
import top.asdb.codexremote.ssh.RemoteBootstrap
import top.asdb.codexremote.ssh.RemoteCodexSettings
import top.asdb.codexremote.ssh.RemoteServerClient
import top.asdb.codexremote.ssh.SshServerConnectionManager
import top.asdb.codexremote.ssh.SshTerminalManager
import top.asdb.codexremote.ssh.SshTerminalOutputBatch
import java.io.ByteArrayOutputStream
import java.util.LinkedHashMap
import java.util.Locale
import java.util.UUID

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val store = ProfileStore(application)
    private val connections = AgentConnectionManager(
        viewModelScope,
        AgentClientRegistry.default {
            application.assets.open("opencode-bridge.cjs").bufferedReader().use { it.readText() }
        },
    )
    private val hosts = SshServerConnectionManager(viewModelScope)
    private val terminals = SshTerminalManager(viewModelScope)
    private val loaded = store.load()
    private val saved = loaded.copy(profiles = loaded.profiles.map(::normalizeProfile))
    private val initialProfileId = saved.selectedProfileId
        ?.takeIf { selected -> saved.profiles.any { it.id == selected } }
        ?: saved.profiles.firstOrNull()?.id
    private val initialProfile = saved.profiles.firstOrNull { it.id == initialProfileId }
    private val fingerprintProfiles = mutableMapOf<String, ServerProfile>()
    private val setupProfiles = mutableMapOf<AgentConnectionKey, ServerProfile>()
    private val fingerprintJobs = mutableMapOf<String, Job>()
    private val connectionJobs = mutableMapOf<String, Job>()
    private val connectionSyncJobs = mutableMapOf<AgentConnectionKey, Job>()
    private val setupJobs = mutableMapOf<AgentConnectionKey, Job>()
    private val setupMutexes = mutableMapOf<String, Mutex>()
    private val disconnectJobs = mutableMapOf<String, Job>()
    private val uninstallJobs = mutableMapOf<String, Job>()
    private val serverMetricsJobs = mutableMapOf<String, Job>()
    private val sessionNavigationJobs = mutableMapOf<String, Job>()
    private val threadHistoryJobs = mutableMapOf<String, Job>()
    private val threadMutationJobs = mutableMapOf<String, Job>()
    private val customModelSyncJobs = mutableMapOf<AgentConnectionKey, Job>()
    private val customModelSyncRevisions = mutableMapOf<AgentConnectionKey, Long>()
    private val customModelSyncMutexes = mutableMapOf<AgentConnectionKey, Mutex>()
    private var draftPersistJob: Job? = null
    private val sessionSnapshots =
        object : LinkedHashMap<AgentConnectionKey, SessionSnapshot>(8, 0.75f, true) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<AgentConnectionKey, SessionSnapshot>?,
        ): Boolean =
            size > MAX_PROFILE_SESSION_SNAPSHOTS
    }
    private val contextUsageFallbacks = ProfileScopedContextUsageCache()
    private val subAgentNavigationStacks = ProfileScopedBackStack<SubAgentNavigationFrame>()
    private val pendingApprovalsByAgent = mutableMapOf<AgentConnectionKey, List<ApprovalPrompt>>()
    private val resumeNotificationBuffers = mutableMapOf<AgentConnectionKey, ResumeNotificationBuffer>()
    private val unsupportedGoalAgents = mutableSetOf<AgentConnectionKey>()
    private val goalNotificationVersions = LinkedHashMap<String, Long>()
    private val composerDrafts = LinkedHashMap<String, String>().apply {
        loaded.composerDrafts.entries.toList().takeLast(MAX_COMPOSER_DRAFTS).forEach { (key, value) ->
            if (key.isNotBlank() && value.isNotBlank()) put(key, value.take(MAX_COMPOSER_DRAFT_CHARS))
        }
    }
    private val threadModelPreferences = LinkedHashMap<String, ThreadModelPreference>().apply {
        loaded.threadModelPreferences.entries.toList().takeLast(MAX_THREAD_MODEL_PREFERENCES)
            .forEach { (key, preference) ->
                if (key.isNotBlank() && preference.model.isNotBlank()) {
                    val normalized = if (key.contains("\u0000${AgentKind.OpenCode.name}\u0000")) {
                        runCatching {
                            preference.copy(model = normalizeOpenCodeModelId(preference.model))
                        }.getOrDefault(preference)
                    } else {
                        preference
                    }
                    put(key, normalized)
                }
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
    /** Raw App Server models stay separate so a hidden item can later be restored without reconnecting. */
    private val remoteModelsByProfile = mutableMapOf<AgentConnectionKey, List<CodexModel>>()
    private val operations = ProfileOperationTracker()
    private val surfacedDiagnostics = LinkedHashMap<String, Long>()
    private var fingerprintDialogProfileId: String? = null

    private val _state = MutableStateFlow(
        AppUiState(
            debugModeEnabled = DiagnosticLogger.isEnabled(),
            profiles = saved.profiles,
            selectedProfileId = initialProfileId,
            activeAgent = initialProfile?.activeAgent ?: AgentKind.Codex,
            activeAgentCapabilities = AgentCapabilities.None,
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
        saved.profiles.forEach {
            hosts.registerProfile(it)
            connections.registerProfile(it)
        }
        initialProfile?.let { connections.select(it, it.activeAgent) }
        viewModelScope.launch {
            hosts.states.collect { states ->
                _state.update { current ->
                    val merged = current.connectionStates.toMutableMap()
                    val metrics = current.serverMetrics.toMutableMap()
                    states.forEach { (profileId, hostState) ->
                        val localState = merged[profileId]
                        val keepLocalOperation = disconnectJobs[profileId]?.isActive == true ||
                            (hostState.phase == ConnectionPhase.Disconnected &&
                                localState?.phase in setOf(
                                    ConnectionPhase.Probing,
                                    ConnectionPhase.Connecting,
                                    ConnectionPhase.Installing,
                                )) ||
                            shouldHoldConnectedUntilSessionReady(
                                local = localState,
                                remote = hostState,
                                preparingActiveConnection = connectionJobs[profileId]?.isActive == true &&
                                    current.selectedProfileId == profileId,
                            )
                        if (!keepLocalOperation) merged[profileId] = hostState
                        if (hostState.phase != ConnectionPhase.Connected) metrics.remove(profileId)
                    }
                    current.copy(
                        connectionStates = merged,
                        serverMetrics = metrics,
                        connection = current.selectedProfileId?.let(merged::get) ?: current.connection,
                    )
                }
            }
        }
        viewModelScope.launch {
            connections.agentStates.collect { agentStates ->
                _state.update { current ->
                    val activeKey = current.selectedProfileId?.let {
                        AgentConnectionKey(it, current.activeAgent)
                    }
                    val activeAgentConnected = activeKey?.let { key ->
                        agentStates[key]?.phase == ConnectionPhase.Connected
                    } == true
                    current.copy(
                        agentConnectionStates = agentStates,
                        activeAgentCapabilities = if (activeAgentConnected) {
                            connections.capabilities(activeKey!!.profileId, activeKey.agent)
                                ?: capabilitiesFor(activeKey.agent)
                        } else {
                            AgentCapabilities.None
                        },
                        connection = current.selectedProfileId?.let(current.connectionStates::get)
                            ?: current.connection,
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
                if (event.value.message.startsWith(REMOTE_CONNECTION_TIMING_PREFIX)) {
                    DiagnosticLogger.info(
                        "ConnectionTiming",
                        "profile=${profileRef(event.profileId)} " +
                            event.value.message.removePrefix(REMOTE_CONNECTION_TIMING_PREFIX),
                    )
                    return@collect
                }
                DiagnosticLogger.warn(
                    "Remote",
                    "diagnostic profile=${profileRef(event.profileId)} ${event.value.message}",
                )
                if (isActiveAgent(event.key)) {
                    val diagnostic = sanitizeCodexDiagnostic(event.value.message)
                    if (shouldSurfaceCodexDiagnostic(diagnostic)) {
                        val phase = _state.value.agentConnectionStates[event.key]?.phase
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
        connectionSyncJobs.values.forEach(Job::cancel)
        setupJobs.values.forEach(Job::cancel)
        disconnectJobs.values.forEach(Job::cancel)
        uninstallJobs.values.forEach(Job::cancel)
        serverMetricsJobs.values.forEach(Job::cancel)
        sessionNavigationJobs.values.forEach(Job::cancel)
        threadHistoryJobs.values.forEach(Job::cancel)
        threadMutationJobs.values.forEach(Job::cancel)
        customModelSyncJobs.values.forEach(Job::cancel)
        customModelSyncJobs.clear()
        customModelSyncRevisions.clear()
        customModelSyncMutexes.clear()
        terminals.closeAll()
        hosts.close()
        connections.close()
        super.onCleared()
    }

    fun saveProfile(profile: ServerProfile) {
        val before = _state.value
        val formIncludedAgentModelSettings = profile.agentModelSettings.isNotEmpty()
        val input = normalizeProfile(profile)
        val existing = before.profiles.firstOrNull { it.id == input.id }
        val identityChanged = existing != null && !sameConnectionIdentity(existing, input)
        val agentChanged = existing != null &&
            (existing.agentMode != input.agentMode || existing.activeAgent != input.activeAgent)
        // These fields are managed outside the server form. Preserve them when an older form
        // draft is saved, but reset them when the profile is repointed at a different server.
        val normalized = if (existing != null && !identityChanged) {
            input.copy(
                workspacePromptShown = input.workspacePromptShown || existing.workspacePromptShown,
                preferredModel = input.preferredModel.ifBlank { existing.preferredModel },
                preferredEffort = input.preferredEffort.ifBlank { existing.preferredEffort },
                testModel = input.testModel.ifBlank { existing.testModel },
                // The server form does not edit model picker preferences. A restored form draft
                // must not discard models managed from the conversation screen.
                customModels = input.customModels.ifEmpty { existing.customModels },
                hiddenModelIds = input.hiddenModelIds.ifEmpty { existing.hiddenModelIds },
                agentModelSettings = if (formIncludedAgentModelSettings) {
                    input.agentModelSettings.mapValues { (agent, settings) ->
                        settings.copy(
                            managedModelIds = (
                                existing.modelSettings(agent).managedModelIds + settings.managedModelIds
                            ).distinct(),
                        )
                    }
                } else {
                    existing.agentModelSettings.ifEmpty { input.agentModelSettings }
                },
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
            cancelCustomModelSync(normalized.id)
            fingerprintJobs.remove(normalized.id)?.cancel()
            connectionJobs.remove(normalized.id)?.cancel()
            cancelConnectionSync(normalized.id)
            cancelSetupJobs(normalized.id)
            uninstallJobs.remove(normalized.id)?.cancel()
            serverMetricsJobs.remove(normalized.id)?.cancel()
            clearSetupStates(normalized.id)
            pendingFingerprints.remove(normalized.id)
            fingerprintProfiles.remove(normalized.id)
            pendingApprovalsByAgent.keys.removeAll { it.profileId == normalized.id }
            sessionSnapshots.keys.removeAll { it.profileId == normalized.id }
            remoteModelsByProfile.keys.removeAll { it.profileId == normalized.id }
            effectiveProfiles.remove(normalized.id)
            removeComposerDrafts(normalized.id)
            removeThreadModelPreferences(normalized.id)
            removeCompletedTurnTimings(normalized.id)
        }
        if (switching || agentChanged) {
            before.selectedProfileId?.let { previousId ->
                sessionSnapshots[AgentConnectionKey(previousId, before.activeAgent)] = SessionSnapshot.capture(before)
            }
        }
        // Registering a changed identity intentionally replaces the old client. The local state is
        // reset below so the UI cannot continue presenting a closed SSH session as connected.
        val connectionProfile = if (!identityChanged && normalized.remoteCommand == RemoteBootstrap.MANAGED_REMOTE_COMMAND) {
            effectiveProfiles[normalized.id]?.let { normalized.copy(remoteCommand = it.remoteCommand) } ?: normalized
        } else {
            normalized
        }
        hosts.registerProfile(connectionProfile)
        connections.registerProfile(connectionProfile)
        connections.select(normalized.id, normalized.activeAgent)
        _state.update { current ->
            val profiles = current.profiles.toMutableList()
            val index = profiles.indexOfFirst { it.id == normalized.id }
            if (index >= 0) profiles[index] = normalized else profiles += normalized
            val connection = if (identityChanged) {
                ConnectionState()
            } else {
                hosts.states.value[normalized.id]
                    ?: current.connectionStates[normalized.id]
                    ?: ConnectionState()
            }
            val base = current.copy(
                profiles = profiles,
                selectedProfileId = normalized.id,
                activeAgent = normalized.activeAgent,
                // A registered adapter is not necessarily connected.  Keep Agent-only
                // controls disabled until the user explicitly starts this lane from the
                // server page.
                activeAgentCapabilities = connections.capabilities(normalized.id, normalized.activeAgent)
                    ?.takeIf { isAgentConnected(normalized.id, normalized.activeAgent) }
                    ?: AgentCapabilities.None,
                serverMetrics = if (identityChanged) current.serverMetrics - normalized.id else current.serverMetrics,
                agentThreadLists = if (identityChanged) {
                    current.agentThreadLists.filterKeys { it.profileId != normalized.id }
                } else {
                    current.agentThreadLists
                },
            )
            if (switching || identityChanged || agentChanged) {
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
            invalidateLane(it, "file-manager-list")
            invalidateLane(it, "file-manager-operation")
            sessionSnapshots[AgentConnectionKey(it, _state.value.activeAgent)] = SessionSnapshot.capture(_state.value)
            clearSubAgentNavigation(it)
        }
        // loadConnectedSession may have resolved the managed command to a concrete executable.
        // Select the already-connected entry by id; re-registering the original managed command
        // here would replace and close that client immediately after a successful connection.
        connections.select(profile.id, profile.activeAgent)
        val agentKey = AgentConnectionKey(id, profile.activeAgent)
        val connection = hosts.states.value[id]
            ?: _state.value.connectionStates[id]
            ?: ConnectionState()
        _state.update { current ->
            val agentConnected = current.agentConnectionStates[agentKey]?.phase == ConnectionPhase.Connected
            restoreProfileState(
                current.copy(
                    selectedProfileId = id,
                    activeAgent = profile.activeAgent,
                    activeAgentCapabilities = connections.capabilities(id, profile.activeAgent)
                        ?.takeIf { agentConnected }
                        ?: AgentCapabilities.None,
                ),
                profile,
                connection,
            )
        }
        persistProfiles()
        if (isAgentConnected(id, profile.activeAgent)) refreshThreads(silent = true)
    }

    fun selectAgent(agent: AgentKind) {
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val profile = current.profiles.firstOrNull { it.id == profileId } ?: return
        if (connectionJobs[profileId]?.isActive == true) return
        if (hosts.states.value[profileId]?.phase != ConnectionPhase.Connected) {
            _state.update { it.copy(error = "SSH 服务器尚未连接") }
            return
        }
        val targetKey = AgentConnectionKey(profileId, agent)
        val sourceKey = AgentConnectionKey(profileId, current.activeAgent)
        if (current.activeAgent != agent) {
            sessionSnapshots[AgentConnectionKey(profileId, current.activeAgent)] = SessionSnapshot.capture(current)
            invalidateLane(profileId, "session-navigation")
            invalidateLane(profileId, "thread-history")
            invalidateLane(profileId, "thread-mutation")
            clearSubAgentNavigation(profileId)
        }
        val updatedProfile = profile.copy(activeAgent = agent)
        // Agent lanes are already registered and may contain a resolved remote command after
        // connect. Re-registering the persisted profile here can replace a live Codex client.
        connections.select(profileId, agent)
        val agentConnected = isAgentConnected(profileId, agent)
        val hostConnection = hosts.states.value[profileId] ?: ConnectionState()
        _state.update { state ->
            val profiles = state.profiles.map { if (it.id == profileId) updatedProfile else it }
            restoreProfileState(
                state.copy(
                    profiles = profiles,
                    activeAgent = agent,
                    agentThreadLists = state.agentThreadLists + (sourceKey to state.threads),
                    activeAgentCapabilities = connections.capabilities(profileId, agent)
                        ?.takeIf { agentConnected }
                        ?: AgentCapabilities.None,
                ),
                updatedProfile,
                hostConnection,
            )
        }
        persistProfiles()
        if (setupState(targetKey)?.prompt != null) {
            showRemoteSetup(targetKey)
        } else if (agentConnected) {
            refreshThreads(silent = true)
        } else {
            connectAgent(updatedProfile, agent)
        }
    }

    /** Starts exactly one Agent lane after the SSH host page is already available. */
    private fun connectAgent(profile: ServerProfile, agent: AgentKind) {
        val profileId = profile.id
        val key = AgentConnectionKey(profileId, agent)
        val connectionStartedNanos = System.nanoTime()
        if (connectionJobs[profileId]?.isActive == true || setupJobs[key]?.isActive == true ||
            setupState(key)?.prompt != null
        ) return
        if (hosts.states.value[profileId]?.phase != ConnectionPhase.Connected) return
        val ticket = operations.begin(profileId, "agent-connect")
        updateAgentConnection(
            profileId,
            agent,
            ConnectionState(ConnectionPhase.Connecting, "正在检测 ${agent.label}"),
        )
        if (isActiveAgent(key)) {
            _state.update { it.copy(loading = true, error = null, remoteSetup = null) }
        }
        val job = viewModelScope.launch {
            try {
                val effectiveProfile = timedConnectionStage(profileId, agent, "runtime_probe") {
                    prepareRemote(profile, agent)
                } ?: return@launch
                effectiveProfiles[profileId] = effectiveProfile
                val connected = timedConnectionStage(profileId, agent, "agent_start_initialize") {
                    loadConnectedSession(effectiveProfile, agent)
                }
                if (!isCurrent(ticket)) return@launch
                clearConnectionJobIfCurrent(profileId)
                showConnected(profile, agent, connected)
                logConnectionTiming(
                    profileId = profileId,
                    agent = agent,
                    stage = "agent_visible",
                    startedNanos = connectionStartedNanos,
                    detail = "cached_threads=${connected.threads.size} cached_models=${connected.models.size}",
                )
                connections.client(profileId, agent)?.let { client ->
                    startConnectedSessionRefresh(effectiveProfile, agent, client)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isCurrent(ticket)) showConnectionError(error, profileId, agent)
            } finally {
                operations.finish(ticket)
                if (connectionJobs[profileId] === currentCoroutineContext()[Job]) {
                    connectionJobs.remove(profileId)
                }
            }
        }
        connectionJobs[profileId] = job
    }

    fun openCompletedThread(profileId: String, agent: AgentKind, threadId: String) {
        if (profileId.isBlank() || threadId.isBlank()) return
        val before = _state.value
        val profile = before.profiles.firstOrNull { it.id == profileId } ?: return
        if (before.selectedProfileId == profileId && before.activeAgent == agent &&
            before.activeThread?.id == threadId &&
            (before.screen == AppScreen.Work || before.screen == AppScreen.AgentWork)
        ) return
        val key = AgentConnectionKey(profileId, agent)
        val connection = connections.agentStates.value[key]
            ?: before.agentConnectionStates[key]
            ?: ConnectionState()
        selectProfile(profileId)
        selectAgent(agent)
        if (connection.phase != ConnectionPhase.Connected) {
            showError(IllegalStateException("服务器连接已断开，请重新连接后打开会话"), profileId)
            return
        }
        val current = _state.value
        val thread = current.threads.firstOrNull { it.id == threadId }
            ?: current.activeThread?.takeIf { it.id == threadId }
            ?: connections.client(profileId, agent)?.cachedThread(threadId)?.thread
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
        hosts.remove(id)
        val wasSelected = _state.value.selectedProfileId == id
        invalidateProfile(id)
        cancelCustomModelSync(id)
        sessionSnapshots.keys.removeAll { it.profileId == id }
        contextUsageFallbacks.clear(id)
        clearSubAgentNavigation(id)
        pendingApprovalsByAgent.keys.removeAll { it.profileId == id }
        cancelSetupJobs(id)
        clearSetupStates(id)
        effectiveProfiles.remove(id)
        remoteModelsByProfile.keys.removeAll { it.profileId == id }
        pendingFingerprints.remove(id)
        fingerprintProfiles.remove(id)
        removeComposerDrafts(id)
        removeThreadModelPreferences(id)
        removeCompletedTurnTimings(id)
        if (fingerprintDialogProfileId == id) fingerprintDialogProfileId = null
        fingerprintJobs.remove(id)?.cancel()
        connectionJobs.remove(id)?.cancel()
        cancelConnectionSync(id)
        uninstallJobs.remove(id)?.cancel()
        serverMetricsJobs.remove(id)?.cancel()
        disconnectJobs.remove(id)?.cancel()
        _state.update { current ->
            val profiles = current.profiles.filterNot { it.id == id }
            val agentThreadLists = current.agentThreadLists.filterKeys { it.profileId != id }
            val selected = if (current.selectedProfileId == id) profiles.firstOrNull()?.id else current.selectedProfileId
            if (!wasSelected) return@update current.copy(
                profiles = profiles,
                connectionStates = current.connectionStates - id,
                serverMetrics = current.serverMetrics - id,
                agentThreadLists = agentThreadLists,
            )
            val nextProfile = profiles.firstOrNull { it.id == selected }
            if (nextProfile == null) {
                clearSessionState(current.copy(
                    profiles = profiles,
                    selectedProfileId = null,
                    connectionStates = current.connectionStates - id,
                    serverMetrics = current.serverMetrics - id,
                    agentThreadLists = agentThreadLists,
                ))
            } else {
                val connection = hosts.states.value[selected]
                    ?: current.connectionStates[selected]
                    ?: ConnectionState()
                restoreProfileState(
                    current.copy(
                        profiles = profiles,
                        selectedProfileId = selected,
                        connectionStates = current.connectionStates - id,
                        serverMetrics = current.serverMetrics - id,
                        agentThreadLists = agentThreadLists,
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
            connectionJobs[profile.id]?.isActive == true || hasActiveSetupJob(profile.id)
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
                val fingerprint = hosts.probeFingerprint(normalized)
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
        if (connectionJobs[normalized.id]?.isActive == true || hasActiveSetupJob(normalized.id) ||
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
            hosts.registerProfile(normalized)
            connections.registerProfile(normalized)
        }
        if (normalized.hostFingerprint.isBlank()) {
            if (makeActive) probeFingerprint(normalized)
            return
        }
        if (makeActive) {
            _state.update {
                it.copy(
                    connection = ConnectionState(ConnectionPhase.Connecting, "正在连接 SSH"),
                    loading = true,
                    error = null,
                    remoteSetup = null,
                    setupProgress = "",
                    setupProgressPercent = 0,
                    setupProgressDetail = "",
                    setupDownloadPercent = null,
                    agentThreadLists = it.agentThreadLists,
                )
            }
        }
        updateProfileConnection(normalized.id, ConnectionState(ConnectionPhase.Connecting, "正在连接 SSH"))
        val ticket = operations.begin(normalized.id, "connect")
        val job = viewModelScope.launch {
            try {
                timedConnectionStage(normalized.id, null, "ssh_host_connect") {
                    hosts.connect(normalized)
                }
                if (!isCurrent(ticket)) return@launch
                clearConnectionJobIfCurrent(normalized.id)
                showHostConnected(normalized)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isCurrent(ticket)) {
                    showHostConnectionError(error, normalized.id)
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
        val state = _state.value
        val profileId = state.selectedProfileId ?: return
        val agent = state.remoteSetup?.agent ?: return
        val key = AgentConnectionKey(profileId, agent)
        if (setupJobs[key]?.isActive == true || connectionJobs[profileId]?.isActive == true ||
            fingerprintJobs[profileId]?.isActive == true || disconnectJobs[profileId]?.isActive == true ||
            uninstallJobs[profileId]?.isActive == true
        ) return
        DiagnosticLogger.info(
            "Setup",
            "install_start profile=${profileRef(profileId)} agent=${agent.name}",
        )
        val normalizedProxy = try {
            RemoteBootstrap.validateProxyUrl(proxyUrl)
        } catch (error: IllegalArgumentException) {
            showError(error, profileId)
            return
        }
        val profile = setupProfiles[key]?.copy(proxyUrl = normalizedProxy) ?: return
        setupProfiles[key] = profile
        _state.update { current ->
            current.copy(
                profiles = current.profiles.map { stored ->
                    if (stored.id == profileId) stored.copy(proxyUrl = normalizedProxy) else stored
                },
            )
        }
        persistProfiles()
        val ticket = operations.begin(profileId, setupLane(agent))
        val waitingForAnotherAgent = hasActiveSetupJob(profileId)
        updateSetupState(key) {
            it.copy(
                inProgress = true,
                progress = if (waitingForAnotherAgent) "等待安装队列" else "准备安装",
                percent = 0,
                detail = if (waitingForAnotherAgent) {
                    "同一服务器的 Agent 依赖将依次安装"
                } else {
                    ""
                },
                downloadPercent = null,
                minimized = false,
            )
        }
        updateAgentConnection(
            profileId,
            agent,
            ConnectionState(ConnectionPhase.Installing, "正在安装 ${agent.label}"),
        )
        _state.update { it.copy(error = null) }
        val setupMutex = setupMutexes.getOrPut(profileId) { Mutex() }
        val job = viewModelScope.launch {
            try {
                setupMutex.withLock {
                    if (!operations.isCurrent(ticket)) return@withLock
                    updateSetupState(key) {
                        it.copy(
                            inProgress = true,
                            progress = "准备安装",
                            detail = "",
                            downloadPercent = null,
                        )
                    }
                    connections.installRuntime(profile, agent) { progress ->
                        if (operations.isCurrent(ticket)) {
                            updateSetupState(key) {
                                it.copy(
                                    inProgress = true,
                                    progress = progress.message,
                                    percent = progress.percent.coerceIn(0, 100),
                                    detail = progress.detail,
                                    downloadPercent = progress.downloadPercent,
                                )
                            }
                        }
                    }
                    val verified = connections.inspectRuntime(profile, agent, hosts.client(profileId))
                    check(verified.compatibleCommand != null) {
                        "安装完成，但未检测到兼容的 ${agent.label}"
                    }
                    if (!operations.isCurrent(ticket)) return@withLock
                    removeSetupState(key)
                    setupJobs.remove(key)

                    // Keep installation and its automatic connection ordered per server. This
                    // prevents the next Agent install from racing the profile-wide connection job.
                    connectionJobs[profileId]?.join()
                    if (!operations.isCurrent(ticket) ||
                        hosts.states.value[profileId]?.phase != ConnectionPhase.Connected
                    ) return@withLock
                    connectAgent(profile.copy(activeAgent = agent), agent)
                    connectionJobs[profileId]?.join()
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (operations.isCurrent(ticket)) {
                    updateSetupState(key) {
                        it.copy(inProgress = false, progress = "安装失败", percent = it.percent)
                    }
                    updateAgentConnection(
                        profileId,
                        agent,
                        ConnectionState(ConnectionPhase.Failed, "${agent.label} 安装失败"),
                    )
                    if (isActiveAgent(key)) {
                        _state.update {
                            it.copy(
                                error = error.message ?: "远程 Agent 安装失败",
                            )
                        }
                    }
                }
            } finally {
                operations.finish(ticket)
                if (setupJobs[key] === currentCoroutineContext()[Job]) {
                    setupJobs.remove(key)
                }
            }
        }
        setupJobs[key] = job
    }

    fun cancelRemoteSetup() {
        val state = _state.value
        val profileId = state.selectedProfileId ?: return
        val agent = state.remoteSetup?.agent ?: return
        val key = AgentConnectionKey(profileId, agent)
        if (setupJobs[key]?.isActive == true) return
        operations.invalidateLane(profileId, setupLane(agent))
        removeSetupState(key)
        updateAgentConnection(profileId, agent, ConnectionState())
    }

    fun minimizeRemoteSetup() {
        val state = _state.value
        val profileId = state.selectedProfileId ?: return
        val agent = state.remoteSetup?.agent ?: return
        val key = AgentConnectionKey(profileId, agent)
        val setup = setupState(key) ?: return
        _state.update { current ->
            if (current.selectedProfileId != profileId || current.remoteSetup?.agent != agent) return@update current
            current.copy(
                remoteSetup = null,
                setupInProgress = false,
                setupProgress = "",
                setupProgressPercent = 0,
                setupProgressDetail = "",
                setupDownloadPercent = null,
                agentSetupStates = current.agentSetupStates + (key to setup.copy(minimized = true)),
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
            invalidateLane(id, "file-manager-list")
            invalidateLane(id, "file-manager-operation")
            _state.value.activeThread?.let { thread ->
                rememberContextUsage(id, thread.id, _state.value.tokenUsage)
                activeClient()?.cacheThread(
                    thread,
                    _state.value.timeline,
                    _state.value.olderTurnsCursor,
                    _state.value.tokenUsage,
                )
            }
            sessionSnapshots[sessionKey(id)] = SessionSnapshot.capture(_state.value)
            clearSubAgentNavigation(id)
        }
        _state.update {
            it.copy(
                screen = AppScreen.Servers,
                workspacePickerVisible = false,
                fileManagerProfileId = null,
                fileManagerLoading = false,
                fileManagerCurrentPath = "",
                fileManagerParentPath = null,
                fileManagerEntries = emptyList(),
                fileManagerClipboard = null,
                fileManagerOperation = null,
                fileManagerError = null,
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
        if (hosts.states.value[profileId]?.phase != ConnectionPhase.Connected) {
            _state.update { it.copy(error = "SSH 服务器尚未连接") }
            return
        }
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
        if (hasActiveSetupJob(profileId)) {
            showError(IllegalStateException("远程安装正在进行，请完成或取消后再卸载"), profileId)
            return
        }
        val job = viewModelScope.launch {
            try {
                AgentKind.entries.forEach { agent ->
                    updateAgentConnection(
                        profileId,
                        agent,
                        ConnectionState(ConnectionPhase.Installing, "正在卸载 ${agent.label}"),
                    )
                }
                AgentKind.entries.forEach { agent ->
                    connections.uninstallRuntime(profile, agent)
                }
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
        val client = hosts.client(profileId)?.takeIf { it.isConnected() } ?: return
        val job = viewModelScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            try {
                val effectiveProfile = hosts.profile(profileId) ?: profile
                val metrics = client.readServerMetrics(effectiveProfile)
                _state.update { state ->
                    val stateConnection = state.connectionStates[profileId]
                        ?: if (state.selectedProfileId == profileId) state.connection else ConnectionState()
                    if (hosts.client(profileId) !== client ||
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
        job.start()
    }

    fun refreshThreads(silent: Boolean = false) {
        val profileId = _state.value.selectedProfileId ?: return
        val key = sessionKey(profileId)
        val client = connections.client(profileId, key.agent)?.takeIf { it.isConnected() } ?: return
        val operation = beginClientOperation(key, threadListLane(key.agent), client) ?: return
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
                    sessionSnapshots[sessionKey(profileId)]?.let { snapshot ->
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
        subAgentNavigationStacks.clear(subAgentNavigationScope(profile.id))
        DiagnosticLogger.info("Thread", "create_start profile=${profileRef(profile.id)}")
        val client = connections.client(profile.id)?.takeIf { it.isConnected() } ?: return
        invalidateLane(profile.id, "session-navigation")
        invalidateLane(profile.id, "thread-history")
        val operation = beginClientOperation(profile.id, "session-navigation", client) ?: return
        val modelSettings = profile.modelSettings(operation.key.agent)
        val selection = resolveNewThreadModelSelection(
            models = _state.value.models,
            configuredModel = modelSettings.preferredModel,
            configuredEffort = modelSettings.preferredEffort,
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
        subAgentNavigationStacks.clear(subAgentNavigationScope(profileId))
        openThreadInternal(thread, AppScreen.Work, agentName = null)
    }

    fun openSubAgentThread(threadId: String, agentName: String) {
        val current = _state.value
        if (!current.activeAgentCapabilities.subAgents) return
        val profileId = current.selectedProfileId ?: return
        val navigationScope = subAgentNavigationScope(profileId)
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
        if (subAgentNavigationStacks.size(navigationScope) >= MAX_SUB_AGENT_NAVIGATION_DEPTH) {
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
            navigationScope,
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
                cliVersion = current.agentConnectionStates[AgentConnectionKey(profileId, current.activeAgent)]
                    ?.cliVersion.orEmpty(),
            )
        if (!openThreadInternal(child, AppScreen.AgentWork, agentName.ifBlank { null })) {
            subAgentNavigationStacks.pop(navigationScope)
        }
    }

    fun backFromSubAgentThread() {
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val navigationScope = subAgentNavigationScope(profileId)
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
        if (subAgentNavigationStacks.isPopPending(navigationScope)) return
        val frame = subAgentNavigationStacks.beginPendingPop(navigationScope) ?: run {
            backToThreads()
            return
        }
        val parentThread = frame.snapshot.activeThread ?: run {
            subAgentNavigationStacks.completePendingPop(navigationScope, frame)
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
            onResumed = { subAgentNavigationStacks.completePendingPop(navigationScope, frame) },
            onResumeFailure = { error ->
                // A newer navigation owns the screen and stack. Do not let an older failed
                // resume replace it with a stale child snapshot.
                if (subAgentNavigationStacks.cancelPendingPop(navigationScope, frame)) {
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
        if (!accepted && subAgentNavigationStacks.completePendingPop(navigationScope, frame) != null) {
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
        val key = sessionKey(profileId)
        DiagnosticLogger.info(
            "Thread",
            "open_start profile=${profileRef(profileId)} thread=${profileRef(thread.id)}",
        )
        val client = connections.client(profileId)?.takeIf { it.isConnected() } ?: return false
        invalidateLane(profileId, "session-navigation")
        invalidateLane(profileId, "thread-history")
        val operation = beginClientOperation(profileId, "session-navigation", client) ?: return false
        val resumeBuffer = ResumeNotificationBuffer(thread.id, operation.generation)
        resumeNotificationBuffers[key] = resumeBuffer
        val approvalMode = _state.value.approvalMode
        val threadSelection = resolveThreadModelSelection(profileId, thread.id, _state.value.models)
        // Returning from the thread list keeps the previous WorkScreen in the profile snapshot.
        // Reuse its start time while thread/resume fetches the authoritative server timestamp.
        val retainedTurnTiming = initialSnapshot?.turnTiming
            ?.takeIf { it.threadId == thread.id }
            ?: sessionSnapshots[sessionKey(profileId)]?.turnTiming?.takeIf { it.threadId == thread.id }
        val cached = (client.cachedThread(thread.id) ?: client.cachedThreadStale(thread.id))
            ?.takeIf { it.thread.id == thread.id }
        val rememberedTokenUsage = client.cachedContextUsage(thread.id)
            ?: contextUsageFallbacks.get(agentScopeId(key), thread.id)
            ?: cached?.tokenUsage?.takeIf { it.hasKnownContextWindow() }
            ?: initialSnapshot?.tokenUsage?.takeIf { it.hasKnownContextWindow() }
            ?: sessionSnapshots[sessionKey(profileId)]
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
                    turnTiming = restoredTurnTiming(
                        profileId = profileId,
                        threadId = cachedThread.id,
                        running = running,
                        current = retainedTurnTiming,
                        activeTurnId = cachedThread.activeTurnId ?: activeTurn,
                    ),
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
                        turnTiming = restoredTurnTiming(
                            profileId = profileId,
                            threadId = snapshotThread.id,
                            running = running,
                            current = retainedTurnTiming,
                            activeTurnId = snapshotThread.activeTurnId ?: activeTurn,
                        ),
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
                    turnTiming = restoredTurnTiming(
                        profileId = profileId,
                        threadId = thread.id,
                        running = running,
                        current = retainedTurnTiming,
                        activeTurnId = thread.activeTurnId,
                    ),
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
                            ?: contextUsageFallbacks.get(agentScopeId(key), loaded.id)
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
                            turnTiming = restoredTurnTiming(
                                profileId = profileId,
                                threadId = loaded.id,
                                running = running,
                                current = current.turnTiming,
                                activeTurnId = loaded.activeTurnId ?: activeTurn,
                                activeTurnStartedAtMillis = resumed.activeTurnStartedAtMillis,
                            ),
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
                        key,
                        resumeBuffer,
                        timeline,
                        replay = true,
                        snapshotSequence = responseSequence,
                    )
                    sessionSnapshots[sessionKey(profileId)]?.let { snapshot ->
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
                    releaseResumeNotifications(key, resumeBuffer, timeline, replay = false)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationCurrent(operation)) {
                    val baseline = if (isActiveProfile(profileId)) {
                        _state.value.timeline
                    } else {
                        sessionSnapshots[sessionKey(profileId)]?.timeline.orEmpty()
                    }
                    releaseResumeNotifications(
                        key,
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
                    releaseResumeNotifications(key, resumeBuffer, emptyList(), replay = false)
                }
            } finally {
                releaseResumeNotifications(key, resumeBuffer, emptyList(), replay = false)
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
        client: RemoteAgentClient,
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
                sessionSnapshots[sessionKey(profileId)]?.let { snapshot ->
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
        profileId?.let { subAgentNavigationStacks.clear(subAgentNavigationScope(it)) }
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
                profileId?.let { id -> sessionSnapshots[sessionKey(id)] = SessionSnapshot.capture(updated) }
            }
        }
        profileId?.let { pendingApprovalsByAgent[sessionKey(it)] = emptyList() }
        persistProfiles()
        refreshThreads(silent = true)
    }

    fun send(text: String) {
        val clean = text.trim()
        val current = _state.value
        val profileId = current.selectedProfileId ?: return
        val thread = current.activeThread ?: return
        val client = activeClient() ?: return
        val profile = current.profiles.firstOrNull { it.id == profileId }
        val selectedModelSettings = profile?.modelSettings(current.activeAgent)
        val selectedCustomModel = current.selectedModel?.let { selected ->
            selectedModelSettings?.customModels
                ?.firstOrNull { it.modelId == selected }
        }
        val pendingModelRemovals = selectedModelSettings?.let(::pendingManagedModelRemovals).orEmpty()
        val modelSyncRequired = selectedCustomModel != null || pendingModelRemovals.isNotEmpty()
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
                    if (profile != null && modelSyncRequired) {
                        if (current.activeAgent == AgentKind.OpenCode) {
                            syncCustomModelsNow(
                                profileId = profileId,
                                agent = current.activeAgent,
                                requireConnected = true,
                            )
                        } else if (selectedCustomModel != null) {
                            client.ensureCustomModel(profile, selectedCustomModel)
                        }
                    }
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
                    composerDrafts.remove(composerDraftKey(operation.key, thread.id))
                    completedTurnTimings.remove(threadStorageKey(operation.key, thread.id))
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
        if (!current.activeAgentCapabilities.interruptTurn) return
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
        if (!current.activeAgentCapabilities.compactThread) return
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
        if (!_state.value.activeAgentCapabilities.threadGoals) return
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
        if (!_state.value.activeAgentCapabilities.threadGoals) return
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
        if (!_state.value.activeAgentCapabilities.threadGoals) return
        if (_state.value.activeGoal == null) return
        mutateActiveGoal { client, threadId ->
            client.clearThreadGoal(threadId)
            null
        }
    }

    private fun mutateActiveGoal(
        mutation: suspend (RemoteAgentClient, String) -> ThreadGoal?,
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
        if (!current.activeAgentCapabilities.reviewChanges) return
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
        if (!current.activeAgentCapabilities.rollbackThread) return
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
                    sessionSnapshots[sessionKey(profileId)]?.let { snapshot ->
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
        if (!current.activeAgentCapabilities.archiveThread) return
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
                    composerDrafts.remove(composerDraftKey(operation.key, threadId))
                    threadModelPreferences.remove(threadStorageKey(operation.key, threadId))
                    completedTurnTimings.remove(threadStorageKey(operation.key, threadId))
                    contextUsageFallbacks.remove(agentScopeId(operation.key), threadId)
                    pendingApprovalsByAgent[operation.key] = emptyList()
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
        if (!current.activeAgentCapabilities.renameThread) return
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
        if (!_state.value.activeAgentCapabilities.approvals) return
        val profileId = _state.value.selectedProfileId ?: return
        val prompt = _state.value.approval ?: return
        val client = activeClient() ?: return
        val operation = beginClientOperation(profileId, "approval", client) ?: return
        viewModelScope.launch {
            try {
                client.answerApproval(prompt, accept, answers)
                val remaining = pendingApprovalsByAgent[operation.key].orEmpty()
                    .filterNot { it.requestId == prompt.requestId }
                pendingApprovalsByAgent[operation.key] = remaining
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
        uploadAttachments(context, listOf(uri))
    }

    fun uploadAttachments(context: Context, uris: List<Uri>) {
        if (uris.isEmpty()) return
        val profileId = _state.value.selectedProfileId ?: return
        currentProfile() ?: return
        val client = activeClient() ?: return
        uploadAttachmentContents(profileId, client, uris) { uri ->
            readAttachmentContent(context, uri)
        }
    }

    /** Adds the newest retained diagnostic log for legacy callers. */
    fun addDebugLogAttachment() {
        addDebugLogAttachments(DiagnosticLogger.listLogs().take(1).map { it.id })
    }

    /** Adds each user-selected, redacted diagnostic log as its own text attachment. */
    fun addDebugLogAttachments(logIds: List<String>) {
        val selectedIds = logIds.distinct()
        if (selectedIds.isEmpty()) return
        val profileId = _state.value.selectedProfileId ?: return
        currentProfile() ?: return
        val client = activeClient() ?: return
        uploadAttachmentContents(profileId, client, selectedIds) { id ->
            val maxBytes = MAX_INLINE_TEXT_ATTACHMENT_BYTES.toInt()
            val text = withContext(Dispatchers.IO) {
                DiagnosticLogger.attachmentText(id, maxBytes)
            } ?: throw IllegalStateException("所选 Debug 日志已不可用")
            check(text.isNotBlank()) { "所选 Debug 日志为空" }
            val bytes = text.toByteArray(Charsets.UTF_8)
            check(bytes.size <= maxBytes) { "Debug 日志不能超过 512 KB" }
            AttachmentUploadContent(
                name = "codex-debug-log-$id",
                mimeType = "text/plain",
                bytes = bytes,
                textContent = text,
            )
        }
    }

    private fun <T> uploadAttachmentContents(
        profileId: String,
        client: RemoteAgentClient,
        items: List<T>,
        loadContent: suspend (T) -> AttachmentUploadContent,
    ) {
        val operation = beginClientOperation(profileId, "upload", client, exclusive = false) ?: return
        viewModelScope.launch {
            if (isOperationVisible(operation)) applySessionState(profileId) { it.copy(loading = true, error = null) }
            var firstError: Throwable? = null
            var completed = false
            try {
                items.forEach { item ->
                    try {
                        val content = loadContent(item)
                        val remotePath = client.upload(content.name, content.bytes)
                        val attachment = PendingAttachment(
                            name = content.name,
                            remotePath = remotePath,
                            mimeType = content.mimeType,
                            textContent = content.textContent,
                        )
                        if (isOperationCurrent(operation)) {
                            applySessionState(profileId) { state ->
                                state.copy(attachments = state.attachments + attachment)
                            }
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        if (firstError == null) firstError = error
                    }
                }
                firstError?.let { error ->
                    if (isOperationCurrent(operation)) showError(error, profileId)
                }
                completed = true
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationCurrent(operation)) showError(error, profileId)
            } finally {
                if (completed && firstError == null && isOperationCurrent(operation)) {
                    applySessionState(profileId) { it.copy(loading = false) }
                }
                finishClientOperation(operation)
            }
        }
    }

    private suspend fun readAttachmentContent(context: Context, uri: Uri): AttachmentUploadContent =
        withContext(Dispatchers.IO) {
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
        val key = composerDraftKey(sessionKey(profileId), threadId)
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
        if (!_state.value.activeAgentCapabilities.models) return
        persistThreadModelPreference(model, effort.orEmpty())
    }

    fun selectEffort(effort: String) {
        if (!_state.value.activeAgentCapabilities.reasoningEffort) return
        val model = _state.value.selectedModel ?: return
        persistThreadModelPreference(model, effort)
    }

    /** Loads the configured OpenAI-compatible API's /models list through the connected server. */
    fun fetchApiModelOptions() {
        if (!_state.value.activeAgentCapabilities.globalSettings) return
        val profileId = _state.value.selectedProfileId ?: return
        if (_state.value.apiModelOptionsLoading) return
        val profile = currentProfile() ?: return
        val client = activeClient()?.takeIf { it.isConnected() } ?: run {
            _state.update {
                it.copy(
                    apiModelOptionsProfileId = profileId,
                    apiModelOptionsError = "服务器未连接，无法获取模型列表",
                )
            }
            return
        }
        val operation = beginClientOperation(profileId, "api-model-list", client) ?: return
        _state.update {
            it.copy(
                apiModelOptions = emptyList(),
                apiModelOptionsProfileId = profileId,
                apiModelOptionsLoading = true,
                apiModelOptionsError = null,
            )
        }
        viewModelScope.launch {
            try {
                val settings = client.readGlobalSettings(profile)
                DiagnosticLogger.info(
                    "ApiModels",
                    "fetch_start profile=${profileRef(profileId)} provider=${settings.modelProvider} " +
                        "base_url_configured=${settings.baseUrl.isNotBlank()} " +
                        "api_key_configured=${settings.apiKey.isNotBlank()} " +
                        "proxy_configured=${settings.proxyUrl.isNotBlank()}",
                )
                val models = client.fetchApiModels(
                    profile = profile,
                    baseUrl = settings.baseUrl,
                    apiKey = settings.apiKey,
                    proxyUrl = settings.proxyUrl,
                )
                if (isOperationVisible(operation)) {
                    DiagnosticLogger.info(
                        "ApiModels",
                        "fetch_success profile=${profileRef(profileId)} models=${models.size}",
                    )
                    _state.update {
                        it.copy(
                            apiModelOptions = models,
                            apiModelOptionsProfileId = profileId,
                            apiModelOptionsLoading = false,
                            apiModelOptionsError = null,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                DiagnosticLogger.warn(
                    "ApiModels",
                    "fetch_failed profile=${profileRef(profileId)} " +
                        "error=${error.message ?: error::class.simpleName}",
                )
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            apiModelOptions = emptyList(),
                            apiModelOptionsProfileId = profileId,
                            apiModelOptionsLoading = false,
                            apiModelOptionsError = error.message ?: "无法获取 API 模型列表",
                        )
                    }
                }
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun saveCustomModel(originalModelId: String?, definition: CustomModelDefinition) {
        val profileId = _state.value.selectedProfileId ?: return
        val agent = _state.value.activeAgent
        val normalized = runCatching {
            normalizeCustomModelDefinition(
                if (agent == AgentKind.OpenCode) {
                    definition.copy(modelId = normalizeOpenCodeModelId(definition.modelId))
                } else {
                    definition
                },
            )
        }.getOrElse { error ->
            _state.update { it.copy(error = error.message ?: "自定义模型格式错误") }
            return
        }
        val profile = currentProfile() ?: return
        val settings = profile.modelSettings(agent)
        val originalId = originalModelId?.trim()?.let { id ->
            if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(id) else id
        }.takeUnless { it.isNullOrBlank() }
        val originalIndex = originalId?.let { id ->
            settings.customModels.indexOfFirst { it.modelId == id }
        } ?: -1
        val duplicateIndex = settings.customModels.indexOfFirst { it.modelId == normalized.modelId }
        if (duplicateIndex >= 0 && duplicateIndex != originalIndex) {
            _state.update { it.copy(error = "已有相同的自定义模型 ID") }
            return
        }
        if (originalIndex < 0 &&
            settings.customModels.size >= MAX_CUSTOM_MODELS
        ) {
            _state.update { it.copy(error = "自定义模型最多可添加 $MAX_CUSTOM_MODELS 个") }
            return
        }
        updateProfileModelCatalog(profileId) { currentSettings ->
            val replacementIndex = originalId?.let { id ->
                currentSettings.customModels.indexOfFirst { it.modelId == id }
            } ?: currentSettings.customModels.indexOfFirst { it.modelId == normalized.modelId }
            val customModels = if (replacementIndex >= 0) {
                currentSettings.customModels.mapIndexed { index, current ->
                    if (index == replacementIndex) normalized else current
                }
            } else {
                currentSettings.customModels + normalized
            }
            currentSettings.copy(
                customModels = customModels,
                managedModelIds = (
                    currentSettings.managedModelIds + originalId.orEmpty() + normalized.modelId
                ).filter(String::isNotBlank).distinct(),
            )
        }
    }

    fun deleteCustomModel(modelId: String) {
        val profileId = _state.value.selectedProfileId ?: return
        val agent = _state.value.activeAgent
        val normalizedId = modelId.trim().let { id ->
            if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(id) else id
        }
        if (normalizedId.isBlank()) return
        updateProfileModelCatalog(profileId) { settings ->
            if (settings.customModels.none { it.modelId == normalizedId }) return@updateProfileModelCatalog settings
            settings.copy(
                preferredModel = settings.preferredModel.takeUnless { it == normalizedId }.orEmpty(),
                testModel = settings.testModel.takeUnless { it == normalizedId }.orEmpty(),
                customModels = settings.customModels.filterNot { it.modelId == normalizedId },
                managedModelIds = (settings.managedModelIds + normalizedId).distinct(),
            )
        }
    }

    /** Hiding affects only the Android picker; it never removes a provider-side model. */
    fun setModelHidden(modelId: String, hidden: Boolean) {
        val profileId = _state.value.selectedProfileId ?: return
        val agent = _state.value.activeAgent
        val normalizedId = modelId.trim().let { id ->
            if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(id) else id
        }
        if (normalizedId.isBlank()) return
        updateProfileModelCatalog(profileId) { settings ->
            val hiddenIds = if (hidden) {
                (settings.hiddenModelIds + normalizedId).distinct()
            } else {
                settings.hiddenModelIds.filterNot { it == normalizedId }
            }
            settings.copy(hiddenModelIds = hiddenIds)
        }
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
        if (!isAgentConnected(profileId, _state.value.activeAgent)) return
        val client = hosts.client(profileId)?.takeIf { it.isConnected() } ?: return
        val operation = beginHostOperation(profileId, "workspace", client) ?: return
        _state.update {
            it.copy(workspacePickerVisible = true, workspaceLoading = true, workspaceError = null)
        }
        viewModelScope.launch {
            try {
                val listing = client.listDirectories(path)
                if (isHostOperationVisible(operation)) {
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
                if (isHostOperationCurrent(operation) && !isActiveProfile(profileId)) {
                    val snapshotKey = sessionKey(profileId)
                    sessionSnapshots[snapshotKey] = (sessionSnapshots[snapshotKey] ?: SessionSnapshot()).copy(
                        workspaceCurrentPath = listing.currentPath,
                        workspaceParentPath = listing.parentPath,
                        workspaceDirectories = listing.directories,
                        workspaceError = null,
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isHostOperationVisible(operation)) {
                    _state.update {
                        it.copy(workspaceLoading = false, workspaceError = error.message ?: "无法读取目录")
                    }
                }
            } finally {
                finishHostOperation(operation)
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

    /** Opens an SFTP-backed browser scoped to the currently selected connected server. */
    fun showFileManager() {
        val profileId = _state.value.selectedProfileId ?: return
        val profile = currentProfile() ?: return
        val client = hosts.client(profileId)?.takeIf { it.isConnected() } ?: run {
            _state.update { it.copy(error = "服务器未连接，无法打开文件管理") }
            return
        }
        val previous = _state.value
        val initialPath = previous.fileManagerCurrentPath
            .takeIf { previous.fileManagerProfileId == profileId && it.isNotBlank() }
            ?: profile.workspace.ifBlank { "." }
        _state.update {
            it.copy(
                screen = AppScreen.FileManager,
                fileManagerProfileId = profileId,
                fileManagerLoading = true,
                fileManagerCurrentPath = initialPath,
                fileManagerParentPath = null,
                fileManagerEntries = emptyList(),
                fileManagerClipboard = null,
                fileManagerOperation = null,
                fileManagerError = null,
            )
        }
        browseFileManager(initialPath, client)
    }

    fun closeFileManager() {
        val profileId = _state.value.fileManagerProfileId ?: _state.value.selectedProfileId
        profileId?.let {
            invalidateLane(it, "file-manager-list")
            invalidateLane(it, "file-manager-operation")
        }
        _state.update {
            it.copy(
                screen = AppScreen.Threads,
                fileManagerProfileId = null,
                fileManagerLoading = false,
                fileManagerCurrentPath = "",
                fileManagerParentPath = null,
                fileManagerEntries = emptyList(),
                fileManagerClipboard = null,
                fileManagerOperation = null,
                fileManagerError = null,
            )
        }
    }

    fun refreshFileManager() {
        val path = _state.value.fileManagerCurrentPath
        if (path.isNotBlank()) browseFileManager(path)
    }

    fun browseFileManager(path: String) {
        val profileId = _state.value.fileManagerProfileId ?: return
        val client = hosts.client(profileId)?.takeIf { it.isConnected() } ?: return
        browseFileManager(path, client)
    }

    private fun browseFileManager(path: String, client: RemoteServerClient) {
        val snapshot = _state.value
        val profileId = snapshot.fileManagerProfileId ?: return
        if (snapshot.selectedProfileId != profileId || snapshot.screen != AppScreen.FileManager) return
        val operation = beginHostOperation(profileId, "file-manager-list", client) ?: run {
            _state.update { it.copy(fileManagerLoading = false, fileManagerError = "服务器连接已断开") }
            return
        }
        _state.update {
            if (it.fileManagerProfileId == profileId && it.screen == AppScreen.FileManager) {
                it.copy(fileManagerLoading = true, fileManagerError = null)
            } else {
                it
            }
        }
        viewModelScope.launch {
            try {
                val listing = client.listFiles(path)
                if (isFileManagerOperationVisible(operation)) {
                    publishFileManagerListing(listing)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                publishFileManagerError(operation, error, "无法读取目录")
            } finally {
                finishHostOperation(operation)
            }
        }
    }

    fun uploadRemoteFiles(context: Context, uris: List<Uri>) {
        if (uris.isEmpty()) return
        launchFileManagerOperation("正在上传 ${uris.size} 个文件", "已上传 ${uris.size} 个文件") { client, directory ->
            withContext(Dispatchers.IO) {
                uris.forEach { uri ->
                    val name = remoteUploadFileName(context, uri)
                    val input = context.contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("无法读取 $name")
                    input.use { client.uploadFile(directory, name, it) }
                }
            }
        }
    }

    fun downloadRemoteFile(context: Context, path: String, destination: Uri) {
        if (path.isBlank()) return
        launchFileManagerOperation("正在下载文件", "已保存到本地") { client, _ ->
            withContext(Dispatchers.IO) {
                val output = context.contentResolver.openOutputStream(destination, "w")
                    ?: throw IllegalStateException("无法创建本地文件")
                output.use { client.downloadFile(path, it) }
            }
        }
    }

    fun downloadLinkedRemoteFile(context: Context, path: String, destination: Uri) {
        if (!path.startsWith('/')) return
        val profileId = _state.value.selectedProfileId ?: return
        val client = hosts.client(profileId)?.takeIf { it.isConnected() } ?: return
        val operation = beginHostOperation(profileId, "remote-link-download", client) ?: return
        val fileName = path.substringAfterLast('/').ifBlank { "文件" }
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val output = context.contentResolver.openOutputStream(destination, "w")
                        ?: throw IllegalStateException("无法创建本地文件")
                    output.use { client.downloadFile(path, it) }
                }
                if (isHostOperationVisible(operation)) {
                    _state.update { it.copy(diagnostic = "已保存 $fileName") }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isHostOperationVisible(operation)) showError(error, profileId)
            } finally {
                finishHostOperation(operation)
            }
        }
    }

    fun renameRemoteFile(entry: RemoteFileEntry, newName: String) {
        launchFileManagerOperation("正在重命名", "已重命名") { client, _ ->
            client.renameFile(entry.path, newName)
        }
    }

    fun deleteRemoteFiles(entries: List<RemoteFileEntry>) {
        val paths = entries.map(RemoteFileEntry::path).distinct()
        if (paths.isEmpty()) return
        launchFileManagerOperation("正在删除 ${paths.size} 项", "已删除 ${paths.size} 项") { client, _ ->
            client.deleteFiles(paths)
        }
    }

    fun copyRemoteFiles(entries: List<RemoteFileEntry>) {
        setRemoteFileClipboard(entries, RemoteFileTransferMode.Copy)
    }

    fun cutRemoteFiles(entries: List<RemoteFileEntry>) {
        setRemoteFileClipboard(entries, RemoteFileTransferMode.Move)
    }

    private fun setRemoteFileClipboard(entries: List<RemoteFileEntry>, mode: RemoteFileTransferMode) {
        val snapshot = _state.value
        if (snapshot.screen != AppScreen.FileManager || snapshot.fileManagerProfileId != snapshot.selectedProfileId) return
        val selected = entries.filter { it.path.isNotBlank() }.distinctBy(RemoteFileEntry::path)
        if (selected.isEmpty()) return
        _state.update {
            if (it.screen == AppScreen.FileManager && it.fileManagerProfileId == snapshot.selectedProfileId) {
                it.copy(
                    fileManagerClipboard = RemoteFileClipboard(selected, mode),
                    fileManagerError = null,
                )
            } else {
                it
            }
        }
    }

    fun pasteRemoteFiles() {
        val snapshot = _state.value
        val clipboard = snapshot.fileManagerClipboard ?: return
        if (snapshot.fileManagerCurrentPath.isBlank()) return
        launchFileManagerOperation(
            if (clipboard.mode == RemoteFileTransferMode.Copy) "正在复制 ${clipboard.entries.size} 项" else "正在移动 ${clipboard.entries.size} 项",
            if (clipboard.mode == RemoteFileTransferMode.Copy) "已复制 ${clipboard.entries.size} 项" else "已移动 ${clipboard.entries.size} 项",
            onSuccess = { state ->
                if (clipboard.mode == RemoteFileTransferMode.Move) state.copy(fileManagerClipboard = null) else state
            },
        ) { client, directory ->
            client.transferFiles(clipboard.entries.map(RemoteFileEntry::path), directory, clipboard.mode)
        }
    }

    private fun launchFileManagerOperation(
        label: String,
        successMessage: String,
        onSuccess: (AppUiState) -> AppUiState = { it },
        action: suspend (RemoteServerClient, String) -> Unit,
    ) {
        val snapshot = _state.value
        val profileId = snapshot.fileManagerProfileId ?: return
        val directory = snapshot.fileManagerCurrentPath.takeIf { it.isNotBlank() } ?: return
        if (snapshot.screen != AppScreen.FileManager || snapshot.selectedProfileId != profileId) return
        val client = hosts.client(profileId)?.takeIf { it.isConnected() } ?: run {
            _state.update { it.copy(fileManagerError = "服务器连接已断开") }
            return
        }
        val operation = beginHostOperation(profileId, "file-manager-operation", client) ?: run {
            _state.update { it.copy(fileManagerError = "服务器连接已断开") }
            return
        }
        _state.update {
            if (it.screen == AppScreen.FileManager && it.fileManagerProfileId == profileId) {
                it.copy(fileManagerOperation = label, fileManagerError = null)
            } else {
                it
            }
        }
        viewModelScope.launch {
            try {
                action(client, directory)
                val listing = client.listFiles(directory)
                if (isFileManagerOperationVisible(operation)) {
                    _state.update { current ->
                        if (current.fileManagerCurrentPath != directory) current else onSuccess(
                            current.copy(
                                fileManagerLoading = false,
                                fileManagerCurrentPath = listing.currentPath,
                                fileManagerParentPath = listing.parentPath,
                                fileManagerEntries = listing.entries,
                                fileManagerError = null,
                                diagnostic = successMessage,
                            ),
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                publishFileManagerError(operation, error, "文件操作失败")
            } finally {
                if (isFileManagerOperationVisible(operation)) {
                    _state.update { it.copy(fileManagerOperation = null) }
                }
                finishHostOperation(operation)
            }
        }
    }

    private fun isFileManagerOperationVisible(operation: HostOperation): Boolean =
        isHostOperationVisible(operation) &&
            _state.value.screen == AppScreen.FileManager &&
            _state.value.fileManagerProfileId == operation.profileId

    private fun publishFileManagerListing(listing: RemoteFileListing) {
        _state.update {
            it.copy(
                fileManagerLoading = false,
                fileManagerCurrentPath = listing.currentPath,
                fileManagerParentPath = listing.parentPath,
                fileManagerEntries = listing.entries,
                fileManagerError = null,
            )
        }
    }

    private fun publishFileManagerError(
        operation: HostOperation,
        error: Throwable,
        fallback: String,
    ) {
        val profileId = operation.profileId
        val message = userFacingErrorMessage(error, profileId, fallback)
        DiagnosticLogger.error("FileManager", "failed profile=${profileRef(profileId)} action=${operation.ticket.lane}", error)
        if (isFileManagerOperationVisible(operation)) {
            _state.update {
                it.copy(
                    fileManagerLoading = false,
                    fileManagerOperation = null,
                    fileManagerError = message,
                )
            }
        }
    }

    fun showAgentSettings() {
        if (!_state.value.activeAgentCapabilities.globalSettings) return
        val profileId = _state.value.selectedProfileId ?: return
        val agent = _state.value.activeAgent
        val profile = currentProfile() ?: return
        val client = activeClient()?.takeIf { it.isConnected() } ?: run {
            _state.update { it.copy(error = "服务器未连接，无法读取 ${agent.label} 配置") }
            return
        }
        val operation = beginClientOperation(profileId, "agent-settings", client) ?: return
        _state.update {
            it.copy(
                agentSettingsVisible = true,
                agentSettingsLoading = true,
                agentSettingsSaving = false,
                agentSettingsTesting = false,
                agentSettings = null,
                agentSettingsTestResult = null,
                agentSettingsError = null,
            )
        }
        viewModelScope.launch {
            try {
                val settings = client.readGlobalSettings(profile)
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            agentSettingsLoading = false,
                            agentSettings = settings,
                            agentSettingsError = null,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            agentSettingsLoading = false,
                            agentSettingsError = error.message ?: "无法读取 ${agent.label} 全局配置",
                        )
                    }
                }
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun dismissAgentSettings() {
        _state.update { current ->
            if (current.agentSettingsSaving || current.agentSettingsTesting) current else {
                current.copy(
                    agentSettingsVisible = false,
                    agentSettingsLoading = false,
                    agentSettingsTesting = false,
                    agentSettings = null,
                    agentSettingsTestResult = null,
                    agentSettingsError = null,
                )
            }
        }
    }

    fun testAgentSettings(baseUrl: String, apiKey: String, proxyUrl: String, testModel: String) {
        if (!_state.value.activeAgentCapabilities.globalSettings) return
        val profileId = _state.value.selectedProfileId ?: return
        val agent = _state.value.activeAgent
        val profile = currentProfile() ?: return
        val current = _state.value
        if (current.agentSettingsLoading || current.agentSettingsSaving || current.agentSettingsTesting) return
        val client = activeClient()?.takeIf { it.isConnected() } ?: run {
            _state.update { it.copy(agentSettingsError = "服务器未连接，无法测试 ${agent.label} API") }
            return
        }
        val operation = beginClientOperation(profileId, "agent-settings", client) ?: return
        _state.update {
            it.copy(
                agentSettingsTesting = true,
                agentSettingsTestResult = null,
                agentSettingsError = null,
            )
        }
        viewModelScope.launch {
            try {
                val result = client.testGlobalSettings(profile, baseUrl, apiKey, proxyUrl, testModel)
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            agentSettingsTesting = false,
                            agentSettingsTestResult = result,
                            agentSettingsError = null,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            agentSettingsTesting = false,
                            agentSettingsTestResult = null,
                            agentSettingsError = error.message ?: "无法测试 ${agent.label} API 连接",
                        )
                    }
                }
            } finally {
                finishClientOperation(operation)
            }
        }
    }

    fun saveAgentSettings(
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
        defaultModel: String,
        defaultReasoningEffort: String,
        testModel: String,
        preserveCurrentProvider: Boolean,
    ) {
        if (!_state.value.activeAgentCapabilities.globalSettings) return
        val profileId = _state.value.selectedProfileId ?: return
        val agent = _state.value.activeAgent
        val profile = currentProfile() ?: return
        if (_state.value.agentSettingsTesting) return
        val normalizedTestModel = runCatching {
            val normalized = RemoteCodexSettings.normalizeTestModel(testModel)
            if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(normalized) else normalized
        }
            .getOrElse { error ->
                _state.update {
                    it.copy(agentSettingsError = error.message ?: "测试模型格式错误")
                }
                return
            }
        val normalizedDefaultModel = runCatching {
            val normalized = RemoteCodexSettings.normalizeDefaultModel(defaultModel)
            if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(normalized) else normalized
        }
            .getOrElse { error ->
                _state.update {
                    it.copy(agentSettingsError = error.message ?: "默认模型格式错误")
                }
                return
            }
        val normalizedDefaultReasoningEffort = runCatching {
            if (_state.value.activeAgentCapabilities.reasoningEffort) {
                RemoteCodexSettings.normalizeDefaultReasoningEffort(defaultReasoningEffort)
            } else {
                ""
            }
        }.getOrElse { error ->
            _state.update {
                it.copy(agentSettingsError = error.message ?: "默认思考强度格式错误")
            }
            return
        }
        val client = activeClient()?.takeIf { it.isConnected() } ?: run {
            _state.update { it.copy(agentSettingsError = "服务器未连接，无法保存 ${agent.label} 配置") }
            return
        }
        val operation = beginClientOperation(profileId, "agent-settings", client) ?: return
        _state.update {
            it.copy(
                agentSettingsSaving = true,
                agentSettingsTestResult = null,
                agentSettingsError = null,
            )
        }
        viewModelScope.launch {
            var saved = false
            try {
                client.writeGlobalSettings(
                    profile = profile,
                    baseUrl = baseUrl,
                    apiKey = apiKey,
                    proxyUrl = proxyUrl,
                    defaultModel = normalizedDefaultModel,
                    defaultReasoningEffort = normalizedDefaultReasoningEffort,
                    preserveCurrentProvider = preserveCurrentProvider,
                )
                saved = true
                updateProfileAgentDefaults(
                    profileId = profileId,
                    agent = operation.key.agent,
                    testModel = normalizedTestModel,
                    defaultModel = normalizedDefaultModel,
                    defaultEffort = normalizedDefaultReasoningEffort,
                )
                if (operation.key.agent == AgentKind.OpenCode) {
                    runCatching {
                        syncCustomModelsNow(
                            profileId = profileId,
                            agent = operation.key.agent,
                            requireConnected = false,
                        )
                    }.onFailure { syncError ->
                        DiagnosticLogger.warn(
                            "Models",
                            "sync_after_settings_failed profile=${profileRef(profileId)} " +
                                "error=${syncError.message ?: syncError::class.simpleName}",
                        )
                    }
                }
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            agentSettingsVisible = false,
                            agentSettingsLoading = false,
                            agentSettingsSaving = false,
                            agentSettingsTesting = false,
                            agentSettings = null,
                            agentSettingsTestResult = null,
                            agentSettingsError = null,
                        )
                    }
                }
                DiagnosticLogger.info(
                    "AgentSettings",
                    "updated global configuration profile=${profileRef(profileId)} agent=${operation.key.agent.label}",
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isOperationVisible(operation)) {
                    _state.update {
                        it.copy(
                            agentSettingsSaving = false,
                            agentSettingsError = error.message ?: "无法保存 ${agent.label} 全局配置",
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
        client: RemoteAgentClient,
        exclusive: Boolean = true,
    ): ClientOperation? = beginClientOperation(sessionKey(profileId), lane, client, exclusive)

    private fun beginClientOperation(
        key: AgentConnectionKey,
        lane: String,
        client: RemoteAgentClient,
        exclusive: Boolean = true,
    ): ClientOperation? {
        val generation = client.currentGeneration() ?: return null
        if (connections.client(key.profileId, key.agent) !== client) return null
        return ClientOperation(
            ticket = operations.begin(key.profileId, lane, exclusive),
            key = key,
            client = client,
            generation = generation,
        )
    }

    private fun beginHostOperation(
        profileId: String,
        lane: String,
        client: RemoteServerClient,
        exclusive: Boolean = true,
    ): HostOperation? {
        val generation = client.currentGeneration() ?: return null
        if (hosts.client(profileId) !== client) return null
        return HostOperation(
            ticket = operations.begin(profileId, lane, exclusive),
            profileId = profileId,
            client = client,
            generation = generation,
        )
    }

    private fun isCurrent(ticket: ProfileOperationTracker.Ticket): Boolean = operations.isCurrent(ticket)

    private fun isOperationCurrent(operation: ClientOperation): Boolean =
        operations.isCurrent(operation.ticket) &&
            connections.client(operation.key.profileId, operation.key.agent) === operation.client &&
            operation.client.isGenerationActive(operation.generation)

    private fun isOperationVisible(operation: ClientOperation): Boolean =
        isOperationCurrent(operation) && isActiveAgent(operation.key)

    private fun isHostOperationCurrent(operation: HostOperation): Boolean =
        operations.isCurrent(operation.ticket) &&
            hosts.client(operation.profileId) === operation.client &&
            operation.client.isConnected() &&
            operation.client.currentGeneration() == operation.generation

    private fun isHostOperationVisible(operation: HostOperation): Boolean =
        isHostOperationCurrent(operation) && isActiveProfile(operation.profileId)

    private fun finishClientOperation(operation: ClientOperation) {
        operations.finish(operation.ticket)
    }

    private fun finishHostOperation(operation: HostOperation) {
        operations.finish(operation.ticket)
    }

    private fun invalidateProfile(profileId: String) {
        operations.invalidateProfile(profileId)
        sessionNavigationJobs.remove(profileId)?.cancel()
        threadHistoryJobs.remove(profileId)?.cancel()
        threadMutationJobs.remove(profileId)?.cancel()
        resumeNotificationBuffers.keys.removeAll { it.profileId == profileId }
        unsupportedGoalAgents.removeAll { it.profileId == profileId }
        removeGoalNotificationVersions(profileId)
    }

    private fun invalidateAgent(key: AgentConnectionKey) {
        resumeNotificationBuffers.remove(key)
        unsupportedGoalAgents.remove(key)
        removeGoalNotificationVersions(key)
        if (isActiveAgent(key)) {
            invalidateLane(key.profileId, "session-navigation")
            invalidateLane(key.profileId, "thread-history")
            invalidateLane(key.profileId, "thread-mutation")
        }
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
        val key = sessionKey(profileId)
        val buffer = resumeNotificationBuffers[key] ?: return
        val timeline = if (isActiveAgent(key)) {
            _state.value.timeline
        } else {
            sessionSnapshots[key]?.timeline.orEmpty()
        }
        releaseResumeNotifications(
            key = key,
            buffer = buffer,
            snapshot = timeline,
            replay = true,
            snapshotSequence = Long.MIN_VALUE,
        )
    }

    private fun applySessionState(
        profileId: String,
        agent: AgentKind = activeAgentFor(profileId),
        transform: (AppUiState) -> AppUiState,
    ) {
        val key = AgentConnectionKey(profileId, agent)
        if (isActiveAgent(key)) {
            _state.update { current ->
                if (current.selectedProfileId != profileId || current.activeAgent != agent) return@update current
                val transformed = enforceActiveTimelineBounds(transform(current))
                transformed.copy(
                    agentThreadLists = transformed.agentThreadLists + (key to transformed.threads),
                ).also { updated ->
                    sessionSnapshots[key] = SessionSnapshot.capture(updated)
                }
            }
            return
        }
        val profile = _state.value.profiles.firstOrNull { it.id == profileId }
        val base = (sessionSnapshots[key] ?: SessionSnapshot()).restore(
            AppUiState(
                selectedProfileId = profileId,
                activeAgent = agent,
                activeAgentCapabilities = capabilitiesFor(agent),
                approvalMode = profile?.approvalMode ?: ApprovalMode.RequestApproval,
                sandbox = (profile?.approvalMode ?: ApprovalMode.RequestApproval).sandbox,
            ),
        )
        val updated = enforceActiveTimelineBounds(transform(base))
        sessionSnapshots[key] = SessionSnapshot.capture(updated)
        _state.update { current ->
            current.copy(agentThreadLists = current.agentThreadLists + (key to updated.threads))
        }
    }

    private fun restoreProfileState(
        base: AppUiState,
        profile: ServerProfile,
        connection: ConnectionState,
    ): AppUiState {
        val setupKey = AgentConnectionKey(profile.id, profile.activeAgent)
        val setup = base.agentSetupStates[setupKey]
        val visibleSetup = setup?.takeUnless { it.minimized }
        val pendingFingerprint = pendingFingerprints[profile.id]
        val agentConnected = isAgentConnected(profile.id, profile.activeAgent)
        fingerprintDialogProfileId = profile.id.takeIf { pendingFingerprint != null }
        val cleanBase = base.copy(
            activeAgent = profile.activeAgent,
            activeAgentCapabilities = if (agentConnected) {
                connections.capabilities(profile.id, profile.activeAgent) ?: capabilitiesFor(profile.activeAgent)
            } else {
                AgentCapabilities.None
            },
            approvalMode = profile.approvalMode,
            sandbox = profile.approvalMode.sandbox,
            connection = connection,
            connectionStates = base.connectionStates + (profile.id to connection),
            fileManagerProfileId = null,
            fileManagerLoading = false,
            fileManagerCurrentPath = "",
            fileManagerParentPath = null,
            fileManagerEntries = emptyList(),
            fileManagerClipboard = null,
            fileManagerOperation = null,
            fileManagerError = null,
        )
        val restored = if (agentConnected) {
            sessionSnapshots[AgentConnectionKey(profile.id, profile.activeAgent)]
                ?.restore(cleanBase) ?: clearSessionFields(cleanBase)
        } else {
            clearSessionFields(cleanBase)
        }
        val approvals = pendingApprovalsByAgent[AgentConnectionKey(profile.id, profile.activeAgent)].orEmpty()
        return restored.copy(
            selectedProfileId = profile.id,
            screen = if (connection.phase == ConnectionPhase.Connected) AppScreen.Threads else AppScreen.Servers,
            connection = connection,
            pendingFingerprint = pendingFingerprint,
            remoteSetup = visibleSetup?.prompt,
            setupInProgress = visibleSetup?.inProgress == true,
            setupProgress = visibleSetup?.progress.orEmpty(),
            setupProgressPercent = visibleSetup?.percent ?: 0,
            setupProgressDetail = visibleSetup?.detail.orEmpty(),
            setupDownloadPercent = visibleSetup?.downloadPercent,
            approvalMode = profile.approvalMode,
            sandbox = profile.approvalMode.sandbox,
            approvalQueue = approvals,
            approval = approvals.firstOrNull(),
            agentThreadLists = restored.agentThreadLists + (setupKey to restored.threads),
            workspacePickerVisible = false,
            workspaceLoading = false,
            fileManagerProfileId = null,
            fileManagerLoading = false,
            fileManagerCurrentPath = "",
            fileManagerParentPath = null,
            fileManagerEntries = emptyList(),
            fileManagerClipboard = null,
            fileManagerOperation = null,
            fileManagerError = null,
            agentSettingsVisible = false,
            agentSettingsLoading = false,
            agentSettingsSaving = false,
            agentSettingsTesting = false,
            agentSettings = null,
            agentSettingsTestResult = null,
            agentSettingsError = null,
            apiModelOptions = emptyList(),
            apiModelOptionsProfileId = null,
            apiModelOptionsLoading = false,
            apiModelOptionsError = null,
            submitting = false,
            error = null,
            diagnostic = null,
            loading = connection.phase in setOf(
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
        setupProgressDetail = "",
        setupDownloadPercent = null,
        agentSetupStates = emptyMap(),
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
        apiModelOptions = emptyList(),
        apiModelOptionsProfileId = null,
        apiModelOptionsLoading = false,
        apiModelOptionsError = null,
        selectedModel = null,
        selectedEffort = null,
        composerDraft = "",
        workspacePickerVisible = false,
        workspaceLoading = false,
        workspaceCurrentPath = "",
        workspaceParentPath = null,
        workspaceDirectories = emptyList(),
        workspaceError = null,
        agentSettingsVisible = false,
        agentSettingsLoading = false,
        agentSettingsSaving = false,
        agentSettingsTesting = false,
        agentSettings = null,
        agentSettingsTestResult = null,
        agentSettingsError = null,
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
        invalidateProfile(profileId)
        cancelCustomModelSync(profileId)
        fingerprintJobs[profileId]?.cancel()
        connectionJobs[profileId]?.cancel()
        cancelConnectionSync(profileId)
        cancelSetupJobs(profileId)
        serverMetricsJobs.remove(profileId)?.cancel()
        contextUsageFallbacks.clear(profileId)
        clearSubAgentNavigation(profileId)
        effectiveProfiles.remove(profileId)
        pendingApprovalsByAgent.keys.removeAll { it.profileId == profileId }
        clearSetupStates(profileId)
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
                    setupProgressDetail = "",
                    setupDownloadPercent = null,
                    agentThreadLists = current.agentThreadLists,
                )
            }
        }
        val job = viewModelScope.launch {
            try {
                hosts.disconnect(profileId)
                connections.disconnectProfile(profileId)
                if (_state.value.profiles.any { it.id == profileId }) {
                    updateProfileConnection(profileId, ConnectionState())
                }
                DiagnosticLogger.info("Connection", "disconnect_success profile=${profileRef(profileId)}")
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (_state.value.profiles.any { it.id == profileId }) {
                    showHostConnectionError(error, profileId)
                }
            } finally {
                if (disconnectJobs[profileId] === currentCoroutineContext()[Job]) {
                    disconnectJobs.remove(profileId)
                }
            }
        }
        disconnectJobs[profileId] = job
    }

    private fun setupState(key: AgentConnectionKey): AgentSetupState? =
        _state.value.agentSetupStates[key]

    private fun updateSetupState(
        key: AgentConnectionKey,
        transform: (AgentSetupState) -> AgentSetupState,
    ) {
        _state.update { current ->
            val updated = transform(current.agentSetupStates[key] ?: AgentSetupState())
            val visible = current.selectedProfileId == key.profileId &&
                current.remoteSetup?.agent == key.agent && !updated.minimized
            current.copy(
                agentSetupStates = current.agentSetupStates + (key to updated),
                remoteSetup = if (visible) updated.prompt else current.remoteSetup,
                setupInProgress = if (visible) updated.inProgress else current.setupInProgress,
                setupProgress = if (visible) updated.progress else current.setupProgress,
                setupProgressPercent = if (visible) updated.percent else current.setupProgressPercent,
                setupProgressDetail = if (visible) updated.detail else current.setupProgressDetail,
                setupDownloadPercent = if (visible) updated.downloadPercent else current.setupDownloadPercent,
            )
        }
    }

    private fun showRemoteSetup(key: AgentConnectionKey) {
        val setup = setupState(key) ?: return
        val prompt = setup.prompt ?: return
        _state.update { current ->
            if (current.selectedProfileId != key.profileId || current.activeAgent != key.agent) {
                return@update current
            }
            val visible = setup.copy(minimized = false)
            current.copy(
                remoteSetup = prompt,
                setupInProgress = visible.inProgress,
                setupProgress = visible.progress,
                setupProgressPercent = visible.percent,
                setupProgressDetail = visible.detail,
                setupDownloadPercent = visible.downloadPercent,
                agentSetupStates = current.agentSetupStates + (key to visible),
                loading = false,
            )
        }
    }

    private fun removeSetupState(key: AgentConnectionKey) {
        setupProfiles.remove(key)
        _state.update { current ->
            val wasVisible = current.selectedProfileId == key.profileId &&
                current.remoteSetup?.agent == key.agent
            current.copy(
                agentSetupStates = current.agentSetupStates - key,
                remoteSetup = if (wasVisible) null else current.remoteSetup,
                setupInProgress = if (wasVisible) false else current.setupInProgress,
                setupProgress = if (wasVisible) "" else current.setupProgress,
                setupProgressPercent = if (wasVisible) 0 else current.setupProgressPercent,
                setupProgressDetail = if (wasVisible) "" else current.setupProgressDetail,
                setupDownloadPercent = if (wasVisible) null else current.setupDownloadPercent,
            )
        }
    }

    private fun clearSetupStates(profileId: String) {
        setupProfiles.keys.removeAll { it.profileId == profileId }
        _state.update { current ->
            val wasVisible = current.selectedProfileId == profileId && current.remoteSetup != null
            current.copy(
                agentSetupStates = current.agentSetupStates.filterKeys { it.profileId != profileId },
                remoteSetup = if (wasVisible) null else current.remoteSetup,
                setupInProgress = if (wasVisible) false else current.setupInProgress,
                setupProgress = if (wasVisible) "" else current.setupProgress,
                setupProgressPercent = if (wasVisible) 0 else current.setupProgressPercent,
                setupProgressDetail = if (wasVisible) "" else current.setupProgressDetail,
                setupDownloadPercent = if (wasVisible) null else current.setupDownloadPercent,
            )
        }
    }

    private fun cancelSetupJobs(profileId: String) {
        setupJobs.keys.filter { it.profileId == profileId }.forEach { key ->
            setupJobs.remove(key)?.cancel()
        }
    }

    private fun cancelConnectionSync(profileId: String) {
        connectionSyncJobs.keys.filter { it.profileId == profileId }.forEach { key ->
            connectionSyncJobs.remove(key)?.cancel()
        }
    }

    private fun hasActiveSetupJob(profileId: String): Boolean =
        setupJobs.any { (key, job) -> key.profileId == profileId && job.isActive }

    private fun setupLane(agent: AgentKind): String = "setup-${agent.name}"

    private fun modelListLane(agent: AgentKind): String = "model-list-${agent.name}"

    private fun threadListLane(agent: AgentKind): String = "thread-list-${agent.name}"

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

    private fun activeClient(): RemoteAgentClient? =
        _state.value.selectedProfileId?.let(connections::client)

    private fun isAgentConnected(profileId: String, agent: AgentKind): Boolean =
        _state.value.agentConnectionStates[AgentConnectionKey(profileId, agent)]?.phase ==
            ConnectionPhase.Connected

    private suspend fun clearConnectionJobIfCurrent(profileId: String) {
        if (connectionJobs[profileId] === currentCoroutineContext()[Job]) {
            connectionJobs.remove(profileId)
        }
    }

    private fun updateAgentConnection(
        profileId: String,
        agent: AgentKind,
        connection: ConnectionState,
    ) {
        val key = AgentConnectionKey(profileId, agent)
        _state.update { current ->
            current.copy(
                agentConnectionStates = current.agentConnectionStates + (key to connection),
                connection = current.connectionStates[profileId] ?: current.connection,
            )
        }
    }

    private fun activeAgentFor(profileId: String): AgentKind {
        val state = _state.value
        if (state.selectedProfileId == profileId) return state.activeAgent
        return connections.activeAgent(profileId)
            ?: state.profiles.firstOrNull { it.id == profileId }?.activeAgent
            ?: AgentKind.Codex
    }

    private fun sessionKey(profileId: String, agent: AgentKind = activeAgentFor(profileId)) =
        AgentConnectionKey(profileId, agent)

    private fun subAgentNavigationScope(profileId: String): String =
        agentScopeId(sessionKey(profileId))

    private fun clearSubAgentNavigation(profileId: String) {
        AgentKind.entries.forEach { agent ->
            subAgentNavigationStacks.clear(agentScopeId(AgentConnectionKey(profileId, agent)))
        }
    }

    private fun isActiveAgent(key: AgentConnectionKey): Boolean =
        _state.value.selectedProfileId == key.profileId && _state.value.activeAgent == key.agent

    private fun capabilitiesFor(agent: AgentKind): AgentCapabilities = when (agent) {
        AgentKind.Codex -> AgentCapabilities.Codex
        AgentKind.OpenCode -> AgentCapabilities.OpenCode
    }

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
        client: RemoteAgentClient,
        operation: ClientOperation,
    ) {
        val agentKey = operation.key
        if (agentKey in unsupportedGoalAgents) return
        val storageKey = threadStorageKey(agentKey, threadId)
        val notificationVersion = goalNotificationVersions[storageKey] ?: 0L
        val goal = try {
            client.getThreadGoal(threadId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (isUnsupportedGoalMethod(error)) unsupportedGoalAgents += agentKey
            DiagnosticLogger.warn(
                "Goal",
                "read_failed profile=${profileRef(profileId)} thread=${profileRef(threadId)} ${error.message.orEmpty()}",
            )
            return
        }
        if (!isOperationCurrent(operation) || goalNotificationVersions[storageKey] != notificationVersion) return
        applySessionState(profileId, agentKey.agent) { current ->
            if (current.activeThread?.id == threadId) current.copy(activeGoal = goal) else current
        }
    }

    private fun markGoalNotification(key: AgentConnectionKey, threadId: String) {
        if (threadId.isBlank()) return
        val storageKey = threadStorageKey(key, threadId)
        goalNotificationVersions[storageKey] = (goalNotificationVersions[storageKey] ?: 0L) + 1L
        while (goalNotificationVersions.size > MAX_GOAL_NOTIFICATION_VERSIONS) {
            goalNotificationVersions.remove(goalNotificationVersions.keys.first())
        }
    }

    private fun removeGoalNotificationVersions(profileId: String) {
        val prefix = "$profileId\u0000"
        goalNotificationVersions.keys.removeAll { it.startsWith(prefix) }
    }

    private fun removeGoalNotificationVersions(key: AgentConnectionKey) {
        val prefix = "${key.profileId}\u0000${key.agent.name}\u0000"
        goalNotificationVersions.keys.removeAll { it.startsWith(prefix) }
    }

    private fun isUnsupportedGoalMethod(error: Throwable): Boolean {
        val message = error.message.orEmpty()
        return message.contains("method not found", ignoreCase = true) ||
            message.contains("unknown method", ignoreCase = true)
    }

    private fun reduceProfileNotification(event: ProfiledAgentNotification) {
        val key = event.key
        val profileId = event.profileId
        val client = connections.client(profileId, event.agent) ?: return
        val notification = event.value
        if (!client.isGenerationActive(notification.generation)) return
        if (notification.method == "thread/goal/updated" || notification.method == "thread/goal/cleared") {
            markGoalNotification(key, notification.params.string("threadId"))
        }
        if (notification.method == "turn/completed") {
            publishTurnCompletion(key, notification.params.string("threadId"))
        }
        resumeNotificationBuffers[key]?.let { buffer ->
            if (buffer.offer(notification)) return
        }
        applySessionState(profileId, event.agent) { current ->
            CodexEventReducer.reduce(current, notification.method, notification.params)
        }
        syncCompletedTurnTiming(key, notification.method, notification.params)
        if (notification.method == "turn/completed" || notification.method == "thread/tokenUsage/updated") {
            sessionSnapshots[key]?.activeThread?.let { thread ->
                val snapshot = sessionSnapshots[key]
                rememberContextUsage(key, thread.id, snapshot?.tokenUsage)
                client.cacheThread(
                    thread,
                    snapshot?.timeline.orEmpty(),
                    snapshot?.olderTurnsCursor,
                    snapshot?.tokenUsage,
                )
            }
        }
        if (notification.method == "turn/completed") {
            if (isActiveAgent(key)) refreshThreads(silent = true)
        }
    }

    private fun publishTurnCompletion(key: AgentConnectionKey, reportedThreadId: String) {
        val current = _state.value
        val profileId = key.profileId
        val snapshot = sessionSnapshots[key]
        val activeThread = if (isActiveAgent(key)) current.activeThread else snapshot?.activeThread
        val threadId = reportedThreadId.ifBlank { activeThread?.id.orEmpty() }
        if (threadId.isBlank()) return
        val thread = if (isActiveAgent(key)) {
            current.threads.firstOrNull { it.id == threadId }
        } else {
            snapshot?.threads?.firstOrNull { it.id == threadId }
        } ?: activeThread?.takeIf { it.id == threadId }
        val profile = current.profiles.firstOrNull { it.id == profileId } ?: return
        _turnCompletions.tryEmit(
            TurnCompletion(
                profileId = profileId,
                agent = key.agent,
                profileName = profile.name.ifBlank { profile.host },
                threadId = threadId,
                threadTitle = thread?.title.orEmpty(),
                threadPreview = thread?.preview.orEmpty(),
            ),
        )
    }

    private fun releaseResumeNotifications(
        key: AgentConnectionKey,
        buffer: ResumeNotificationBuffer,
        snapshot: List<top.asdb.codexremote.data.TimelineEntry>,
        replay: Boolean,
        snapshotSequence: Long = Long.MAX_VALUE,
    ) {
        if (resumeNotificationBuffers[key] !== buffer) return
        resumeNotificationBuffers.remove(key)
        if (!replay) return
        val profileId = key.profileId
        val client = connections.client(profileId, key.agent) ?: return
        val notifications = buffer.drain(snapshot, snapshotSequence).filter { notification ->
            client.isGenerationActive(notification.generation)
        }
        var reducedState: AppUiState? = null
        if (notifications.isNotEmpty()) {
            applySessionState(profileId, key.agent) { current ->
                notifications.fold(current) { state, notification ->
                    CodexEventReducer.reduce(state, notification.method, notification.params)
                }.also { reducedState = it }
            }
        }
        if (notifications.any {
            it.method == "turn/completed" || it.method == "thread/tokenUsage/updated"
        }) {
            val snapshotState = reducedState ?: if (isActiveAgent(key)) {
                _state.value
            } else {
                sessionSnapshots[key]?.restore(
                    AppUiState(selectedProfileId = profileId, activeAgent = key.agent),
                )
            }
            snapshotState?.activeThread?.let { thread ->
                rememberContextUsage(key, thread.id, snapshotState.tokenUsage)
                client.cacheThread(
                    thread,
                    snapshotState.timeline,
                    snapshotState.olderTurnsCursor,
                    snapshotState.tokenUsage,
                )
            }
        }
        if (notifications.any { it.method == "turn/completed" }) {
            if (isActiveAgent(key)) refreshThreads(silent = true)
        }
        if (buffer.overflowed && isActiveAgent(key)) {
            _state.update { it.copy(diagnostic = "恢复会话期间输出过多，部分流式内容已截断") }
        }
    }

    private suspend fun receiveProfileApproval(event: ProfiledAgentApproval) {
        val key = event.key
        val profileId = event.profileId
        val client = connections.client(profileId, event.agent) ?: return
        if (!client.isGenerationActive(event.value.generation)) return
        val approval = event.value.prompt
        val existing = pendingApprovalsByAgent[key].orEmpty()
        if (existing.any { it.requestId == approval.requestId }) return
        if (existing.size >= MAX_PENDING_APPROVALS) {
            // Keep an untrusted server from retaining an unbounded number of request payloads.
            runCatching { client.answerApproval(approval, accept = false) }
            if (isActiveAgent(key)) {
                _state.update { it.copy(diagnostic = "审批请求过多，已自动拒绝新的请求") }
            }
            return
        }
        val queue = existing + approval
        pendingApprovalsByAgent[key] = queue
        if (isActiveAgent(key)) {
            _state.update { current ->
                current.copy(approvalQueue = queue, approval = current.approval ?: queue.firstOrNull())
            }
        }
    }

    private fun handleProfileClosed(event: ProfiledAgentConnectionEvent) {
        val key = event.key
        connectionSyncJobs.remove(key)?.cancel()
        invalidateAgent(key)
        if (isActiveAgent(key)) subAgentNavigationStacks.clear(agentScopeId(key))
        val failureMessage = presentCodexDiagnostic(
            event.value.message,
            ConnectionPhase.Failed,
        ).ifBlank { "${event.agent.label} SSH 通道已关闭" }
        val snapshot = sessionSnapshots[key]
        if (snapshot != null) {
            sessionSnapshots[key] = snapshot.copy(
                activeTurnId = null,
                running = false,
                loading = false,
                submitting = false,
                olderTurnsLoading = false,
            )
        }
        pendingApprovalsByAgent.remove(key)
        if (!isActiveAgent(key)) return
        _state.update {
            it.copy(
                agentConnectionStates = it.agentConnectionStates + (
                    key to ConnectionState(ConnectionPhase.Failed, failureMessage)
                ),
                activeAgentCapabilities = AgentCapabilities.None,
                connection = it.connectionStates[key.profileId] ?: it.connection,
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
                setupProgressDetail = "",
                setupDownloadPercent = null,
                diagnostic = failureMessage,
            )
        }
    }

    private suspend fun prepareRemote(profile: ServerProfile, agent: AgentKind): ServerProfile? {
        if (agent == AgentKind.Codex && profile.remoteCommand != RemoteBootstrap.MANAGED_REMOTE_COMMAND) {
            return profile
        }
        val environment = connections.inspectRuntime(profile, agent, hosts.client(profile.id))
        environment.installationProblem?.let { problem ->
            throw IllegalStateException("${agent.label}: $problem")
        }
        environment.compatibleCommand?.let { command ->
            return if (agent == AgentKind.Codex) profile.copy(remoteCommand = command) else profile
        }

        val setupKey = AgentConnectionKey(profile.id, agent)
        setupProfiles[setupKey] = profile
        val detail = environment.detectedVersion?.let { version ->
            "${agent.label}: 检测到 $version，需要安装兼容版本。"
        } ?: "${agent.label}: 尚未安装，将在当前 SSH 用户目录安装。"
        val prompt = RemoteSetupPrompt(
            title = "安装远程 ${agent.label}",
            detail = detail,
            os = environment.os,
            architecture = environment.architecture,
            home = environment.home,
            detectedVersion = environment.detectedVersion,
            agent = agent,
        )
        updateAgentConnection(
            profile.id,
            agent,
            ConnectionState(ConnectionPhase.Disconnected, "需要安装 ${agent.label}"),
        )
        updateSetupState(setupKey) { AgentSetupState(prompt = prompt) }
        if (isActiveAgent(setupKey)) showRemoteSetup(setupKey)
        return null
    }

    private suspend fun loadConnectedSession(
        profile: ServerProfile,
        agent: AgentKind,
    ): ConnectedSession {
        connections.register(profile, agent)
        val version = connections.connect(profile, agent)
        val key = AgentConnectionKey(profile.id, agent)
        val snapshot = sessionSnapshots[key]
        val cachedThreads = _state.value.agentThreadLists[key] ?: snapshot?.threads.orEmpty()
        val cachedModels = remoteModelsByProfile[key] ?: snapshot?.models.orEmpty()
        val cachedWorkspace = snapshot?.workspaceCurrentPath?.takeIf(String::isNotBlank)?.let { path ->
            RemoteDirectoryListing(
                currentPath = path,
                parentPath = snapshot.workspaceParentPath,
                directories = snapshot.workspaceDirectories,
            )
        }
        return ConnectedSession(
            version = version,
            models = cachedModels,
            threads = cachedThreads,
            workspace = cachedWorkspace,
            workspaceError = snapshot?.workspaceError,
        )
    }

    private fun startConnectedSessionRefresh(
        profile: ServerProfile,
        agent: AgentKind,
        client: RemoteAgentClient,
    ) {
        val key = AgentConnectionKey(profile.id, agent)
        val generation = client.currentGeneration() ?: return
        connectionSyncJobs.remove(key)?.cancel()
        val startedNanos = System.nanoTime()
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try {
                val modelRefresh = launch modelRefresh@{
                    val operation = beginClientOperation(
                        key = key,
                        lane = modelListLane(agent),
                        client = client,
                    ) ?: return@modelRefresh
                    try {
                        val models = timedConnectionStage(profile.id, agent, "model_list") {
                            client.listModels()
                        }
                        if (isOperationCurrent(operation)) {
                            applyConnectedModels(profile, agent, models)
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Throwable) {
                        // The timing log contains the failure; cached models remain usable.
                    } finally {
                        finishClientOperation(operation)
                    }
                }
                val threadRefresh = launch threadRefresh@{
                    val operation = beginClientOperation(
                        key = key,
                        lane = threadListLane(agent),
                        client = client,
                    ) ?: return@threadRefresh
                    try {
                        val threads = timedConnectionStage(profile.id, agent, "thread_list") {
                            client.listThreads()
                        }
                        if (isOperationCurrent(operation)) {
                            applySessionState(profile.id, agent) { current ->
                                current.copy(
                                    threads = threads,
                                    activeThread = current.activeThread?.let { active ->
                                        threads.firstOrNull { it.id == active.id } ?: active
                                    },
                                    loading = false,
                                )
                            }
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Throwable) {
                        // Keep the cached list visible when a background refresh fails.
                    } finally {
                        finishClientOperation(operation)
                    }
                }
                val workspaceRefresh = launch workspaceRefresh@{
                    val host = hosts.client(profile.id)?.takeIf { it.isConnected() }
                        ?: return@workspaceRefresh
                    val operation = beginHostOperation(profile.id, "workspace", host)
                        ?: return@workspaceRefresh
                    try {
                        val workspace = timedConnectionStage(profile.id, agent, "workspace_list") {
                            loadInitialWorkspace(profile, host)
                        }
                        if (isHostOperationCurrent(operation)) {
                            applySessionState(profile.id, agent) { current ->
                                current.copy(
                                    workspaceLoading = false,
                                    workspaceCurrentPath = workspace.listing?.currentPath
                                        ?: profile.workspace.ifBlank { "/" },
                                    workspaceParentPath = workspace.listing?.parentPath,
                                    workspaceDirectories = workspace.listing?.directories.orEmpty(),
                                    workspaceError = workspace.preferredError,
                                )
                            }
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        if (isHostOperationCurrent(operation)) {
                            applySessionState(profile.id, agent) { current ->
                                current.copy(workspaceLoading = false, workspaceError = error.message ?: "无法读取目录")
                            }
                        }
                    } finally {
                        finishHostOperation(operation)
                    }
                }
                listOf(modelRefresh, threadRefresh, workspaceRefresh).forEach { it.join() }
            } finally {
                if (client.isGenerationActive(generation)) {
                    logConnectionTiming(
                        profileId = profile.id,
                        agent = agent,
                        stage = "initial_sync_complete",
                        startedNanos = startedNanos,
                    )
                }
                if (connectionSyncJobs[key] === currentCoroutineContext()[Job]) {
                    connectionSyncJobs.remove(key)
                }
            }
        }
        connectionSyncJobs[key] = job
        job.start()
    }

    private suspend fun loadInitialWorkspace(
        profile: ServerProfile,
        host: RemoteServerClient,
    ): InitialWorkspaceResult {
        val preferred = runCatching {
            host.listDirectories(profile.workspace.takeIf { it.isNotBlank() })
        }
        val fallback = if (preferred.isFailure && profile.workspace.isNotBlank()) {
            runCatching { host.listDirectories(null) }
        } else {
            preferred
        }
        return InitialWorkspaceResult(
            listing = fallback.getOrThrow(),
            preferredError = preferred.exceptionOrNull()?.message,
        )
    }

    private fun applyConnectedModels(
        profile: ServerProfile,
        agent: AgentKind,
        remoteModels: List<CodexModel>,
    ) {
        val key = AgentConnectionKey(profile.id, agent)
        remoteModelsByProfile[key] = remoteModels
        val configuredProfile = _state.value.profiles.firstOrNull { it.id == profile.id } ?: profile
        val settings = configuredProfile.modelSettings(agent)
        val models = buildModelCatalog(
            remoteModels = remoteModels,
            customModels = settings.customModels,
            hiddenModelIds = settings.hiddenModelIds,
            customReasoningEfforts = if (agent == AgentKind.OpenCode) {
                ::openCodeReasoningEfforts
            } else {
                { emptyList() }
            },
        )
        applySessionState(profile.id, agent) { current ->
            val preferred = resolveNewThreadModelSelection(
                models = models,
                configuredModel = settings.preferredModel,
                configuredEffort = settings.preferredEffort,
            )
            val selectedModel = current.selectedModel?.takeIf { selected ->
                models.any { it.model == selected }
            } ?: preferred.model ?: models.firstOrNull()?.model
            val selected = models.firstOrNull { it.model == selectedModel }
            val selectedEffort = current.selectedEffort?.takeIf { effort ->
                selected == null || selected.efforts.isEmpty() || effort in selected.efforts
            } ?: preferred.effort ?: selected?.defaultEffort
            current.copy(
                models = models,
                selectedModel = selectedModel,
                selectedEffort = selectedEffort,
            )
        }
    }

    /** Completes SSH login without probing, installing, or starting an Agent. */
    private fun showHostConnected(profile: ServerProfile) {
        val profileId = profile.id
        val hostState = hosts.states.value[profileId]
            ?: ConnectionState(ConnectionPhase.Connected, "SSH 已连接")
        DiagnosticLogger.info("Connection", "ssh_connect_success profile=${profileRef(profileId)}")
        val activeAgent = _state.value.activeAgent.takeIf { it in AgentKind.entries }
            ?: profile.activeAgent
        _state.update { current ->
            val base = clearSessionFields(current)
            base.copy(
                screen = AppScreen.Threads,
                selectedProfileId = profileId,
                activeAgent = activeAgent,
                activeAgentCapabilities = if (isAgentConnected(profileId, activeAgent)) {
                    capabilitiesFor(activeAgent)
                } else {
                    AgentCapabilities.None
                },
                connection = hostState,
                connectionStates = current.connectionStates + (profileId to hostState),
                agentConnectionStates = current.agentConnectionStates,
                loading = false,
                workspacePickerVisible = false,
                remoteSetup = null,
                setupInProgress = false,
                setupProgress = "",
                setupProgressPercent = 0,
                setupProgressDetail = "",
                setupDownloadPercent = null,
                error = null,
                diagnostic = null,
            )
        }
        persistProfiles()
    }

    private fun showConnected(
        profile: ServerProfile,
        agent: AgentKind,
        connected: ConnectedSession,
    ) {
        val key = AgentConnectionKey(profile.id, agent)
        DiagnosticLogger.info(
            "Connection",
            "connect_success profile=${profileRef(profile.id)} agent=${agent.name} " +
                "version=${connected.version} cached_threads=${connected.threads.size} " +
                "cached_models=${connected.models.size}",
        )
        val configuredProfile = _state.value.profiles.firstOrNull { it.id == profile.id } ?: profile
        val modelSettings = configuredProfile.modelSettings(agent)
        remoteModelsByProfile[key] = connected.models
        val models = buildModelCatalog(
            remoteModels = connected.models,
            customModels = modelSettings.customModels,
            hiddenModelIds = modelSettings.hiddenModelIds,
            customReasoningEfforts = if (agent == AgentKind.OpenCode) {
                ::openCodeReasoningEfforts
            } else {
                { emptyList() }
            },
        )
        val defaultModel = models.firstOrNull { it.isDefault } ?: models.firstOrNull()
        val preferredSelection = resolveNewThreadModelSelection(
            models = models,
            configuredModel = modelSettings.preferredModel,
            configuredEffort = modelSettings.preferredEffort,
        )
        val expectedVersion = when (agent) {
            AgentKind.Codex -> BuildConfig.PINNED_CODEX_VERSION
            AgentKind.OpenCode -> BuildConfig.PINNED_OPENCODE_VERSION
        }
        val pinned = isPinnedVersion(connected.version, expectedVersion)
        val versionMessage = if (pinned) {
            "已连接 · ${agent.label} $expectedVersion"
        } else {
            "已连接 · ${agent.label} ${connected.version}"
        }
        val connectedState = ConnectionState(ConnectionPhase.Connected, versionMessage, connected.version)
        val hostState = hosts.states.value[profile.id]
            ?: ConnectionState(ConnectionPhase.Connected, "SSH 已连接")
        removeSetupState(key)
        pendingFingerprints.remove(profile.id)
        fingerprintProfiles.remove(profile.id)
        if (isActiveAgent(key)) subAgentNavigationStacks.clear(agentScopeId(key))
        if (!isActiveAgent(key)) {
            sessionSnapshots[key] = SessionSnapshot(
                threads = connected.threads,
                models = models,
                selectedModel = preferredSelection.model ?: defaultModel?.model,
                selectedEffort = preferredSelection.effort ?: defaultModel?.defaultEffort,
                workspaceCurrentPath = connected.workspace?.currentPath ?: configuredProfile.workspace.ifBlank { "/" },
                workspaceParentPath = connected.workspace?.parentPath,
                workspaceDirectories = connected.workspace?.directories.orEmpty(),
                workspaceError = connected.workspaceError,
                loading = false,
            )
            _state.update { current ->
                current.copy(agentThreadLists = current.agentThreadLists + (key to connected.threads))
            }
            scheduleCustomModelSync(profile.id, agent, immediate = true)
            return
        }
        // Keep the resolved command/client created by loadConnectedSession.
        connections.select(profile.id, agent)
        val showInitialWorkspacePrompt = configuredProfile.workspace.isBlank() && !configuredProfile.workspacePromptShown
        _state.update {
            val profiles = it.profiles.map { stored ->
                if (stored.id == profile.id && !stored.workspacePromptShown) {
                    stored.copy(workspacePromptShown = true)
                } else stored
            }
            it.copy(
                profiles = profiles,
                screen = AppScreen.Threads,
                activeAgent = agent,
                activeAgentCapabilities = connections.capabilities(profile.id, agent)
                    ?: capabilitiesFor(agent),
                connection = hostState,
                connectionStates = it.connectionStates + (profile.id to hostState),
                agentConnectionStates = it.agentConnectionStates + (key to connectedState),
                threads = connected.threads,
                agentThreadLists = it.agentThreadLists + (key to connected.threads),
                models = models,
                apiModelOptions = emptyList(),
                apiModelOptionsProfileId = null,
                apiModelOptionsLoading = false,
                apiModelOptionsError = null,
                selectedModel = preferredSelection.model ?: defaultModel?.model,
                selectedEffort = preferredSelection.effort ?: defaultModel?.defaultEffort,
                approvalMode = configuredProfile.approvalMode,
                sandbox = configuredProfile.approvalMode.sandbox,
                workspacePickerVisible = showInitialWorkspacePrompt,
                workspaceLoading = showInitialWorkspacePrompt,
                workspaceCurrentPath = connected.workspace?.currentPath
                    ?: configuredProfile.workspace.ifBlank { "/" },
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
                approvalQueue = pendingApprovalsByAgent[key].orEmpty(),
                approval = pendingApprovalsByAgent[key]?.firstOrNull(),
                loading = false,
                error = null,
                remoteSetup = null,
                setupInProgress = false,
                setupProgress = "",
                setupProgressPercent = 100,
                setupProgressDetail = "",
                setupDownloadPercent = null,
                diagnostic = if (!pinned) {
                    "服务器 ${agent.label} 与客户端固定版本 $expectedVersion 不一致"
                } else it.diagnostic,
            ).also { updated -> sessionSnapshots[key] = SessionSnapshot.capture(updated) }
        }
        persistProfiles()
        scheduleCustomModelSync(profile.id, agent, immediate = true)
    }

    private fun currentProfile(): ServerProfile? {
        val state = _state.value
        return state.profiles.firstOrNull { it.id == state.selectedProfileId }
    }

    private fun normalizeProfile(profile: ServerProfile): ServerProfile {
        val settings = profile.agentModelSettings.toMutableMap()
        settings.putIfAbsent(
            AgentKind.Codex,
            AgentModelSettings(
                preferredModel = profile.preferredModel,
                preferredEffort = profile.preferredEffort,
                testModel = profile.testModel,
                customModels = profile.customModels,
                hiddenModelIds = profile.hiddenModelIds,
            ),
        )
        val normalizedSettings = settings.mapValues { (agent, value) -> normalizeAgentModelSettings(agent, value) }
        val legacyCodex = normalizedSettings.getValue(AgentKind.Codex)
        return profile.copy(
            name = profile.name.trim().ifBlank { profile.host.trim().ifBlank { "服务器" } },
            host = profile.host.trim(),
            username = profile.username.trim().ifBlank { "root" },
            workspace = profile.workspace.trim(),
            proxyUrl = profile.proxyUrl.trim(),
            hostFingerprint = profile.hostFingerprint.trim(),
            remoteCommand = profile.remoteCommand.trim().ifBlank { RemoteBootstrap.MANAGED_REMOTE_COMMAND },
            preferredModel = legacyCodex.preferredModel,
            preferredEffort = legacyCodex.preferredEffort,
            testModel = legacyCodex.testModel,
            customModels = legacyCodex.customModels,
            hiddenModelIds = legacyCodex.hiddenModelIds,
            // The old selector is retained only for JSON compatibility; Agent lanes are chosen
            // on the connected server page now.
            agentMode = top.asdb.codexremote.data.AgentMode.Both,
            activeAgent = profile.activeAgent,
            agentModelSettings = normalizedSettings,
        )
    }

    private fun normalizeAgentModelSettings(
        agent: AgentKind,
        settings: AgentModelSettings,
    ): AgentModelSettings {
        val customModels = settings.customModels.mapNotNull {
            runCatching {
                normalizeCustomModelDefinition(
                    if (agent == AgentKind.OpenCode) {
                        it.copy(modelId = normalizeOpenCodeModelId(it.modelId))
                    } else {
                        it
                    },
                )
            }.getOrNull()
        }.distinctBy { it.modelId }.take(MAX_CUSTOM_MODELS)
        val managedModelIds = (
            customModels.map(CustomModelDefinition::modelId) + settings.managedModelIds
        ).asSequence()
            .map(String::trim)
            .filter(String::isNotBlank)
            .mapNotNull { id ->
                runCatching {
                    if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(id) else id
                }.getOrNull()
            }
            .distinct()
            .take(MAX_MANAGED_MODEL_IDS)
            .toList()
        return settings.copy(
            preferredModel = settings.preferredModel.trim().let { model ->
                if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(model) else model
            },
            preferredEffort = settings.preferredEffort.trim(),
            testModel = settings.testModel.trim().let { model ->
                if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(model) else model
            },
            customModels = customModels,
            hiddenModelIds = settings.hiddenModelIds.asSequence()
                .map(String::trim)
                .filter(String::isNotBlank)
                .map { id -> if (agent == AgentKind.OpenCode) normalizeOpenCodeModelId(id) else id }
                .distinct()
                .take(MAX_HIDDEN_MODEL_IDS)
                .toList(),
            managedModelIds = managedModelIds,
        )
    }

    private fun updateProfileModelCatalog(
        profileId: String,
        transform: (AgentModelSettings) -> AgentModelSettings,
    ) {
        val current = _state.value
        val key = sessionKey(profileId)
        val profile = current.profiles.firstOrNull { it.id == profileId } ?: return
        val previousSettings = profile.modelSettings(key.agent)
        val updatedSettings = normalizeAgentModelSettings(key.agent, transform(previousSettings))
        val updatedProfile = normalizeProfile(profile.withModelSettings(key.agent, updatedSettings))
        val fallbackModels = if (current.selectedProfileId == profileId) {
            current.models.filterNot(CodexModel::isCustom)
        } else {
            sessionSnapshots[key]?.models.orEmpty().filterNot(CodexModel::isCustom)
        }
        val remoteModels = remoteModelsByProfile[key] ?: fallbackModels
        val pendingRemovals = pendingManagedModelRemovals(updatedSettings)
        val catalog = buildModelCatalog(
            remoteModels = remoteModels,
            customModels = updatedSettings.customModels,
            hiddenModelIds = updatedSettings.hiddenModelIds + pendingRemovals,
            customReasoningEfforts = if (key.agent == AgentKind.OpenCode) {
                ::openCodeReasoningEfforts
            } else {
                { emptyList() }
            },
        )
        _state.update { latest ->
            val profiles = latest.profiles.map { candidate ->
                if (candidate.id == profileId) updatedProfile else candidate
            }
            if (latest.selectedProfileId == profileId) {
                val selectedIsAvailable = latest.selectedModel?.let { selected ->
                    catalog.any { model -> model.id == selected || model.model == selected }
                } == true
                val fallback = resolveModelSelection(
                    models = catalog,
                    preferredModel = updatedSettings.preferredModel,
                    preferredEffort = updatedSettings.preferredEffort,
                )
                latest.copy(
                    profiles = profiles,
                    models = catalog,
                    selectedModel = latest.selectedModel.takeIf { selectedIsAvailable } ?: fallback.model,
                    selectedEffort = latest.selectedEffort.takeIf { selectedIsAvailable } ?: fallback.effort,
                )
            } else {
                latest.copy(profiles = profiles)
            }
        }
        if (_state.value.selectedProfileId == profileId) {
            sessionSnapshots[key] = SessionSnapshot.capture(_state.value)
        } else {
            val snapshot = sessionSnapshots[key] ?: SessionSnapshot()
            sessionSnapshots[key] = snapshot.copy(models = catalog)
        }
        persistProfiles()
        if (key.agent == AgentKind.OpenCode && (
                previousSettings.customModels != updatedSettings.customModels ||
                    previousSettings.managedModelIds != updatedSettings.managedModelIds
            )
        ) {
            scheduleCustomModelSync(profileId, key.agent)
        }
    }

    private fun pendingManagedModelRemovals(settings: AgentModelSettings): List<String> {
        val currentIds = settings.customModels.mapTo(HashSet(), CustomModelDefinition::modelId)
        return settings.managedModelIds
            .asSequence()
            .filterNot { it in currentIds }
            .distinct()
            .toList()
    }

    /** Coalesces rapid picker edits and reconciles them on a single bridge request. */
    private fun scheduleCustomModelSync(
        profileId: String,
        agent: AgentKind,
        immediate: Boolean = false,
    ) {
        if (agent != AgentKind.OpenCode) return
        val key = AgentConnectionKey(profileId, agent)
        val revision = synchronized(customModelSyncJobs) {
            val next = (customModelSyncRevisions[key] ?: 0L) + 1L
            customModelSyncRevisions[key] = next
            next
        }
        synchronized(customModelSyncJobs) {
            customModelSyncJobs[key]?.cancel()
        }
        val job = viewModelScope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            try {
                if (!immediate) delay(MODEL_SYNC_DEBOUNCE_MS)
                syncCustomModelsNow(
                    profileId = profileId,
                    agent = agent,
                    expectedRevision = revision,
                    requireConnected = false,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                DiagnosticLogger.warn(
                    "Models",
                    "sync_failed profile=${profileRef(profileId)} agent=${agent.label} " +
                        "error=${error.message ?: error::class.simpleName}",
                )
            } finally {
                val currentJob = currentCoroutineContext()[Job]
                synchronized(customModelSyncJobs) {
                    if (customModelSyncJobs[key] === currentJob) {
                        customModelSyncJobs.remove(key)
                    }
                }
            }
        }
        synchronized(customModelSyncJobs) {
            customModelSyncJobs[key] = job
        }
        job.start()
    }

    private suspend fun syncCustomModelsNow(
        profileId: String,
        agent: AgentKind,
        expectedRevision: Long? = null,
        requireConnected: Boolean,
    ) {
        if (agent != AgentKind.OpenCode) return
        val key = AgentConnectionKey(profileId, agent)
        val mutex = synchronized(customModelSyncMutexes) {
            customModelSyncMutexes.getOrPut(key) { Mutex() }
        }
        mutex.withLock {
            val profile = _state.value.profiles.firstOrNull { it.id == profileId }
                ?: return@withLock
            val settings = profile.modelSettings(agent)
            val removals = pendingManagedModelRemovals(settings)
            if (settings.customModels.isEmpty() && removals.isEmpty()) return@withLock
            val client = connections.client(profileId, agent)?.takeIf { it.isConnected() }
                ?: run {
                    if (requireConnected) error("OpenCode 连接已断开，无法同步模型")
                    return@withLock
                }
            val generation = client.currentGeneration()
                ?: run {
                    if (requireConnected) error("OpenCode 连接尚未就绪，无法同步模型")
                    return@withLock
                }
            DiagnosticLogger.info(
                "Models",
                "sync_start profile=${profileRef(profileId)} agent=${agent.label} " +
                    "models=${settings.customModels.size} removals=${removals.size}",
            )
            client.syncCustomModels(profile, settings.customModels, removals)
            if (!client.isGenerationActive(generation)) return@withLock
            val revisionIsCurrent = expectedRevision == null || synchronized(customModelSyncJobs) {
                customModelSyncRevisions[key] == expectedRevision
            }
            if (!revisionIsCurrent) return@withLock
            clearSyncedModelTombstones(profileId, agent, removals)
            DiagnosticLogger.info(
                "Models",
                "sync_success profile=${profileRef(profileId)} agent=${agent.label}",
            )
        }
    }

    private fun clearSyncedModelTombstones(
        profileId: String,
        agent: AgentKind,
        syncedIds: List<String>,
    ) {
        if (syncedIds.isEmpty()) return
        val currentProfile = _state.value.profiles.firstOrNull { it.id == profileId } ?: return
        val settings = currentProfile.modelSettings(agent)
        val key = AgentConnectionKey(profileId, agent)
        val syncedSet = syncedIds.toHashSet()
        remoteModelsByProfile[key] = remoteModelsByProfile[key].orEmpty().filterNot { model ->
            model.id in syncedSet || model.model in syncedSet
        }
        sessionSnapshots[key]?.let { snapshot ->
            sessionSnapshots[key] = snapshot.copy(
                models = snapshot.models.filterNot { model ->
                    model.id in syncedSet || model.model in syncedSet
                },
            )
        }
        val currentIds = settings.customModels.mapTo(HashSet(), CustomModelDefinition::modelId)
        val updatedManagedIds = settings.managedModelIds.filterNot { id ->
            id in syncedIds && id !in currentIds
        }
        if (updatedManagedIds == settings.managedModelIds) return
        val updatedProfile = normalizeProfile(
            currentProfile.withModelSettings(
                agent,
                settings.copy(managedModelIds = updatedManagedIds),
            ),
        )
        _state.update { current ->
            current.copy(
                profiles = current.profiles.map { profile ->
                    if (profile.id == profileId) updatedProfile else profile
                },
            )
        }
        persistProfiles()
    }

    private fun cancelCustomModelSync(profileId: String) {
        val keys = synchronized(customModelSyncJobs) {
            customModelSyncJobs.keys.filter { it.profileId == profileId }
        }
        synchronized(customModelSyncJobs) {
            keys.forEach { key ->
                customModelSyncJobs.remove(key)?.cancel()
                customModelSyncRevisions.remove(key)
            }
        }
    }

    private fun updateProfileAgentDefaults(
        profileId: String,
        agent: AgentKind,
        testModel: String,
        defaultModel: String,
        defaultEffort: String,
    ) {
        _state.update { current ->
            current.copy(
                profiles = current.profiles.map { profile ->
                    if (profile.id == profileId) {
                        profile.withModelSettings(
                            agent,
                            profile.modelSettings(agent).copy(
                                preferredModel = defaultModel,
                                preferredEffort = defaultEffort,
                                testModel = testModel,
                            ),
                        )
                    } else {
                        profile
                    }
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
        threadModelPreferences[threadStorageKey(sessionKey(profileId), threadId)] =
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
        val key = sessionKey(profileId)
        val stored = threadModelPreferences[threadStorageKey(key, threadId)]
            ?: threadModelPreferences[threadStorageKey(profileId, threadId)]
                ?.takeIf { key.agent == AgentKind.Codex }
        val profile = _state.value.profiles.firstOrNull { it.id == profileId }
        val settings = profile?.modelSettings(key.agent)
        return resolveThreadModelSelection(
            models = models,
            preference = stored,
            fallbackModel = settings?.preferredModel.orEmpty(),
            fallbackEffort = settings?.preferredEffort.orEmpty(),
        )
    }

    private fun rememberThreadModelPreference(
        profileId: String,
        threadId: String,
        selection: ResolvedModelSelection,
    ) {
        val model = selection.model ?: return
        threadModelPreferences[threadStorageKey(sessionKey(profileId), threadId)] =
            ThreadModelPreference(model, selection.effort.orEmpty())
        trimThreadModelPreferences()
        persistProfiles()
    }

    private fun composerDraft(profileId: String, threadId: String): String {
        val key = sessionKey(profileId)
        return composerDrafts[composerDraftKey(key, threadId)]
            ?: composerDrafts[composerDraftKey(profileId, threadId)]
                ?.takeIf { key.agent == AgentKind.Codex }
            ?: ""
    }

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
        activeTurnId: String? = null,
        activeTurnStartedAtMillis: Long? = null,
    ): TurnTiming? {
        if (threadId.isBlank()) return null
        val currentTiming = current?.takeIf { it.threadId == threadId }
        if (running) {
            return recoverRunningTurnTiming(
                threadId = threadId,
                activeTurnId = activeTurnId,
                activeTurnStartedAtMillis = activeTurnStartedAtMillis,
                current = currentTiming,
            )
        }
        return currentTiming?.takeIf { it.completedAtMillis != null }
            ?: completedTurnTimings[threadStorageKey(sessionKey(profileId), threadId)]
            ?: completedTurnTimings[threadStorageKey(profileId, threadId)]
                ?.takeIf { activeAgentFor(profileId) == AgentKind.Codex }
                ?.takeIf { it.threadId == threadId && it.completedAtMillis != null }
    }

    private fun syncCompletedTurnTiming(
        key: AgentConnectionKey,
        method: String,
        params: kotlinx.serialization.json.JsonObject,
    ) {
        if (method !in TURN_TIMING_EVENT_METHODS) return
        val snapshot = sessionSnapshots[key]
        val timing = snapshot?.turnTiming
        val threadId = params.string("threadId").ifBlank { timing?.threadId.orEmpty() }
        if (threadId.isBlank()) return
        val storageKey = threadStorageKey(key, threadId)
        val completed = timing?.takeIf { it.threadId == threadId && it.completedAtMillis != null }
        val changed = when {
            completed != null && completedTurnTimings[storageKey] != completed -> {
                completedTurnTimings[storageKey] = completed
                trimCompletedTurnTimings()
                true
            }

            method == "turn/started" ||
                (method == "thread/status/changed" &&
                    snapshot?.activeThread?.id == threadId && snapshot.running) -> {
                completedTurnTimings.remove(storageKey) != null
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
        rememberContextUsage(sessionKey(profileId), threadId, usage)
    }

    private fun rememberContextUsage(key: AgentConnectionKey, threadId: String, usage: TokenUsage?) {
        usage?.let { contextUsageFallbacks.remember(agentScopeId(key), threadId, it) }
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

    private fun showConnectionError(
        error: Throwable,
        profileId: String? = _state.value.selectedProfileId,
        agent: AgentKind? = profileId?.let(::activeAgentFor),
    ) {
        profileId ?: return
        val selectedAgent = agent ?: activeAgentFor(profileId)
        val key = AgentConnectionKey(profileId, selectedAgent)
        val message = presentCodexDiagnostic(error.message.orEmpty(), ConnectionPhase.Failed)
            .ifBlank { "连接失败" }
        DiagnosticLogger.error(
            "Connection",
            "connect_failed profile=${profileRef(profileId)} agent=${selectedAgent.name}",
            error,
        )
        val failed = ConnectionState(ConnectionPhase.Failed, message)
        _state.update { current ->
            current.copy(
                agentConnectionStates = current.agentConnectionStates + (key to failed),
                connection = current.connectionStates[profileId] ?: current.connection,
            )
        }
        applySessionState(profileId, selectedAgent) {
            it.copy(
                connection = it.connectionStates[profileId] ?: it.connection,
                loading = false,
                error = message,
            )
        }
    }

    private fun showHostConnectionError(error: Throwable, profileId: String) {
        val message = presentCodexDiagnostic(error.message.orEmpty(), ConnectionPhase.Failed)
            .ifBlank { "SSH 连接失败" }
        DiagnosticLogger.error("Connection", "ssh_connect_failed profile=${profileRef(profileId)}", error)
        val failed = ConnectionState(ConnectionPhase.Failed, message)
        updateProfileConnection(profileId, failed)
        if (isActiveProfile(profileId)) {
            _state.update { it.copy(connection = failed, loading = false, error = message) }
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

    private fun isPinnedVersion(userAgent: String, expectedVersion: String): Boolean {
        val version = Regex.escape(expectedVersion)
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
        private const val MODEL_SYNC_DEBOUNCE_MS = 180L
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

private fun remoteUploadFileName(context: Context, uri: Uri): String {
    var name = uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "upload"
    context.contentResolver.query(
        uri,
        arrayOf(OpenableColumns.DISPLAY_NAME),
        null,
        null,
        null,
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }
                ?.let { index -> cursor.getString(index)?.takeIf { it.isNotBlank() }?.let { name = it } }
        }
    }
    return name
}

private fun profileRef(value: String): String = value.take(8).ifBlank { "unknown" }

private suspend fun <T> timedConnectionStage(
    profileId: String,
    agent: AgentKind?,
    stage: String,
    block: suspend () -> T,
): T {
    val startedNanos = System.nanoTime()
    return try {
        block().also {
            logConnectionTiming(profileId, agent, stage, startedNanos)
        }
    } catch (error: Throwable) {
        logConnectionTiming(
            profileId = profileId,
            agent = agent,
            stage = stage,
            startedNanos = startedNanos,
            status = "failed",
            detail = error.message.orEmpty().replace(Regex("\\s+"), " ").take(160),
        )
        throw error
    }
}

private fun logConnectionTiming(
    profileId: String,
    agent: AgentKind?,
    stage: String,
    startedNanos: Long,
    status: String = "success",
    detail: String = "",
) {
    recordConnectionTiming(
        profileId = profileId,
        agent = agent?.name ?: "Host",
        stage = stage,
        startedNanos = startedNanos,
        status = status,
        detail = detail,
    )
}

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

private data class InitialWorkspaceResult(
    val listing: RemoteDirectoryListing?,
    val preferredError: String?,
)

private data class ClientOperation(
    val ticket: ProfileOperationTracker.Ticket,
    val key: AgentConnectionKey,
    val client: RemoteAgentClient,
    val generation: Long,
)

private data class HostOperation(
    val ticket: ProfileOperationTracker.Ticket,
    val profileId: String,
    val client: RemoteServerClient,
    val generation: Long,
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

/**
 * New threads must honor the remote user's configured defaults even when a custom provider does
 * not advertise that model in `model/list`. Existing thread preferences still use the stricter
 * [resolveModelSelection] fallback so a removed per-thread model cannot trap a conversation.
 */
internal fun resolveNewThreadModelSelection(
    models: List<top.asdb.codexremote.data.CodexModel>,
    configuredModel: String,
    configuredEffort: String,
): ResolvedModelSelection {
    val fallback = resolveModelSelection(models, configuredModel, configuredEffort)
    val explicitModel = configuredModel.trim().takeIf { it.isNotEmpty() }
    val selected = explicitModel?.let { model -> models.firstOrNull { it.model == model } }
    val explicitEffort = configuredEffort.trim().takeIf { effort ->
        effort.isNotEmpty() && (selected == null || selected.efforts.isEmpty() || effort in selected.efforts)
    }
    return ResolvedModelSelection(
        model = explicitModel ?: fallback.model,
        effort = explicitEffort ?: fallback.effort,
    )
}

/** Merges provider-advertised models with local picker preferences for one server profile. */
internal fun buildModelCatalog(
    remoteModels: List<CodexModel>,
    customModels: List<CustomModelDefinition>,
    hiddenModelIds: Collection<String>,
    customReasoningEfforts: (String) -> List<String> = { emptyList() },
): List<CodexModel> {
    val hidden = hiddenModelIds.asSequence().map(String::trim).filter(String::isNotBlank).toSet()
    val models = remoteModels.filterNot { remote ->
        remote.id in hidden || remote.model in hidden
    }.distinctBy { it.model.ifBlank { it.id } }.toMutableList()
    customModels.forEach { custom ->
        val modelId = custom.modelId.trim()
        if (modelId.isBlank()) return@forEach
        val inferredEfforts = customReasoningEfforts(modelId)
        val index = models.indexOfFirst { it.model == modelId || it.id == modelId }
        if (index >= 0) {
            val remote = models[index]
            models[index] = remote.copy(
                model = modelId,
                displayName = custom.displayName.ifBlank { remote.displayName },
                contextWindowTokens = custom.contextWindowTokens.takeIf { it > 0L }
                    ?: remote.contextWindowTokens,
                maxOutputTokens = custom.maxOutputTokens.takeIf { it > 0L } ?: remote.maxOutputTokens,
                efforts = remote.efforts.ifEmpty { inferredEfforts },
                isCustom = true,
            )
        } else {
            models += CodexModel(
                id = modelId,
                model = modelId,
                displayName = custom.displayName.ifBlank { modelId },
                description = "自定义模型",
                isDefault = false,
                defaultEffort = "",
                efforts = inferredEfforts,
                contextWindowTokens = custom.contextWindowTokens,
                maxOutputTokens = custom.maxOutputTokens,
                isCustom = true,
            )
        }
    }
    return models
}

internal fun normalizeCustomModelDefinition(value: CustomModelDefinition): CustomModelDefinition {
    val modelId = value.modelId.trim()
    require(modelId.isNotBlank()) { "请输入模型 ID" }
    require(modelId.length <= MAX_CUSTOM_MODEL_ID_CHARS &&
        modelId.matches(Regex("[A-Za-z0-9._:/@+\\-]+"))
    ) {
        "模型 ID 只能包含字母、数字及 . _ - / : @ +"
    }
    val displayName = value.displayName.trim()
    require(displayName.length <= MAX_CUSTOM_MODEL_NAME_CHARS && displayName.none { it.isISOControl() }) {
        "显示名称不能超过 $MAX_CUSTOM_MODEL_NAME_CHARS 个字符或包含控制字符"
    }
    require(value.contextWindowTokens in 0L..MAX_MODEL_TOKEN_LIMIT) {
        "上下文长度必须在 0 到 $MAX_MODEL_TOKEN_LIMIT 之间"
    }
    require(value.maxOutputTokens in 0L..MAX_MODEL_TOKEN_LIMIT) {
        "最大输出长度必须在 0 到 $MAX_MODEL_TOKEN_LIMIT 之间"
    }
    return CustomModelDefinition(
        modelId = modelId,
        displayName = displayName,
        contextWindowTokens = value.contextWindowTokens,
        maxOutputTokens = value.maxOutputTokens,
    )
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

private fun composerDraftKey(key: AgentConnectionKey, threadId: String): String =
    "${key.profileId}\u0000${key.agent.name}\u0000$threadId"

private fun threadStorageKey(profileId: String, threadId: String): String =
    "$profileId\u0000$threadId"

private fun threadStorageKey(key: AgentConnectionKey, threadId: String): String =
    "${key.profileId}\u0000${key.agent.name}\u0000$threadId"

private fun agentScopeId(key: AgentConnectionKey): String =
    "${key.profileId}\u0000${key.agent.name}"

internal fun recoverRunningTurnTiming(
    threadId: String,
    activeTurnId: String?,
    activeTurnStartedAtMillis: Long?,
    current: TurnTiming?,
): TurnTiming? {
    if (threadId.isBlank()) return null
    val currentTiming = current?.takeIf { it.threadId == threadId && it.completedAtMillis == null }
    val startedAtMillis = normalizeEpochMillis(activeTurnStartedAtMillis ?: 0L)
        ?: normalizeEpochMillis(currentTiming?.startedAtMillis ?: 0L)
        ?: return null
    return TurnTiming(
        threadId = threadId,
        turnId = activeTurnId?.takeIf { it.isNotBlank() } ?: currentTiming?.turnId,
        startedAtMillis = startedAtMillis,
    )
}

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
private const val REMOTE_CONNECTION_TIMING_PREFIX = "__CODEX_REMOTE_TIMING "
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
private const val MAX_CUSTOM_MODELS = 100
private const val MAX_HIDDEN_MODEL_IDS = 500
private const val MAX_MANAGED_MODEL_IDS = 512
private const val MAX_CUSTOM_MODEL_ID_CHARS = 200
private const val MAX_CUSTOM_MODEL_NAME_CHARS = 120
private const val MAX_MODEL_TOKEN_LIMIT = 10_000_000L
