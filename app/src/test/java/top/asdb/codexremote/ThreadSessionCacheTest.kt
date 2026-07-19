package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import top.asdb.codexremote.codex.ThreadSessionCache
import top.asdb.codexremote.data.CodexThread

class ThreadSessionCacheTest {
    private fun thread(id: String) = CodexThread(
        id = id,
        title = id,
        preview = "",
        cwd = "/tmp",
        source = "appServer",
        status = "idle",
        createdAt = 0,
        updatedAt = 0,
        cliVersion = "",
    )

    @Test
    fun evictsLeastRecentlyUsedEntry() {
        val cache = ThreadSessionCache(maxEntries = 2, ttlMs = 60_000, nowMs = { 1_000 })
        cache.put(thread("a"), emptyList())
        cache.put(thread("b"), emptyList())
        cache.get("a")
        cache.put(thread("c"), emptyList())

        assertNull(cache.getStale("b"))
        assertEquals("a", cache.get("a")?.thread?.id)
        assertEquals("c", cache.get("c")?.thread?.id)
    }

    @Test
    fun freshReadExpiresButStaleReadRemainsAvailable() {
        var now = 100L
        val cache = ThreadSessionCache(maxEntries = 2, ttlMs = 10, nowMs = { now })
        cache.put(thread("a"), emptyList())
        now = 111L

        assertNull(cache.get("a"))
        assertEquals("a", cache.getStale("a")?.thread?.id)
    }
}
