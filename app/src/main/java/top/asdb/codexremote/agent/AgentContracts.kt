package top.asdb.codexremote.agent

import top.asdb.codexremote.codex.ThreadSessionCache
import top.asdb.codexremote.data.AgentThread
import top.asdb.codexremote.data.TimelineEntry

/** Protocol-neutral snapshot returned when an Agent session is opened or restored. */
data class AgentSession(
    val thread: AgentThread,
    val timeline: List<TimelineEntry>,
    /** Last normalized event included in the response snapshot. */
    val responseSequence: Long,
    val activeTurnStartedAtMillis: Long? = null,
    val nextTurnsCursor: String? = null,
    val turnIds: List<String> = emptyList(),
    val itemsView: String = "full",
)

/** One bounded page of normalized Agent session history. */
data class AgentThreadPage(
    val timeline: List<TimelineEntry>,
    val nextCursor: String?,
    val turnIds: List<String> = emptyList(),
    val itemsView: String = "full",
)

/** Compatibility bridge to the existing bounded in-memory cache implementation. */
typealias AgentThreadCacheSnapshot = ThreadSessionCache.Snapshot
