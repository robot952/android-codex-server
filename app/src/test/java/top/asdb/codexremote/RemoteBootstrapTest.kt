package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.ssh.RemoteBootstrap
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class RemoteBootstrapTest {
    @Test
    fun `probe parser finds compatible managed install`() {
        val environment = RemoteBootstrap.parseProbe(
            listOf(
                "__CODEX_REMOTE_OS=Linux",
                "__CODEX_REMOTE_ARCH=x86_64",
                "__CODEX_REMOTE_HOME=/home/dev",
                "__CODEX_REMOTE_LIBC=glibc",
                "__CODEX_REMOTE_MANAGED_PATH=/home/dev/.local/bin/codex-remote",
                "__CODEX_REMOTE_MANAGED_VERSION=codex-cli 0.144.6",
                "__CODEX_REMOTE_HAS_SHELL=1",
                "__CODEX_REMOTE_HAS_TAR=1",
                "__CODEX_REMOTE_HAS_SHA256=1",
                "__CODEX_REMOTE_HAS_FLOCK=1",
                "__CODEX_REMOTE_HAS_SETSID_WAIT=1",
                "__CODEX_REMOTE_DOWNLOADER=curl",
            ),
        )

        assertEquals(
            "'/home/dev/.local/bin/codex-remote' app-server --listen stdio://",
            environment.compatibleCommand("0.144.6"),
        )
        val endpoint = requireNotNull(environment.durableEndpoint("0.144.6"))
        assertEquals("/home/dev/.local/share/codex-remote/durable/app-server.sock", endpoint.socketPath)
        assertEquals("0.144.6", endpoint.expectedCliVersion)
        assertEquals(
            "'/home/dev/.local/bin/codex-remote' app-server proxy --sock " +
                "'/home/dev/.local/share/codex-remote/durable/app-server.sock'",
            endpoint.proxyCommand(),
        )
        assertNull(environment.installationProblem())
    }

    @Test
    fun `different system version requires isolated install`() {
        val environment = RemoteBootstrap.parseProbe(
            listOf(
                "__CODEX_REMOTE_OS=Linux",
                "__CODEX_REMOTE_ARCH=aarch64",
                "__CODEX_REMOTE_HOME=/root",
                "__CODEX_REMOTE_LIBC=glibc",
                "__CODEX_REMOTE_SYSTEM_PATH=/usr/local/bin/codex",
                "__CODEX_REMOTE_SYSTEM_VERSION=codex-cli 0.145.0-alpha.18",
                "__CODEX_REMOTE_HAS_SHELL=1",
                "__CODEX_REMOTE_HAS_TAR=1",
                "__CODEX_REMOTE_HAS_SHA256=1",
                "__CODEX_REMOTE_HAS_FLOCK=1",
                "__CODEX_REMOTE_HAS_SETSID_WAIT=1",
                "__CODEX_REMOTE_DOWNLOADER=wget",
            ),
        )

        assertNull(environment.compatibleCommand("0.144.6"))
        assertEquals("codex-cli 0.145.0-alpha.18", environment.detectedVersion())
        assertNull(environment.installationProblem())
    }

    @Test
    fun `installer is pinned and never requests system privileges`() {
        val script = RemoteBootstrap.installScript("0.144.6", "22.17.0")

        assertTrue(script.contains("@openai/codex@0.144.6"))
        assertTrue(script.contains("node-v22.17.0-linux-"))
        assertTrue(script.contains("0fa01328a0f3d10800623f7107fbcd654a60ec178fab1ef5b9779e94e0419e1a"))
        assertTrue(script.contains("3e99df8b01b27dc8b334a2a30d1cd500442b3b0877d217b308fd61a9ccfc33d4"))
        assertTrue(script.contains("\$HOME/.local/share/codex-remote"))
        assertTrue(script.contains("flock -n 9"))
        assertTrue(script.contains("trap cleanup EXIT"))
        assertTrue(script.contains("trap on_signal HUP INT TERM"))
        assertTrue(script.contains("SSH_PARENT=\"\${CODEX_REMOTE_SSH_PID:-\$PPID}\""))
        assertTrue(script.contains("kill -0 \"\$SSH_PARENT\""))
        assertTrue(script.contains("/proc/\$SSH_PARENT/stat"))
        assertTrue(script.contains("read -r _ _ PARENT_STATE _"))
        assertTrue(script.contains("\$PARENT_STATE\" != Z"))
        assertFalse(script.contains("cut -d"))
        assertTrue(script.contains("trap 'exit 0' USR1"))
        assertTrue(script.contains("trap '' HUP INT TERM"))
        assertTrue(script.contains("kill -TERM 0"))
        assertTrue(script.contains("kill -USR1 \"\$WATCHDOG_PID\""))
        assertFalse(script.contains("mkdir \"\$LOCK"))
        assertTrue(script.contains("bin/node\" --version"))
        assertTrue(script.contains("bin/npm\" --version"))
        assertTrue(script.contains("INSTALL_COMMITTED=1"))
        assertFalse(script.contains("rm -rf \"\$NODE_DIR\""))
        assertFalse(script.contains("rm -rf \"\$RELEASE\""))
        assertFalse(script.contains("sudo"))
        assertFalse(script.contains("/usr/local"))
    }

    @Test
    fun `missing flock blocks automatic installation`() {
        val environment = RemoteBootstrap.parseProbe(
            listOf(
                "__CODEX_REMOTE_OS=Linux",
                "__CODEX_REMOTE_ARCH=x86_64",
                "__CODEX_REMOTE_HOME=/home/dev",
                "__CODEX_REMOTE_LIBC=glibc",
                "__CODEX_REMOTE_HAS_SHELL=1",
                "__CODEX_REMOTE_HAS_TAR=1",
                "__CODEX_REMOTE_HAS_SHA256=1",
                "__CODEX_REMOTE_HAS_FLOCK=0",
                "__CODEX_REMOTE_HAS_SETSID_WAIT=1",
                "__CODEX_REMOTE_DOWNLOADER=curl",
            ),
        )

        assertTrue(environment.installationProblem().orEmpty().contains("flock"))
    }

    @Test
    fun `missing setsid wait blocks automatic installation`() {
        val environment = RemoteBootstrap.parseProbe(
            listOf(
                "__CODEX_REMOTE_OS=Linux",
                "__CODEX_REMOTE_ARCH=x86_64",
                "__CODEX_REMOTE_HOME=/home/dev",
                "__CODEX_REMOTE_LIBC=glibc",
                "__CODEX_REMOTE_HAS_SHELL=1",
                "__CODEX_REMOTE_HAS_TAR=1",
                "__CODEX_REMOTE_HAS_SHA256=1",
                "__CODEX_REMOTE_HAS_FLOCK=1",
                "__CODEX_REMOTE_HAS_SETSID_WAIT=0",
                "__CODEX_REMOTE_DOWNLOADER=curl",
            ),
        )

        assertTrue(environment.installationProblem().orEmpty().contains("setsid"))
        assertNull(environment.durableEndpoint("0.144.6"))
    }

    @Test
    fun `durable server script stays private and has valid posix syntax`() {
        val endpoint = top.asdb.codexremote.ssh.RemoteAppServerEndpoint(
            executable = "/home/dev/.local/bin/codex-remote",
            socketPath = "/home/dev/.local/share/codex-remote/durable/app-server.sock",
            expectedCliVersion = "0.144.6",
        )
        val script = RemoteBootstrap.durableServerScript(endpoint)

        assertTrue(script.contains("umask 077"))
        assertTrue(script.contains("flock -w 15 9"))
        assertTrue(script.contains("EXPECTED_VERSION='codex-cli 0.144.6'"))
        assertTrue(script.contains("Codex 版本不匹配"))
        assertTrue(script.contains("setsid sh -c"))
        assertTrue(script.contains("exec \"\$2\" app-server --listen \"\$3\""))
        assertTrue(script.contains("app-server.pid"))
        assertTrue(script.contains("app-server.version"))
        assertTrue(script.contains("后台运行目录不能是符号链接"))
        assertFalse(script.contains("ws://"))
        assertFalse(script.contains("sudo"))

        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use { it.write(script) }

        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
    }

    @Test
    fun `durable server refuses an executable whose version no longer matches the pin`() {
        val home = Files.createTempDirectory("codex-remote-durable-version").toFile()
        try {
            val executable = home.resolve("codex-remote")
            executable.writeText(
                """
                #!/bin/sh
                if [ "${'$'}{1:-}" = "--version" ]; then
                  printf '%s' 'codex-cli 0.145.0'
                  exit 0
                fi
                exit 1
                """.trimIndent(),
            )
            assertTrue(executable.setExecutable(true))
            val endpoint = top.asdb.codexremote.ssh.RemoteAppServerEndpoint(
                executable = executable.absolutePath,
                socketPath = home.resolve(".local/share/codex-remote/durable/app-server.sock").absolutePath,
                expectedCliVersion = "0.144.6",
            )
            val process = ProcessBuilder("sh", "-s").start()
            process.outputStream.bufferedWriter().use {
                it.write(RemoteBootstrap.durableServerScript(endpoint))
            }

            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(65, process.exitValue())
            assertTrue(process.errorStream.bufferedReader().readText().contains("Codex 版本不匹配"))
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `managed command comparison permits form whitespace only`() {
        assertTrue(RemoteBootstrap.isManagedRemoteCommand(RemoteBootstrap.MANAGED_REMOTE_COMMAND))
        assertTrue(RemoteBootstrap.isManagedRemoteCommand("  ${RemoteBootstrap.MANAGED_REMOTE_COMMAND}  "))
        assertFalse(RemoteBootstrap.isManagedRemoteCommand("codex app-server --listen stdio://"))
    }

    @Test
    fun `musl host is rejected before downloading glibc runtime`() {
        val environment = RemoteBootstrap.parseProbe(
            listOf(
                "__CODEX_REMOTE_OS=Linux",
                "__CODEX_REMOTE_ARCH=x86_64",
                "__CODEX_REMOTE_HOME=/home/dev",
                "__CODEX_REMOTE_LIBC=musl",
                "__CODEX_REMOTE_HAS_SHELL=1",
                "__CODEX_REMOTE_HAS_TAR=1",
                "__CODEX_REMOTE_HAS_SHA256=1",
                "__CODEX_REMOTE_HAS_FLOCK=1",
                "__CODEX_REMOTE_DOWNLOADER=curl",
            ),
        )

        assertTrue(environment.installationProblem().orEmpty().contains("musl"))
    }

    @Test
    fun `generated installer has valid posix shell syntax`() {
        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use {
            it.write(RemoteBootstrap.installScript("0.144.6", "22.17.0"))
        }

        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
    }

    @Test
    fun `uninstaller removes only app managed runtime`() {
        val home = Files.createTempDirectory("codex-remote-uninstall").toFile()
        var vscodeProcess: Process? = null
        try {
            val managedRoot = home.resolve(".local/share/codex-remote")
            val managedWrapper = home.resolve(".local/bin/codex-remote")
            val systemCodex = home.resolve(".local/bin/codex")
            val accountState = home.resolve(".codex/auth.json")
            val appUploads = home.resolve(".codex-mobile/uploads/attachment.txt")
            val vscodeState = home.resolve(".vscode-server/extensions/openai.chatgpt")
            managedRoot.resolve("runtime/node/bin").mkdirs()
            managedRoot.resolve("runtime/node/bin/node").writeText("managed")
            requireNotNull(managedWrapper.parentFile).mkdirs()
            managedWrapper.writeText("managed")
            systemCodex.writeText("system")
            requireNotNull(accountState.parentFile).mkdirs()
            accountState.writeText("account")
            requireNotNull(appUploads.parentFile).mkdirs()
            appUploads.writeText("attachment")
            vscodeState.mkdirs()
            vscodeProcess = ProcessBuilder(
                "bash",
                "-c",
                "while :; do sleep 1; done",
                home.resolve(".vscode-server/bin/node").absolutePath,
                home.resolve(".vscode-server/extensions/openai/codex.js").absolutePath,
                "app-server",
            ).start()

            val process = ProcessBuilder("sh", "-c", RemoteBootstrap.uninstallScript)
                .apply { environment()["HOME"] = home.absolutePath }
                .start()

            assertTrue(process.waitFor(10, TimeUnit.SECONDS))
            assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
            assertFalse(managedRoot.exists())
            assertFalse(managedWrapper.exists())
            assertFalse(home.resolve(".codex-mobile").exists())
            assertTrue(systemCodex.exists())
            assertTrue(accountState.exists())
            assertTrue(vscodeState.exists())
            assertTrue(vscodeProcess.isAlive)
        } finally {
            vscodeProcess?.destroyForcibly()
            vscodeProcess?.waitFor(2, TimeUnit.SECONDS)
            home.deleteRecursively()
        }
    }

    @Test
    fun `generated uninstaller has valid posix shell syntax and no broad process matcher`() {
        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use { it.write(RemoteBootstrap.uninstallScript) }

        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
        assertFalse(RemoteBootstrap.uninstallScript.contains("pkill"))
        assertFalse(RemoteBootstrap.uninstallScript.contains("\$HOME/.codex\""))
        assertFalse(RemoteBootstrap.uninstallScript.contains(".vscode-server"))
        assertTrue(
            RemoteBootstrap.uninstallScript.contains(
                "\$ROOT\"/runtime/*/bin/node\\ \"\$ROOT\"/releases/*/lib/node_modules/@openai/codex/bin/codex.js\\ app-server*",
            ),
        )
    }
}
