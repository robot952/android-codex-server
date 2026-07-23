package top.asdb.codexremote

import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.data.hasKnownContextWindow
import java.util.LinkedHashMap

/**
 * Small process-lifetime fallback for context rings. It remains available when an SSH client
 * is recreated while the user is navigating between sessions on the same server.
 */
internal class ProfileScopedContextUsageCache(
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
) {
    init {
        require(maxEntries > 0) { "maxEntries must be positive" }
    }

    private val entries = object : LinkedHashMap<String, TokenUsage>(maxEntries, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, TokenUsage>?): Boolean =
            size > maxEntries
    }

    @Synchronized
    fun remember(profileId: String, threadId: String, usage: TokenUsage) {
        if (profileId.isBlank() || threadId.isBlank() || !usage.hasKnownContextWindow()) return
        entries[key(profileId, threadId)] = usage
    }

    @Synchronized
    fun get(profileId: String, threadId: String): TokenUsage? =
        entries[key(profileId, threadId)]

    @Synchronized
    fun remove(profileId: String, threadId: String) {
        entries.remove(key(profileId, threadId))
    }

    @Synchronized
    fun clear(profileId: String) {
        if (profileId.isBlank()) return
        val prefix = "$profileId\u0000"
        entries.keys.removeAll { it.startsWith(prefix) }
    }

    @Synchronized
    fun size(): Int = entries.size

    private fun key(profileId: String, threadId: String): String = "$profileId\u0000$threadId"

    private companion object {
        const val DEFAULT_MAX_ENTRIES = 64
    }
}
