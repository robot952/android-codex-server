package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
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

    @Test
    fun `duplicate completion for one turn is suppressed`() {
        val deduplicator = TurnCompletionDeduplicator()
        val completion = completion(turnId = "turn-a")

        assertTrue(deduplicator.shouldPublish(completion))
        assertFalse(deduplicator.shouldPublish(completion))
    }

    @Test
    fun `different turns in one thread are published`() {
        val deduplicator = TurnCompletionDeduplicator()

        assertTrue(deduplicator.shouldPublish(completion(turnId = "turn-a")))
        assertTrue(deduplicator.shouldPublish(completion(turnId = "turn-b")))
    }

    @Test
    fun `completion without a turn id is not permanently suppressed`() {
        val deduplicator = TurnCompletionDeduplicator()
        val completion = completion(turnId = "")

        assertTrue(deduplicator.shouldPublish(completion))
        assertTrue(deduplicator.shouldPublish(completion))
    }

    @Test
    fun `old completion identities are evicted from the bounded cache`() {
        val deduplicator = TurnCompletionDeduplicator(maxEntries = 2)

        assertTrue(deduplicator.shouldPublish(completion(turnId = "turn-a")))
        assertTrue(deduplicator.shouldPublish(completion(turnId = "turn-b")))
        assertTrue(deduplicator.shouldPublish(completion(turnId = "turn-c")))
        assertTrue(deduplicator.shouldPublish(completion(turnId = "turn-a")))
    }

    private fun completion(turnId: String) = TurnCompletion(
        profileId = "server-a",
        agent = AgentKind.Codex,
        profileName = "Server A",
        threadId = "thread-a",
        turnId = turnId,
        threadTitle = "Thread A",
        threadPreview = "Preview",
    )
}
