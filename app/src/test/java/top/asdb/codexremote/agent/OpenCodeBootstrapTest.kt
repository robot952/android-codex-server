package top.asdb.codexremote.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.ssh.RemoteBootstrap
import java.util.concurrent.TimeUnit

class OpenCodeBootstrapTest {
    @Test
    fun `probe accepts npm executable symlinks`() {
        assertTrue(OpenCodeBootstrap.probeScript.contains("find -L"))
        assertTrue(OpenCodeBootstrap.probeScript.contains("node_modules/.bin/opencode"))
    }

    @Test
    fun `install uses pinned domestic registry and only selected platform binary`() {
        val script = OpenCodeBootstrap.installScript(
            openCodeVersion = "1.18.11",
            proxyUrl = "http://127.0.0.1:7890",
            bridgeSource = "console.log('bridge')",
        )

        assertTrue(script.contains("opencode-ai\":\"1.18.11"))
        assertTrue(script.contains("jsonc-parser\":\"3.3.1"))
        assertTrue(script.contains("npm_config_registry=https://registry.npmmirror.com"))
        assertTrue(script.contains("PLATFORM_PACKAGE=opencode-linux-arm64"))
        assertTrue(script.contains("PLATFORM_PACKAGE=opencode-linux-x64"))
        assertTrue(script.contains("PLATFORM_PACKAGE=opencode-linux-x64-baseline"))
        assertTrue(!script.contains("opencode-linux-arm64-musl"))
        assertTrue(!script.contains("opencode-linux-x64-musl"))
        assertTrue(script.contains("--ignore-scripts"))
        assertTrue(script.contains("--omit=optional"))
        assertTrue(script.contains("ln -s \"../\$PLATFORM_PACKAGE/bin/opencode\""))
        assertTrue(script.contains("HTTP_PROXY=\"\$PROXY\""))
        assertTrue(script.contains(OpenCodeBootstrap.bridgeSha256("console.log('bridge')")))
        assertTrue(script.contains("bridge.sha256"))
    }

    @Test
    fun `probe parser ignores unrelated remote output`() {
        assertEquals(
            mapOf(
                "VERSION" to "1.18.11",
                "BRIDGE" to "/home/user/.local/bin/bridge",
                "BRIDGE_SHA256" to "abc123",
            ),
            OpenCodeBootstrap.parseProbe(
                listOf(
                    "shell warning",
                    "__CODEX_REMOTE_OPENCODE_VERSION=1.18.11",
                    "__CODEX_REMOTE_OPENCODE_BRIDGE=/home/user/.local/bin/bridge",
                    "__CODEX_REMOTE_OPENCODE_BRIDGE_SHA256=abc123",
                ),
            ),
        )
    }

    @Test
    fun `combined probe includes host and OpenCode checks with valid shell syntax`() {
        val script = OpenCodeBootstrap.combinedProbeScript

        assertTrue(script.contains(RemoteBootstrap.probeScript))
        assertTrue(script.contains(OpenCodeBootstrap.probeScript))
        assertTrue(script.contains("__CODEX_REMOTE_%s=%s"))
        assertTrue(script.contains("__CODEX_REMOTE_OPENCODE_%s=%s"))
        assertTrue(script.contains("value OS "))
        assertTrue(script.contains("value VERSION "))

        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use { it.write(script) }

        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
    }
}
