package top.asdb.agent

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.system.Os
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.tukaani.xz.XZInputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.URL
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal data class ProotProcessSpec(
    val command: List<String>,
    val environment: Map<String, String>,
)

internal fun buildProotProcessSpec(
    nativeDirectory: File,
    rootfs: File,
    temp: File,
    guestCommand: List<String>,
): ProotProcessSpec {
    val proot = File(nativeDirectory, "libproot.so")
    val loader = File(nativeDirectory, "libproot-loader.so")
    check(proot.canExecute() && loader.isFile) { "APK 中缺少 ARM64 PRoot 运行时" }
    return ProotProcessSpec(
        command = buildList {
            add(proot.absolutePath)
            add("--link2symlink")
            add("--kill-on-exit")
            add("--root-id")
            add("--rootfs=${rootfs.absolutePath}")
            add("--cwd=/root")
            add("--bind=/dev")
            add("--bind=/proc")
            add("--bind=/sys")
            add("/usr/bin/env")
            add("-i")
            add("HOME=/root")
            add("LANG=C.UTF-8")
            add("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            add("TERM=xterm-256color")
            add("TMPDIR=/tmp")
            addAll(guestCommand)
        },
        environment = mapOf(
            "PROOT_LOADER" to loader.absolutePath,
            "PROOT_TMP_DIR" to temp.absolutePath,
            "LD_LIBRARY_PATH" to nativeDirectory.absolutePath,
        ),
    )
}

/** Owns the experimental PRoot Debian instance and its loopback-only SSH server. */
object LocalLinuxManager {
    private const val CHANNEL = "top.asdb.agent/local_linux"
    private const val ROOTFS_VERSION = "debian-trixie-pd-v4.37.0"
    private const val ROOTFS_URL =
        "https://easycli.sh/proot-distro/debian-trixie-aarch64-pd-v4.37.0.tar.xz"
    private const val ROOTFS_SHA256 =
        "9bd3b19ff7cd300c7c7bf33124b726eb199f4bab9a3b1472f34749c6d12c9195"
    private const val ROOTFS_MAX_BYTES = 48L * 1024L * 1024L
    private const val ROOTFS_EXPECTED_BYTES = 35_401_288L
    private const val PROCESS_OUTPUT_LIMIT = 256 * 1024
    private const val INSTALL_TIMEOUT_MINUTES = 20L
    private const val START_TIMEOUT_SECONDS = 20L
    private const val PREFS_NAME = "local_linux_runtime_secure"
    private const val KEY_PASSWORD = "password"
    private const val KEY_PORT = "port"
    private const val KEY_CREDENTIALS_VERSION = "credentials_version"

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val operationActive = AtomicBoolean(false)
    private val lock = Any()
    private var securePreferences: SharedPreferences? = null
    private var channel: MethodChannel? = null
    private var sshProcess: Process? = null

    fun register(context: Context, engine: FlutterEngine) {
        val appContext = context.applicationContext
        val next = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        next.setMethodCallHandler { call, result -> handleCall(appContext, call, result) }
        channel = next
    }

    private fun handleCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status(context))
            "installAndStart" -> runOperation(result) { installAndStart(context) }
            "stop" -> runOperation(result) {
                stopProcess()
                null
            }
            "uninstall" -> runOperation(result) {
                stopProcess()
                deleteTreeNoFollow(runtimeDirectory(context).toPath())
                preferences(context).edit().clear().commit()
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun runOperation(
        result: MethodChannel.Result,
        operation: () -> Any?,
    ) {
        if (!operationActive.compareAndSet(false, true)) {
            result.error("local_linux_busy", "本机 Linux 正在执行另一项操作", null)
            return
        }
        executor.execute {
            val outcome = runCatching(operation)
            operationActive.set(false)
            mainHandler.post {
                outcome.onSuccess(result::success).onFailure { error ->
                    DiagnosticLogBridge.append(
                        "WARN",
                        "LocalLinux",
                        "operation_failed detail=${error.message.orEmpty().take(180)}",
                        error,
                    )
                    result.error(
                        "local_linux_failed",
                        error.message ?: "本机 Linux 操作失败",
                        null,
                    )
                }
            }
        }
    }

    private fun status(context: Context): Map<String, Any?> {
        val supported = supportedArchitecture()
        val installed = installedRootfs(context) != null
        val running = synchronized(lock) { sshProcess?.isAlive == true }
        val prefs = preferences(context)
        return linkedMapOf(
            "supported" to supported,
            "installed" to installed,
            "running" to running,
            "port" to if (running) prefs.getInt(KEY_PORT, 0) else 0,
            "password" to if (running) prefs.getString(KEY_PASSWORD, "").orEmpty() else "",
            "architecture" to Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
            "rootfsVersion" to ROOTFS_VERSION,
            "message" to when {
                !supported -> "目前仅支持 ARM64 Android 设备"
                running -> "本机 Linux 正在运行"
                installed -> "本机 Linux 已安装"
                else -> "首次使用需下载约 35 MB"
            },
        )
    }

    private fun installAndStart(context: Context): Map<String, Any?> {
        check(supportedArchitecture()) { "目前仅支持 ARM64 Android 设备" }
        val existing = synchronized(lock) { sshProcess?.takeIf { it.isAlive } }
        if (existing != null) return status(context)

        var rootfs = installedRootfs(context)
        if (rootfs == null) {
            publishProgress("installing", 2, "正在准备 Debian 下载")
            rootfs = installRootfs(context)
        }
        publishProgress("starting", 92, "正在启动本机 SSH")
        val credentials = ensureCredentials(context)
        configureSsh(context, rootfs, credentials)
        val process = startSsh(context, rootfs)
        synchronized(lock) { sshProcess = process }
        try {
            waitForPort(credentials.port, process)
        } catch (error: Throwable) {
            synchronized(lock) {
                if (sshProcess === process) sshProcess = null
            }
            throw error
        }
        publishProgress("running", 100, "本机 Linux 正在运行", installed = true)
        DiagnosticLogBridge.append(
            "INFO",
            "LocalLinux",
            "started port=${credentials.port} rootfs=$ROOTFS_VERSION",
        )
        return status(context)
    }

    private fun installRootfs(context: Context): File {
        val runtime = runtimeDirectory(context)
        runtime.mkdirs()
        val archive = File(runtime, "rootfs.tar.xz.part")
        val staging = File(runtime, "rootfs.staging")
        deleteTreeNoFollow(staging.toPath())
        try {
            downloadRootfs(archive)
            publishProgress("installing", 46, "正在校验 Debian 文件")
            check(sha256(archive).equals(ROOTFS_SHA256, ignoreCase = true)) {
                "Debian 文件校验失败，请重试"
            }
            staging.mkdirs()
            extractRootfs(archive, staging)
            prepareRootfsFiles(staging)
            publishProgress("installing", 72, "正在安装 SSH、Git 和下载工具")
            installRequiredPackages(context, staging)
            File(staging, ".agent-rootfs-version").writeText(ROOTFS_VERSION)
            val target = File(runtime, "rootfs")
            deleteTreeNoFollow(target.toPath())
            check(staging.renameTo(target)) { "无法提交 Debian 安装目录" }
            archive.delete()
            return target
        } catch (error: Throwable) {
            deleteTreeNoFollow(staging.toPath())
            archive.delete()
            throw error
        }
    }

    private fun downloadRootfs(target: File) {
        val connection = URL(ROOTFS_URL).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 20_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("Accept-Encoding", "identity")
        try {
            connection.connect()
            check(connection.responseCode in 200..299) {
                "Debian 下载失败（HTTP ${connection.responseCode}）"
            }
            val declared = connection.contentLengthLong.takeIf { it > 0 }
            val progressTotal = declared ?: ROOTFS_EXPECTED_BYTES
            check(progressTotal <= ROOTFS_MAX_BYTES) { "Debian 下载文件超过大小限制" }
            var downloaded = 0L
            BufferedInputStream(connection.inputStream).use { input ->
                BufferedOutputStream(FileOutputStream(target)).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var lastPercent = -1
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        downloaded += count
                        check(downloaded <= ROOTFS_MAX_BYTES) {
                            "Debian 下载文件超过大小限制"
                        }
                        output.write(buffer, 0, count)
                        val percent =
                            4 + ((downloaded * 40 / progressTotal).coerceIn(0, 40)).toInt()
                        if (percent != lastPercent) {
                            lastPercent = percent
                            publishProgress(
                                "installing",
                                percent,
                                "正在下载 Debian",
                                downloadedBytes = downloaded,
                                totalBytes = progressTotal,
                            )
                        }
                    }
                }
            }
            check(downloaded > 0) { "Debian 下载内容为空" }
            check(declared == null || downloaded == declared) {
                "Debian 下载中断（已接收 $downloaded / $declared 字节），请重试"
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun extractRootfs(archive: File, staging: File) {
        val stagingPath = staging.toPath().toAbsolutePath().normalize()
        var extractedBytes = 0L
        var entries = 0
        TarArchiveInputStream(XZInputStream(BufferedInputStream(FileInputStream(archive)))).use { tar ->
            while (true) {
                val entry = tar.nextEntry as? TarArchiveEntry ?: break
                val relative = strippedArchivePath(entry.name) ?: continue
                val target = stagingPath.resolve(relative).normalize()
                check(target.startsWith(stagingPath)) { "Debian 归档包含越界路径" }
                checkNoSymlinkParent(stagingPath, target.parent)
                when {
                    entry.isDirectory -> Files.createDirectories(target)
                    entry.isSymbolicLink -> {
                        Files.createDirectories(target.parent)
                        Files.deleteIfExists(target)
                        Files.createSymbolicLink(target, Paths.get(entry.linkName))
                    }
                    entry.isLink -> error("Debian 归档包含不支持的硬链接")
                    entry.isFile -> {
                        extractedBytes += entry.size
                        check(extractedBytes <= 256L * 1024L * 1024L) {
                            "Debian 解压内容超过大小限制"
                        }
                        Files.createDirectories(target.parent)
                        BufferedOutputStream(Files.newOutputStream(target)).use { output ->
                            tar.copyTo(output, 64 * 1024)
                        }
                        runCatching { Os.chmod(target.toString(), entry.mode and 0x1ff) }
                    }
                    else -> error("Debian 归档包含不支持的文件类型")
                }
                entries++
                if (entries % 250 == 0) {
                    val percent = 48 + (entries / 250).coerceAtMost(20)
                    publishProgress("installing", percent, "正在解压 Debian")
                }
            }
        }
        check(File(staging, "etc").isDirectory && File(staging, "usr/bin/env").isFile) {
            "Debian 文件结构无效"
        }
    }

    private fun prepareRootfsFiles(rootfs: File) {
        File(rootfs, "root/workspace").mkdirs()
        File(rootfs, "tmp").mkdirs()
        File(rootfs, "run/sshd").mkdirs()
        File(rootfs, "etc/resolv.conf").writeText("nameserver 1.1.1.1\nnameserver 8.8.8.8\n")
        File(rootfs, "etc/hosts").writeText("127.0.0.1 localhost\n::1 localhost\n")
        File(rootfs, "etc/environment").appendText(
            "\nLANG=C.UTF-8\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n",
        )
    }

    private fun installRequiredPackages(context: Context, rootfs: File) {
        val command = listOf(
            "/bin/sh",
            "-lc",
            "export DEBIAN_FRONTEND=noninteractive; " +
                "apt-get update && " +
                "apt-get install -y --no-install-recommends openssh-server curl git ca-certificates xz-utils && " +
                "apt-get clean && rm -rf /var/lib/apt/lists/*",
        )
        runProot(context, rootfs, command, INSTALL_TIMEOUT_MINUTES, TimeUnit.MINUTES)
    }

    private fun configureSsh(context: Context, rootfs: File, credentials: Credentials) {
        File(rootfs, "run/sshd").mkdirs()
        val config = File(rootfs, "etc/ssh/sshd_config.agent")
        check(File(rootfs, "usr/sbin/sshd").isFile) { "Debian SSH 服务尚未安装" }
        config.parentFile?.mkdirs()
        config.writeText(
            "Port ${credentials.port}\n" +
                "ListenAddress 127.0.0.1\n" +
                "HostKey /etc/ssh/ssh_host_ed25519_key\n" +
                "PasswordAuthentication yes\n" +
                "PermitRootLogin yes\n" +
                "UsePAM no\n" +
                "PrintMotd no\n" +
                "PidFile /run/sshd-agent.pid\n" +
                "Subsystem sftp internal-sftp\n" +
                "AllowTcpForwarding no\n" +
                "X11Forwarding no\n",
        )
        runProot(
            context,
            rootfs,
            listOf("/bin/sh", "-lc", "ssh-keygen -A && chpasswd"),
            2,
            TimeUnit.MINUTES,
            stdin = "root:${credentials.password}\n",
        )
    }

    private fun startSsh(context: Context, rootfs: File): Process {
        val process = prootProcessBuilder(
            context,
            rootfs,
            listOf("/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config.agent"),
        )
            .redirectErrorStream(true)
            .start()
        Thread {
            drainProcessOutput(process, "sshd")
        }.apply {
            name = "local-linux-sshd-output"
            isDaemon = true
            start()
        }
        return process
    }

    private fun runProot(
        context: Context,
        rootfs: File,
        guestCommand: List<String>,
        timeout: Long,
        unit: TimeUnit,
        stdin: String? = null,
    ): String {
        val process = prootProcessBuilder(context, rootfs, guestCommand)
            .redirectErrorStream(true)
            .start()
        if (stdin != null) {
            process.outputStream.bufferedWriter().use { it.write(stdin) }
        } else {
            process.outputStream.close()
        }
        val output = StringBuilder()
        val reader = executorForOutput(process, output)
        if (!process.waitFor(timeout, unit)) {
            process.destroy()
            process.waitFor(2, TimeUnit.SECONDS)
            if (process.isAlive) process.destroyForcibly()
            error("Debian 准备超时")
        }
        reader.join(2_000)
        check(process.exitValue() == 0) {
            "Debian 准备失败：${output.toString().takeLast(800)}"
        }
        return output.toString()
    }

    private fun prootProcessBuilder(
        context: Context,
        rootfs: File,
        guestCommand: List<String>,
    ): ProcessBuilder {
        val nativeDirectory = File(context.applicationInfo.nativeLibraryDir)
        val temp = File(runtimeDirectory(context), "proot-tmp").apply { mkdirs() }
        val spec = buildProotProcessSpec(nativeDirectory, rootfs, temp, guestCommand)
        return ProcessBuilder(spec.command).apply {
            environment().putAll(spec.environment)
        }
    }

    private fun waitForPort(port: Int, process: Process) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(START_TIMEOUT_SECONDS)
        while (System.nanoTime() < deadline) {
            check(process.isAlive) { "本机 SSH 启动后立即退出" }
            runCatching {
                java.net.Socket().use { socket ->
                    socket.connect(java.net.InetSocketAddress("127.0.0.1", port), 300)
                }
            }.onSuccess { return }
            Thread.sleep(150)
        }
        process.destroyForcibly()
        error("等待本机 SSH 启动超时")
    }

    private fun ensureCredentials(context: Context): Credentials {
        val prefs = preferences(context)
        val currentVersion = prefs.getString(KEY_CREDENTIALS_VERSION, null)
        val credentialsCurrent = currentVersion == ROOTFS_VERSION
        val password = if (credentialsCurrent) {
            prefs.getString(KEY_PASSWORD, null)?.takeIf { it.length >= 24 }
        } else {
            null
        } ?: randomHex(24)
        var port = if (credentialsCurrent) {
            prefs.getInt(KEY_PORT, 0).takeIf { it in 1024..65535 }
        } else {
            null
        } ?: 0
        if (port == 0 || !portAvailable(port)) port = ServerSocket(0).use { it.localPort }
        check(
            prefs.edit()
                .putString(KEY_PASSWORD, password)
                .putInt(KEY_PORT, port)
                .putString(KEY_CREDENTIALS_VERSION, ROOTFS_VERSION)
                .commit(),
        ) {
            "无法保存本机 Linux 凭据"
        }
        return Credentials(port, password)
    }

    private fun preferences(context: Context): SharedPreferences = synchronized(lock) {
        securePreferences ?: run {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            ).also { securePreferences = it }
        }
    }

    private fun installedRootfs(context: Context): File? {
        val rootfs = File(runtimeDirectory(context), "rootfs")
        val marker = File(rootfs, ".agent-rootfs-version")
        return rootfs.takeIf { marker.readTextOrNull() == ROOTFS_VERSION }
    }

    private fun runtimeDirectory(context: Context) = File(context.filesDir, "local-linux")

    private fun stopProcess() {
        val process = synchronized(lock) {
            val current = sshProcess
            sshProcess = null
            current
        } ?: return
        process.destroy()
        process.waitFor(2, TimeUnit.SECONDS)
        if (process.isAlive) process.destroyForcibly()
        DiagnosticLogBridge.append("INFO", "LocalLinux", "stopped")
    }

    private fun publishProgress(
        phase: String,
        percent: Int,
        message: String,
        downloadedBytes: Long = 0,
        totalBytes: Long? = null,
        installed: Boolean = false,
    ) {
        val payload = linkedMapOf<String, Any?>(
            "phase" to phase,
            "percent" to percent.coerceIn(0, 100),
            "message" to message,
            "downloadedBytes" to downloadedBytes.coerceAtLeast(0),
            "totalBytes" to totalBytes,
            "installed" to installed,
        )
        mainHandler.post { channel?.invokeMethod("progress", payload) }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { byte ->
            (byte.toInt() and 0xff).toString(16).padStart(2, '0')
        }
    }

    private fun strippedArchivePath(name: String): String? {
        val normalized = name.replace('\\', '/').trimStart('/')
        val slash = normalized.indexOf('/')
        if (slash < 0 || slash == normalized.length - 1) return null
        val relative = normalized.substring(slash + 1)
        check(relative.split('/').none { it == ".." }) { "Debian 归档路径无效" }
        return relative
    }

    private fun checkNoSymlinkParent(root: Path, parent: Path?) {
        var current = parent ?: return
        while (current != root) {
            check(!Files.isSymbolicLink(current)) { "Debian 归档尝试写入符号链接目录" }
            current = current.parent ?: break
        }
    }

    private fun deleteTreeNoFollow(path: Path) {
        if (!Files.exists(path, java.nio.file.LinkOption.NOFOLLOW_LINKS)) return
        Files.walkFileTree(path, object : SimpleFileVisitor<Path>() {
            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                Files.deleteIfExists(file)
                return FileVisitResult.CONTINUE
            }

            override fun postVisitDirectory(dir: Path, error: java.io.IOException?): FileVisitResult {
                if (error != null) throw error
                Files.deleteIfExists(dir)
                return FileVisitResult.CONTINUE
            }
        })
    }

    private fun executorForOutput(process: Process, output: StringBuilder): Thread = Thread {
        process.inputStream.bufferedReader().useLines { lines ->
            lines.forEach { line ->
                if (output.length < PROCESS_OUTPUT_LIMIT) {
                    output.append(line.take(2_000)).append('\n')
                }
            }
        }
    }.apply {
        isDaemon = true
        start()
    }

    private fun drainProcessOutput(process: Process, label: String) {
        val tail = ArrayDeque<String>()
        process.inputStream.bufferedReader().useLines { lines ->
            lines.forEach { line ->
                if (tail.size >= 12) tail.removeFirst()
                tail.addLast(line.take(400))
            }
        }
        val expected = synchronized(lock) { sshProcess === process }
        if (expected) {
            synchronized(lock) { if (sshProcess === process) sshProcess = null }
            DiagnosticLogBridge.append(
                "WARN",
                "LocalLinux",
                "$label exited code=${runCatching { process.exitValue() }.getOrDefault(-1)} " +
                    "tail=${tail.joinToString(" | ").take(1_200)}",
            )
        }
    }

    private fun supportedArchitecture(): Boolean =
        Build.SUPPORTED_ABIS.any { it == "arm64-v8a" }

    private fun randomHex(bytes: Int): String = ByteArray(bytes).also(SecureRandom()::nextBytes)
        .joinToString("") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') }

    private fun portAvailable(port: Int): Boolean = runCatching { ServerSocket(port).use {} }.isSuccess

    private fun File.readTextOrNull(): String? = runCatching { readText().trim() }.getOrNull()

    private data class Credentials(val port: Int, val password: String)
}
