package top.asdb.codexremote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.codex.CodexEventReducer
import top.asdb.codexremote.codex.CodexNotification
import top.asdb.codexremote.codex.ResumeNotificationBuffer
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind

class ResumeNotificationBufferTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `skips exact agent and command suffixes already present in snapshot`() {
        val buffer = ResumeNotificationBuffer("thread", generation = 7)
        buffer.offer(delta("item/agentMessage/delta", "turn", "agent", "A"))
        buffer.offer(delta("item/commandExecution/outputDelta", "turn", "command", "X"))
        buffer.offer(delta("item/agentMessage/delta", "turn", "agent", "B"))
        buffer.offer(delta("item/commandExecution/outputDelta", "turn", "command", "Y"))
        val snapshot = listOf(
            TimelineEntry("agent", TimelineKind.AgentMessage, text = "preAB", turnId = "turn"),
            TimelineEntry("command", TimelineKind.Command, output = "preXY", turnId = "turn"),
        )

        assertTrue(buffer.drain(snapshot).isEmpty())
    }

    @Test
    fun `keeps snapshot plan authoritative and skips independent reasoning suffixes`() {
        val buffer = ResumeNotificationBuffer("thread", generation = 7)
        buffer.offer(delta("item/plan/delta", "turn", "plan", "P"))
        buffer.offer(delta("item/plan/delta", "turn", "plan", "Q"))
        buffer.offer(indexedDelta("item/reasoning/summaryTextDelta", "turn", "reason", "summaryIndex", 0, "A"))
        buffer.offer(indexedDelta("item/reasoning/summaryTextDelta", "turn", "reason", "summaryIndex", 0, "B"))
        buffer.offer(indexedDelta("item/reasoning/textDelta", "turn", "reason", "contentIndex", 0, "X"))
        buffer.offer(indexedDelta("item/reasoning/textDelta", "turn", "reason", "contentIndex", 0, "Y"))
        val snapshot = listOf(
            // Completed plan content is not defined as a concatenation of plan deltas.
            TimelineEntry("plan", TimelineKind.Plan, text = "server formatted plan", turnId = "turn"),
            TimelineEntry(
                "reason",
                TimelineKind.Reasoning,
                text = "preAB",
                turnId = "turn",
                reasoningSummary = listOf("preAB"),
                reasoningContent = listOf("rawXY"),
            ),
        )

        assertTrue(buffer.drain(snapshot).isEmpty())
    }

    @Test
    fun `replays missing delta once and keeps turn and kind identities separate`() {
        val buffer = ResumeNotificationBuffer("thread", generation = 7)
        buffer.offer(delta("item/agentMessage/delta", "turn-1", "same", "agent-one"))
        buffer.offer(delta("item/commandExecution/outputDelta", "turn-1", "same", "command"))
        buffer.offer(delta("item/agentMessage/delta", "turn-2", "same", "agent-two"))

        var state = AppUiState(timeline = listOf(
            TimelineEntry("same", TimelineKind.AgentMessage, text = "base", turnId = "turn-1"),
            TimelineEntry("same", TimelineKind.Command, output = "base", turnId = "turn-1"),
            TimelineEntry("same", TimelineKind.AgentMessage, text = "base", turnId = "turn-2"),
        ))
        buffer.drain(state.timeline).forEach { event ->
            state = CodexEventReducer.reduce(state, event.method, event.params)
        }

        assertEquals("baseagent-one", state.timeline[0].text)
        assertEquals("basecommand", state.timeline[1].output)
        assertEquals("baseagent-two", state.timeline[2].text)
    }

    @Test
    fun `completed agent payload wins over every buffered agent delta`() {
        val buffer = ResumeNotificationBuffer("thread", generation = 7)
        buffer.offer(delta("item/agentMessage/delta", "turn", "agent", "duplicate"))
        buffer.offer(notification(
            "item/completed",
            """{"threadId":"thread","turnId":"turn","item":{"id":"agent","type":"agentMessage","text":"final"}}""",
        ))

        var state = AppUiState(timeline = listOf(
            TimelineEntry("agent", TimelineKind.AgentMessage, text = "snapshot", turnId = "turn"),
        ))
        buffer.drain(state.timeline).forEach { event ->
            state = CodexEventReducer.reduce(state, event.method, event.params)
        }

        assertEquals("final", state.timeline.single().text)
    }

    @Test
    fun `only intercepts matching thread and generation`() {
        val buffer = ResumeNotificationBuffer("target", generation = 7)

        assertFalse(buffer.offer(notification("turn/started", """{"threadId":"other"}""", 7)))
        assertFalse(buffer.offer(notification("turn/started", """{"threadId":"target"}""", 8)))
        assertTrue(buffer.offer(notification("turn/started", """{"threadId":"target"}""", 7)))
    }

    @Test
    fun `bounded buffer preserves terminal payload after dropping excess deltas`() {
        val buffer = ResumeNotificationBuffer(
            "thread",
            generation = 7,
            maxEvents = 1,
            maxWeightChars = 256,
        )
        buffer.offer(delta("item/agentMessage/delta", "turn", "agent", "partial"))
        buffer.offer(delta("item/agentMessage/delta", "turn", "agent", "dropped"))
        buffer.offer(notification(
            "item/completed",
            """{"threadId":"thread","turnId":"turn","item":{"id":"agent","type":"agentMessage","text":"final"}}""",
        ))

        val replay = buffer.drain(emptyList())

        assertTrue(buffer.overflowed)
        assertEquals(listOf("item/completed"), replay.map { it.method })
    }

    @Test
    fun `bounded buffer never exceeds event limit for non delta payloads`() {
        val buffer = ResumeNotificationBuffer(
            "thread",
            generation = 7,
            maxEvents = 2,
            maxWeightChars = 4_096,
        )
        repeat(20) { index ->
            buffer.offer(notification("turn/started", """{"threadId":"thread","turn":{"id":"$index"}}"""))
        }

        val replay = buffer.drain(emptyList())

        assertTrue(buffer.overflowed)
        assertEquals(2, replay.size)
    }

    @Test
    fun `adjacent deltas are coalesced before replay`() {
        val buffer = ResumeNotificationBuffer("thread", generation = 7)
        repeat(1_000) { buffer.offer(delta("item/agentMessage/delta", "turn", "agent", "x")) }

        val replay = buffer.drain(emptyList())

        assertEquals(1, replay.size)
        assertEquals(1_000, replay.single().params["delta"].toString().trim('"').length)
    }

    @Test
    fun `interleaved streams retain wire order while adjacent fragments merge`() {
        val buffer = ResumeNotificationBuffer("thread", generation = 7)
        buffer.offer(delta("item/agentMessage/delta", "turn", "agent", "A1"))
        buffer.offer(delta("item/commandExecution/outputDelta", "turn", "command", "C1"))
        buffer.offer(delta("item/agentMessage/delta", "turn", "agent", "A2"))

        val replay = buffer.drain(emptyList())

        assertEquals(
            listOf("item/agentMessage/delta", "item/commandExecution/outputDelta", "item/agentMessage/delta"),
            replay.map { it.method },
        )
        assertEquals(listOf("A1", "C1", "A2"), replay.map { it.params["delta"].toString().trim('"') })
    }

    @Test
    fun `plan delta after response snapshot is not discarded`() {
        val buffer = ResumeNotificationBuffer("thread", generation = 7)
        buffer.offer(delta("item/plan/delta", "turn", "plan", "before", sequence = 9))
        buffer.offer(delta("item/plan/delta", "turn", "plan", "after", sequence = 11))
        val snapshot = listOf(
            TimelineEntry("plan", TimelineKind.Plan, text = "authoritative snapshot", turnId = "turn"),
        )

        val replay = buffer.drain(snapshot, snapshotSequence = 10)

        assertEquals(1, replay.size)
        assertEquals("\"after\"", replay.single().params["delta"].toString())
    }

    private fun delta(
        method: String,
        turnId: String,
        itemId: String,
        delta: String,
        sequence: Long = 0,
    ) = notification(
        method,
        """{"threadId":"thread","turnId":"$turnId","itemId":"$itemId","delta":"$delta"}""",
        sequence = sequence,
    )

    private fun indexedDelta(
        method: String,
        turnId: String,
        itemId: String,
        indexName: String,
        index: Int,
        delta: String,
    ) = notification(
        method,
        """{"threadId":"thread","turnId":"$turnId","itemId":"$itemId","$indexName":$index,"delta":"$delta"}""",
    )

    private fun notification(
        method: String,
        params: String,
        generation: Long = 7,
        sequence: Long = 0,
    ) = CodexNotification(
        generation,
        method,
        json.parseToJsonElement(params).jsonObject,
        sequence,
    )
}
