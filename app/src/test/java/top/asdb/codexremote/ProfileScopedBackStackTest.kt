package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
