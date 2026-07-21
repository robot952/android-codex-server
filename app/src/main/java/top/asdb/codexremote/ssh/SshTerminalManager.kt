package top.asdb.codexremote.ssh

import com.jcraft.jsch.ChannelShell
import com.jcraft.jsch.Session
import java.io.InputStream
import java.io.OutputStream
import java.util.ArrayDeque
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong
import top.asdb.codexremote.data.AuthMode
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.diagnostics.DiagnosticLogger

enum class SshTerminalPhase { Disconnected, Connecting, Connected, Failed }

data class SshTerminalSessionState(
    val profileId: String,
    val profileName: String,
    val endpoint: String,
    val phase: SshTerminalPhase = SshTerminalPhase.Disconnected,
    val message: String = "未连接",
    val generation: Long = 0,
)

data class SshTerminalManagerState(
    val visibleProfileId: String? = null,
    val sessions: Map<String, SshTerminalSessionState> = emptyMap(),
)

data class SshTerminalOutputSignal(
    val profileId: String,
    val generation: Long,
    val sequence: Long,
)

data class SshTerminalOutputChunk(
    val sequence: Long,
    val bytes: ByteArray,
)

data class SshTerminalOutputBatch(
    val generation: Long,
    val chunks: List<SshTerminalOutputChunk>,
    val latestSequence: Long,
    val resetRequired: Boolean,
    val historyTruncated: Boolean,
)

/** Owns one independent interactive SSH shell for every server profile. */
class SshTerminalManager(private val scope: CoroutineScope) {
    private val lock = Any()
    private val generationTokens = SshTerminalGenerationTokens()
    private val sessions = LinkedHashMap<String, SshTerminalConnection>()
    private var visibleProfileId: String? = null
    private val _state = MutableStateFlow(SshTerminalManagerState())
    private val _outputSignals = MutableSharedFlow<SshTerminalOutputSignal>(
        extraBufferCapacity = 256,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    val state: StateFlow<SshTerminalManagerState> = _state.asStateFlow()
    val outputSignals: SharedFlow<SshTerminalOutputSignal> = _outputSignals.asSharedFlow()

    fun open(profile: ServerProfile) {
        var replaced: SshTerminalConnection? = null
        val connection = synchronized(lock) {
            val existing = sessions[profile.id]
            val selected = if (existing != null && existing.matches(profile)) {
                existing
            } else {
                replaced = sessions.remove(profile.id)
                SshTerminalConnection(
                    scope = scope,
                    initialProfile = profile,
                    nextGenerationToken = generationTokens::next,
                    onStateChanged = ::publishState,
                    onOutput = { signal -> _outputSignals.tryEmit(signal) },
                ).also { sessions[profile.id] = it }
            }
            visibleProfileId = profile.id
            selected
        }
        replaced?.close()
        // Keep the membership check and the open operation under the manager lock. A concurrent
        // profile close must not remove this connection and then leave an untracked shell running.
        synchronized(lock) {
            if (sessions[profile.id] === connection) connection.open(profile)
        }
        publishState()
        DiagnosticLogger.info("Terminal", "open profile=${profile.id.take(8)}")
    }

    fun hide() {
        val hidden = synchronized(lock) {
            visibleProfileId.also { visibleProfileId = null }
        }
        if (hidden != null) DiagnosticLogger.info("Terminal", "hide profile=${hidden.take(8)}")
        publishState()
    }

    fun closeVisible() {
        synchronized(lock) { visibleProfileId }?.let(::closeProfile)
    }

    fun closeProfile(profileId: String) {
        val removed = synchronized(lock) {
            if (visibleProfileId == profileId) visibleProfileId = null
            sessions.remove(profileId)
        }
        removed?.close()
        if (removed != null) DiagnosticLogger.info("Terminal", "close profile=${profileId.take(8)}")
        publishState()
    }

    fun closeAll() {
        val removed = synchronized(lock) {
            visibleProfileId = null
            sessions.values.toList().also { sessions.clear() }
        }
        removed.forEach(SshTerminalConnection::close)
        publishState()
    }

    fun send(profileId: String, value: ByteArray): Boolean =
        synchronized(lock) { sessions[profileId] }?.send(value) == true

    fun resize(profileId: String, columns: Int, rows: Int) {
        synchronized(lock) { sessions[profileId] }?.resize(columns, rows)
    }

    fun outputAfter(
        profileId: String,
        generation: Long,
        sequence: Long,
    ): SshTerminalOutputBatch = synchronized(lock) { sessions[profileId] }
        ?.outputAfter(generation, sequence)
        ?: SshTerminalOutputBatch(
            generation = generation,
            chunks = emptyList(),
            latestSequence = sequence,
            resetRequired = false,
            historyTruncated = false,
        )

    private fun publishState() {
        // Build and publish while holding the same lock. Publishing after releasing it allows a
        // stale callback (for example, a connect completion racing with Hide/Close) to resurrect
        // a hidden or removed terminal in StateFlow.
        synchronized(lock) {
            _state.value = SshTerminalManagerState(
                visibleProfileId = visibleProfileId,
                sessions = sessions.values.associate { it.profileId to it.snapshot() },
            )
        }
    }
}

private class SshTerminalConnection(
    private val scope: CoroutineScope,
    initialProfile: ServerProfile,
    private val nextGenerationToken: () -> Long,
    private val onStateChanged: () -> Unit,
    private val onOutput: (SshTerminalOutputSignal) -> Unit,
) {
    private val lock = Any()
    private var profile = initialProfile
    private var identity = initialProfile.terminalIdentity()
    private var generation = 0L
    private var phase = SshTerminalPhase.Disconnected
    private var message = "未连接"
    private var connectJob: Job? = null
    private var writerJob: Job? = null
    private var resizeWriterJob: Job? = null
    private var connectingSession: Session? = null
    private var connectingChannel: ChannelShell? = null
    private var session: Session? = null
    private var channel: ChannelShell? = null
    private var inputQueue: BoundedTerminalInputQueue? = null
    private var resizeQueue: SshTerminalResizeQueue? = null
    private var requestedColumns = DEFAULT_COLUMNS
    private var requestedRows = DEFAULT_ROWS
    private var nextSequence = 0L
    private val outputHistory = ArrayDeque<SshTerminalOutputChunk>()
    private var outputHistoryBytes = 0
    private var historyTruncated = false

    val profileId: String get() = synchronized(lock) { profile.id }

    fun matches(value: ServerProfile): Boolean = synchronized(lock) {
        identity == value.terminalIdentity()
    }

    fun snapshot(): SshTerminalSessionState = synchronized(lock) {
        SshTerminalSessionState(
            profileId = profile.id,
            profileName = profile.name,
            endpoint = "${profile.username}@${profile.host}:${profile.port}",
            phase = phase,
            message = message,
            generation = generation,
        )
    }

    fun open(value: ServerProfile) {
        var previous: TerminalResources? = null
        var nextGeneration = 0L
        var alreadyActive = false
        synchronized(lock) {
            profile = value
            if (identity == value.terminalIdentity() &&
                phase in setOf(SshTerminalPhase.Connecting, SshTerminalPhase.Connected)
            ) {
                alreadyActive = true
            } else {
                identity = value.terminalIdentity()
                generation = nextGenerationToken()
                nextGeneration = generation
                previous = detachLocked(includeConnectJob = true)
                phase = SshTerminalPhase.Connecting
                message = "正在连接"
                nextSequence = 0L
                outputHistory.clear()
                outputHistoryBytes = 0
                historyTruncated = false
            }
        }
        if (alreadyActive) {
            onStateChanged()
            return
        }
        previous?.close()
        onStateChanged()

        val job = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            connect(nextGeneration, value)
        }
        val accepted = synchronized(lock) {
            if (generation == nextGeneration && phase == SshTerminalPhase.Connecting) {
                connectJob = job
                true
            } else {
                false
            }
        }
        if (accepted) job.start() else job.cancel()
    }

    fun send(value: ByteArray): Boolean {
        if (value.isEmpty()) return true
        val queue = synchronized(lock) {
            inputQueue?.takeIf { phase == SshTerminalPhase.Connected }
        } ?: return false
        return queue.trySend(value)
    }

    fun resize(columns: Int, rows: Int) {
        val safeColumns = columns.coerceIn(MIN_COLUMNS, MAX_COLUMNS)
        val safeRows = rows.coerceIn(MIN_ROWS, MAX_ROWS)
        val active = synchronized(lock) {
            requestedColumns = safeColumns
            requestedRows = safeRows
            resizeQueue?.takeIf { phase == SshTerminalPhase.Connected }
        } ?: return
        active.trySend(SshTerminalSize(safeColumns, safeRows))
    }

    fun outputAfter(expectedGeneration: Long, afterSequence: Long): SshTerminalOutputBatch =
        synchronized(lock) {
            val firstSequence = outputHistory.peekFirst()?.sequence ?: nextSequence
            val generationChanged = expectedGeneration != generation
            val cursorAhead = afterSequence >= nextSequence && afterSequence >= 0
            val resetRequired = generationChanged || cursorAhead || afterSequence < 0 ||
                afterSequence < firstSequence - 1
            val chunks = if (resetRequired) {
                outputHistory.toList()
            } else {
                outputHistory.filter { it.sequence > afterSequence }
            }
            SshTerminalOutputBatch(
                generation = generation,
                chunks = chunks,
                latestSequence = chunks.lastOrNull()?.sequence ?: if (resetRequired) -1L else afterSequence,
                resetRequired = resetRequired,
                historyTruncated = historyTruncated,
            )
        }

    fun close() {
        val resources = synchronized(lock) {
            generation = nextGenerationToken()
            phase = SshTerminalPhase.Disconnected
            message = "已关闭"
            detachLocked(includeConnectJob = true)
        }
        resources.close()
        onStateChanged()
    }

    private suspend fun connect(expectedGeneration: Long, value: ServerProfile) {
        var sshSession: Session? = null
        var shell: ChannelShell? = null
        try {
            sshSession = createPinnedSshSession(value)
            check(registerConnectingSession(expectedGeneration, sshSession)) { "SSH 终端连接已取消" }
            runCancellableConnect(
                connect = { sshSession.connect(SSH_CONNECT_TIMEOUT_MS) },
                disconnect = sshSession::disconnect,
            )

            shell = sshSession.openChannel("shell") as ChannelShell
            val initialSize = synchronized(lock) { SshTerminalSize(requestedColumns, requestedRows) }
            shell.setPtyType("xterm-256color", initialSize.columns, initialSize.rows, 0, 0)
            check(registerConnectingChannel(expectedGeneration, shell)) { "SSH 终端连接已取消" }
            val stdout = shell.inputStream
            val stdin = shell.outputStream
            runCancellableConnect(
                connect = { shell.connect(SSH_CHANNEL_TIMEOUT_MS) },
                disconnect = shell::disconnect,
            )

            val queue = BoundedTerminalInputQueue()
            val outputWriter = scope.launch(Dispatchers.IO) {
                try {
                    while (true) {
                        val bytes = queue.receive() ?: break
                        try {
                            stdin.write(bytes)
                            stdin.flush()
                        } finally {
                            queue.release(bytes.size)
                        }
                    }
                } catch (error: Throwable) {
                    if (error !is CancellationException) {
                        failGeneration(expectedGeneration, error, currentCoroutineContext()[Job])
                    }
                }
            }
            val pendingResizes = SshTerminalResizeQueue()
            val resizeWriter = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                pendingResizes.consumeLatest { size ->
                    try {
                        shell.setPtySize(size.columns, size.rows, 0, 0)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Throwable) {
                        // The read loop owns connection failure. A resize error should not replace it.
                    }
                }
            }
            check(
                publishConnected(
                    expectedGeneration = expectedGeneration,
                    sshSession = sshSession,
                    shell = shell,
                    queue = queue,
                    outputWriter = outputWriter,
                    initialSize = initialSize,
                    pendingResizes = pendingResizes,
                    resizeWriter = resizeWriter,
                ),
            ) {
                "SSH 终端连接已取消"
            }
            resizeWriter.start()
            onStateChanged()
            value.workspace.trim().takeIf(String::isNotEmpty)?.let { workspace ->
                queue.trySend("cd -- ${posixShellQuote(workspace)}\r".toByteArray(Charsets.UTF_8))
            }
            readOutput(expectedGeneration, stdout)
            finishGeneration(expectedGeneration, "SSH 终端已断开", currentCoroutineContext()[Job])
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            failGeneration(expectedGeneration, error, currentCoroutineContext()[Job])
        } finally {
            shell?.runCatching { disconnect() }
            sshSession?.runCatching { disconnect() }
        }
    }

    private suspend fun readOutput(expectedGeneration: Long, stdout: InputStream) {
        val buffer = ByteArray(OUTPUT_CHUNK_BYTES)
        while (currentCoroutineContext().isActive) {
            val count = stdout.read(buffer)
            if (count < 0) break
            if (count > 0) appendOutput(expectedGeneration, buffer.copyOf(count))
        }
    }

    private fun appendOutput(expectedGeneration: Long, bytes: ByteArray) {
        val signal = synchronized(lock) {
            if (generation != expectedGeneration) return
            val chunk = SshTerminalOutputChunk(nextSequence++, bytes)
            outputHistory.addLast(chunk)
            outputHistoryBytes += bytes.size
            while (outputHistoryBytes > MAX_OUTPUT_HISTORY_BYTES && outputHistory.size > 1) {
                outputHistoryBytes -= outputHistory.removeFirst().bytes.size
                historyTruncated = true
            }
            SshTerminalOutputSignal(profile.id, expectedGeneration, chunk.sequence)
        }
        onOutput(signal)
    }

    private fun registerConnectingSession(expectedGeneration: Long, value: Session): Boolean =
        synchronized(lock) {
            if (generation != expectedGeneration || phase != SshTerminalPhase.Connecting) return@synchronized false
            connectingSession = value
            true
        }

    private fun registerConnectingChannel(expectedGeneration: Long, value: ChannelShell): Boolean =
        synchronized(lock) {
            if (generation != expectedGeneration || connectingSession == null) return@synchronized false
            connectingChannel = value
            true
        }

    private fun publishConnected(
        expectedGeneration: Long,
        sshSession: Session,
        shell: ChannelShell,
        queue: BoundedTerminalInputQueue,
        outputWriter: Job,
        initialSize: SshTerminalSize,
        pendingResizes: SshTerminalResizeQueue,
        resizeWriter: Job,
    ): Boolean = synchronized(lock) {
        if (
            generation != expectedGeneration ||
            connectingSession !== sshSession ||
            connectingChannel !== shell
        ) {
            queue.close()
            outputWriter.cancel()
            pendingResizes.close()
            resizeWriter.cancel()
            return@synchronized false
        }
        connectingSession = null
        connectingChannel = null
        session = sshSession
        channel = shell
        inputQueue = queue
        writerJob = outputWriter
        resizeQueue = pendingResizes
        resizeWriterJob = resizeWriter
        phase = SshTerminalPhase.Connected
        message = "已连接"
        val latestSize = SshTerminalSize(requestedColumns, requestedRows)
        if (latestSize != initialSize) pendingResizes.trySend(latestSize)
        true
    }

    private fun finishGeneration(expectedGeneration: Long, detail: String, caller: Job?) {
        val resources = synchronized(lock) {
            phase = firstTerminalPhase(
                currentGeneration = generation,
                expectedGeneration = expectedGeneration,
                currentPhase = phase,
                requestedPhase = SshTerminalPhase.Disconnected,
            ) ?: return
            message = detail
            detachLocked(includeConnectJob = false, excludedJob = caller)
        }
        resources.close()
        onStateChanged()
    }

    private fun failGeneration(expectedGeneration: Long, error: Throwable, caller: Job?) {
        val detail = error.message?.takeIf { it.isNotBlank() } ?: "SSH 终端连接失败"
        val resources = synchronized(lock) {
            phase = firstTerminalPhase(
                currentGeneration = generation,
                expectedGeneration = expectedGeneration,
                currentPhase = phase,
                requestedPhase = SshTerminalPhase.Failed,
            ) ?: return
            message = detail
            detachLocked(includeConnectJob = true, excludedJob = caller)
        }
        appendOutput(expectedGeneration, "\r\n[SSH: $detail]\r\n".toByteArray(Charsets.UTF_8))
        resources.close()
        DiagnosticLogger.warn("Terminal", "failed profile=${profileId.take(8)} error=$detail")
        onStateChanged()
    }

    private fun detachLocked(
        includeConnectJob: Boolean,
        excludedJob: Job? = null,
    ): TerminalResources {
        val resources = TerminalResources(
            jobs = buildList {
                if (includeConnectJob) connectJob?.takeUnless { it === excludedJob }?.let(::add)
                writerJob?.takeUnless { it === excludedJob }?.let(::add)
                resizeWriterJob?.takeUnless { it === excludedJob }?.let(::add)
            },
            queue = inputQueue,
            resizeQueue = resizeQueue,
            connectingSession = connectingSession,
            connectingChannel = connectingChannel,
            session = session,
            channel = channel,
        )
        connectJob = null
        writerJob = null
        resizeWriterJob = null
        inputQueue = null
        resizeQueue = null
        connectingSession = null
        connectingChannel = null
        session = null
        channel = null
        return resources
    }

    private data class TerminalResources(
        val jobs: List<Job> = emptyList(),
        val queue: BoundedTerminalInputQueue? = null,
        val resizeQueue: SshTerminalResizeQueue? = null,
        val connectingSession: Session? = null,
        val connectingChannel: ChannelShell? = null,
        val session: Session? = null,
        val channel: ChannelShell? = null,
    ) {
        fun close() {
            queue?.close()
            resizeQueue?.close()
            jobs.forEach(Job::cancel)
            connectingChannel?.runCatching { disconnect() }
            channel?.runCatching { disconnect() }
            connectingSession?.runCatching { disconnect() }
            session?.runCatching { disconnect() }
        }
    }

    private companion object {
        const val DEFAULT_COLUMNS = 80
        const val DEFAULT_ROWS = 24
        const val MIN_COLUMNS = 10
        const val MAX_COLUMNS = 500
        const val MIN_ROWS = 2
        const val MAX_ROWS = 300
        const val OUTPUT_CHUNK_BYTES = 8 * 1024
        const val MAX_OUTPUT_HISTORY_BYTES = 2 * 1024 * 1024
    }
}

internal data class SshTerminalSize(val columns: Int, val rows: Int)

internal class SshTerminalResizeQueue {
    private val requests = Channel<SshTerminalSize>(Channel.CONFLATED)

    fun trySend(size: SshTerminalSize): Boolean = requests.trySend(size).isSuccess

    suspend fun consumeLatest(apply: suspend (SshTerminalSize) -> Unit) {
        while (true) {
            val size = requests.receiveCatching().getOrNull() ?: return
            apply(size)
        }
    }

    fun close() {
        requests.close()
    }
}

internal fun firstTerminalPhase(
    currentGeneration: Long,
    expectedGeneration: Long,
    currentPhase: SshTerminalPhase,
    requestedPhase: SshTerminalPhase,
): SshTerminalPhase? {
    require(requestedPhase == SshTerminalPhase.Disconnected || requestedPhase == SshTerminalPhase.Failed)
    return requestedPhase.takeIf {
        currentGeneration == expectedGeneration &&
            currentPhase in setOf(SshTerminalPhase.Connecting, SshTerminalPhase.Connected)
    }
}

/** Generates process-wide terminal lifecycle tokens so replacement connections cannot reuse a UI key. */
internal class SshTerminalGenerationTokens {
    private val counter = AtomicLong(0)

    fun next(): Long = counter.incrementAndGet()
}

private class BoundedTerminalInputQueue {
    private val channel = Channel<ByteArray>(Channel.UNLIMITED)
    private val lock = Any()
    private var pendingBytes = 0
    private var pendingChunks = 0
    private var closed = false

    fun trySend(value: ByteArray): Boolean {
        if (value.isEmpty()) return true
        if (value.size > MAX_INPUT_PAYLOAD_BYTES) return false
        val chunks = splitInputBytes(value)
        synchronized(lock) {
            if (closed || pendingBytes + value.size > MAX_INPUT_QUEUE_BYTES ||
                pendingChunks + chunks.size > MAX_INPUT_QUEUE_CHUNKS
            ) {
                return false
            }
            pendingBytes += value.size
            pendingChunks += chunks.size
            chunks.forEach { chunk ->
                // The channel is unlimited; the explicit byte/chunk budget above is the bound.
                check(channel.trySend(chunk).isSuccess) { "SSH 终端输入队列已关闭" }
            }
            return true
        }
    }

    suspend fun receive(): ByteArray? = channel.receiveCatching().getOrNull()

    fun release(bytes: Int) {
        synchronized(lock) {
            pendingBytes = (pendingBytes - bytes).coerceAtLeast(0)
            pendingChunks = (pendingChunks - 1).coerceAtLeast(0)
        }
    }

    fun close() {
        synchronized(lock) {
            if (!closed) {
                closed = true
                channel.close()
            }
        }
    }

    private companion object {
        const val MAX_INPUT_QUEUE_BYTES = 512 * 1024
        const val MAX_INPUT_QUEUE_CHUNKS = 256
        const val MAX_INPUT_PAYLOAD_BYTES = 512 * 1024
        const val INPUT_CHUNK_BYTES = 16 * 1024

        fun splitInputBytes(value: ByteArray): List<ByteArray> {
            if (value.size <= INPUT_CHUNK_BYTES) return listOf(value.copyOf())
            val chunks = ArrayList<ByteArray>((value.size + INPUT_CHUNK_BYTES - 1) / INPUT_CHUNK_BYTES)
            var offset = 0
            while (offset < value.size) {
                val end = minOf(value.size, offset + INPUT_CHUNK_BYTES)
                chunks += value.copyOfRange(offset, end)
                offset = end
            }
            return chunks
        }
    }
}

internal fun posixShellQuote(value: String): String = "'${value.replace("'", "'\"'\"'")}'"

private data class SshTerminalIdentity(
    val host: String,
    val port: Int,
    val username: String,
    val authMode: AuthMode,
    val password: String,
    val privateKeyPem: String,
    val privateKeyPassphrase: String,
    val hostFingerprint: String,
)

private fun ServerProfile.terminalIdentity() = SshTerminalIdentity(
    host = host,
    port = port,
    username = username,
    authMode = authMode,
    password = password,
    privateKeyPem = privateKeyPem,
    privateKeyPassphrase = privateKeyPassphrase,
    hostFingerprint = hostFingerprint,
)
