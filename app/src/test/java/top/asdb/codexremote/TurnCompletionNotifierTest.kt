package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import top.asdb.codexremote.data.AgentKind

class TurnCompletionNotifierTest {
    @Test
    fun `notification id is stable for one server thread`() {
        assertEquals(
            completionNotificationId("server-a", AgentKind.Codex, "thread-a"),
            completionNotificationId("server-a", AgentKind.Codex, "thread-a"),
        )
    }

    @Test
    fun `different server threads use different notification ids`() {
        assertNotEquals(
            completionNotificationId("server-a", AgentKind.Codex, "thread-a"),
            completionNotificationId("server-b", AgentKind.Codex, "thread-b"),
        )
    }

    @Test
    fun `same server thread uses a different id for each agent`() {
        assertNotEquals(
            completionNotificationId("server-a", AgentKind.Codex, "thread-a"),
            completionNotificationId("server-a", AgentKind.OpenCode, "thread-a"),
        )
    }
}
