package top.asdb.codexremote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.codex.buildThreadResumeParams
import top.asdb.codexremote.codex.buildThreadTurnsListParams
import top.asdb.codexremote.codex.parseThreadTurnsPagePayload
import top.asdb.codexremote.codex.parseResumedThreadPayload
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind
import top.asdb.codexremote.data.ApprovalMode
import top.asdb.codexremote.data.TurnTiming

class ThreadPagingTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun resumeRequestsBoundedInitialTurnsPage() {
        val params = buildThreadResumeParams("thread-1", ApprovalMode.RequestApproval)

        assertEquals("thread-1", params["threadId"]?.toString()?.trim('"'))
        assertEquals("true", params["excludeTurns"]?.toString())
        val page = params["initialTurnsPage"]?.jsonObject
        assertEquals("4", page?.get("limit")?.toString())
        assertEquals("\"desc\"", page?.get("sortDirection")?.toString())
        assertEquals("\"full\"", page?.get("itemsView")?.toString())
    }

    @Test
    fun olderTurnPagesStaySmallAndRequestFullItems() {
        val params = buildThreadTurnsListParams("thread-1", "cursor-1")

        assertEquals("thread-1", params["threadId"]?.toString()?.trim('"'))
        assertEquals("cursor-1", params["cursor"]?.toString()?.trim('"'))
        assertEquals("4", params["limit"]?.toString())
        assertEquals("\"desc\"", params["sortDirection"]?.toString())
        assertEquals("\"full\"", params["itemsView"]?.toString())

        val summary = buildThreadTurnsListParams("thread-1", "cursor-1", itemsView = "summary")
        assertEquals("\"summary\"", summary["itemsView"]?.toString())
        val oneTurn = buildThreadTurnsListParams("thread-1", "cursor-1", limit = 1)
        assertEquals("1", oneTurn["limit"]?.toString())
    }

    @Test
    fun turnPageIsReversedToChronologicalTimeline() {
        val page = json.parseToJsonElement(
            """
            {
              "nextCursor": "older-cursor",
              "data": [
                {"id":"new-turn","status":"completed","startedAt":20,
                 "items":[{"id":"new-item","type":"agentMessage","text":"new"}]},
                {"id":"old-turn","status":"completed","startedAt":10,
                 "items":[{"id":"old-item","type":"agentMessage","text":"old"}]}
              ]
            }
            """.trimIndent(),
        ).jsonObject

        val parsed = parseThreadTurnsPagePayload(page)

        assertEquals("older-cursor", parsed.nextCursor)
        assertEquals(listOf("old", "new"), parsed.timeline.map { it.text })
        assertTrue(parsed.timeline.all { it.turnId.isNotBlank() })
    }

    @Test
    fun subAgentResumeHidesInheritedParentTurnsAndStopsPaging() {
        val response = json.parseToJsonElement(
            """
            {
              "thread": {
                "id": "child-thread",
                "threadSource": "subagent",
                "createdAt": 100,
                "source": {"subAgent": {}}
              },
              "initialTurnsPage": {
                "nextCursor": "parent-history",
                "data": [
                  {"id":"child-turn","status":"completed","startedAt":120,
                   "items":[{"id":"child-message","type":"agentMessage","text":"child only"}]},
                  {"id":"parent-turn","status":"completed","startedAt":90,
                   "items":[{"id":"parent-message","type":"agentMessage","text":"parent history"}]}
                ]
              }
            }
            """.trimIndent(),
        ).jsonObject

        val parsed = parseResumedThreadPayload(response, responseSequence = 1)

        assertEquals("child-thread", parsed.thread.id)
        assertEquals(listOf("child only"), parsed.timeline.map { it.text })
        assertEquals(listOf("child-turn"), parsed.turnIds)
        assertEquals(null, parsed.nextTurnsCursor)
    }

    @Test
    fun resumedActiveTurnRetainsTheServerStartTimeForTimingRecovery() {
        val response = json.parseToJsonElement(
            """
            {
              "thread": {"id":"thread-1","status":"active"},
              "initialTurnsPage": {
                "data": [
                  {"id":"turn-1","status":"inProgress","startedAt":1722475800123,"items":[]}
                ]
              }
            }
            """.trimIndent(),
        ).jsonObject

        val parsed = parseResumedThreadPayload(response, responseSequence = 1)

        assertEquals("turn-1", parsed.thread.activeTurnId)
        assertEquals(1722475800123L, parsed.activeTurnStartedAtMillis)
    }

    @Test
    fun runningTimingRecoveryUsesTheServerTimeOrKeepsTheExistingStart() {
        val current = TurnTiming(
            threadId = "thread-1",
            turnId = "turn-1",
            startedAtMillis = 1_000L,
        )

        val resumed = recoverRunningTurnTiming(
            threadId = "thread-1",
            activeTurnId = "turn-1",
            activeTurnStartedAtMillis = 500L,
            current = current,
        )
        val retained = recoverRunningTurnTiming(
            threadId = "thread-1",
            activeTurnId = "turn-1",
            activeTurnStartedAtMillis = null,
            current = current,
        )
        val otherThread = recoverRunningTurnTiming(
            threadId = "thread-1",
            activeTurnId = "turn-1",
            activeTurnStartedAtMillis = null,
            current = current.copy(threadId = "thread-2"),
        )
        val completed = recoverRunningTurnTiming(
            threadId = "thread-1",
            activeTurnId = "turn-1",
            activeTurnStartedAtMillis = null,
            current = current.copy(completedAtMillis = 2_000L),
        )

        assertEquals(500L, resumed?.startedAtMillis)
        assertEquals(1_000L, retained?.startedAtMillis)
        assertEquals(null, otherThread)
        assertEquals(null, completed)
    }

    @Test
    fun subAgentOlderPageStopsAtInheritedParentHistory() {
        val page = json.parseToJsonElement(
            """
            {
              "nextCursor": "even-older-parent-history",
              "data": [
                {"id":"recent-child-turn","status":"completed","startedAt":130,
                 "items":[{"id":"child-message","type":"agentMessage","text":"child"}]},
                {"id":"parent-turn","status":"completed","startedAt":90,
                 "items":[{"id":"parent-message","type":"agentMessage","text":"parent"}]}
              ]
            }
            """.trimIndent(),
        ).jsonObject

        val parsed = parseThreadTurnsPagePayload(page, subAgentCreatedAt = 100)

        assertEquals(listOf("child"), parsed.timeline.map { it.text })
        assertEquals(listOf("recent-child-turn"), parsed.turnIds)
        assertEquals(null, parsed.nextCursor)
    }

    @Test
    fun olderTimelineIsPrependedInOrderWithoutDuplicates() {
        fun entry(turn: String, id: String, text: String) = TimelineEntry(
            id = id,
            kind = TimelineKind.AgentMessage,
            text = text,
            turnId = turn,
        )
        val existing = listOf(entry("turn-2", "same", "newer"), entry("turn-3", "last", "latest"))
        val older = listOf(
            entry("turn-0", "first", "oldest"),
            entry("turn-1", "middle", "older"),
            entry("turn-2", "same", "duplicate"),
            entry("turn-1", "middle", "duplicate in page"),
        )

        val merged = prependOlderTimeline(existing, older)

        assertTrue(merged.accepted)
        assertEquals(listOf("oldest", "older", "newer", "latest"), merged.timeline.map { it.text })
    }

    @Test
    fun olderTimelineStopsBeforeCrossingMobileMemoryBound() {
        val existing = listOf(
            TimelineEntry("new", TimelineKind.AgentMessage, text = "1234", turnId = "turn-new"),
        )
        val older = listOf(
            TimelineEntry("old", TimelineKind.AgentMessage, text = "x".repeat(100), turnId = "turn-old"),
        )

        val merged = prependOlderTimeline(existing, older, maxWeightChars = 40, maxEntries = 10)

        assertTrue(!merged.accepted)
        assertEquals(existing, merged.timeline)
    }

    @Test
    fun activeTimelineKeepsOnlyNewestContiguousEntriesWithinBound() {
        val timeline = (1..5).map { index ->
            TimelineEntry(
                id = "item-$index",
                kind = TimelineKind.AgentMessage,
                text = "x".repeat(10),
                turnId = "turn-$index",
            )
        }

        val bounded = boundActiveTimeline(timeline, maxWeightChars = 60, maxEntries = 3)

        assertTrue(bounded.truncated)
        assertEquals(listOf("item-4", "item-5"), bounded.timeline.map { it.id })
    }

    @Test
    fun changedResumeCursorDropsCachedPagesToAvoidHistoryGaps() {
        fun entry(turn: String, text: String) = TimelineEntry(
            id = turn,
            kind = TimelineKind.AgentMessage,
            text = text,
            turnId = turn,
        )
        val cached = listOf(entry("turn-7", "7"), entry("turn-10", "10"))
        val refreshed = listOf(entry("turn-17", "17"), entry("turn-20", "20"))

        val result = reconcileResumedTimeline(
            cachedTimeline = cached,
            cachedNextCursor = "after-turn-7",
            refreshedTimeline = refreshed,
            refreshedNextCursor = "after-turn-17",
            cachedThreadUpdatedAt = 10,
            refreshedThreadUpdatedAt = 20,
        )

        assertEquals(refreshed, result.timeline)
        assertEquals("after-turn-17", result.nextCursor)
    }

    @Test
    fun changedThreadRevisionDropsOverlappingCachedHistory() {
        fun entry(turn: String) = TimelineEntry(
            id = turn,
            kind = TimelineKind.AgentMessage,
            text = turn,
            turnId = turn,
        )
        val cached = listOf(entry("turn-1"), entry("turn-2"))
        val refreshed = listOf(entry("turn-2"), entry("turn-3"))

        val result = reconcileResumedTimeline(
            cachedTimeline = cached,
            cachedNextCursor = "old-cursor",
            refreshedTimeline = refreshed,
            refreshedNextCursor = "fresh-cursor",
            cachedThreadUpdatedAt = 10,
            refreshedThreadUpdatedAt = 11,
        )

        assertEquals(refreshed, result.timeline)
        assertEquals("fresh-cursor", result.nextCursor)
    }

    @Test
    fun missingCachedCursorUsesFreshPageAfterMemoryTruncation() {
        fun entry(turn: String) = TimelineEntry(
            id = turn,
            kind = TimelineKind.AgentMessage,
            text = turn,
            turnId = turn,
        )
        val cached = listOf(entry("turn-2"), entry("turn-3"))
        val refreshed = listOf(entry("turn-3"), entry("turn-4"))

        val result = reconcileResumedTimeline(
            cachedTimeline = cached,
            cachedNextCursor = null,
            refreshedTimeline = refreshed,
            refreshedNextCursor = "fresh-older",
            cachedThreadUpdatedAt = 10,
            refreshedThreadUpdatedAt = 10,
        )

        assertEquals(refreshed, result.timeline)
        assertEquals("fresh-older", result.nextCursor)
    }

    @Test
    fun unchangedResumeCursorRetainsAlreadyLoadedOlderPages() {
        fun entry(turn: String, id: String, text: String) = TimelineEntry(
            id = id,
            kind = TimelineKind.AgentMessage,
            text = text,
            turnId = turn,
        )
        val cached = listOf(
            entry("turn-1", "old", "older cached"),
            entry("turn-2", "recent", "stale recent"),
        )
        val refreshed = listOf(entry("turn-2", "recent", "fresh recent"))

        val result = reconcileResumedTimeline(
            cachedTimeline = cached,
            cachedNextCursor = "same-cursor",
            refreshedTimeline = refreshed,
            refreshedNextCursor = "same-cursor",
            cachedThreadUpdatedAt = 10,
            refreshedThreadUpdatedAt = 10,
        )

        assertEquals(listOf("older cached", "fresh recent"), result.timeline.map { it.text })
        assertEquals("same-cursor", result.nextCursor)
    }

    @Test
    fun overlappingResumeRetainsLoadedPagesAndTheirOlderCursor() {
        fun entry(turn: String) = TimelineEntry(
            id = turn,
            kind = TimelineKind.AgentMessage,
            text = turn,
            turnId = turn,
        )
        val cached = (33..40).map { entry("turn-$it") }
        val refreshed = (37..40).map { entry("turn-$it") }

        val result = reconcileResumedTimeline(
            cachedTimeline = cached,
            cachedNextCursor = "after-turn-33",
            refreshedTimeline = refreshed,
            refreshedNextCursor = "after-turn-37",
            cachedThreadUpdatedAt = 10,
            refreshedThreadUpdatedAt = 10,
        )

        assertEquals((33..40).map { "turn-$it" }, result.timeline.map { it.turnId })
        assertEquals("after-turn-33", result.nextCursor)
    }

    @Test
    fun unchangedSummaryDoesNotReplaceCachedFullTurnItems() {
        val cached = listOf(
            TimelineEntry("user", TimelineKind.UserMessage, text = "question", turnId = "turn-1"),
            TimelineEntry("command", TimelineKind.Command, command = "make test", turnId = "turn-1"),
            TimelineEntry("agent", TimelineKind.AgentMessage, text = "answer", turnId = "turn-1"),
        )
        val summary = listOf(
            cached.first(),
            cached.last().copy(text = "updated answer"),
        )

        val result = reconcileResumedTimeline(
            cachedTimeline = cached,
            cachedNextCursor = "older",
            refreshedTimeline = summary,
            refreshedNextCursor = null,
            refreshedTurnIds = listOf("turn-1"),
            cachedThreadUpdatedAt = 10,
            refreshedThreadUpdatedAt = 10,
            refreshedItemsView = "summary",
        )

        assertEquals(listOf("question", "", "updated answer"), result.timeline.map { it.text })
        assertEquals("make test", result.timeline[1].command)
        assertEquals("older", result.nextCursor)
    }

    @Test
    fun unchangedNotLoadedPageKeepsCachedDetails() {
        val cached = listOf(
            TimelineEntry("command", TimelineKind.Command, command = "make test", turnId = "turn-1"),
        )

        val result = reconcileResumedTimeline(
            cachedTimeline = cached,
            cachedNextCursor = "older",
            refreshedTimeline = emptyList(),
            refreshedNextCursor = null,
            refreshedTurnIds = listOf("turn-1"),
            cachedThreadUpdatedAt = 10,
            refreshedThreadUpdatedAt = 10,
            refreshedItemsView = "notLoaded",
        )

        assertEquals(cached, result.timeline)
        assertEquals("older", result.nextCursor)
    }

    @Test
    fun resumedPagedTurnsAreReversedButLegacyTurnsKeepWireOrder() {
        val paged = json.parseToJsonElement(
            """{
              "thread":{"id":"thread-1","cwd":"/tmp","turns":[]},
              "initialTurnsPage":{"nextCursor":"older","data":[
                {"id":"turn-2","items":[{"id":"item-2","type":"agentMessage","text":"new"}]},
                {"id":"turn-1","items":[{"id":"item-1","type":"agentMessage","text":"old"}]}
              ]}
            }""",
        ).jsonObject
        val legacy = json.parseToJsonElement(
            """{"thread":{"id":"thread-1","cwd":"/tmp","turns":[
              {"id":"turn-1","items":[{"id":"item-1","type":"agentMessage","text":"old"}]},
              {"id":"turn-2","items":[{"id":"item-2","type":"agentMessage","text":"new"}]}
            ]}}""",
        ).jsonObject

        val pagedResult = parseResumedThreadPayload(paged, 10)
        val legacyResult = parseResumedThreadPayload(legacy, 11)

        assertEquals(listOf("old", "new"), pagedResult.timeline.map { it.text })
        assertEquals("older", pagedResult.nextTurnsCursor)
        assertEquals(10L, pagedResult.responseSequence)
        assertEquals(listOf("old", "new"), legacyResult.timeline.map { it.text })
        assertEquals(null, legacyResult.nextTurnsCursor)
    }
}
