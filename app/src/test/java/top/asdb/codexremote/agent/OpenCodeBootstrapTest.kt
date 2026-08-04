package top.asdb.codexremote.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

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
        assertTrue(script.contains("--omit=optional"))
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
}
