package top.asdb.codexremote

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.ssh.SshTerminalGenerationTokens
import top.asdb.codexremote.ssh.SshTerminalPhase
import top.asdb.codexremote.ssh.SshTerminalResizeQueue
import top.asdb.codexremote.ssh.SshTerminalSize
import top.asdb.codexremote.ssh.firstTerminalPhase
import top.asdb.codexremote.ssh.posixShellQuote
import top.asdb.codexremote.ui.encodeTerminalInput
import top.asdb.codexremote.ui.limitTerminalUtf8

class SshTerminalHelpersTest {
    @Test
    fun `workspace paths are safely quoted for the remote shell`() {
        assertEquals("'/home/root/project'", posixShellQuote("/home/root/project"))
        assertEquals("'/tmp/it'\"'\"'s safe'", posixShellQuote("/tmp/it's safe"))
        assertEquals("''", posixShellQuote(""))
    }

    @Test
    fun `control modifier produces terminal control bytes`() {
        assertArrayEquals(byteArrayOf(3), encodeTerminalInput("c", control = true, alt = false))
        assertArrayEquals(byteArrayOf(26), encodeTerminalInput("Z", control = true, alt = false))
    }

    @Test
    fun `alt modifier prefixes escape without corrupting utf8`() {
        val expected = byteArrayOf(0x1b) + "中".toByteArray(Charsets.UTF_8)
        assertArrayEquals(expected, encodeTerminalInput("中", control = false, alt = true))
    }

    @Test
    fun `special key sequences remain ordered`() {
        val arrowUp = "\u001b[A".toByteArray(Charsets.UTF_8)
        assertArrayEquals(arrowUp, encodeTerminalInput("\u001b[A", control = false, alt = false))
        assertArrayEquals(byteArrayOf(0x1b) + arrowUp, encodeTerminalInput("\u001b[A", false, true))
    }

    @Test
    fun `utf8 input limit never splits a multibyte character`() {
        val truncated = limitTerminalUtf8("ab中🙂z", maxBytes = 8)
        assertEquals("ab中", truncated.value)
        assertArrayEquals("ab中".toByteArray(Charsets.UTF_8), truncated.bytes)
        assertTrue(truncated.truncated)

        val exact = limitTerminalUtf8("ab中🙂", maxBytes = 9)
        assertEquals("ab中🙂", exact.value)
        assertFalse(exact.truncated)
    }

    @Test
    fun `replacement terminal connections receive unique generations`() {
        val tokens = SshTerminalGenerationTokens()
        assertEquals(1L, tokens.next())
        assertEquals(2L, tokens.next())
    }

    @Test
    fun `the first terminal state transition wins for a generation`() {
        var phase = SshTerminalPhase.Connected
        phase = firstTerminalPhase(7L, 7L, phase, SshTerminalPhase.Failed)!!

        assertEquals(SshTerminalPhase.Failed, phase)
        assertNull(firstTerminalPhase(7L, 7L, phase, SshTerminalPhase.Disconnected))

        var disconnectedFirst = SshTerminalPhase.Connected
        disconnectedFirst = firstTerminalPhase(
            8L,
            8L,
            disconnectedFirst,
            SshTerminalPhase.Disconnected,
        )!!
        assertNull(firstTerminalPhase(8L, 8L, disconnectedFirst, SshTerminalPhase.Failed))
        assertNull(firstTerminalPhase(9L, 8L, SshTerminalPhase.Connected, SshTerminalPhase.Failed))
    }

    @Test
    fun `resize writer is serial and coalesces pending requests to the latest size`() = runTest {
        val requests = SshTerminalResizeQueue()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val secondApplied = CompletableDeferred<Unit>()
        val applied = mutableListOf<SshTerminalSize>()
        val writer = launch {
            requests.consumeLatest { size ->
                applied += size
                if (applied.size == 1) {
                    firstStarted.complete(Unit)
                    releaseFirst.await()
                } else {
                    secondApplied.complete(Unit)
                }
            }
        }

        assertTrue(requests.trySend(SshTerminalSize(80, 24)))
        firstStarted.await()
        assertTrue(requests.trySend(SshTerminalSize(100, 30)))
        assertTrue(requests.trySend(SshTerminalSize(140, 45)))
        releaseFirst.complete(Unit)
        secondApplied.await()
        requests.close()
        writer.join()

        assertEquals(
            listOf(SshTerminalSize(80, 24), SshTerminalSize(140, 45)),
            applied,
        )
    }
}
