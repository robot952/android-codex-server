package top.asdb.codexremote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.codex.ProfileOperationTracker

class ProfileOperationTrackerTest {
    @Test
    fun `new exclusive operation supersedes only the same profile and lane`() {
        val tracker = ProfileOperationTracker()
        val firstOpen = tracker.begin("server-a", "open")
        val otherServer = tracker.begin("server-b", "open")
        val latestOpen = tracker.begin("server-a", "open")

        assertFalse(tracker.isCurrent(firstOpen))
        assertTrue(tracker.isCurrent(otherServer))
        assertTrue(tracker.isCurrent(latestOpen))
    }

    @Test
    fun `profile invalidation rejects exclusive and concurrent tickets`() {
        val tracker = ProfileOperationTracker()
        val open = tracker.begin("server-a", "open")
        val upload = tracker.begin("server-a", "upload", exclusive = false)

        tracker.invalidateProfile("server-a")

        assertFalse(tracker.isCurrent(open))
        assertFalse(tracker.isCurrent(upload))
        assertTrue(tracker.isCurrent(tracker.begin("server-a", "open")))
    }

    @Test
    fun `lane invalidation does not affect another lane or profile`() {
        val tracker = ProfileOperationTracker()
        val open = tracker.begin("server-a", "open")
        val refresh = tracker.begin("server-a", "refresh")
        val otherServer = tracker.begin("server-b", "open")

        tracker.invalidateLane("server-a", "open")

        assertFalse(tracker.isCurrent(open))
        assertTrue(tracker.isCurrent(refresh))
        assertTrue(tracker.isCurrent(otherServer))
    }
}
