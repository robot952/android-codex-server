package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.data.TokenUsageBreakdown

class ProfileScopedContextUsageCacheTest {
    private val knownUsage = TokenUsage(
        last = TokenUsageBreakdown(totalTokens = 129_000),
        modelContextWindow = 353_000,
    )

    @Test
    fun keepsKnownUsageWhenAnIncompleteUpdateArrives() {
        val cache = ProfileScopedContextUsageCache(maxEntries = 4)

        cache.remember("server-a", "thread-a", knownUsage)
        cache.remember("server-a", "thread-a", TokenUsage())

        assertEquals(knownUsage, cache.get("server-a", "thread-a"))
    }

    @Test
    fun isolatesProfilesAndClearsOnlyTheRequestedProfile() {
        val cache = ProfileScopedContextUsageCache(maxEntries = 4)

        cache.remember("server-a", "thread-1", knownUsage)
        cache.remember("server-b", "thread-1", knownUsage.copy(modelContextWindow = 128_000))
        cache.clear("server-a")

        assertNull(cache.get("server-a", "thread-1"))
        assertEquals(128_000L, cache.get("server-b", "thread-1")?.modelContextWindow ?: -1L)
    }

    @Test
    fun evictsLeastRecentlyUsedUsage() {
        val cache = ProfileScopedContextUsageCache(maxEntries = 2)

        cache.remember("server", "first", knownUsage)
        cache.remember("server", "second", knownUsage)
        cache.get("server", "first")
        cache.remember("server", "third", knownUsage)

        assertEquals(knownUsage, cache.get("server", "first"))
        assertNull(cache.get("server", "second"))
        assertEquals(knownUsage, cache.get("server", "third"))
    }
}
