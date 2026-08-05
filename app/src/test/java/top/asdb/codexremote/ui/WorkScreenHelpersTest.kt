package top.asdb.codexremote.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.ThreadGoalStatus

class WorkScreenHelpersTest {
    @Test
    fun onlyActiveGoalRequiresPauseConfirmation() {
        assertTrue(shouldConfirmGoalPause(ThreadGoalStatus.Active))
        assertFalse(shouldConfirmGoalPause(ThreadGoalStatus.Paused))
        assertFalse(shouldConfirmGoalPause(ThreadGoalStatus.Complete))
        assertFalse(shouldConfirmGoalPause(null))
    }

    @Test
    fun formatsTurnElapsedWithCompactUnits() {
        val startedAtMillis = 1_700_000_000_000L

        assertEquals("0s", formatTurnElapsed(startedAtMillis, startedAtMillis + 999L))
        assertEquals("59s", formatTurnElapsed(startedAtMillis, startedAtMillis + 59_999L))
        assertEquals("1m 0s", formatTurnElapsed(startedAtMillis, startedAtMillis + 60_000L))
        assertEquals("1m 1s", formatTurnElapsed(startedAtMillis, startedAtMillis + 61_000L))
        assertEquals("1h 0m 0s", formatTurnElapsed(startedAtMillis, startedAtMillis + 3_600_000L))
        assertEquals("1h 2m 3s", formatTurnElapsed(startedAtMillis, startedAtMillis + 3_723_000L))
    }
}
