package top.asdb.codexremote.codex

import top.asdb.codexremote.data.CodexThread
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.data.hasKnownContextWindow
import java.util.LinkedHashMap

/** In-memory, per-server LRU cache used as a fast UI/timeout fallback for opened threads. */
class ThreadSessionCache(
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
    private val ttlMs: Long = DEFAULT_TTL_MS,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val maxWeightChars: Int = DEFAULT_MAX_WEIGHT_CHARS,
) {
    init {
        require(maxEntries > 0) { "maxEntries must be positive" }
        require(ttlMs > 0) { "ttlMs must be positive" }
        require(maxWeightChars > 0) { "maxWeightChars must be positive" }
    }

    data class Snapshot(
        val thread: CodexThread,
        val timeline: List<TimelineEntry>,
        val savedAtMs: Long,
        val nextTurnsCursor: String? = null,
        /** Latest server-reported usage for this thread's current context window. */
        val tokenUsage: TokenUsage? = null,
    )

    private data class WeightedSnapshot(val value: Snapshot, val weightChars: Int)

    private val entries = object : LinkedHashMap<String, WeightedSnapshot>(maxEntries, 0.75f, true) {}
    // Context usage is tiny and must survive an oversized transcript being rejected from the
    // display cache. It remains session-scoped; a fresh server notification is authoritative.
    private val contextUsages = object : LinkedHashMap<String, TokenUsage>(maxEntries, 0.75f, true) {}
    private var currentWeightChars = 0

    @Synchronized
    fun get(threadId: String): Snapshot? {
        val snapshot = entries[threadId]?.value ?: return null
        if (nowMs() - snapshot.savedAtMs > ttlMs) {
            return null
        }
        return snapshot.withLatestContextUsage(threadId)
    }

    /** Returns an expired snapshot too, for a last-resort timeout fallback. */
    @Synchronized
    fun getStale(threadId: String): Snapshot? = entries[threadId]?.value?.withLatestContextUsage(threadId)

    /** Returns the latest usable context value even when no transcript snapshot was retained. */
    @Synchronized
    fun contextUsage(threadId: String): TokenUsage? = contextUsages[threadId]

    @Synchronized
    fun put(
        thread: CodexThread,
        timeline: List<TimelineEntry>,
        nextTurnsCursor: String? = null,
        tokenUsage: TokenUsage? = null,
    ) {
        tokenUsage?.takeIf { it.hasKnownContextWindow() }?.let { usage ->
            contextUsages[thread.id] = usage
            while (contextUsages.size > maxContextUsageEntries) {
                contextUsages.remove(contextUsages.entries.first().key)
            }
        }
        val rememberedUsage = contextUsages[thread.id]
        val weight = snapshotWeight(thread, timeline, nextTurnsCursor)
        if (weight > maxWeightChars) return
        removeLocked(thread.id)
        val snapshot = Snapshot(thread, timeline.toList(), nowMs(), nextTurnsCursor, rememberedUsage)
        entries[thread.id] = WeightedSnapshot(snapshot, weight)
        currentWeightChars += weight
        while (entries.size > maxEntries || currentWeightChars > maxWeightChars) {
            removeLocked(entries.entries.first().key)
        }
    }

    @Synchronized
    fun remove(threadId: String) {
        removeLocked(threadId)
        contextUsages.remove(threadId)
    }

    @Synchronized
    fun clear() {
        entries.clear()
        contextUsages.clear()
        currentWeightChars = 0
    }

    @Synchronized
    fun size(): Int = entries.size

    private fun removeLocked(threadId: String) {
        entries.remove(threadId)?.let { currentWeightChars -= it.weightChars }
    }

    private fun Snapshot.withLatestContextUsage(threadId: String): Snapshot = copy(
        tokenUsage = contextUsages[threadId] ?: tokenUsage,
    )

    private fun snapshotWeight(
        thread: CodexThread,
        timeline: List<TimelineEntry>,
        nextTurnsCursor: String?,
    ): Int {
        var result = thread.id.length + thread.title.length + thread.preview.length + thread.cwd.length +
            thread.source.length + thread.status.length + thread.cliVersion.length + nextTurnsCursor.orEmpty().length
        result = saturatedAdd(result, estimateTimelineWeightChars(timeline))
        return result
    }

    private fun saturatedAdd(left: Int, right: Int): Int =
        if (right > Int.MAX_VALUE - left) Int.MAX_VALUE else left + right

    companion object {
        const val DEFAULT_MAX_ENTRIES = 8
        const val DEFAULT_TTL_MS = 30 * 60 * 1000L
        const val DEFAULT_MAX_WEIGHT_CHARS = 2 * 1024 * 1024
        private const val CONTEXT_USAGE_ENTRIES_PER_TRANSCRIPT = 4
    }

    private val maxContextUsageEntries: Int =
        maxEntries.coerceAtMost(Int.MAX_VALUE / CONTEXT_USAGE_ENTRIES_PER_TRANSCRIPT) *
            CONTEXT_USAGE_ENTRIES_PER_TRANSCRIPT
}

internal fun estimateTimelineWeightChars(timeline: List<TimelineEntry>): Int {
    var result = 0
    timeline.forEach { entry ->
        result = saturatedAdd(
            result,
            entry.id.length + entry.title.length + entry.text.length + entry.status.length +
                entry.command.length + entry.cwd.length + entry.output.length + entry.turnId.length +
                entry.subAgentPath.length + entry.subAgentThreadId.length + entry.subAgentActivity.length,
        )
        entry.reasoningSummary.forEach { result = saturatedAdd(result, it.length) }
        entry.reasoningContent.forEach { result = saturatedAdd(result, it.length) }
        entry.changes.forEach { change ->
            result = saturatedAdd(result, change.path.length + change.kind.length + change.diff.length)
        }
    }
    return result
}

private fun saturatedAdd(left: Int, right: Int): Int =
    if (right > Int.MAX_VALUE - left) Int.MAX_VALUE else left + right
