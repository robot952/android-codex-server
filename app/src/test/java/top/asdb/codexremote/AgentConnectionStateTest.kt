package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Test
import top.asdb.codexremote.agent.aggregateAgentConnectionStates
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState

class AgentConnectionStateTest {
    @Test
    fun `all connected agents produce one connected server state`() {
        val state = aggregateAgentConnectionStates(
            listOf(
                ConnectionState(ConnectionPhase.Connected, cliVersion = "codex 1"),
                ConnectionState(ConnectionPhase.Connected, cliVersion = "opencode 2"),
            ),
        )

        assertEquals(ConnectionPhase.Connected, state.phase)
        assertEquals("codex 1 / opencode 2", state.cliVersion)
    }

    @Test
    fun `one connected agent keeps the optional server lane connected`() {
        val state = aggregateAgentConnectionStates(
            listOf(
                ConnectionState(ConnectionPhase.Connected),
                ConnectionState(ConnectionPhase.Failed, "OpenCode failed"),
            ),
        )

        assertEquals(ConnectionPhase.Connected, state.phase)
        assertEquals("已连接", state.message)
    }

    @Test
    fun `installation takes precedence over other lane states`() {
        val state = aggregateAgentConnectionStates(
            listOf(
                ConnectionState(ConnectionPhase.Connected),
                ConnectionState(ConnectionPhase.Installing, "正在安装 OpenCode"),
            ),
        )

        assertEquals(ConnectionPhase.Installing, state.phase)
        assertEquals("正在安装 OpenCode", state.message)
    }
}
