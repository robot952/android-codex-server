package top.asdb.agent

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionForegroundServiceTest {
    @Test
    fun successfulRoutineHeartbeatStaysSilent() {
        assertFalse(shouldLogHeartbeatCompletion(499, 0, 0))
    }

    @Test
    fun slowOrSkippedHeartbeatIsStillDiagnosable() {
        assertTrue(shouldLogHeartbeatCompletion(5_001, 0, 0))
        assertTrue(shouldLogHeartbeatCompletion(100, 1, 0))
        assertTrue(shouldLogHeartbeatCompletion(100, 0, 1))
    }
}
