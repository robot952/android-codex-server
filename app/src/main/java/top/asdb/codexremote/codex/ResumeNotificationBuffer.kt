package top.asdb.codexremote.codex

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind

/** Holds target-thread notifications until thread/resume has atomically published its snapshot. */
internal class ResumeNotificationBuffer(
    private val threadId: String,
    private val generation: Long,
    private val maxEvents: Int = DEFAULT_MAX_EVENTS,
    private val maxWeightChars: Int = DEFAULT_MAX_WEIGHT_CHARS,
) {
    private data class BufferedEvent(val notification: CodexNotification, val weightChars: Int)

    private val events = ArrayList<BufferedEvent>()
    private var weightChars = 0
    var overflowed: Boolean = false
        private set

    init {
        require(maxEvents > 0)
        require(maxWeightChars > 0)
    }

    /** Returns true when the notification belongs to this resume and was intercepted. */
    fun offer(notification: CodexNotification): Boolean {
        if (notification.generation != generation) return false
        if (notification.params.string("threadId") != threadId) return false
        val weight = estimateNotificationWeight(notification, maxWeightChars)
        if (weight > maxWeightChars) {
            overflowed = true
            return true
        }
        if (events.size >= maxEvents || weightChars.toLong() + weight > maxWeightChars.toLong()) {
            overflowed = true
            // Full payloads are more useful than streaming fragments after a resume snapshot.
            if (notification.deltaKey() != null) return true
            makeRoomFor(weight)
        }
        if (events.size >= maxEvents || weightChars.toLong() + weight > maxWeightChars.toLong()) {
            overflowed = true
            return true
        }
        events += BufferedEvent(notification, weight)
        weightChars += weight
        return true
    }

    private fun makeRoomFor(incomingWeight: Int) {
        while (events.isNotEmpty() &&
            (events.size >= maxEvents || weightChars.toLong() + incomingWeight > maxWeightChars.toLong())
        ) {
            val deltaIndex = events.indexOfFirst { it.notification.deltaKey() != null }
            val removed = events.removeAt(if (deltaIndex >= 0) deltaIndex else 0)
            weightChars -= removed.weightChars
        }
    }

    /**
     * Replays in wire order. Deltas already represented by the snapshot are removed as one exact
     * aggregate suffix, matching the official Codex client behavior without fuzzy overlap guesses.
     */
    fun drain(
        snapshot: List<TimelineEntry>,
        snapshotSequence: Long = Long.MAX_VALUE,
    ): List<CodexNotification> {
        if (events.isEmpty()) return emptyList()
        val buffered = events.map(BufferedEvent::notification)
        val completedAuthoritativeKeys = buffered.mapNotNullTo(HashSet()) { notification ->
            if (notification.method != "item/completed") return@mapNotNullTo null
            notification.itemKey()?.takeIf { it.kind in setOf(TimelineKind.AgentMessage, TimelineKind.Plan) }
        }
        val aggregates = LinkedHashMap<StreamKey, StringBuilder>()
        buffered.forEach { notification ->
            if (notification.sequence > snapshotSequence) return@forEach
            val key = notification.deltaKey() ?: return@forEach
            if (key.timelineKey in completedAuthoritativeKeys) return@forEach
            aggregates.getOrPut(key, ::StringBuilder).append(notification.params.string("delta"))
        }
        val snapshotByKey = snapshot.associateBy(TimelineEntry::timelineKey)
        val remainingSkip = aggregates.mapValuesTo(HashMap()) { (key, aggregate) ->
            val existing = snapshotByKey[key.timelineKey]
            when {
                key.field == StreamField.Plan && existing != null -> aggregate.length
                else -> aggregate.length.takeIf {
                    it > 0 && existing?.streamValue(key).orEmpty().endsWith(aggregate)
                } ?: 0
            }
        }
        val replay = ArrayList<CodexNotification>(buffered.size)
        buffered.forEach { notification ->
            val key = notification.deltaKey()
            if (key != null && key.timelineKey in completedAuthoritativeKeys) return@forEach
            if (key == null) {
                replay += notification
                return@forEach
            }
            val delta = notification.params.string("delta")
            val skip = if (notification.sequence <= snapshotSequence) remainingSkip[key] ?: 0 else 0
            val consumed = minOf(skip, delta.length)
            remainingSkip[key] = skip - consumed
            val remaining = delta.drop(consumed)
            if (remaining.isNotEmpty()) replay += notification.withDelta(remaining)
        }
        events.clear()
        weightChars = 0
        return replay.coalesceDeltas()
    }

    private fun CodexNotification.deltaKey(): StreamKey? = when (method) {
        "item/agentMessage/delta" -> params.explicitKey(TimelineKind.AgentMessage)
            ?.let { StreamKey(it, StreamField.Text) }
        "item/plan/delta" -> params.explicitKey(TimelineKind.Plan)
            ?.let { StreamKey(it, StreamField.Plan) }
        "item/commandExecution/outputDelta" -> params.explicitKey(TimelineKind.Command)
            ?.let { StreamKey(it, StreamField.Output) }
        "item/reasoning/summaryTextDelta" -> params.explicitKey(TimelineKind.Reasoning)
            ?.let { StreamKey(it, StreamField.ReasoningSummary, params.long("summaryIndex")) }
        "item/reasoning/textDelta" -> params.explicitKey(TimelineKind.Reasoning)
            ?.let { StreamKey(it, StreamField.ReasoningContent, params.long("contentIndex")) }
        else -> null
    }

    private fun CodexNotification.itemKey(): TimelineKey? {
        val item = params.obj("item") ?: return null
        val entry = CodexPayloadParser.parseItem(item, params.string("turnId")) ?: return null
        return entry.timelineKey()
    }

    private fun JsonObject.explicitKey(kind: TimelineKind): TimelineKey? {
        val itemId = string("itemId")
        val turnId = string("turnId")
        return if (itemId.isBlank() || turnId.isBlank()) null else TimelineKey(turnId, itemId, kind)
    }

    private fun CodexNotification.withDelta(delta: String): CodexNotification = copy(
        params = JsonObject(params + ("delta" to JsonPrimitive(delta))),
    )

    private fun List<CodexNotification>.coalesceDeltas(): List<CodexNotification> {
        if (size < 2) return this
        val result = ArrayList<CodexNotification>(size)
        // Only merge adjacent fragments for the same stream.  Keeping a map of all open
        // streams would emit the first stream's later fragments before an intervening
        // command/reasoning stream, changing the wire order and making the rendered AI
        // timeline appear scrambled.
        var pendingKey: StreamKey? = null
        var pendingNotification: CodexNotification? = null
        var pendingDelta = StringBuilder()
        fun flush() {
            pendingNotification?.let { notification ->
                result += notification.withDelta(pendingDelta.toString())
            }
            pendingKey = null
            pendingNotification = null
            pendingDelta = StringBuilder()
        }
        for (notification in this) {
            val key = notification.deltaKey()
            if (key == null) {
                flush()
                result += notification
            } else if (key == pendingKey) {
                pendingDelta.append(notification.params.string("delta"))
            } else {
                flush()
                pendingKey = key
                pendingNotification = notification
                pendingDelta.append(notification.params.string("delta"))
            }
        }
        flush()
        return result
    }

    companion object {
        private const val DEFAULT_MAX_EVENTS = 4_096
        private const val DEFAULT_MAX_WEIGHT_CHARS = 4 * 1024 * 1024
    }
}

private fun estimateNotificationWeight(notification: CodexNotification, limit: Int): Int {
    var total = notification.method.length.coerceAtMost(limit + 1)
    val pending = ArrayDeque<JsonElement>()
    pending.addLast(notification.params)
    while (pending.isNotEmpty() && total <= limit) {
        when (val element = pending.removeLast()) {
            is JsonObject -> element.forEach { (key, value) ->
                total = (total.toLong() + key.length).coerceAtMost((limit + 1).toLong()).toInt()
                if (total <= limit) pending.addLast(value)
            }
            is JsonArray -> element.forEach(pending::addLast)
            is JsonPrimitive -> {
                total = (total.toLong() + element.contentOrNull.orEmpty().length)
                    .coerceAtMost((limit + 1).toLong()).toInt()
            }
        }
    }
    return total
}

internal data class TimelineKey(
    val turnId: String,
    val itemId: String,
    val kind: TimelineKind,
)

private enum class StreamField { Text, Plan, Output, ReasoningSummary, ReasoningContent }

private data class StreamKey(
    val timelineKey: TimelineKey,
    val field: StreamField,
    val partIndex: Long = -1,
)

internal fun TimelineEntry.timelineKey(): TimelineKey = TimelineKey(turnId, id, kind)

private fun TimelineEntry.streamValue(key: StreamKey): String = when (key.field) {
    StreamField.Text -> text
    StreamField.Plan -> ""
    StreamField.Output -> output
    StreamField.ReasoningSummary -> key.partIndex.takeIf { it in 0..Int.MAX_VALUE.toLong() }
        ?.toInt()?.let(reasoningSummary::getOrNull).orEmpty()
    StreamField.ReasoningContent -> key.partIndex.takeIf { it in 0..Int.MAX_VALUE.toLong() }
        ?.toInt()?.let(reasoningContent::getOrNull).orEmpty()
}
