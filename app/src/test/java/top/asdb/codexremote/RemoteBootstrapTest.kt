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
                "__CODEX_REMOTE_MANAGED_VERSION=codex-cli 0.146.0",
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
            environment.compatibleCommand("0.146.0"),
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

        assertNull(environment.compatibleCommand("0.146.0"))
        assertEquals("codex-cli 0.145.0-alpha.18", environment.detectedVersion())
        assertNull(environment.installationProblem())
    }

    @Test
    fun `installer is pinned and never requests system privileges`() {
        val script = RemoteBootstrap.installScript("0.146.0", "22.17.0")

        assertTrue(script.contains("\"@openai/codex\":\"0.146.0\""))
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
        assertTrue(script.contains("for CANDIDATE in \"\$ROOT\"/runtime/\"\$NODE_NAME\"-*"))
        assertTrue(script.contains("Reuse any verified matching"))
        assertTrue(script.contains("::progress::%s|%s|%s|%s"))
        assertTrue(script.contains("download_file"))
        assertTrue(script.contains("--package-lock-only"))
        assertTrue(script.contains("npm\" ci"))
        assertTrue(script.contains("共 \$PACKAGE_TOTAL 个组件"))
        assertTrue(script.contains("node_modules/@openai/codex/bin/codex.js"))
        assertTrue(script.contains("INSTALL_COMMITTED=1"))
        assertFalse(script.contains("rm -rf \"\$NODE_DIR\""))
        assertFalse(script.contains("rm -rf \"\$RELEASE\""))
        assertFalse(script.contains("sudo"))
        assertFalse(script.contains("/usr/local"))
    }

    @Test
    fun `managed wrapper sources the Codex Remote global environment`() {
        val script = RemoteBootstrap.installScript("0.146.0", "22.17.0")

        assertTrue(script.contains("# codex-remote-global-env"))
        assertTrue(script.contains(".codex/codex-remote.env"))
        assertTrue(script.contains("MODEL_CACHE=\"\\\${HOME}/.codex/models_cache.json\""))
        assertTrue(script.contains("[ \"\\\${1:-}\" = \"app-server\" ]"))
        assertTrue(script.contains("supports_reasoning_summaries"))
        assertTrue(script.contains("MODEL_CACHE.incompatible."))
        assertTrue(script.contains("date +%s"))
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
            it.write(RemoteBootstrap.installScript("0.146.0", "22.17.0"))
        }

        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
    }

    @Test
    fun `node runtime installer reuses a verified suffixed release`() {
        val home = Files.createTempDirectory("codex-remote-node-reuse").toFile()
        try {
            val machine = ProcessBuilder("uname", "-m").start().let { process ->
                assertTrue(process.waitFor(5, TimeUnit.SECONDS))
                process.inputStream.bufferedReader().readText().trim()
            }
            val nodeArch = when (machine) {
                "x86_64", "amd64" -> "x64"
                "aarch64", "arm64" -> "arm64"
                else -> return
            }
            val runtimeBin = home.resolve(
                ".local/share/codex-remote/runtime/node-v22.17.0-linux-$nodeArch-existing/bin",
            )
            runtimeBin.mkdirs()
            runtimeBin.resolve("node").apply {
                writeText("#!/bin/sh\nprintf 'v22.17.0\\n'\n")
                assertTrue(setExecutable(true))
            }
            runtimeBin.resolve("npm").apply {
                writeText("#!/bin/sh\nprintf '10.0.0\\n'\n")
                assertTrue(setExecutable(true))
            }
            val fakeBin = home.resolve("fake-bin").apply { mkdirs() }
            fakeBin.resolve("curl").apply {
                writeText("#!/bin/sh\nexit 99\n")
                assertTrue(setExecutable(true))
            }

            val process = ProcessBuilder("sh", "-c", RemoteBootstrap.installNodeRuntimeScript("22.17.0"))
                .apply {
                    environment()["HOME"] = home.absolutePath
                    environment()["PATH"] = "${fakeBin.absolutePath}:${environment()["PATH"]}"
                }
                .start()

            assertTrue(process.waitFor(10, TimeUnit.SECONDS))
            val output = process.inputStream.bufferedReader().readText()
            assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
            assertTrue(output.contains("复用现有 Node.js 运行时"))
            assertFalse(output.contains("下载独立 Node.js 运行时"))
        } finally {
            home.deleteRecursively()
        }
    }

    @Test
    fun `node-only installer is valid and never installs Codex`() {
        val script = RemoteBootstrap.installNodeRuntimeScript("22.17.0")

        assertTrue(script.contains("node-v22.17.0-linux-"))
        assertTrue(script.contains("0fa01328a0f3d10800623f7107fbcd654a60ec178fab1ef5b9779e94e0419e1a"))
        assertTrue(script.contains("3e99df8b01b27dc8b334a2a30d1cd500442b3b0877d217b308fd61a9ccfc33d4"))
        assertTrue(script.contains("共享 Node.js 运行时已就绪"))
        assertFalse(script.contains("@openai/codex"))
        assertFalse(script.contains("node_modules/@openai/codex"))
        assertFalse(script.contains("npm install"))
        assertFalse(script.contains("npm\" ci"))
        assertFalse(script.contains("准备 Codex CLI 安装目录"))

        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use { it.write(script) }

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
