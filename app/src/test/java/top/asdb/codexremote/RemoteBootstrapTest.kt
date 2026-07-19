package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.ssh.RemoteBootstrap
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
}
