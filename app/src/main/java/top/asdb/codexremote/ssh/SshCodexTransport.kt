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
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import top.asdb.codexremote.data.AuthMode
import top.asdb.codexremote.data.RemoteDirectory
import top.asdb.codexremote.data.RemoteDirectoryListing
import top.asdb.codexremote.data.ServerProfile
import java.io.BufferedReader
import java.io.ByteArrayInputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.UUID

class SshCodexTransport {
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var session: Session? = null
    private var channel: ChannelExec? = null
    private var writer: OutputStream? = null
    private var readerJob: Job? = null
    private val writeMutex = Mutex()

    private val _lines = MutableSharedFlow<String>(extraBufferCapacity = 256)
    val lines: SharedFlow<String> = _lines.asSharedFlow()

    private val _diagnostics = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val diagnostics: SharedFlow<String> = _diagnostics.asSharedFlow()

    private val _closed = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val closed: SharedFlow<String> = _closed.asSharedFlow()

    suspend fun probeFingerprint(profile: ServerProfile): String = withContext(Dispatchers.IO) {
        require(profile.host.isNotBlank()) { "请输入服务器地址" }
        require(profile.username.isNotBlank()) { "请输入用户名" }
        val capture = FingerprintCaptureHostKeyRepository()
        val probe = JSch().apply { hostKeyRepository = capture }
            .getSession(profile.username, profile.host, profile.port)
        probe.setConfig("StrictHostKeyChecking", "yes")
        probe.timeout = CONNECT_TIMEOUT_MS
        try {
            try {
                probe.connect(CONNECT_TIMEOUT_MS)
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

    suspend fun connect(profile: ServerProfile) = withContext(Dispatchers.IO) {
        disconnect()
        require(profile.host.isNotBlank()) { "服务器地址不能为空" }
        require(profile.username.isNotBlank()) { "用户名不能为空" }
        require(profile.hostFingerprint.isNotBlank()) { "请先核对并保存 SSH 主机指纹" }
        require(profile.remoteCommand.isNotBlank()) { "Codex 远程命令不能为空" }

        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        var sshSession: Session? = null
        var exec: ChannelExec? = null
        try {
            val jsch = JSch().apply {
                hostKeyRepository = PinnedHostKeyRepository(profile.hostFingerprint)
                when (profile.authMode) {
                    AuthMode.Password -> Unit
                    AuthMode.PrivateKey -> {
                        require(profile.privateKeyPem.isNotBlank()) { "请选择 SSH 私钥" }
                        addIdentity(
                            profile.name,
                            profile.privateKeyPem.toByteArray(),
                            null,
                            profile.privateKeyPassphrase.takeIf { it.isNotEmpty() }?.toByteArray(),
                        )
                    }
                }
            }
            sshSession = jsch.getSession(profile.username, profile.host, profile.port).apply {
                setConfig("StrictHostKeyChecking", "yes")
                setConfig(
                    "PreferredAuthentications",
                    if (profile.authMode == AuthMode.Password) "password,keyboard-interactive" else "publickey",
                )
                if (profile.authMode == AuthMode.Password) {
                    require(profile.password.isNotEmpty()) { "密码不能为空" }
                    setPassword(profile.password)
                }
                serverAliveInterval = 15_000
                serverAliveCountMax = 3
                timeout = CONNECT_TIMEOUT_MS
            }
            val connectedSession = requireNotNull(sshSession)
            connectedSession.connect(CONNECT_TIMEOUT_MS)

            val stderrIn = PipedInputStream(16 * 1024)
            val stderrOut = PipedOutputStream(stderrIn)
            val connectedExec = connectedSession.openChannel("exec") as ChannelExec
            exec = connectedExec
            connectedExec.setPty(false)
            connectedExec.setCommand(profile.remoteCommand)
            connectedExec.setErrStream(stderrOut)
            val stdout = connectedExec.inputStream
            val stdin = connectedExec.outputStream
            connectedExec.connect(CHANNEL_TIMEOUT_MS)

            session = sshSession
            channel = exec
            writer = stdin

            readerJob = scope.launch {
                runCatching {
                    BufferedReader(InputStreamReader(stdout, Charsets.UTF_8)).useLines { sequence ->
                        sequence.forEach { _lines.emit(it) }
                    }
                }.onFailure { _diagnostics.emit(it.message ?: "SSH 输出流异常") }
                _closed.emit("Codex SSH 通道已关闭")
            }
            scope.launch {
                BufferedReader(InputStreamReader(stderrIn, Charsets.UTF_8)).useLines { sequence ->
                    sequence.forEach { line -> if (line.isNotBlank()) _diagnostics.emit(line) }
                }
            }
        } catch (error: Throwable) {
            exec?.disconnect()
            sshSession?.disconnect()
            scope.cancel()
            throw error
        }
    }

    suspend fun sendLine(line: String) = withContext(Dispatchers.IO) {
        writeMutex.withLock {
            val output = writer ?: throw IllegalStateException("SSH 通道尚未连接")
            output.write(line.toByteArray(Charsets.UTF_8))
            output.write('\n'.code)
            output.flush()
        }
    }

    suspend fun listDirectories(path: String?): RemoteDirectoryListing = withContext(Dispatchers.IO) {
        val sshSession = session ?: throw IllegalStateException("SSH 通道尚未连接")
        val sftp = sshSession.openChannel("sftp") as ChannelSftp
        sftp.connect(CHANNEL_TIMEOUT_MS)
        try {
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
            val sshSession = session ?: throw IllegalStateException("SSH 通道尚未连接")
            val sftp = sshSession.openChannel("sftp") as ChannelSftp
            sftp.connect(CHANNEL_TIMEOUT_MS)
            try {
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

    fun isConnected(): Boolean = session?.isConnected == true && channel?.isConnected == true

    suspend fun disconnect() = withContext(Dispatchers.IO) {
        readerJob?.cancel()
        writer?.runCatching { close() }
        channel?.disconnect()
        session?.disconnect()
        writer = null
        channel = null
        session = null
        scope.cancel()
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
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val CHANNEL_TIMEOUT_MS = 10_000
    }
}
