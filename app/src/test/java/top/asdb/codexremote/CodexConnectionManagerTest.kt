package top.asdb.codexremote

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test
import top.asdb.codexremote.codex.CodexConnectionManager
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.data.AgentMode
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

    @Test
    fun `every profile owns an independent client for each on-demand agent`() = runTest {
        val manager = CodexConnectionManager(this)
        val profile = ServerProfile(
            id = "both",
            host = "host-a",
            agentMode = AgentMode.Both,
            activeAgent = AgentKind.Codex,
        )

        manager.registerProfile(profile)
        val codex = manager.client(profile.id, AgentKind.Codex)
        val openCode = manager.client(profile.id, AgentKind.OpenCode)

        assertNotSame(codex, openCode)
        assertSame(openCode, manager.select(profile, AgentKind.OpenCode))
        assertEquals(AgentKind.OpenCode, manager.activeKey.value?.agent)

        manager.registerProfile(profile.copy(agentMode = AgentMode.Codex, activeAgent = AgentKind.Codex))
        assertSame(openCode, manager.client(profile.id, AgentKind.OpenCode))
        manager.close()
    }

    @Test
    fun `selecting an existing lane preserves a codex client with resolved command`() = runTest {
        val manager = CodexConnectionManager(this)
        val profile = ServerProfile(
            id = "both-resolved",
            host = "host-a",
            agentMode = AgentMode.Both,
            activeAgent = AgentKind.Codex,
            remoteCommand = "managed-codex",
        )

        manager.registerProfile(profile)
        val openCode = manager.client(profile.id, AgentKind.OpenCode)
        val resolvedCodex = manager.register(
            profile.copy(remoteCommand = "/home/user/.local/bin/codex-app-server"),
            AgentKind.Codex,
        )

        assertSame(openCode, manager.select(profile.id, AgentKind.OpenCode))
        assertSame(resolvedCodex, manager.client(profile.id, AgentKind.Codex))
        manager.close()
    }
}
