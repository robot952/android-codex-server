package top.asdb.codexremote.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.AgentConnectionKey
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState
import top.asdb.codexremote.data.CodexThread

class ThreadListAvailabilityTest {
    @Test
    fun `disconnected agent never exposes cached task rows`() {
        val cached = listOf(testThread("cached", "Cached task"))

        assertEquals(emptyList<CodexThread>(), visibleAgentThreads(cached, "", agentConnected = false))
        assertEquals(cached, visibleAgentThreads(cached, "", agentConnected = true))
    }

    @Test
    fun `connected agent filters cached tasks by query`() {
        val matching = testThread("match", "Server status")
        val cached = listOf(matching, testThread("other", "Write tests"))

        assertEquals(listOf(matching), visibleAgentThreads(cached, "server", agentConnected = true))
    }

    @Test
    fun `ssh only keeps terminal and files enabled while agent controls stay disabled`() {
        val profileId = "server"
        val availability = serverPageAvailability(
            AppUiState(
                selectedProfileId = profileId,
                activeAgent = AgentKind.Codex,
                connectionStates = mapOf(
                    profileId to ConnectionState(ConnectionPhase.Connected, "SSH 已连接"),
                ),
            ),
        )

        assertTrue(availability.terminalEnabled)
        assertTrue(availability.fileManagerEnabled)
        assertFalse(availability.workspaceEnabled)
        assertFalse(availability.modelSettingsEnabled)
        assertTrue(availability.agentSelectionEnabled)
    }

    @Test
    fun `connected agent enables workspace and model settings`() {
        val profileId = "server"
        val agent = AgentKind.OpenCode
        val availability = serverPageAvailability(
            AppUiState(
                selectedProfileId = profileId,
                activeAgent = agent,
                connectionStates = mapOf(
                    profileId to ConnectionState(ConnectionPhase.Connected, "SSH 已连接"),
                ),
                agentConnectionStates = mapOf(
                    AgentConnectionKey(profileId, agent) to
                        ConnectionState(ConnectionPhase.Connected, "已连接"),
                ),
            ),
        )

        assertTrue(availability.workspaceEnabled)
        assertTrue(availability.modelSettingsEnabled)
    }

    @Test
    fun `agent switcher is disabled while an agent is connecting`() {
        val profileId = "server"
        val availability = serverPageAvailability(
            AppUiState(
                selectedProfileId = profileId,
                connectionStates = mapOf(
                    profileId to ConnectionState(ConnectionPhase.Connected, "SSH 已连接"),
                ),
                agentConnectionStates = mapOf(
                    AgentConnectionKey(profileId, AgentKind.Codex) to
                        ConnectionState(ConnectionPhase.Connecting, "正在连接"),
                ),
            ),
        )

        assertFalse(availability.agentSelectionEnabled)
    }

    @Test
    fun `agent switcher stays usable while the active lane downloads its runtime`() {
        val profileId = "server"
        val availability = serverPageAvailability(
            AppUiState(
                selectedProfileId = profileId,
                activeAgent = AgentKind.OpenCode,
                connectionStates = mapOf(
                    profileId to ConnectionState(ConnectionPhase.Connected, "SSH 已连接"),
                ),
                agentConnectionStates = mapOf(
                    AgentConnectionKey(profileId, AgentKind.OpenCode) to
                        ConnectionState(ConnectionPhase.Installing, "正在安装 OpenCode"),
                ),
            ),
        )

        assertTrue(availability.agentSelectionEnabled)
        assertFalse(availability.workspaceEnabled)
        assertFalse(availability.modelSettingsEnabled)
    }

    private fun testThread(id: String, title: String) = CodexThread(
        id = id,
        title = title,
        preview = title,
        cwd = "/workspace",
        source = "test",
        status = "idle",
        createdAt = 1L,
        updatedAt = 1L,
        cliVersion = "test",
    )
}
