package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileScopedBackStackTest {
    @Test
    fun keepsNestedNavigationIndependentForEachProfile() {
        val stack = ProfileScopedBackStack<String>()

        stack.push("server-a", "parent")
        stack.push("server-a", "agent-a")
        stack.push("server-b", "other-parent")

        assertEquals("agent-a", stack.peek("server-a"))
        assertEquals("other-parent", stack.peek("server-b"))
        assertEquals("agent-a", stack.pop("server-a"))
        assertEquals("parent", stack.pop("server-a"))
        assertNull(stack.pop("server-a"))
        assertEquals("other-parent", stack.pop("server-b"))
    }

    @Test
    fun clearOnlyRemovesTheRequestedProfile() {
        val stack = ProfileScopedBackStack<String>()

        stack.push("server-a", "parent")
        stack.push("server-b", "other-parent")
        stack.clear("server-a")

        assertEquals(0, stack.size("server-a"))
        assertEquals(1, stack.size("server-b"))
        assertEquals("other-parent", stack.peek("server-b"))
    }

    @Test
    fun onlyPopsTheExpectedTopFrame() {
        val stack = ProfileScopedBackStack<Any>()
        val parent = Any()
        val child = Any()

        stack.push("server", parent)
        stack.push("server", child)

        assertNull(stack.popIfTop("server", parent))
        assertEquals(child, stack.peek("server"))
        assertEquals(child, stack.popIfTop("server", child))
        assertEquals(parent, stack.popIfTop("server", parent))
    }

    @Test
    fun pendingPopMakesRepeatedBackRequestsIdempotentUntilResumeCompletes() {
        val stack = ProfileScopedBackStack<Any>()
        val parent = Any()
        val child = Any()
        stack.push("server", parent)
        stack.push("server", child)

        assertEquals(child, stack.beginPendingPop("server"))
        assertTrue(stack.isPopPending("server"))
        assertNull(stack.beginPendingPop("server"))
        assertEquals(child, stack.completePendingPop("server", child))
        assertFalse(stack.isPopPending("server"))
        assertEquals(parent, stack.peek("server"))
    }

    @Test
    fun failedPendingPopKeepsNestedFrameAvailableForRetry() {
        val stack = ProfileScopedBackStack<Any>()
        val root = Any()
        val agent = Any()
        val child = Any()
        stack.push("server", root)
        stack.push("server", agent)
        stack.push("server", child)

        assertEquals(child, stack.beginPendingPop("server"))
        assertTrue(stack.cancelPendingPop("server", child))
        assertFalse(stack.isPopPending("server"))
        assertEquals(child, stack.peek("server"))
        assertEquals(child, stack.beginPendingPop("server"))
        assertEquals(child, stack.completePendingPop("server", child))
        assertEquals(agent, stack.peek("server"))
    }

    @Test
    fun nestedReturnsCompleteOneParentAtATime() {
        val stack = ProfileScopedBackStack<Any>()
        val root = Any()
        val firstAgent = Any()
        val secondAgent = Any()
        stack.push("server", root)
        stack.push("server", firstAgent)
        stack.push("server", secondAgent)

        assertEquals(secondAgent, stack.beginPendingPop("server"))
        assertEquals(secondAgent, stack.completePendingPop("server", secondAgent))
        assertEquals(firstAgent, stack.peek("server"))
        assertEquals(firstAgent, stack.beginPendingPop("server"))
        assertEquals(firstAgent, stack.completePendingPop("server", firstAgent))
        assertEquals(root, stack.peek("server"))
    }

    @Test
    fun clearingProfileCancelsOnlyItsPendingReturn() {
        val stack = ProfileScopedBackStack<Any>()
        val first = Any()
        val second = Any()
        stack.push("server-a", first)
        stack.push("server-b", second)
        stack.beginPendingPop("server-a")

        stack.clear("server-a")

        assertFalse(stack.isPopPending("server-a"))
        assertNull(stack.peek("server-a"))
        assertEquals(second, stack.peek("server-b"))
    }

    @Test
    fun latePendingCompletionCannotPopANewerFrame() {
        data class Frame(val id: String)

        val stack = ProfileScopedBackStack<Frame>()
        val parent = Frame("parent")
        val child = Frame("same")
        val newer = Frame("same")
        stack.push("server", parent)
        stack.push("server", child)
        stack.beginPendingPop("server")
        stack.push("server", newer)

        assertNull(stack.completePendingPop("server", child))
        assertEquals(newer, stack.peek("server"))
        assertFalse(stack.isPopPending("server"))
    }
}
