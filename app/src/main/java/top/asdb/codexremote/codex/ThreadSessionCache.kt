package top.asdb.codexremote.codex

import top.asdb.codexremote.data.CodexThread
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TokenUsage
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
    private var currentWeightChars = 0

    @Synchronized
    fun get(threadId: String): Snapshot? {
        val value = entries.entries.firstOrNull { it.key == threadId }?.value?.value ?: return null
        if (nowMs() - value.savedAtMs > ttlMs) {
            return null
        }
        entries[threadId] // Promote only a fresh entry in access order.
        return value
    }

    /** Returns an expired snapshot too, for a last-resort timeout fallback. */
    @Synchronized
    fun getStale(threadId: String): Snapshot? = entries[threadId]?.value

    @Synchronized
    fun put(
        thread: CodexThread,
        timeline: List<TimelineEntry>,
        nextTurnsCursor: String? = null,
        tokenUsage: TokenUsage? = null,
    ) {
        val weight = snapshotWeight(thread, timeline, nextTurnsCursor)
        if (weight > maxWeightChars) return
        removeLocked(thread.id)
        val snapshot = Snapshot(thread, timeline.toList(), nowMs(), nextTurnsCursor, tokenUsage)
        entries[thread.id] = WeightedSnapshot(snapshot, weight)
        currentWeightChars += weight
        while (entries.size > maxEntries || currentWeightChars > maxWeightChars) {
            removeLocked(entries.entries.first().key)
        }
    }

    @Synchronized
    fun remove(threadId: String) {
        removeLocked(threadId)
    }

    @Synchronized
    fun clear() {
        entries.clear()
        currentWeightChars = 0
    }

    @Synchronized
    fun size(): Int = entries.size

    private fun removeLocked(threadId: String) {
        entries.remove(threadId)?.let { currentWeightChars -= it.weightChars }
    }

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
    }
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
