package top.asdb.codexremote.agent

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import top.asdb.codexremote.codex.CodexAppServerClient
import top.asdb.codexremote.data.AgentConnectionKey
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.ssh.RemoteInstallProgress

data class ProfiledAgentNotification(
    val key: AgentConnectionKey,
    val value: AgentNotification,
) {
    val profileId: String get() = key.profileId
    val agent: AgentKind get() = key.agent
}

data class ProfiledAgentApproval(
    val key: AgentConnectionKey,
    val value: AgentApproval,
) {
    val profileId: String get() = key.profileId
    val agent: AgentKind get() = key.agent
}

data class ProfiledAgentConnectionEvent(
    val key: AgentConnectionKey,
    val value: AgentConnectionEvent,
) {
    val profileId: String get() = key.profileId
    val agent: AgentKind get() = key.agent
}

/** Registry boundary used to add a new Agent adapter without changing connection management. */
class AgentClientRegistry(
    factories: Map<AgentKind, (CoroutineScope) -> RemoteAgentClient>,
) {
    private val factories = factories.toMap()

    fun create(kind: AgentKind, scope: CoroutineScope): RemoteAgentClient =
        factories[kind]?.invoke(scope)
            ?: error("尚未注册 ${kind.label} 客户端适配器")

    companion object {
        fun default(openCodeBridgeSource: () -> String = { "" }): AgentClientRegistry = AgentClientRegistry(
            mapOf(
                AgentKind.Codex to { scope -> CodexAppServerClient(scope) },
                AgentKind.OpenCode to { scope -> OpenCodeAgentClient(scope, bridgeSource = openCodeBridgeSource) },
            ),
        )
    }
}

/**
 * Owns one independent client for each (server profile, agent) lane.
 *
 * Profile-level state is retained for existing server cards, while [agentStates] exposes the
 * exact state needed by the dual-agent switcher.
 */
class AgentConnectionManager(
    private val parentScope: CoroutineScope,
    private val registry: AgentClientRegistry = AgentClientRegistry.default(),
) {
    private class Entry(
        var profile: ServerProfile,
        val key: AgentConnectionKey,
        val scope: CoroutineScope,
        val client: RemoteAgentClient,
    ) {
        val connectMutex = Mutex()
        var version: String? = null
    }

    private val lock = Any()
    private val entries = LinkedHashMap<AgentConnectionKey, Entry>()
    private val activeAgents = LinkedHashMap<String, AgentKind>()
    private val _agentStates = MutableStateFlow<Map<AgentConnectionKey, ConnectionState>>(emptyMap())
    private val _states = MutableStateFlow<Map<String, ConnectionState>>(emptyMap())
    private val _activeKey = MutableStateFlow<AgentConnectionKey?>(null)
    private val _activeProfileId = MutableStateFlow<String?>(null)
    private val _notifications = MutableSharedFlow<ProfiledAgentNotification>()
    private val _approvals = MutableSharedFlow<ProfiledAgentApproval>()
    private val _diagnostics = MutableSharedFlow<ProfiledAgentConnectionEvent>()
    private val _closed = MutableSharedFlow<ProfiledAgentConnectionEvent>()

    val agentStates: StateFlow<Map<AgentConnectionKey, ConnectionState>> = _agentStates.asStateFlow()
    val states: StateFlow<Map<String, ConnectionState>> = _states.asStateFlow()
    val activeKey: StateFlow<AgentConnectionKey?> = _activeKey.asStateFlow()
    val activeProfileId: StateFlow<String?> = _activeProfileId.asStateFlow()
    val notifications: SharedFlow<ProfiledAgentNotification> = _notifications.asSharedFlow()
    val approvals: SharedFlow<ProfiledAgentApproval> = _approvals.asSharedFlow()
    val diagnostics: SharedFlow<ProfiledAgentConnectionEvent> = _diagnostics.asSharedFlow()
    val closed: SharedFlow<ProfiledAgentConnectionEvent> = _closed.asSharedFlow()

    fun registerProfile(profile: ServerProfile) {
        profile.agentMode.agents.forEach { register(profile, it) }
        val disabled = AgentKind.entries.filterNot(profile.agentMode::contains)
        disabled.forEach { removeEntryNow(AgentConnectionKey(profile.id, it)) }
        val active = profile.activeAgent.takeIf(profile.agentMode::contains) ?: profile.agentMode.agents.first()
        activeAgents[profile.id] = active
    }

    fun register(
        profile: ServerProfile,
        agent: AgentKind = profile.activeAgent.takeIf(profile.agentMode::contains)
            ?: profile.agentMode.agents.first(),
    ): RemoteAgentClient = ensureEntry(profile, agent).client

    fun select(profile: ServerProfile, agent: AgentKind = profile.activeAgent): RemoteAgentClient {
        val selected = agent.takeIf(profile.agentMode::contains) ?: profile.agentMode.agents.first()
        val client = ensureEntry(profile, selected).client
        activeAgents[profile.id] = selected
        setActiveKey(AgentConnectionKey(profile.id, selected))
        return client
    }

    fun select(profileId: String, agent: AgentKind? = null): RemoteAgentClient? = synchronized(lock) {
        val selected = agent ?: activeAgents[profileId]
            ?: entries.keys.firstOrNull { it.profileId == profileId }?.agent
            ?: return@synchronized null
        val key = AgentConnectionKey(profileId, selected)
        val client = entries[key]?.client ?: return@synchronized null
        activeAgents[profileId] = selected
        setActiveKey(key)
        client
    }

    fun activeAgent(profileId: String): AgentKind? = synchronized(lock) {
        activeAgents[profileId] ?: entries.keys.firstOrNull { it.profileId == profileId }?.agent
    }

    fun client(profileId: String, agent: AgentKind? = null): RemoteAgentClient? = synchronized(lock) {
        val selected = agent ?: activeAgents[profileId] ?: return@synchronized null
        entries[AgentConnectionKey(profileId, selected)]?.client
    }

    fun profile(profileId: String, agent: AgentKind? = null): ServerProfile? = synchronized(lock) {
        val selected = agent ?: activeAgents[profileId] ?: return@synchronized null
        entries[AgentConnectionKey(profileId, selected)]?.profile
    }

    fun capabilities(profileId: String, agent: AgentKind? = null) = client(profileId, agent)?.capabilities

    fun connectedProfileIds(): List<String> = states.value
        .filterValues { it.phase == ConnectionPhase.Connected }
        .keys
        .toList()

    suspend fun probeFingerprint(profile: ServerProfile): String =
        ensureEntry(profile, profile.agentMode.agents.first()).client.probeFingerprint(profile)

    suspend fun inspectRuntime(profile: ServerProfile, agent: AgentKind): AgentRuntimeInspection =
        ensureEntry(profile, agent).client.inspectRuntime(profile)

    suspend fun installRuntime(
        profile: ServerProfile,
        agent: AgentKind,
        onProgress: (RemoteInstallProgress) -> Unit,
    ) = ensureEntry(profile, agent).client.installRuntime(profile, onProgress)

    suspend fun uninstallRuntime(profile: ServerProfile, agent: AgentKind) {
        val entry = ensureEntry(profile, agent)
        entry.connectMutex.withLock {
            updateState(entry, ConnectionState(ConnectionPhase.Installing, "正在卸载 ${agent.label}"))
            try {
                entry.client.uninstallRuntime(profile)
                entry.client.disconnect()
                entry.version = null
                updateState(entry, ConnectionState())
            } catch (error: Throwable) {
                entry.version = null
                updateState(entry, ConnectionState(ConnectionPhase.Failed, error.message ?: "卸载失败"))
                throw error
            }
        }
    }

    suspend fun connect(profile: ServerProfile, agent: AgentKind? = null): String {
        val selected = agent ?: activeAgents[profile.id]
            ?: profile.activeAgent.takeIf(profile.agentMode::contains)
            ?: profile.agentMode.agents.first()
        val entry = ensureEntry(profile, selected)
        return entry.connectMutex.withLock {
            if (entry.client.isConnected()) {
                updateState(entry, ConnectionState(ConnectionPhase.Connected, "已连接", entry.version))
                return@withLock entry.version.orEmpty()
            }
            updateState(entry, ConnectionState(ConnectionPhase.Connecting, "正在连接 ${selected.label}"))
            try {
                val version = entry.client.connect(profile)
                check(isCurrentEntry(entry.key, entry)) { "服务器连接配置已更新" }
                entry.version = version
                updateState(entry, ConnectionState(ConnectionPhase.Connected, "已连接", version))
                version
            } catch (error: CancellationException) {
                updateState(entry, ConnectionState())
                throw error
            } catch (error: Throwable) {
                updateState(entry, ConnectionState(ConnectionPhase.Failed, error.message ?: "连接失败"))
                throw error
            }
        }
    }

    suspend fun disconnect(
        profileId: String,
        agent: AgentKind? = null,
        expectedClient: RemoteAgentClient? = null,
    ) {
        val selected = agent ?: activeAgent(profileId) ?: return
        val key = AgentConnectionKey(profileId, selected)
        val entry = synchronized(lock) { entries[key] } ?: return
        if (expectedClient != null && entry.client !== expectedClient) return
        entry.connectMutex.withLock {
            if (expectedClient != null && !isCurrentEntry(key, entry)) return@withLock
            entry.client.disconnect()
            entry.version = null
            updateState(entry, ConnectionState())
        }
    }

    suspend fun disconnectProfile(profileId: String) {
        val agents = synchronized(lock) { entries.keys.filter { it.profileId == profileId }.map { it.agent } }
        agents.forEach { disconnect(profileId, it) }
    }

    suspend fun remove(profileId: String) {
        val removed = synchronized(lock) {
            entries.keys.filter { it.profileId == profileId }.mapNotNull(entries::remove).also {
                activeAgents.remove(profileId)
                _agentStates.update { current -> current.filterKeys { it.profileId != profileId } }
                _states.update { it - profileId }
                if (_activeKey.value?.profileId == profileId) setActiveKey(entries.keys.firstOrNull())
            }
        }
        removed.forEach {
            it.client.close()
            it.scope.cancel()
        }
    }

    fun close() {
        val values = synchronized(lock) {
            val result = entries.values.toList()
            entries.clear()
            activeAgents.clear()
            _agentStates.value = emptyMap()
            _states.value = emptyMap()
            setActiveKey(null)
            result
        }
        values.forEach {
            it.client.close()
            it.scope.cancel()
        }
    }

    private fun ensureEntry(profile: ServerProfile, agent: AgentKind): Entry = synchronized(lock) {
        val key = AgentConnectionKey(profile.id, agent)
        val existing = entries[key]
        if (existing != null && connectionIdentity(existing.profile, agent) == connectionIdentity(profile, agent)) {
            existing.profile = profile
            return@synchronized existing
        }
        if (existing != null) {
            existing.client.close()
            existing.scope.cancel()
        }
        val childJob = SupervisorJob(parentScope.coroutineContext[Job])
        val childScope = CoroutineScope(parentScope.coroutineContext + childJob + Dispatchers.IO)
        val entry = Entry(profile, key, childScope, registry.create(agent, childScope))
        entries[key] = entry
        activeAgents.putIfAbsent(profile.id, profile.activeAgent.takeIf(profile.agentMode::contains) ?: agent)
        _agentStates.update { current -> current + (key to ConnectionState()) }
        updateAggregateState(profile.id)
        attachEventForwarders(entry)
        entry
    }

    private fun removeEntryNow(key: AgentConnectionKey) {
        val entry = synchronized(lock) { entries.remove(key) } ?: return
        entry.client.close()
        entry.scope.cancel()
        _agentStates.update { it - key }
        updateAggregateState(key.profileId)
    }

    private fun attachEventForwarders(entry: Entry) {
        entry.scope.launch {
            entry.client.notifications.collect {
                if (isCurrentEntry(entry.key, entry)) _notifications.emit(ProfiledAgentNotification(entry.key, it))
            }
        }
        entry.scope.launch {
            entry.client.approvals.collect {
                if (isCurrentEntry(entry.key, entry)) _approvals.emit(ProfiledAgentApproval(entry.key, it))
            }
        }
        entry.scope.launch {
            entry.client.diagnostics.collect {
                if (isCurrentEntry(entry.key, entry)) _diagnostics.emit(ProfiledAgentConnectionEvent(entry.key, it))
            }
        }
        entry.scope.launch {
            entry.client.closed.collect { event ->
                if (!isCurrentEntry(entry.key, entry)) return@collect
                updateState(entry, ConnectionState(ConnectionPhase.Failed, event.message))
                _closed.emit(ProfiledAgentConnectionEvent(entry.key, event))
            }
        }
    }

    private fun updateState(entry: Entry, state: ConnectionState) {
        if (!isCurrentEntry(entry.key, entry)) return
        _agentStates.update { current -> current + (entry.key to state) }
        updateAggregateState(entry.key.profileId)
    }

    private fun updateAggregateState(profileId: String) {
        val profileEntries = synchronized(lock) {
            entries.filterKeys { it.profileId == profileId }.values.toList()
        }
        if (profileEntries.isEmpty()) {
            _states.update { it - profileId }
            return
        }
        val laneStates = _agentStates.value.filterKeys { it.profileId == profileId }
        val state = aggregateConnectionState(profileEntries, laneStates)
        _states.update { it + (profileId to state) }
    }

    private fun aggregateConnectionState(
        profileEntries: List<Entry>,
        laneStates: Map<AgentConnectionKey, ConnectionState>,
    ): ConnectionState = aggregateAgentConnectionStates(
        profileEntries.map { laneStates[it.key] ?: ConnectionState() },
    )

    private fun isCurrentEntry(key: AgentConnectionKey, entry: Entry): Boolean =
        synchronized(lock) { entries[key] === entry }

    private fun setActiveKey(key: AgentConnectionKey?) {
        _activeKey.value = key
        _activeProfileId.value = key?.profileId
    }

    private data class ConnectionIdentity(
        val agent: AgentKind,
        val host: String,
        val port: Int,
        val username: String,
        val authMode: top.asdb.codexremote.data.AuthMode,
        val password: String,
        val privateKeyPem: String,
        val privateKeyPassphrase: String,
        val hostFingerprint: String,
        val remoteCommand: String,
    )

    private fun connectionIdentity(profile: ServerProfile, agent: AgentKind) = ConnectionIdentity(
        agent = agent,
        host = profile.host,
        port = profile.port,
        username = profile.username,
        authMode = profile.authMode,
        password = profile.password,
        privateKeyPem = profile.privateKeyPem,
        privateKeyPassphrase = profile.privateKeyPassphrase,
        hostFingerprint = profile.hostFingerprint,
        remoteCommand = if (agent == AgentKind.Codex) profile.remoteCommand else "managed-opencode",
    )
}

internal fun aggregateAgentConnectionStates(states: List<ConnectionState>): ConnectionState {
    if (states.isEmpty()) return ConnectionState()
    val pending = states.firstOrNull { it.phase == ConnectionPhase.Installing }
        ?: states.firstOrNull { it.phase == ConnectionPhase.Connecting }
        ?: states.firstOrNull { it.phase == ConnectionPhase.Probing }
    if (pending != null) return pending
    if (states.all { it.phase == ConnectionPhase.Connected }) {
        val versions = states.mapNotNull(ConnectionState::cliVersion).distinct().joinToString(" / ")
        return ConnectionState(ConnectionPhase.Connected, "已连接", versions.ifBlank { null })
    }
    if (states.any { it.phase == ConnectionPhase.Connected }) {
        return ConnectionState(ConnectionPhase.Failed, "部分 Agent 连接失败")
    }
    return states.firstOrNull { it.phase == ConnectionPhase.Failed } ?: ConnectionState()
}
