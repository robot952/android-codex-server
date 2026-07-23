package top.asdb.codexremote.ui

import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind

/** Display state for a remote collaborator. Terminal states never regress to a late activity item. */
internal enum class SubAgentDisplayStatus(
    val label: String,
    val isActive: Boolean,
) {
    Preparing("准备中", true),
    Started("已开始工作", true),
    Updated("已更新", true),
    Working("正在工作", true),
    Completed("已完成", false),
    Interrupted("已中断", false),
    Failed("失败", false),
    Stopped("已停止", false),
    Unavailable("未找到", false),
}

internal data class SubAgentPresentation(
    val threadId: String,
    val name: String,
    val path: String,
    val turnId: String,
    val status: SubAgentDisplayStatus,
    val summary: String,
    val timelineIndex: Int,
) {
    val isOpenable: Boolean get() = threadId.isNotBlank()

    /**
     * A stable identity for the avatar. Status and timeline position are deliberately excluded so
     * a collaborator keeps the same visual identity throughout its lifetime.
     */
    val avatarIdentityKey: String
        get() = threadId.ifBlank { path.ifBlank { name } }

    /** Returns a deterministic palette index without relying on [Int.absoluteValue]. */
    fun avatarColorIndex(paletteSize: Int): Int {
        require(paletteSize > 0) { "paletteSize must be positive" }
        return Math.floorMod(avatarIdentityKey.hashCode(), paletteSize)
    }
}

internal data class SubAgentActivityGroupPresentation(
    val agents: List<SubAgentPresentation>,
    val status: SubAgentDisplayStatus,
    val statusLabel: String,
    val isActive: Boolean,
)

internal sealed interface TimelineRenderRow {
    val stableKey: String

    data class Entry(val entry: TimelineEntry) : TimelineRenderRow {
        override val stableKey: String = "entry:${entry.turnId}:${entry.kind}:${entry.id}"
    }

    data class SubAgents(val entries: List<TimelineEntry>) : TimelineRenderRow {
        override val stableKey: String = entries.joinToString(
            prefix = "agents:",
            separator = ":",
        ) { "${it.turnId}:${it.id}" }
    }
}

/** Groups adjacent activities from the same turn into the compact tag row used in the transcript. */
internal fun List<TimelineEntry>.toTimelineRenderRows(): List<TimelineRenderRow> {
    if (isEmpty()) return emptyList()
    val rows = ArrayList<TimelineRenderRow>(size)
    val pendingAgents = ArrayList<TimelineEntry>()

    fun flushAgents() {
        if (pendingAgents.isNotEmpty()) {
            rows += TimelineRenderRow.SubAgents(pendingAgents.toList())
            pendingAgents.clear()
        }
    }

    for (entry in this) {
        if (entry.kind == TimelineKind.SubAgent) {
            val previousTurn = pendingAgents.lastOrNull()?.turnId
            val canJoin = pendingAgents.isEmpty() ||
                (previousTurn != null && previousTurn.isNotBlank() && previousTurn == entry.turnId)
            if (!canJoin) flushAgents()
            pendingAgents += entry
        } else {
            flushAgents()
            rows += TimelineRenderRow.Entry(entry)
        }
    }
    flushAgents()
    return rows
}

/** Returns one latest status per sub-agent for the composer panel. */
internal fun List<TimelineEntry>.toSubAgentPresentations(): List<SubAgentPresentation> {
    val agents = LinkedHashMap<String, SubAgentPresentation>()
    forEachIndexed { index, entry ->
        if (entry.kind != TimelineKind.SubAgent) return@forEachIndexed
        val candidate = entry.toSubAgentPresentation(index)
        val key = candidate.threadId.takeIf { it.isNotBlank() } ?: "entry:${entry.id}:$index"
        agents[key] = agents[key]?.mergeWith(candidate) ?: candidate
    }
    return agents.values.sortedWith(
        compareByDescending<SubAgentPresentation> { it.status.isActive }
            .thenByDescending { it.timelineIndex },
    )
}

internal fun List<TimelineEntry>.toSubAgentActivityGroupPresentation(): SubAgentActivityGroupPresentation {
    val agents = toSubAgentPresentations()
    val statuses = agents.map(SubAgentPresentation::status).distinct()
    val active = agents.any { it.status.isActive }
    val displayStatus = when {
        statuses.isEmpty() -> SubAgentDisplayStatus.Unavailable
        statuses.size == 1 -> statuses.single()
        active -> SubAgentDisplayStatus.Working
        agents.any { it.status == SubAgentDisplayStatus.Failed } -> SubAgentDisplayStatus.Failed
        agents.any { it.status == SubAgentDisplayStatus.Interrupted } -> SubAgentDisplayStatus.Interrupted
        agents.any { it.status == SubAgentDisplayStatus.Unavailable } -> SubAgentDisplayStatus.Unavailable
        agents.any { it.status == SubAgentDisplayStatus.Stopped } -> SubAgentDisplayStatus.Stopped
        agents.all { it.status == SubAgentDisplayStatus.Completed } -> SubAgentDisplayStatus.Completed
        else -> agents.first().status
    }
    return SubAgentActivityGroupPresentation(
        agents = agents,
        status = displayStatus,
        statusLabel = displayStatus.label,
        isActive = active,
    )
}

private fun TimelineEntry.toSubAgentPresentation(index: Int): SubAgentPresentation {
    val path = subAgentPath.trim()
    val leafName = path.trimEnd('/', '\\').substringAfterLast('/').substringAfterLast('\\').trim()
    val threadId = subAgentThreadId.trim()
    return SubAgentPresentation(
        threadId = threadId,
        name = leafName.ifBlank { threadId.take(8).ifBlank { "智能体" } },
        path = path,
        turnId = turnId,
        status = toDisplayStatus(),
        summary = text.trim(),
        timelineIndex = index,
    )
}

private fun TimelineEntry.toDisplayStatus(): SubAgentDisplayStatus = when (status) {
    "completed" -> SubAgentDisplayStatus.Completed
    "interrupted" -> SubAgentDisplayStatus.Interrupted
    "errored", "failed" -> SubAgentDisplayStatus.Failed
    "shutdown" -> SubAgentDisplayStatus.Stopped
    "notFound" -> SubAgentDisplayStatus.Unavailable
    "pendingInit" -> SubAgentDisplayStatus.Preparing
    "running", "inProgress", "unknown", "started", "interacted" -> when (subAgentActivity) {
        "started" -> SubAgentDisplayStatus.Started
        "interacted" -> SubAgentDisplayStatus.Updated
        else -> SubAgentDisplayStatus.Working
    }
    else -> when (subAgentActivity) {
        "started" -> SubAgentDisplayStatus.Started
        "interacted" -> SubAgentDisplayStatus.Updated
        "interrupted" -> SubAgentDisplayStatus.Interrupted
        else -> SubAgentDisplayStatus.Working
    }
}

private fun SubAgentPresentation.mergeWith(next: SubAgentPresentation): SubAgentPresentation {
    // `subAgentActivity` items can be delivered after an authoritative terminal collab state.
    // Preserve that terminal result only within the same turn. A later turn can deliberately
    // resume the same worker, and the composer must show it as active again.
    val sameOrUnknownTurn = turnId.isBlank() || next.turnId.isBlank() || turnId == next.turnId
    if (!status.isActive && next.status.isActive && sameOrUnknownTurn) {
        return copy(
            name = next.name.takeUnless { it == "智能体" } ?: name,
            path = next.path.ifBlank { path },
            summary = next.summary.ifBlank { summary },
            timelineIndex = next.timelineIndex,
        )
    }
    return next.copy(
        name = next.name.takeUnless { it == "智能体" } ?: name,
        path = next.path.ifBlank { path },
        summary = next.summary.ifBlank { summary },
    )
}
