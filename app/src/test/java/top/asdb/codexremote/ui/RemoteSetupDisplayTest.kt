package top.asdb.codexremote.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import top.asdb.codexremote.BuildConfig
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.data.RemoteSetupPrompt

class RemoteSetupDisplayTest {
    @Test
    fun `queued setup progress remains at zero`() {
        assertEquals(0f, setupProgressFraction("等待安装队列"), 0f)
    }

    @Test
    fun `OpenCode setup shows its release and bridge paths`() {
        val display = remoteSetupDisplay(
            RemoteSetupPrompt(
                title = "安装远程 OpenCode",
                detail = "尚未安装",
                os = "Linux",
                architecture = "x86_64",
                home = "/home/tester",
                agent = AgentKind.OpenCode,
            ),
        )

        assertEquals(
            "OpenCode ${BuildConfig.PINNED_OPENCODE_VERSION} · 共享 Node ${BuildConfig.PINNED_NODE_VERSION}",
            display.versionLine,
        )
        assertEquals(
            "/home/tester/.local/share/codex-remote/opencode/releases/${BuildConfig.PINNED_OPENCODE_VERSION}",
            display.installPath,
        )
        assertEquals(
            "/home/tester/.local/bin/codex-remote-opencode-bridge",
            display.bridgePath,
        )
    }

    @Test
    fun `Codex setup keeps the shared runtime path`() {
        val display = remoteSetupDisplay(
            RemoteSetupPrompt(
                title = "安装远程 Codex",
                detail = "尚未安装",
                os = "Linux",
                architecture = "x86_64",
                home = "/home/tester",
            ),
        )

        assertEquals(
            "/home/tester/.local/share/codex-remote",
            display.installPath,
        )
        assertEquals(null, display.bridgePath)
    }
}
