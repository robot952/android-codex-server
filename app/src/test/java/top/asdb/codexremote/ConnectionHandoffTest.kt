package top.asdb.codexremote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState

class ConnectionHandoffTest {
    @Test
    fun `connected transport stays loading until active session data is ready`() {
        assertTrue(
            shouldHoldConnectedUntilSessionReady(
                local = ConnectionState(ConnectionPhase.Connecting),
                remote = ConnectionState(ConnectionPhase.Connected),
                preparingActiveConnection = true,
            ),
        )
    }

    @Test
    fun `failed and background connections are never held`() {
        assertFalse(
            shouldHoldConnectedUntilSessionReady(
                local = ConnectionState(ConnectionPhase.Connecting),
                remote = ConnectionState(ConnectionPhase.Failed),
                preparingActiveConnection = true,
            ),
        )
        assertFalse(
            shouldHoldConnectedUntilSessionReady(
                local = ConnectionState(ConnectionPhase.Connecting),
                remote = ConnectionState(ConnectionPhase.Connected),
                preparingActiveConnection = false,
            ),
        )
    }
}
