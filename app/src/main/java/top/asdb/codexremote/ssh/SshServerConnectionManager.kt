package top.asdb.codexremote.ssh

import java.io.InputStream
import java.io.OutputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState
import top.asdb.codexremote.data.RemoteDirectoryListing
import top.asdb.codexremote.data.RemoteFileListing
import top.asdb.codexremote.data.RemoteFileTransferMode
import top.asdb.codexremote.data.ServerMetrics
import top.asdb.codexremote.data.ServerProfile

/** Host-level operations that do not require a Codex/OpenCode Agent. */
interface RemoteServerClient : RemoteShellExecutor {
    suspend fun probeFingerprint(profile: ServerProfile): String
    suspend fun connect(profile: ServerProfile): String
    suspend fun disconnect()
    fun close()
    fun isConnected(): Boolean
    fun currentGeneration(): Long?

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
}

/** Adapter exposing the existing, bounded SFTP implementation as a host-only client. */
class SshServerClient : RemoteServerClient {
    private val transport = SshCodexTransport()

    override suspend fun probeFingerprint(profile: ServerProfile): String =
        transport.probeFingerprint(profile)

    override suspend fun connect(profile: ServerProfile): String {
        transport.connectSsh(profile)
        return "SSH"
    }

    override suspend fun disconnect() = transport.disconnect()

    override fun close() = transport.close()

    override fun isConnected(): Boolean = transport.isSshConnected()

    override fun currentGeneration(): Long? = transport.currentSshGeneration()

    override suspend fun executeShellScript(
        script: String,
        timeoutMs: Long,
        operationName: String,
    ): List<String> = transport.executeConnectedShellScript(script, timeoutMs, operationName)

    override suspend fun listDirectories(path: String?): RemoteDirectoryListing =
        transport.listDirectories(path)

    override suspend fun listFiles(path: String?): RemoteFileListing = transport.listFiles(path)

    override suspend fun readServerMetrics(profile: ServerProfile): ServerMetrics =
        transport.readServerMetrics()

    override suspend fun upload(name: String, bytes: ByteArray): String = transport.upload(name, bytes)

    override suspend fun uploadFile(directory: String, name: String, input: InputStream) =
        transport.uploadFile(directory, name, input)

    override suspend fun downloadFile(path: String, output: OutputStream) =
        transport.downloadFile(path, output)

    override suspend fun renameFile(path: String, newName: String) =
        transport.renameFile(path, newName)

    override suspend fun deleteFiles(paths: List<String>) = transport.deleteFiles(paths)

    override suspend fun transferFiles(
        paths: List<String>,
        destinationDirectory: String,
        mode: RemoteFileTransferMode,
    ) = transport.transferFiles(paths, destinationDirectory, mode)

    override suspend fun downloadImage(path: String): ByteArray = transport.downloadImage(path)
}

/**
 * Owns one independent SSH host connection per server profile.  Agent lanes are deliberately
 * managed by [top.asdb.codexremote.agent.AgentConnectionManager] and never change this state.
 */
class SshServerConnectionManager(
    private val parentScope: CoroutineScope,
    private val clientFactory: () -> RemoteServerClient = { SshServerClient() },
) {
    private class Entry(
        var profile: ServerProfile,
        val client: RemoteServerClient,
        val scope: CoroutineScope,
    ) {
        val connectMutex = Mutex()
        var monitorJob: Job? = null
    }

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private val _states = MutableStateFlow<Map<String, ConnectionState>>(emptyMap())
    val states: StateFlow<Map<String, ConnectionState>> = _states.asStateFlow()

    fun registerProfile(profile: ServerProfile): RemoteServerClient = synchronized(lock) {
        val existing = entries[profile.id]
        if (existing != null && sameIdentity(existing.profile, profile)) {
            existing.profile = profile
            return@synchronized existing.client
        }
        if (existing != null) {
            entries.remove(profile.id)
            _states.update { it - profile.id }
            existing.monitorJob?.cancel()
            existing.client.close()
            existing.scope.cancel()
        }
        val childJob = SupervisorJob(parentScope.coroutineContext[Job])
        val childScope = CoroutineScope(parentScope.coroutineContext + childJob + Dispatchers.IO)
        val entry = Entry(profile, clientFactory(), childScope)
        entries[profile.id] = entry
        _states.update { it + (profile.id to ConnectionState()) }
        entry.client
    }

    fun client(profileId: String): RemoteServerClient? = synchronized(lock) {
        entries[profileId]?.client
    }

    fun profile(profileId: String): ServerProfile? = synchronized(lock) {
        entries[profileId]?.profile
    }

    suspend fun probeFingerprint(profile: ServerProfile): String =
        registerProfile(profile).probeFingerprint(profile)

    suspend fun connect(profile: ServerProfile): String {
        val entry = registerProfile(profile).let { client ->
            synchronized(lock) { entries[profile.id]?.takeIf { it.client === client } }
        } ?: error("服务器连接已失效")
        return entry.connectMutex.withLock {
            if (entry.client.isConnected()) {
                updateState(entry, ConnectionState(ConnectionPhase.Connected, "SSH 已连接"))
                startMonitor(entry)
                return@withLock "SSH"
            }
            updateState(entry, ConnectionState(ConnectionPhase.Connecting, "正在连接 SSH"))
            try {
                val version = entry.client.connect(profile)
                check(isCurrentEntry(profile.id, entry)) { "服务器连接配置已更新" }
                updateState(entry, ConnectionState(ConnectionPhase.Connected, "SSH 已连接"))
                startMonitor(entry)
                version
            } catch (error: kotlinx.coroutines.CancellationException) {
                updateState(entry, ConnectionState())
                throw error
            } catch (error: Throwable) {
                updateState(
                    entry,
                    ConnectionState(ConnectionPhase.Failed, error.message ?: "SSH 连接失败"),
                )
                throw error
            }
        }
    }

    suspend fun disconnect(profileId: String) {
        val entry = synchronized(lock) { entries[profileId] } ?: return
        entry.connectMutex.withLock {
            entry.monitorJob?.cancel()
            entry.monitorJob = null
            entry.client.disconnect()
            updateState(entry, ConnectionState())
        }
    }

    fun remove(profileId: String) {
        val removed = synchronized(lock) {
            entries.remove(profileId).also { _states.update { current -> current - profileId } }
        }
        removed?.monitorJob?.cancel()
        removed?.client?.close()
        removed?.scope?.cancel()
    }

    fun close() {
        val removed = synchronized(lock) {
            entries.values.toList().also {
                entries.clear()
                _states.value = emptyMap()
            }
        }
        removed.forEach {
            it.monitorJob?.cancel()
            it.client.close()
            it.scope.cancel()
        }
    }

    private fun updateState(entry: Entry, state: ConnectionState) {
        synchronized(lock) {
            if (entries[entry.profile.id] === entry) {
                _states.update { it + (entry.profile.id to state) }
            }
        }
    }

    /** Detects a dropped host session even when no SFTP or terminal operation is in flight. */
    private fun startMonitor(entry: Entry) {
        synchronized(lock) {
            if (entries[entry.profile.id] !== entry || entry.monitorJob?.isActive == true) return
            entry.monitorJob = parentScope.launch {
                while (true) {
                    val connected = runCatching { entry.client.isConnected() }.getOrDefault(false)
                    if (!connected) {
                        updateState(
                            entry,
                            ConnectionState(ConnectionPhase.Disconnected, "SSH 连接已断开"),
                        )
                        break
                    }
                    delay(HOST_CONNECTION_POLL_INTERVAL_MS)
                }
            }
        }
    }

    private fun isCurrentEntry(profileId: String, entry: Entry): Boolean = synchronized(lock) {
        entries[profileId] === entry
    }

    private fun sameIdentity(left: ServerProfile, right: ServerProfile): Boolean =
        left.host == right.host &&
            left.port == right.port &&
            left.username == right.username &&
            left.authMode == right.authMode &&
            left.password == right.password &&
            left.privateKeyPem == right.privateKeyPem &&
            left.privateKeyPassphrase == right.privateKeyPassphrase &&
            left.hostFingerprint == right.hostFingerprint

    private companion object {
        const val HOST_CONNECTION_POLL_INTERVAL_MS = 2_000L
    }
}
