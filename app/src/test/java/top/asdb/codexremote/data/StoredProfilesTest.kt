package top.asdb.codexremote.data

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class StoredProfilesTest {
    @Test
    fun `completed turn timings survive encrypted-profile payload serialization`() {
        val timing = TurnTiming(
            threadId = "thread-1",
            turnId = "turn-1",
            startedAtMillis = 1_000L,
            completedAtMillis = 4_500L,
            stopped = true,
        )
        val stored = StoredProfiles(
            completedTurnTimings = mapOf("profile-1\u0000thread-1" to timing),
        )

        val restored = Json.decodeFromString<StoredProfiles>(Json.encodeToString(stored))

        assertEquals(stored.completedTurnTimings, restored.completedTurnTimings)
    }
}
