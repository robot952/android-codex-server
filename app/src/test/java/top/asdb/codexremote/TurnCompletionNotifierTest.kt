package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TurnCompletionNotifierTest {
    @Test
    fun `notification id is stable for one server thread`() {
        assertEquals(
            completionNotificationId("server-a", "thread-a"),
            completionNotificationId("server-a", "thread-a"),
        )
    }

    @Test
    fun `different server threads use different notification ids`() {
        assertNotEquals(
            completionNotificationId("server-a", "thread-a"),
            completionNotificationId("server-b", "thread-b"),
        )
    }
}
