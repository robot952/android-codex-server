package top.asdb.codexremote.ssh

import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonPrimitive
import top.asdb.codexremote.data.CodexConnectionTestResult
import top.asdb.codexremote.data.CodexGlobalSettings
import top.asdb.codexremote.data.RemoteDirectory
import top.asdb.codexremote.data.RemoteDirectoryListing
import top.asdb.codexremote.data.ServerMetrics
import top.asdb.codexremote.data.ServerProfile
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.io.Reader
import java.util.UUID
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal data class SshTransportEvent(
    val generation: Long,
    val value: String,
)

internal data class SshOversizedLineEvent(
    val generation: Long,
    val id: String?,
    val idIsString: Boolean,
    val hasMethod: Boolean,
    val value: String,
)

data class RemoteInstallProgress(
    val percent: Int,
    val message: String,
    val detail: String = "",
    val downloadPercent: Int? = null,
)

class SshCodexTransport {
    private val connectionMutex = Mutex()
    private val connectionStateLock = Any()
    private var connectionGeneration = 0L
    private var scope: CoroutineScope? = null
    private var session: Session? = null
    private var channel: ChannelExec? = null
    private var writer: OutputStream? = null
    private var readerJob: Job? = null
    private var connectingSession: Session? = null
    private var connectingChannel: ChannelExec? = null
    private val writeMutex = Mutex()

    private val _lines = MutableSharedFlow<SshTransportEvent>()
    internal val lines: SharedFlow<SshTransportEvent> = _lines.asSharedFlow()

    private val _diagnostics = MutableSharedFlow<SshTransportEvent>()
    internal val diagnostics: SharedFlow<SshTransportEvent> = _diagnostics.asSharedFlow()

    private val _oversizedLines = MutableSharedFlow<SshOversizedLineEvent>()
    internal val oversizedLines: SharedFlow<SshOversizedLineEvent> = _oversizedLines.asSharedFlow()

    private val _closed = MutableSharedFlow<SshTransportEvent>()
    internal val closed: SharedFlow<SshTransportEvent> = _closed.asSharedFlow()

    /** Samples only procfs and the root filesystem; no remote package or daemon is installed. */
    suspend fun readServerMetrics(profile: ServerProfile): ServerMetrics {
        val lines = executeScript(
            profile = profile,
            script = SERVER_METRICS_SCRIPT,
            timeoutMs = METRICS_TIMEOUT_MS,
            operationName = "读取服务器资源占用",
        )
        return parseServerMetrics(lines, System.currentTimeMillis())
    }

    suspend fun probeFingerprint(profile: ServerProfile): String = withContext(Dispatchers.IO) {
        require(profile.host.isNotBlank()) { "请输入服务器地址" }
        require(profile.username.isNotBlank()) { "请输入用户名" }
        val capture = FingerprintCaptureHostKeyRepository()
        val probe = JSch().apply { hostKeyRepository = capture }
            .getSession(profile.username, profile.host, profile.port)
        probe.setConfig("StrictHostKeyChecking", "yes")
        probe.timeout = SSH_CONNECT_TIMEOUT_MS
        try {
            try {
                runCancellableConnect(
                    connect = { probe.connect(SSH_CONNECT_TIMEOUT_MS) },
                    disconnect = probe::disconnect,
                )
                throw IllegalStateException("SSH 指纹探测未在主机密钥校验阶段停止")
            } catch (error: JSchException) {
                capture.fingerprint() ?: throw IllegalStateException(
                    buildString {
                        append("无法读取服务器 SSH 主机密钥")
                        error.message?.takeIf { it.isNotBlank() }?.let { append(": ").append(it) }
                    },
                    error,
                )
            }
        } finally {
            probe.disconnect()
        }
    }

    suspend fun connect(profile: ServerProfile): Long = withContext(Dispatchers.IO) {
        require(profile.host.isNotBlank()) { "服务器地址不能为空" }
        require(profile.username.isNotBlank()) { "用户名不能为空" }
        require(profile.hostFingerprint.isNotBlank()) { "请先核对并保存 SSH 主机指纹" }
        require(profile.remoteCommand.isNotBlank()) { "Codex 远程命令不能为空" }

        connectionMutex.withLock {
            val attempt = beginConnectionAttempt()
            closeResources(attempt.previous)
            val generation = attempt.generation
            val attemptScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            var sshSession: Session? = null
            var exec: ChannelExec? = null
            try {
                sshSession = createPinnedSshSession(profile)
                check(registerConnectingSession(generation, sshSession)) { "SSH 连接已取消" }
                runCancellableConnect(
                    connect = { sshSession.connect(SSH_CONNECT_TIMEOUT_MS) },
                    disconnect = sshSession::disconnect,
                )
                check(isConnectionCurrent(generation)) { "SSH 连接已取消" }

                val stderrIn = PipedInputStream(16 * 1024)
                val stderrOut = PipedOutputStream(stderrIn)
                exec = sshSession.openChannel("exec") as ChannelExec
                check(registerConnectingChannel(generation, exec)) { "SSH 连接已取消" }
                exec.setPty(false)
                exec.setCommand(appServerCommand(profile.remoteCommand))
                exec.setErrStream(stderrOut)
                val stdout = exec.inputStream
                val stdin = exec.outputStream
                runCancellableConnect(
                    connect = { exec.connect(SSH_CHANNEL_TIMEOUT_MS) },
                    disconnect = exec::disconnect,
                )
                check(publishConnection(generation, attemptScope, sshSession, exec, stdin)) {
                    "SSH 连接已取消"
                }

                val stdoutJob = attemptScope.launch {
                    runCatching {
                        readBoundedJsonLines(
                            reader = InputStreamReader(stdout, Charsets.UTF_8),
                            maxLineChars = MAX_APP_SERVER_LINE_CHARS,
                            onLine = { _lines.emit(SshTransportEvent(generation, it)) },
                            onOversizedLine = { prefix ->
                                val envelope = inspectJsonRpcEnvelopePrefix(prefix)
                                val message = when {
                                    envelope.id != null && !envelope.hasMethod ->
                                        "Codex JSONL 单行超过 $MAX_APP_SERVER_LINE_CHARS 个字符，已改用精简响应"
                                    envelope.id != null ->
                                        "Codex 服务端请求过大，已拒绝该请求以避免回合卡住"
                                    else ->
                                        "Codex JSONL 单行超过 $MAX_APP_SERVER_LINE_CHARS 个字符，已丢弃该条通知"
                                }
                                _oversizedLines.emit(
                                    SshOversizedLineEvent(
                                        generation,
                                        envelope.id,
                                        envelope.idIsString,
                                        envelope.hasMethod,
                                        message,
                                    ),
                                )
                                _diagnostics.emit(
                                    SshTransportEvent(
                                        generation,
                                        message,
                                    ),
                                )
                            },
                        )
                    }.onFailure {
                        if (isConnectionCurrent(generation)) {
                            _diagnostics.emit(SshTransportEvent(generation, it.message ?: "SSH 输出流异常"))
                        }
                    }
                    closeConnectionFromReader(generation, "Codex SSH 通道已关闭")
                }
                registerReaderJob(generation, stdoutJob)
                attemptScope.launch {
                    readBoundedJsonLines(
                        reader = InputStreamReader(stderrIn, Charsets.UTF_8),
                        maxLineChars = MAX_LINE_CHARS,
                        onLine = { line ->
                            if (line.isNotBlank() && isConnectionCurrent(generation)) {
                                _diagnostics.emit(SshTransportEvent(generation, line))
                            }
                        },
                        onOversizedLine = {
                            if (isConnectionCurrent(generation)) {
                                _diagnostics.emit(SshTransportEvent(generation, "SSH 错误输出单行过长，已丢弃"))
                            }
                        },
                    )
                }
                generation
            } catch (error: Throwable) {
                closeResources(invalidateConnection())
                exec?.disconnect()
                sshSession?.disconnect()
                attemptScope.cancel()
                throw error
            }
        }
    }

    suspend fun inspectRemote(profile: ServerProfile): RemoteEnvironment {
        val result = executeScript(profile, RemoteBootstrap.probeScript, PROBE_TIMEOUT_MS)
        return RemoteBootstrap.parseProbe(result)
    }

    suspend fun installRemote(
        profile: ServerProfile,
        codexVersion: String,
        nodeVersion: String,
        onProgress: (String) -> Unit,
    ) = installRemoteDetailed(profile, codexVersion, nodeVersion) { progress ->
        onProgress(progress.message)
    }

    suspend fun installRemoteDetailed(
        profile: ServerProfile,
        codexVersion: String,
        nodeVersion: String,
        onProgress: (RemoteInstallProgress) -> Unit,
    ) {
        executeScript(
            profile = profile,
            script = RemoteBootstrap.installScript(codexVersion, nodeVersion, profile.proxyUrl),
            timeoutMs = INSTALL_TIMEOUT_MS,
            remoteCommand = INSTALL_SHELL_COMMAND,
            operationName = "远程安装",
        ) { line ->
            if (line.startsWith(PROGRESS_PREFIX)) {
                onProgress(parseInstallProgress(line.removePrefix(PROGRESS_PREFIX)))
            }
        }
    }

    /** Removes only the managed Codex Remote runtime; system and VS Code Codex installs are kept. */
    suspend fun uninstallRemote(profile: ServerProfile) {
        executeScript(
            profile = profile,
            script = RemoteBootstrap.uninstallScript,
            timeoutMs = UNINSTALL_TIMEOUT_MS,
            operationName = "远程卸载",
        )
    }

    suspend fun sendLine(line: String, expectedGeneration: Long) = withContext(Dispatchers.IO) {
        writeMutex.withLock {
            val output = synchronized(connectionStateLock) {
                check(connectionGeneration == expectedGeneration) { "SSH 连接已经更改" }
                writer
            }
                ?: throw IllegalStateException("SSH 通道尚未连接")
            output.write(line.toByteArray(Charsets.UTF_8))
            output.write('\n'.code)
            output.flush()
        }
    }

    suspend fun listDirectories(path: String?): RemoteDirectoryListing = withContext(Dispatchers.IO) {
        val sshSession = synchronized(connectionStateLock) { session }
            ?: throw IllegalStateException("SSH 通道尚未连接")
        val sftp = sshSession.openChannel("sftp") as ChannelSftp
        try {
            runCancellableConnect(
                connect = { sftp.connect(SSH_CHANNEL_TIMEOUT_MS) },
                disconnect = sftp::disconnect,
            )
            val requested = path?.trim().takeUnless { it.isNullOrBlank() } ?: "."
            val current = sftp.realpath(requested)
            val parent = if (current == "/") {
                null
            } else {
                current.substringBeforeLast('/').ifBlank { "/" }
            }
            val directories = sftp.ls(current)
                .filterIsInstance<ChannelSftp.LsEntry>()
                .filter { it.filename !in setOf(".", "..") && it.attrs.isDir }
                .map { entry ->
                    RemoteDirectory(
                        name = entry.filename,
                        path = if (current == "/") "/${entry.filename}" else "$current/${entry.filename}",
                    )
                }
                .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
            RemoteDirectoryListing(current, parent, directories)
        } finally {
            sftp.disconnect()
        }
    }

    suspend fun upload(name: String, bytes: ByteArray): String =
        withContext(Dispatchers.IO) {
            val sshSession = synchronized(connectionStateLock) { session }
                ?: throw IllegalStateException("SSH 通道尚未连接")
            val sftp = sshSession.openChannel("sftp") as ChannelSftp
            try {
                runCancellableConnect(
                    connect = { sftp.connect(SSH_CHANNEL_TIMEOUT_MS) },
                    disconnect = sftp::disconnect,
                )
                val home = sftp.home
                val directory = "$home/.codex-mobile/uploads"
                ensureDirectory(sftp, directory)
                val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_").take(120)
                    .ifBlank { "attachment" }
                val remotePath = "$directory/${UUID.randomUUID()}-$safeName"
                ByteArrayInputStream(bytes).use { sftp.put(it, remotePath) }
                remotePath
            } finally {
                sftp.disconnect()
            }
        }

    /** Reads a user-requested image through the already authenticated SSH session. */
    suspend fun downloadImage(path: String): ByteArray = withContext(Dispatchers.IO) {
        val remotePath = path.trim()
        require(remotePath.startsWith('/')) { "图片路径必须是绝对路径" }
        require(remotePath.length <= MAX_REMOTE_PATH_CHARS) { "图片路径过长" }
        val sshSession = synchronized(connectionStateLock) { session }
            ?: throw IllegalStateException("SSH 通道尚未连接")
        val sftp = sshSession.openChannel("sftp") as ChannelSftp
        try {
            runCancellableConnect(
                connect = { sftp.connect(SSH_CHANNEL_TIMEOUT_MS) },
                disconnect = sftp::disconnect,
            )
            val declaredSize = sftp.stat(remotePath).size
            require(declaredSize in 1..MAX_IMAGE_PREVIEW_BYTES) { "图片不能超过 20 MB" }
            val output = BoundedImageOutputStream(MAX_IMAGE_PREVIEW_BYTES.toInt())
            sftp.get(remotePath, output)
            output.toByteArray()
        } finally {
            sftp.disconnect()
        }
    }

    suspend fun readCodexGlobalSettings(profile: ServerProfile): CodexGlobalSettings {
        val lines = executeScript(
            profile = profile,
            script = RemoteCodexSettings.readScript,
            timeoutMs = GLOBAL_SETTINGS_TIMEOUT_MS,
            operationName = "读取 Codex 全局配置",
        )
        return RemoteCodexSettings.parse(lines)
    }

    suspend fun writeCodexGlobalSettings(
        profile: ServerProfile,
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
    ) {
        executeScript(
            profile = profile,
            script = RemoteCodexSettings.writeScript(baseUrl, apiKey, proxyUrl),
            timeoutMs = GLOBAL_SETTINGS_TIMEOUT_MS,
            operationName = "保存 Codex 全局配置",
        )
    }

    suspend fun testCodexGlobalSettings(
        profile: ServerProfile,
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
        testModel: String,
    ): CodexConnectionTestResult {
        val lines = executeScript(
            profile = profile,
            script = RemoteCodexSettings.testConnectionScript(baseUrl, apiKey, proxyUrl, testModel),
            timeoutMs = GLOBAL_SETTINGS_TIMEOUT_MS,
            operationName = "测试 Codex API 连接",
        )
        return RemoteCodexSettings.parseConnectionTest(lines)
    }

    fun isConnected(): Boolean = synchronized(connectionStateLock) {
        session?.isConnected == true && channel?.isConnected == true
    }

    suspend fun disconnect() = withContext(Dispatchers.IO) {
        closeResources(invalidateConnection())
        connectionMutex.withLock {
            closeResources(invalidateConnection())
        }
    }

    fun close() {
        closeResources(invalidateConnection())
    }

    private suspend fun executeScript(
        profile: ServerProfile,
        script: String,
        timeoutMs: Long,
        remoteCommand: String = "sh -s",
        operationName: String = "远程命令",
        onLine: (String) -> Unit = {},
    ): List<String> = coroutineScope {
        val sessionRef = AtomicReference<Session?>()
        val channelRef = AtomicReference<ChannelExec?>()
        val task = async(Dispatchers.IO) {
            executeScriptBlocking(
                profile,
                script,
                remoteCommand,
                operationName,
                onLine,
                sessionRef,
                channelRef,
            )
        }
        try {
            withTimeout(timeoutMs) { task.await() }
        } catch (error: Throwable) {
            channelRef.getAndSet(null)?.disconnect()
            sessionRef.getAndSet(null)?.disconnect()
            task.cancel()
            throw error
        }
    }

    private fun appServerCommand(remoteCommand: String): String = """
        if [ -r "${'$'}HOME/.codex/codex-remote.env" ]; then
          . "${'$'}HOME/.codex/codex-remote.env"
        fi
        exec $remoteCommand
    """.trimIndent()

    private suspend fun executeScriptBlocking(
        profile: ServerProfile,
        script: String,
        remoteCommand: String,
        operationName: String,
        onLine: (String) -> Unit,
        sessionRef: AtomicReference<Session?>,
        channelRef: AtomicReference<ChannelExec?>,
    ): List<String> {
        var sshSession: Session? = null
        var exec: ChannelExec? = null
        try {
            sshSession = createPinnedSshSession(profile).also(sessionRef::set)
            runCancellableConnect(
                connect = { sshSession.connect(SSH_CONNECT_TIMEOUT_MS) },
                disconnect = sshSession::disconnect,
            )
            exec = (sshSession.openChannel("exec") as ChannelExec).also(channelRef::set)
            val stderr = LimitedByteArrayOutputStream(MAX_STDERR_BYTES)
            exec.setPty(false)
            exec.setCommand(remoteCommand)
            exec.setErrStream(stderr)
            val stdout = exec.inputStream
            val stdin = exec.outputStream
            runCancellableConnect(
                connect = { exec.connect(SSH_CHANNEL_TIMEOUT_MS) },
                disconnect = exec::disconnect,
            )
            stdin.bufferedWriter(Charsets.UTF_8).use { writer ->
                writer.write("exec 2>&1\n")
                writer.write(script)
                writer.write('\n'.code)
            }
            val tail = ArrayDeque<String>(MAX_CAPTURED_LINES)
            readBoundedLines(InputStreamReader(stdout, Charsets.UTF_8)) { line ->
                if (tail.size == MAX_CAPTURED_LINES) tail.removeFirst()
                tail.addLast(line)
                onLine(line)
            }
            while (!exec.isClosed) Thread.sleep(10)
            val lines = tail.toList()
            val exitCode = exec.exitStatus
            if (exitCode != 0) {
                val detail = (lines.takeLast(8) + stderr.toString(Charsets.UTF_8.name()))
                    .filter { it.isNotBlank() }
                    .joinToString("\n")
                throw IllegalStateException(
                    buildString {
                        append(operationName).append("失败（退出码 ").append(exitCode).append('）')
                        if (detail.isNotBlank()) append("\n").append(detail)
                    },
                )
            }
            return lines
        } finally {
            channelRef.compareAndSet(exec, null)
            sessionRef.compareAndSet(sshSession, null)
            exec?.disconnect()
            sshSession?.disconnect()
        }
    }

    private fun readBoundedLines(reader: InputStreamReader, onLine: (String) -> Unit) {
        reader.use {
            val buffer = CharArray(2048)
            val line = StringBuilder()
            var truncated = false
            fun emitLine() {
                if (truncated) line.append(" [输出已截断]")
                onLine(line.toString().trimEnd('\r'))
                line.setLength(0)
                truncated = false
            }
            while (true) {
                val count = it.read(buffer)
                if (count < 0) break
                for (index in 0 until count) {
                    val character = buffer[index]
                    if (character == '\n') {
                        emitLine()
                    } else if (line.length < MAX_LINE_CHARS) {
                        line.append(character)
                    } else {
                        truncated = true
                    }
                }
            }
            if (line.isNotEmpty() || truncated) emitLine()
        }
    }

    private class LimitedByteArrayOutputStream(private val limit: Int) : ByteArrayOutputStream() {
        override fun write(value: Int) {
            if (count < limit) super.write(value)
        }

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            val remaining = limit - count
            if (remaining > 0) super.write(bytes, offset, minOf(length, remaining))
        }
    }

    private data class ConnectionResources(
        val scope: CoroutineScope?,
        val readerJob: Job?,
        val writer: OutputStream?,
        val channel: ChannelExec?,
        val session: Session?,
        val connectingChannel: ChannelExec?,
        val connectingSession: Session?,
    )

    private data class ConnectionAttempt(
        val generation: Long,
        val previous: ConnectionResources,
    )

    private fun beginConnectionAttempt(): ConnectionAttempt = synchronized(connectionStateLock) {
        connectionGeneration += 1
        ConnectionAttempt(connectionGeneration, detachConnectionLocked())
    }

    private fun invalidateConnection(): ConnectionResources = synchronized(connectionStateLock) {
        connectionGeneration += 1
        detachConnectionLocked()
    }

    private fun detachConnectionLocked(): ConnectionResources {
        val resources = ConnectionResources(
            scope = scope,
            readerJob = readerJob,
            writer = writer,
            channel = channel,
            session = session,
            connectingChannel = connectingChannel,
            connectingSession = connectingSession,
        )
        scope = null
        readerJob = null
        writer = null
        channel = null
        session = null
        connectingChannel = null
        connectingSession = null
        return resources
    }

    private fun closeResources(resources: ConnectionResources) {
        resources.readerJob?.cancel()
        resources.scope?.cancel()
        resources.connectingChannel?.runCatching { disconnect() }
        resources.channel?.runCatching { disconnect() }
        resources.writer?.runCatching { close() }
        resources.connectingSession?.runCatching { disconnect() }
        resources.session?.runCatching { disconnect() }
    }

    private fun registerConnectingSession(generation: Long, value: Session): Boolean =
        synchronized(connectionStateLock) {
            if (connectionGeneration != generation) return@synchronized false
            connectingSession = value
            true
        }

    private fun registerConnectingChannel(generation: Long, value: ChannelExec): Boolean =
        synchronized(connectionStateLock) {
            if (connectionGeneration != generation || connectingSession == null) {
                return@synchronized false
            }
            connectingChannel = value
            true
        }

    private fun publishConnection(
        generation: Long,
        valueScope: CoroutineScope,
        valueSession: Session,
        valueChannel: ChannelExec,
        valueWriter: OutputStream,
    ): Boolean = synchronized(connectionStateLock) {
        if (
            connectionGeneration != generation ||
            connectingSession !== valueSession ||
            connectingChannel !== valueChannel
        ) {
            return@synchronized false
        }
        scope = valueScope
        session = valueSession
        channel = valueChannel
        writer = valueWriter
        connectingSession = null
        connectingChannel = null
        true
    }

    private fun registerReaderJob(generation: Long, value: Job) {
        val registered = synchronized(connectionStateLock) {
            if (connectionGeneration != generation || scope == null) return@synchronized false
            readerJob = value
            true
        }
        if (!registered) value.cancel()
    }

    private fun isConnectionCurrent(generation: Long): Boolean = synchronized(connectionStateLock) {
        connectionGeneration == generation
    }

    private suspend fun closeConnectionFromReader(generation: Long, message: String) {
        val resources = synchronized(connectionStateLock) {
            if (connectionGeneration != generation) return
            connectionGeneration += 1
            detachConnectionLocked()
        }
        try {
            _closed.emit(SshTransportEvent(generation, message))
        } finally {
            closeResources(resources)
        }
    }

    private fun ensureDirectory(sftp: ChannelSftp, absolutePath: String) {
        val parts = absolutePath.split('/').filter { it.isNotBlank() }
        var current = ""
        parts.forEach { part ->
            current += "/$part"
            runCatching { sftp.stat(current) }.getOrElse { sftp.mkdir(current) }
        }
    }

    companion object {
        private const val PROBE_TIMEOUT_MS = 30_000L
        private const val METRICS_TIMEOUT_MS = 15_000L
        private const val INSTALL_TIMEOUT_MS = 30 * 60_000L
        private const val UNINSTALL_TIMEOUT_MS = 60_000L
        internal const val INSTALL_SHELL_COMMAND = "CODEX_REMOTE_SSH_PID=\$PPID setsid --wait sh -s"
        private const val PROGRESS_PREFIX = "::progress::"
        private const val MAX_CAPTURED_LINES = 64
        private const val MAX_LINE_CHARS = 8 * 1024
        private const val MAX_STDERR_BYTES = 8 * 1024
        private const val MAX_APP_SERVER_LINE_CHARS = 8 * 1024 * 1024
        private const val MAX_IMAGE_PREVIEW_BYTES = 20L * 1024 * 1024
        private const val MAX_REMOTE_PATH_CHARS = 4_096
        private const val GLOBAL_SETTINGS_TIMEOUT_MS = 30_000L
    }
}

private class BoundedImageOutputStream(private val maximumBytes: Int) : OutputStream() {
    private val output = ByteArrayOutputStream()

    override fun write(value: Int) {
        checkCapacity(1)
        output.write(value)
    }

    override fun write(buffer: ByteArray, offset: Int, length: Int) {
        checkCapacity(length)
        output.write(buffer, offset, length)
    }

    fun toByteArray(): ByteArray = output.toByteArray()

    private fun checkCapacity(nextBytes: Int) {
        require(nextBytes >= 0 && output.size() <= maximumBytes - nextBytes) { "图片不能超过 20 MB" }
    }
}

private val SERVER_METRICS_SCRIPT = """
set -u

sample_cpu() {
  awk '/^cpu / {
    total=${'$'}2+${'$'}3+${'$'}4+${'$'}5+${'$'}6+${'$'}7+${'$'}8+${'$'}9
    idle=${'$'}5+${'$'}6
    printf "%.0f %.0f\n", total, idle
    exit
  }' /proc/stat 2>/dev/null
}

network_interface=${'$'}(awk '${'$'}2 == "00000000" { print ${'$'}1; exit }' /proc/net/route 2>/dev/null)
sample_network() {
  awk -v iface="${'$'}network_interface" '
    NR <= 2 { next }
    {
      split(${'$'}0, parts, ":")
      if (length(parts) < 2) next
      name=parts[1]
      gsub(/^[ \t]+|[ \t]+${'$'}/, "", name)
      data=parts[2]
      gsub(/^[ \t]+/, "", data)
      count=split(data, counters, /[ \t]+/)
      if (count < 9) next
      if (iface != "") {
        if (name == iface) {
          print counters[1], counters[9]
          found=1
          exit
        }
      } else if (name != "lo") {
        downloaded+=counters[1]
        uploaded+=counters[9]
        found=1
      }
    }
    END {
      if (iface == "" && found) print downloaded, uploaded
      else if (!found) print "-1 -1"
    }
  ' /proc/net/dev 2>/dev/null
}

read total_a idle_a <<EOF
${'$'}(sample_cpu)
EOF
read downloaded_a uploaded_a <<EOF
${'$'}(sample_network)
EOF
sleep 1
read total_b idle_b <<EOF
${'$'}(sample_cpu)
EOF
read downloaded_b uploaded_b <<EOF
${'$'}(sample_network)
EOF

cpu=-1
if [ "${'$'}{total_b:-0}" -gt "${'$'}{total_a:-0}" ]; then
  total_delta=${'$'}((total_b - total_a))
  idle_delta=${'$'}((idle_b - idle_a))
  cpu=${'$'}(( (total_delta - idle_delta) * 100 / total_delta ))
fi

download_speed=-1
upload_speed=-1
if [ "${'$'}{downloaded_a:-1}" -ge 0 ] && [ "${'$'}{downloaded_b:-1}" -ge "${'$'}{downloaded_a:-1}" ] && \
  [ "${'$'}{uploaded_a:-1}" -ge 0 ] && [ "${'$'}{uploaded_b:-1}" -ge "${'$'}{uploaded_a:-1}" ]; then
  download_speed=${'$'}((downloaded_b - downloaded_a))
  upload_speed=${'$'}((uploaded_b - uploaded_a))
fi

cpu_cores=${'$'}(awk '/^processor[[:space:]]*:/ { count++ } END { if (count > 0) print count; else print "--" }' /proc/cpuinfo 2>/dev/null)

memory=${'$'}(awk '
/^MemTotal:/ { total=${'$'}2 }
/^MemAvailable:/ { available=${'$'}2 }
/^MemFree:/ { free=${'$'}2 }
/^Buffers:/ { buffers=${'$'}2 }
/^Cached:/ { cached=${'$'}2 }
END {
  if (available == 0) available=free+buffers+cached
  if (total > 0) {
    used=total-available
    if (used < 0) used=0
    printf "%.0f|%.0f|%.0f", (used*100)/total, total, used
  } else print "-1|--|--"
}' /proc/meminfo 2>/dev/null)

disk=${'$'}(df -P -k / 2>/dev/null | awk 'NR == 2 { gsub("%", "", ${'$'}5); printf "%s|%s|%s", ${'$'}5, ${'$'}2, ${'$'}3; exit }')
memory_percent=${'$'}{memory%%|*}
memory_sizes=${'$'}{memory#*|}
memory_total=${'$'}{memory_sizes%%|*}
memory_used=${'$'}{memory_sizes#*|}
disk_percent=${'$'}{disk%%|*}
disk_sizes=${'$'}{disk#*|}
disk_total=${'$'}{disk_sizes%%|*}
disk_used=${'$'}{disk_sizes#*|}
printf "CODEX_METRICS|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
  "${'$'}cpu" "${'$'}{memory_percent:---}" "${'$'}{disk_percent:---}" \
  "${'$'}{memory_total:---}" "${'$'}{memory_used:---}" "${'$'}{cpu_cores:---}" \
  "${'$'}{disk_total:---}" "${'$'}{disk_used:---}" "${'$'}download_speed" "${'$'}upload_speed"
""".trimIndent()

internal fun parseServerMetrics(
    lines: List<String>,
    sampledAtEpochMillis: Long = System.currentTimeMillis(),
): ServerMetrics {
    val fields = lines.asReversed()
        .firstOrNull { it.trim().startsWith("CODEX_METRICS|") }
        ?.trim()
        ?.split('|')
    if (fields == null || fields.size < 4) {
        return ServerMetrics(sampledAtEpochMillis = sampledAtEpochMillis, error = "远端未返回资源数据")
    }

    fun parsePercent(value: String): Int? = value.toIntOrNull()
        ?.takeIf { it >= 0 }
        ?.coerceIn(0, 100)
    fun parseCoreCount(value: String): Int? = value.toIntOrNull()?.takeIf { it > 0 }
    fun parseKiB(value: String): Long? = value.toLongOrNull()?.takeIf { it >= 0L }

    val memoryTotalKiB = fields.getOrNull(4)?.let(::parseKiB)
    val memoryUsedKiB = fields.getOrNull(5)?.let(::parseKiB)
        ?.takeIf { used -> memoryTotalKiB == null || used <= memoryTotalKiB }
    val diskTotalKiB = fields.getOrNull(7)?.let(::parseKiB)
    val diskUsedKiB = fields.getOrNull(8)?.let(::parseKiB)
        ?.takeIf { used -> diskTotalKiB == null || used <= diskTotalKiB }
    val networkDownloadBytesPerSecond = fields.getOrNull(9)?.let(::parseKiB)
    val networkUploadBytesPerSecond = fields.getOrNull(10)?.let(::parseKiB)

    return ServerMetrics(
        cpuPercent = parsePercent(fields[1]),
        cpuCoreCount = fields.getOrNull(6)?.let(::parseCoreCount),
        memoryPercent = parsePercent(fields[2]),
        diskPercent = parsePercent(fields[3]),
        memoryTotalKiB = memoryTotalKiB,
        memoryUsedKiB = memoryUsedKiB,
        diskTotalKiB = diskTotalKiB,
        diskUsedKiB = diskUsedKiB,
        networkDownloadBytesPerSecond = networkDownloadBytesPerSecond,
        networkUploadBytesPerSecond = networkUploadBytesPerSecond,
        sampledAtEpochMillis = sampledAtEpochMillis,
    )
}

internal fun parseInstallProgress(value: String): RemoteInstallProgress {
    val parts = value.split('|', limit = 4)
    val percent = parts.firstOrNull()?.toIntOrNull()?.coerceIn(0, 100) ?: 0
    if (parts.size == 4) {
        val downloadPercent = parts[1].trim().toIntOrNull()?.coerceIn(0, 100)
        val message = parts[2].trim().ifBlank { value.trim() }
        val detail = parts[3].trim()
        return RemoteInstallProgress(percent, message, detail, downloadPercent)
    }
    val message = value.substringAfter('|', missingDelimiterValue = "").trim().ifBlank { value.trim() }
    return RemoteInstallProgress(percent, message)
}

internal suspend fun runCancellableConnect(
    connect: () -> Unit,
    disconnect: () -> Unit,
) {
    suspendCancellableCoroutine<Unit> { continuation ->
        continuation.invokeOnCancellation { runCatching { disconnect() } }
        if (!continuation.isActive) {
            runCatching { disconnect() }
            return@suspendCancellableCoroutine
        }
        try {
            connect()
            if (continuation.isActive) {
                continuation.resume(Unit)
            } else {
                runCatching { disconnect() }
            }
        } catch (error: Throwable) {
            runCatching { disconnect() }
            if (continuation.isActive) continuation.resumeWithException(error)
        }
    }
}

internal suspend fun readBoundedJsonLines(
    reader: Reader,
    maxLineChars: Int,
    onLine: suspend (String) -> Unit,
    onOversizedLine: suspend (prefix: String) -> Unit,
) {
    require(maxLineChars > 0)
    reader.use {
        val buffer = CharArray(8 * 1024)
        var line = StringBuilder(minOf(maxLineChars, 8 * 1024))
        var prefix = StringBuilder(minOf(maxLineChars, MAX_OVERSIZED_JSON_PREFIX_CHARS))
        var discarding = false
        suspend fun finishLine() {
            if (discarding) {
                onOversizedLine(prefix.toString().trimEnd('\r'))
            } else {
                onLine(line.toString().trimEnd('\r'))
            }
            line = StringBuilder(minOf(maxLineChars, 8 * 1024))
            prefix = StringBuilder(minOf(maxLineChars, MAX_OVERSIZED_JSON_PREFIX_CHARS))
            discarding = false
        }
        while (true) {
            val count = it.read(buffer)
            if (count < 0) break
            for (index in 0 until count) {
                val character = buffer[index]
                if (character == '\n') {
                    finishLine()
                } else {
                    if (prefix.length < MAX_OVERSIZED_JSON_PREFIX_CHARS) prefix.append(character)
                    if (!discarding && line.length < maxLineChars) {
                        line.append(character)
                    } else if (!discarding && character == '\r' && line.length == maxLineChars) {
                        line.append(character)
                    } else if (!discarding) {
                        line = StringBuilder()
                        discarding = true
                    }
                }
            }
        }
        if (discarding || line.isNotEmpty()) finishLine()
    }
}

internal data class JsonRpcEnvelopeHint(
    val id: String?,
    val idIsString: Boolean,
    val hasMethod: Boolean,
)

/** Reads only complete top-level fields present in a retained oversized-line prefix. */
internal fun inspectJsonRpcEnvelopePrefix(value: String): JsonRpcEnvelopeHint {
    var index = value.skipJsonWhitespace(0)
    if (value.getOrNull(index) != '{') return JsonRpcEnvelopeHint(null, false, false)
    index += 1
    var id: String? = null
    var idIsString = false
    var hasMethod = false
    while (index < value.length) {
        index = value.skipJsonWhitespace(index)
        when (value.getOrNull(index)) {
            '}' -> break
            ',' -> {
                index += 1
                continue
            }
        }
        val key = value.parseJsonString(index) ?: break
        index = value.skipJsonWhitespace(key.nextIndex)
        if (value.getOrNull(index) != ':') break
        index = value.skipJsonWhitespace(index + 1)
        if (key.value == "method") hasMethod = true
        if (key.value == "id") {
            value.parseJsonRpcId(index)?.let { parsed ->
                id = parsed.value
                idIsString = parsed.isString
            }
        }
        index = value.skipJsonValue(index) ?: break
    }
    return JsonRpcEnvelopeHint(id, idIsString, hasMethod)
}

private data class ParsedJsonString(val value: String, val nextIndex: Int)

private fun String.parseJsonString(start: Int): ParsedJsonString? {
    if (getOrNull(start) != '"') return null
    var escaped = false
    var index = start + 1
    while (index < length) {
        val character = this[index]
        if (!escaped && character == '"') {
            val token = substring(start, index + 1)
            val decoded = runCatching { Json.parseToJsonElement(token).jsonPrimitive.content }.getOrNull()
                ?: return null
            return ParsedJsonString(decoded, index + 1)
        }
        escaped = !escaped && character == '\\'
        if (character != '\\') escaped = false
        index += 1
    }
    return null
}

private data class ParsedJsonRpcId(val value: String, val isString: Boolean)

private fun String.parseJsonRpcId(start: Int): ParsedJsonRpcId? {
    parseJsonString(start)?.let { return ParsedJsonRpcId(it.value, true) }
    var end = start
    while (end < length && this[end] !in charArrayOf(',', '}', ' ', '\t', '\r', '\n')) end += 1
    return substring(start, end).takeIf { it.matches(Regex("-?(0|[1-9][0-9]*)")) }
        ?.let { ParsedJsonRpcId(it, false) }
}

private fun String.skipJsonWhitespace(start: Int): Int {
    var index = start
    while (index < length && this[index].isWhitespace()) index += 1
    return index
}

private fun String.skipJsonValue(start: Int): Int? {
    val first = getOrNull(start) ?: return null
    if (first == '"') return parseJsonString(start)?.nextIndex
    if (first != '{' && first != '[') {
        var index = start
        while (index < length && this[index] != ',' && this[index] != '}') index += 1
        return index
    }
    val closes = ArrayDeque<Char>()
    closes.addLast(if (first == '{') '}' else ']')
    var inString = false
    var escaped = false
    var index = start + 1
    while (index < length) {
        val character = this[index]
        if (inString) {
            if (!escaped && character == '"') inString = false
            escaped = !escaped && character == '\\'
            if (character != '\\') escaped = false
        } else {
            when (character) {
                '"' -> inString = true
                '{' -> closes.addLast('}')
                '[' -> closes.addLast(']')
                '}', ']' -> {
                    if (closes.isEmpty() || closes.removeLast() != character) return null
                    if (closes.isEmpty()) return index + 1
                }
            }
        }
        index += 1
    }
    return null
}

private const val MAX_OVERSIZED_JSON_PREFIX_CHARS = 64 * 1024
