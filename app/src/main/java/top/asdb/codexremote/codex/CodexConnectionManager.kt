package top.asdb.codexremote.codex

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
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
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.ssh.RemoteEnvironment
import top.asdb.codexremote.ssh.RemoteInstallProgress

/** A notification tagged with the server profile that produced it. */
data class ProfiledCodexNotification(
    val profileId: String,
    val value: CodexNotification,
)

data class ProfiledCodexApproval(
    val profileId: String,
    val value: CodexApproval,
)

data class ProfiledCodexConnectionEvent(
    val profileId: String,
    val value: CodexConnectionEvent,
)

/**
 * Keeps one independent SSH/Codex client per saved server profile.
 *
 * The old application-level client replaces its SSH transport when another server is selected.
 * This manager is intentionally additive: existing callers can continue using a client directly,
 * while new multi-server screens use [client], [connect], and [select] without disconnecting other
 * profiles. Each entry owns its own coroutine scope and thread cache through its client instance.
 */
class CodexConnectionManager(
    private val parentScope: CoroutineScope,
    private val clientFactory: (CoroutineScope) -> CodexAppServerClient = { scope ->
        CodexAppServerClient(scope)
    },
) {
    private class Entry(
        var profile: ServerProfile,
        val scope: CoroutineScope,
        val client: CodexAppServerClient,
    ) {
        val connectMutex = Mutex()
        var cliVersion: String? = null
    }

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private val _states = MutableStateFlow<Map<String, ConnectionState>>(emptyMap())
    private val _activeProfileId = MutableStateFlow<String?>(null)
    private val _notifications = MutableSharedFlow<ProfiledCodexNotification>()
    private val _approvals = MutableSharedFlow<ProfiledCodexApproval>()
    private val _diagnostics = MutableSharedFlow<ProfiledCodexConnectionEvent>()
    private val _closed = MutableSharedFlow<ProfiledCodexConnectionEvent>()

    val states: StateFlow<Map<String, ConnectionState>> = _states.asStateFlow()
    val activeProfileId: StateFlow<String?> = _activeProfileId.asStateFlow()
    val notifications: SharedFlow<ProfiledCodexNotification> = _notifications.asSharedFlow()
    val approvals: SharedFlow<ProfiledCodexApproval> = _approvals.asSharedFlow()
    val diagnostics: SharedFlow<ProfiledCodexConnectionEvent> = _diagnostics.asSharedFlow()
    val closed: SharedFlow<ProfiledCodexConnectionEvent> = _closed.asSharedFlow()

    /** Register a profile and return its stable client. This does not open a network connection. */
    fun register(profile: ServerProfile): CodexAppServerClient = ensureEntry(profile).client

    /** Select a profile for presentation without touching any other profile's connection. */
    fun select(profile: ServerProfile): CodexAppServerClient {
        val client = ensureEntry(profile).client
        _activeProfileId.value = profile.id
        return client
    }

    fun select(profileId: String): CodexAppServerClient? = synchronized(lock) {
        if (!entries.containsKey(profileId)) return@synchronized null
        _activeProfileId.value = profileId
        entries[profileId]?.client
    }

    fun client(profileId: String): CodexAppServerClient? = synchronized(lock) { entries[profileId]?.client }

    fun profile(profileId: String): ServerProfile? = synchronized(lock) { entries[profileId]?.profile }

    fun connectedProfileIds(): List<String> = states.value
        .filterValues { it.phase == ConnectionPhase.Connected }
        .keys
        .toList()

    suspend fun probeFingerprint(profile: ServerProfile): String = ensureEntry(profile).client.probeFingerprint(profile)

    suspend fun inspectRemote(profile: ServerProfile): RemoteEnvironment = ensureEntry(profile).client.inspectRemote(profile)

    suspend fun installRemote(
        profile: ServerProfile,
        onProgress: (String) -> Unit,
    ) = ensureEntry(profile).client.installRemote(profile, onProgress)

    suspend fun installRemoteDetailed(
        profile: ServerProfile,
        onProgress: (RemoteInstallProgress) -> Unit,
    ) = ensureEntry(profile).client.installRemoteDetailed(profile, onProgress)

    suspend fun connect(profile: ServerProfile): String {
        val entry = ensureEntry(profile)
        return entry.connectMutex.withLock {
            if (entry.client.isConnected()) {
                updateState(
                    entry,
                    ConnectionState(ConnectionPhase.Connected, "已连接", entry.cliVersion),
                )
                return@withLock entry.cliVersion.orEmpty()
            }
            updateState(entry, ConnectionState(ConnectionPhase.Connecting, "正在连接"))
            try {
                val version = entry.client.connect(profile)
                check(isCurrentEntry(profile.id, entry)) { "服务器连接配置已更新" }
                entry.cliVersion = version
                updateState(
                    entry,
                    ConnectionState(ConnectionPhase.Connected, "已连接", version),
                )
                version
            } catch (error: CancellationException) {
                updateState(entry, ConnectionState())
                throw error
            } catch (error: Throwable) {
                updateState(
                    entry,
                    ConnectionState(ConnectionPhase.Failed, error.message ?: "连接失败"),
                )
                throw error
            }
        }
    }

    suspend fun disconnect(profileId: String, expectedClient: CodexAppServerClient? = null) {
        val entry = synchronized(lock) { entries[profileId] } ?: return
        if (expectedClient != null && entry.client !== expectedClient) return
        entry.connectMutex.withLock {
            if (expectedClient != null && !isCurrentEntry(profileId, entry)) return@withLock
            if (expectedClient != null && entry.client !== expectedClient) return@withLock
            entry.client.disconnect()
            entry.cliVersion = null
            updateState(entry, ConnectionState())
        }
    }

    suspend fun remove(profileId: String) {
        val entry = synchronized(lock) {
            entries.remove(profileId).also {
                _states.update { current -> current - profileId }
                if (_activeProfileId.value == profileId) _activeProfileId.value = entries.keys.firstOrNull()
            }
        } ?: return
        entry.client.close()
        entry.scope.cancel()
    }

    /** Close every transport, including profiles that are not currently selected. */
    fun close() {
        val values = synchronized(lock) {
            val result = entries.values.toList()
            entries.clear()
            _states.value = emptyMap()
            _activeProfileId.value = null
            result
        }
        values.forEach {
            it.client.close()
            it.scope.cancel()
        }
    }

    private fun ensureEntry(profile: ServerProfile): Entry {
        synchronized(lock) {
            val existing = entries[profile.id]
            if (existing != null && connectionIdentity(existing.profile) == connectionIdentity(profile)) {
                existing.profile = profile
                return existing
            }
            if (existing != null) {
                existing.client.close()
                existing.scope.cancel()
            }
            val childJob = SupervisorJob(parentScope.coroutineContext[Job])
            val childScope = CoroutineScope(parentScope.coroutineContext + childJob + Dispatchers.IO)
            val entry = Entry(profile, childScope, clientFactory(childScope))
            entries[profile.id] = entry
            _states.update { current -> current + (profile.id to ConnectionState()) }
            attachEventForwarders(profile.id, entry)
            return entry
        }
    }

    private fun attachEventForwarders(profileId: String, entry: Entry) {
        entry.scope.launch {
            entry.client.notifications.collect {
                if (isCurrentEntry(profileId, entry)) {
                    _notifications.emit(ProfiledCodexNotification(profileId, it))
                }
            }
        }
        entry.scope.launch {
            entry.client.approvals.collect {
                if (isCurrentEntry(profileId, entry)) {
                    _approvals.emit(ProfiledCodexApproval(profileId, it))
                }
            }
        }
        entry.scope.launch {
            entry.client.diagnostics.collect { event ->
                if (isCurrentEntry(profileId, entry)) {
                    _diagnostics.emit(ProfiledCodexConnectionEvent(profileId, event))
                }
            }
        }
        entry.scope.launch {
            entry.client.closed.collect { event ->
                if (!isCurrentEntry(profileId, entry)) return@collect
                updateState(entry, ConnectionState(ConnectionPhase.Failed, event.message))
                _closed.emit(ProfiledCodexConnectionEvent(profileId, event))
            }
        }
    }

    private fun updateState(entry: Entry, state: ConnectionState) {
        val profileId = entry.profile.id
        if (!isCurrentEntry(profileId, entry)) return
        _states.update { current ->
            if (current.containsKey(profileId)) current + (profileId to state) else current
        }
    }

    private fun isCurrentEntry(profileId: String, entry: Entry): Boolean =
        synchronized(lock) { entries[profileId] === entry }

    private data class ConnectionIdentity(
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

    private fun connectionIdentity(profile: ServerProfile) = ConnectionIdentity(
        host = profile.host,
        port = profile.port,
        username = profile.username,
        authMode = profile.authMode,
        password = profile.password,
        privateKeyPem = profile.privateKeyPem,
        privateKeyPassphrase = profile.privateKeyPassphrase,
        hostFingerprint = profile.hostFingerprint,
        remoteCommand = profile.remoteCommand,
    )
}
