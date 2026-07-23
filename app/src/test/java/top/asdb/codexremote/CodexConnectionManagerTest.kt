package top.asdb.codexremote

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test
import top.asdb.codexremote.codex.CodexConnectionManager
import top.asdb.codexremote.data.ServerProfile

class CodexConnectionManagerTest {
    @Test
    fun `profiles keep independent stable clients while switching`() = runTest {
        val manager = CodexConnectionManager(this)
        val first = ServerProfile(id = "first", host = "host-a")
        val second = ServerProfile(id = "second", host = "host-b")

        val firstClient = manager.register(first)
        val secondClient = manager.register(second)

        assertNotSame(firstClient, secondClient)
        assertSame(firstClient, manager.select(first))
        assertSame(secondClient, manager.select(second))
        assertSame(firstClient, manager.client(first.id))
        assertEquals(second.id, manager.activeProfileId.value)

        manager.close()
    }

    @Test
    fun `changing connection identity replaces only that profile client`() = runTest {
        val manager = CodexConnectionManager(this)
        val first = ServerProfile(id = "first", host = "host-a")
        val second = ServerProfile(id = "second", host = "host-b")
        val firstClient = manager.register(first)
        val secondClient = manager.register(second)

        val replaced = manager.register(first.copy(host = "host-a-new"))

        assertNotSame(firstClient, replaced)
        assertSame(replaced, manager.select(first.id))
        assertSame(secondClient, manager.client(second.id))
        manager.close()
    }
}
