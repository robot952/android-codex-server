package top.asdb.codexremote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.codex.CodexEventReducer
import top.asdb.codexremote.codex.CodexPayloadParser
import top.asdb.codexremote.codex.MAX_COMMAND_OUTPUT_CHARS
import top.asdb.codexremote.codex.MAX_TIMELINE_TEXT_CHARS
import top.asdb.codexremote.codex.OUTPUT_TRUNCATION_MARKER
import top.asdb.codexremote.codex.TEXT_TRUNCATION_MARKER
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.ThreadGoalStatus
import top.asdb.codexremote.data.TimelineKind
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.data.TokenUsageBreakdown

class CodexPayloadParserTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun parsesAndReducesTokenUsageOnlyForActiveThread() {
        val usage = json.parseToJsonElement(
            """
            {
              "threadId":"thr-1",
              "tokenUsage": {
                "last": {"cachedInputTokens":2,"inputTokens":3,"outputTokens":5,"reasoningOutputTokens":1,"totalTokens":10},
                "total": {"cachedInputTokens":20,"inputTokens":30,"outputTokens":50,"reasoningOutputTokens":10,"totalTokens":100},
                "modelContextWindow": 200000
              }
            }
            """.trimIndent(),
        ).jsonObject
        val active = AppUiState(activeThread = top.asdb.codexremote.data.CodexThread(
            id = "thr-1", title = "", preview = "", cwd = "", source = "", status = "idle",
            createdAt = 0, updatedAt = 0, cliVersion = "",
        ))
        val reduced = CodexEventReducer.reduce(active, "thread/tokenUsage/updated", usage)
        assertEquals(200000L, reduced.tokenUsage?.modelContextWindow)
        assertEquals(10L, reduced.tokenUsage?.last?.totalTokens)

        val ignored = CodexEventReducer.reduce(
            active,
            "thread/tokenUsage/updated",
            buildJsonObject {
                put("threadId", "other")
                put("tokenUsage", usage.getValue("tokenUsage"))
            },
        )
        assertEquals(null, ignored.tokenUsage)

        val unknownWindow = json.parseToJsonElement(
            """{
              "threadId":"thr-1",
              "tokenUsage": {
                "last": {"cachedInputTokens":0,"inputTokens":1,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":1},
                "total": {"cachedInputTokens":0,"inputTokens":1,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":1},
                "modelContextWindow": null
              }
            }""",
        ).jsonObject
        val withoutWindow = CodexEventReducer.reduce(active, "thread/tokenUsage/updated", unknownWindow)
        assertEquals(0L, withoutWindow.tokenUsage?.modelContextWindow)
    }

    @Test
    fun incompleteTokenUsageUpdateDoesNotClearKnownContextWindow() {
        val knownUsage = TokenUsage(
            last = TokenUsageBreakdown(totalTokens = 129_000),
            modelContextWindow = 353_000,
        )
        val active = AppUiState(
            activeThread = top.asdb.codexremote.data.CodexThread(
                id = "thr-1", title = "", preview = "", cwd = "", source = "", status = "idle",
                createdAt = 0, updatedAt = 0, cliVersion = "",
            ),
            tokenUsage = knownUsage,
        )

        val reduced = CodexEventReducer.reduce(
            active,
            "thread/tokenUsage/updated",
            buildJsonObject {
                put("threadId", "thr-1")
                put("tokenUsage", buildJsonObject {
                    put("last", buildJsonObject { put("totalTokens", 1) })
                    put("total", buildJsonObject { put("totalTokens", 1) })
                })
            },
        )

        assertEquals(knownUsage, reduced.tokenUsage)
    }

    @Test
    fun parsesAndReducesNativeThreadGoalNotifications() {
        val active = AppUiState(activeThread = top.asdb.codexremote.data.CodexThread(
            id = "thr-1", title = "", preview = "", cwd = "", source = "", status = "idle",
            createdAt = 0, updatedAt = 0, cliVersion = "",
        ))
        val updated = json.parseToJsonElement(
            """{
              "threadId":"thr-1",
              "goal":{
                "threadId":"thr-1",
                "objective":"完成迁移并保持测试通过",
                "status":"active",
                "createdAt":1000,
                "updatedAt":2000,
                "timeUsedSeconds":24,
                "tokensUsed":1234,
                "tokenBudget":4000
              }
            }""",
        ).jsonObject

        val reduced = CodexEventReducer.reduce(active, "thread/goal/updated", updated)
        assertEquals("完成迁移并保持测试通过", reduced.activeGoal?.objective)
        assertEquals(ThreadGoalStatus.Active, reduced.activeGoal?.status)
        assertEquals(24L, reduced.activeGoal?.timeUsedSeconds)
        assertEquals(4_000L, reduced.activeGoal?.tokenBudget)

        val paused = CodexEventReducer.reduce(
            reduced,
            "thread/goal/updated",
            json.parseToJsonElement(
                updated.toString().replace("\"active\"", "\"paused\""),
            ).jsonObject,
        )
        assertEquals(ThreadGoalStatus.Paused, paused.activeGoal?.status)

        val untouched = CodexEventReducer.reduce(
            paused,
            "thread/goal/updated",
            json.parseToJsonElement(
                updated.toString().replace("\"thr-1\"", "\"other\""),
            ).jsonObject,
        )
        assertEquals(ThreadGoalStatus.Paused, untouched.activeGoal?.status)

        val cleared = CodexEventReducer.reduce(
            paused,
            "thread/goal/cleared",
            json.parseToJsonElement("""{"threadId":"thr-1"}""").jsonObject,
        )
        assertEquals(null, cleared.activeGoal)
    }

    @Test
    fun `context compaction is pending until completed and accepts fresh usage`() {
        val active = AppUiState(activeThread = top.asdb.codexremote.data.CodexThread(
            id = "thr-1", title = "", preview = "", cwd = "", source = "", status = "idle",
            createdAt = 0, updatedAt = 0, cliVersion = "",
        ))
        val item = json.parseToJsonElement(
            """{"threadId":"thr-1","turnId":"turn-1","item":{"id":"compact-1","type":"contextCompaction"}}""",
        ).jsonObject

        val started = CodexEventReducer.reduce(active, "item/started", item)
        assertEquals("正在压缩上下文", started.timeline.single().text)
        assertEquals("inProgress", started.timeline.single().status)

        val completed = CodexEventReducer.reduce(started, "item/completed", item)
        assertEquals("上下文已压缩", completed.timeline.single().text)
        assertEquals("completed", completed.timeline.single().status)

        val usage = json.parseToJsonElement(
            """{
              "threadId":"thr-1","turnId":"turn-1",
              "tokenUsage": {
                "last": {"cachedInputTokens":0,"inputTokens":20,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":20},
                "total": {"cachedInputTokens":0,"inputTokens":200,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":200},
                "modelContextWindow": 1000
              }
            }""",
        ).jsonObject
        val refreshed = CodexEventReducer.reduce(completed, "thread/tokenUsage/updated", usage)
        assertEquals(20L, refreshed.tokenUsage?.last?.totalTokens)
    }

    @Test
    fun parsesThreadListAndTimeline() {
        val list = json.parseToJsonElement(
            """
            {
              "data": [{
                "id": "thr-1",
                "name": "修复构建",
                "preview": "修复构建失败",
                "cwd": "/srv/app",
                "source": "vscode",
                "status": {"type": "idle"},
                "createdAt": 10,
                "updatedAt": 20,
                "cliVersion": "0.144.6"
              }]
            }
            """.trimIndent(),
        ).jsonObject
        val threads = CodexPayloadParser.parseThreads(list)
        assertEquals(1, threads.size)
        assertEquals("修复构建", threads.single().title)
        assertEquals("vscode", threads.single().source)

        val threadPayload = json.parseToJsonElement(
            """
            {
              "thread": {
                "id": "thr-1",
                "preview": "修复构建失败",
                "cwd": "/srv/app",
                "source": "appServer",
                "status": {"type": "idle"},
                "createdAt": 10,
                "updatedAt": 20,
                "cliVersion": "0.144.6",
                "turns": [{
                  "id": "turn-1",
                  "status": "completed",
                  "items": [
                    {"id":"u1","type":"userMessage","content":[{"type":"text","text":"请修复"}]},
                    {"id":"a1","type":"agentMessage","text":"已经完成"},
                    {"id":"c1","type":"commandExecution","command":"./gradlew test","cwd":"/srv/app","status":"completed","aggregatedOutput":"BUILD SUCCESSFUL","commandActions":[]},
                    {"id":"f1","type":"fileChange","status":"completed","changes":[{"path":"app.kt","kind":{"type":"update"},"diff":"--- a/app.kt\n+++ b/app.kt\n-old\n+new"}]}
                  ]
                }]
              }
            }
            """.trimIndent(),
        ).jsonObject
        val (_, timeline) = CodexPayloadParser.parseThreadPayload(threadPayload)
        assertEquals(4, timeline.size)
        assertEquals(TimelineKind.Command, timeline[2].kind)
        assertEquals("BUILD SUCCESSFUL", timeline[2].output)
        assertEquals(1, timeline[3].changes.single().additions)
        assertEquals(1, timeline[3].changes.single().deletions)
    }

    @Test
    fun parsesSubAgentActivityAsDedicatedEntryAndTracksCompletion() {
        val item = json.parseToJsonElement(
            """
            {
              "id":"agent-1",
              "type":"subAgentActivity",
              "agentPath":"root/researcher",
              "agentThreadId":"sub-thread-1",
              "kind":"started"
            }
            """.trimIndent(),
        ).jsonObject

        val entry = requireNotNull(CodexPayloadParser.parseItem(item, "turn-1"))
        assertEquals(TimelineKind.SubAgent, entry.kind)
        assertEquals("", entry.title)
        assertEquals("root/researcher", entry.subAgentPath)
        assertEquals("sub-thread-1", entry.subAgentThreadId)
        assertEquals("started", entry.subAgentActivity)
        assertEquals("running", entry.status)
        assertEquals("", entry.text)

        val notification = buildJsonObject {
            put("threadId", "thread-1")
            put("turnId", "turn-1")
            put("item", item)
        }
        val started = CodexEventReducer.reduce(AppUiState(), "item/started", notification)
        assertEquals("running", started.timeline.single().status)

        val completed = CodexEventReducer.reduce(started, "item/completed", notification)
        assertEquals("running", completed.timeline.single().status)
        assertEquals(1, completed.timeline.size)
    }

    @Test
    fun collabAgentStatesUpdateMatchingSubAgentActivity() {
        val subAgent = json.parseToJsonElement(
            """
            {
              "id":"agent-1",
              "type":"subAgentActivity",
              "agentPath":"root/researcher",
              "agentThreadId":"sub-thread-1",
              "kind":"started"
            }
            """.trimIndent(),
        ).jsonObject
        val collab = json.parseToJsonElement(
            """
            {
              "id":"wait-1",
              "type":"collabAgentToolCall",
              "tool":"wait",
              "status":"completed",
              "senderThreadId":"thread-1",
              "receiverThreadIds":["sub-thread-1"],
              "agentsStates":{
                "sub-thread-1":{"status":"completed","message":"已完成"}
              }
            }
            """.trimIndent(),
        ).jsonObject

        val base = buildJsonObject {
            put("threadId", "thread-1")
            put("turnId", "turn-1")
            put("item", subAgent)
        }
        val started = CodexEventReducer.reduce(AppUiState(), "item/started", base)
        assertEquals("running", started.timeline.single().status)

        val completed = CodexEventReducer.reduce(
            started,
            "item/completed",
            buildJsonObject {
                put("threadId", "thread-1")
                put("turnId", "turn-1")
                put("item", collab)
            },
        )
        assertEquals("completed", completed.timeline.first { it.kind == TimelineKind.SubAgent }.status)
    }

    @Test
    fun lateActivityNotificationDoesNotResurrectCompletedSubAgent() {
        val startedItem = json.parseToJsonElement(
            """
            {
              "threadId":"thread-1","turnId":"turn-1",
              "item":{
                "id":"agent-1","type":"subAgentActivity",
                "agentPath":"root/researcher","agentThreadId":"sub-thread-1","kind":"started"
              }
            }
            """.trimIndent(),
        ).jsonObject
        var state = CodexEventReducer.reduce(AppUiState(), "item/started", startedItem)
        state = CodexEventReducer.reduce(
            state,
            "item/completed",
            json.parseToJsonElement(
                """
                {
                  "threadId":"thread-1","turnId":"turn-1",
                  "item":{
                    "id":"wait-1","type":"collabAgentToolCall","tool":"wait","status":"completed",
                    "senderThreadId":"thread-1","receiverThreadIds":["sub-thread-1"],
                    "agentsStates":{"sub-thread-1":{"status":"completed"}}
                  }
                }
                """.trimIndent(),
            ).jsonObject,
        )
        val lateActivity = CodexEventReducer.reduce(
            state,
            "item/completed",
            startedItem,
        )

        assertEquals("completed", lateActivity.timeline.single { it.kind == TimelineKind.SubAgent }.status)
    }

    @Test
    fun collabAgentStatesOnlyUpdateSubAgentsInTheSameTurn() {
        val old = json.parseToJsonElement(
            """
            {
              "threadId":"thread-1","turnId":"turn-old",
              "item":{
                "id":"old-agent","type":"subAgentActivity",
                "agentPath":"root/researcher","agentThreadId":"sub-thread-1","kind":"started"
              }
            }
            """.trimIndent(),
        ).jsonObject
        val current = json.parseToJsonElement(
            """
            {
              "threadId":"thread-1","turnId":"turn-current",
              "item":{
                "id":"current-agent","type":"subAgentActivity",
                "agentPath":"root/researcher","agentThreadId":"sub-thread-1","kind":"started"
              }
            }
            """.trimIndent(),
        ).jsonObject
        var state = CodexEventReducer.reduce(AppUiState(), "item/started", old)
        state = CodexEventReducer.reduce(state, "item/started", current)
        state = CodexEventReducer.reduce(
            state,
            "item/completed",
            json.parseToJsonElement(
                """
                {
                  "threadId":"thread-1","turnId":"turn-current",
                  "item":{
                    "id":"wait-current","type":"collabAgentToolCall","tool":"wait","status":"completed",
                    "senderThreadId":"thread-1","receiverThreadIds":["sub-thread-1"],
                    "agentsStates":{"sub-thread-1":{"status":"completed"}}
                  }
                }
                """.trimIndent(),
            ).jsonObject,
        )

        assertEquals("running", state.timeline.first { it.id == "old-agent" }.status)
        assertEquals("completed", state.timeline.first { it.id == "current-agent" }.status)
    }

    @Test
    fun parentTurnCompletionStopsUnresolvedSubAgentSpinner() {
        val started = CodexEventReducer.reduce(
            AppUiState(),
            "item/started",
            json.parseToJsonElement(
                """
                {
                  "threadId":"thread-1",
                  "turnId":"turn-1",
                  "item":{
                    "id":"agent-1",
                    "type":"subAgentActivity",
                    "agentPath":"root/researcher",
                    "agentThreadId":"sub-thread-1",
                    "kind":"started"
                  }
                }
                """.trimIndent(),
            ).jsonObject,
        )
        val completed = CodexEventReducer.reduce(
            started.copy(
                activeThread = top.asdb.codexremote.data.CodexThread(
                    id = "thread-1", title = "", preview = "", cwd = "", source = "",
                    status = "active", createdAt = 0, updatedAt = 0, cliVersion = "",
                ),
                activeTurnId = "turn-1",
                running = true,
            ),
            "turn/completed",
            json.parseToJsonElement(
                """{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}""",
            ).jsonObject,
        )
        assertEquals("completed", completed.timeline.single().status)
    }

    @Test
    fun parentInterruptedTurnMarksUnresolvedSubAgentInterrupted() {
        val started = CodexEventReducer.reduce(
            AppUiState(),
            "item/started",
            json.parseToJsonElement(
                """
                {
                  "threadId":"thread-1","turnId":"turn-1",
                  "item":{
                    "id":"agent-1","type":"subAgentActivity",
                    "agentPath":"root/researcher","agentThreadId":"sub-thread-1","kind":"started"
                  }
                }
                """.trimIndent(),
            ).jsonObject,
        )
        val interrupted = CodexEventReducer.reduce(
            started.copy(
                activeThread = top.asdb.codexremote.data.CodexThread(
                    id = "thread-1", title = "", preview = "", cwd = "", source = "", status = "active",
                    createdAt = 0, updatedAt = 0, cliVersion = "",
                ),
                activeTurnId = "turn-1",
                running = true,
            ),
            "turn/completed",
            json.parseToJsonElement(
                """{"threadId":"thread-1","turn":{"id":"turn-1","status":"interrupted"}}""",
            ).jsonObject,
        )

        assertEquals("interrupted", interrupted.timeline.single().status)
    }

    @Test
    fun marksSubAgentActivityFromCompletedTurnAsFinished() {
        val payload = json.parseToJsonElement(
            """
            {
              "thread": {
                "id":"thread-1",
                "turns":[{
                  "id":"turn-1",
                  "status":"completed",
                  "items":[{
                    "id":"agent-1",
                    "type":"subAgentActivity",
                    "agentPath":"root/researcher",
                    "agentThreadId":"sub-thread-1",
                    "kind":"started"
                  }]
                }]
              }
            }
            """.trimIndent(),
        ).jsonObject

        val (_, timeline) = CodexPayloadParser.parseThreadPayload(payload)
        assertEquals("completed", timeline.single().status)
        assertEquals(TimelineKind.SubAgent, timeline.single().kind)
    }

    @Test
    fun marksSubAgentActivityFromFailedTurnAsErrored() {
        val payload = json.parseToJsonElement(
            """
            {
              "thread": {
                "id":"thread-1",
                "turns":[{
                  "id":"turn-1",
                  "status":"failed",
                  "items":[{
                    "id":"agent-1","type":"subAgentActivity",
                    "agentPath":"root/researcher","agentThreadId":"sub-thread-1","kind":"started"
                  }]
                }]
              }
            }
            """.trimIndent(),
        ).jsonObject

        val (_, timeline) = CodexPayloadParser.parseThreadPayload(payload)
        assertEquals("errored", timeline.single().status)
    }

    @Test
    fun reducesStreamingNotificationsWithoutDuplicatingItems() {
        val started = json.parseToJsonElement(
            """{"turn":{"id":"turn-1","status":"inProgress","items":[]}}""",
        ).jsonObject
        val item = json.parseToJsonElement(
            """{"threadId":"thr-1","turnId":"turn-1","item":{"id":"a1","type":"agentMessage","text":""}}""",
        ).jsonObject
        val delta = json.parseToJsonElement(
            """{"threadId":"thr-1","turnId":"turn-1","itemId":"a1","delta":"你好"}""",
        ).jsonObject

        var state = CodexEventReducer.reduce(AppUiState(), "turn/started", started)
        state = CodexEventReducer.reduce(state, "item/started", item)
        state = CodexEventReducer.reduce(state, "item/agentMessage/delta", delta)
        state = CodexEventReducer.reduce(state, "item/agentMessage/delta", delta)

        assertTrue(state.running)
        assertEquals("turn-1", state.activeTurnId)
        assertEquals(1, state.timeline.size)
        assertEquals("你好你好", state.timeline.single().text)
    }

    @Test
    fun capsStreamedTextAndStopsCopyingAfterTheLimit() {
        val contentLimit = MAX_TIMELINE_TEXT_CHARS - TEXT_TRUNCATION_MARKER.length
        val initial = buildJsonObject {
            put("itemId", "agent-large")
            put("delta", "a".repeat(contentLimit))
        }
        val overflow = buildJsonObject {
            put("itemId", "agent-large")
            put("delta", "b".repeat(TEXT_TRUNCATION_MARKER.length + 1))
        }
        val ignored = buildJsonObject {
            put("itemId", "agent-large")
            put("delta", "must-not-be-appended")
        }

        var state = CodexEventReducer.reduce(AppUiState(), "item/agentMessage/delta", initial)
        state = CodexEventReducer.reduce(state, "item/agentMessage/delta", overflow)
        val truncated = state.timeline.single().text

        assertEquals(MAX_TIMELINE_TEXT_CHARS, truncated.length)
        assertTrue(truncated.endsWith(TEXT_TRUNCATION_MARKER))
        state = CodexEventReducer.reduce(state, "item/agentMessage/delta", ignored)
        assertSame(truncated, state.timeline.single().text)
    }

    @Test
    fun preservesNormalReasoningPlanAndCommandDeltas() {
        var state = AppUiState()
        listOf(
            "item/reasoning/textDelta" to "reasoning",
            "item/plan/delta" to "plan",
            "item/commandExecution/outputDelta" to "command",
        ).forEach { (method, itemId) ->
            listOf("first", "-second").forEach { value ->
                state = CodexEventReducer.reduce(state, method, buildJsonObject {
                    put("itemId", itemId)
                    put("delta", value)
                })
            }
        }

        assertEquals("first-second", state.timeline.first { it.id == "reasoning" }.text)
        assertEquals("first-second", state.timeline.first { it.id == "plan" }.text)
        assertEquals("first-second", state.timeline.first { it.id == "command" }.output)
    }

    @Test
    fun `keeps indexed reasoning summary separate from raw reasoning`() {
        var state = AppUiState()
        fun reasoning(method: String, indexName: String, index: Int, delta: String = "") {
            state = CodexEventReducer.reduce(state, method, buildJsonObject {
                put("itemId", "reasoning")
                put("turnId", "turn-1")
                put(indexName, index)
                if (delta.isNotEmpty()) put("delta", delta)
            })
        }

        reasoning("item/reasoning/textDelta", "contentIndex", 0, "raw-content")
        assertEquals("raw-content", state.timeline.single().text)

        reasoning("item/reasoning/summaryPartAdded", "summaryIndex", 1)
        reasoning("item/reasoning/summaryTextDelta", "summaryIndex", 1, "second")
        reasoning("item/reasoning/summaryTextDelta", "summaryIndex", 0, "first")
        reasoning("item/reasoning/textDelta", "contentIndex", 0, "-more-raw")

        val entry = state.timeline.single()
        assertEquals("first\n\nsecond", entry.text)
        assertEquals(listOf("first", "second"), entry.reasoningSummary)
        assertEquals(listOf("raw-content-more-raw"), entry.reasoningContent)
    }

    @Test
    fun `parses object shaped reasoning parts from resumed thread`() {
        val item = json.parseToJsonElement(
            """{
              "id":"reasoning-1",
              "type":"reasoning",
              "summary":[{"type":"summary_text","text":"summary"}],
              "content":[{"type":"reasoning_text","text":"raw"}]
            }""",
        ).jsonObject

        val entry = requireNotNull(CodexPayloadParser.parseItem(item, "turn-1"))
        assertEquals("summary", entry.text)
        assertEquals(listOf("summary"), entry.reasoningSummary)
        assertEquals(listOf("raw"), entry.reasoningContent)
    }

    @Test
    fun capsCommandOutputAndCompletedPayloads() {
        val commandDelta = buildJsonObject {
            put("itemId", "command-large")
            put("delta", "x".repeat(MAX_COMMAND_OUTPUT_CHARS + 1))
        }
        val state = CodexEventReducer.reduce(
            AppUiState(),
            "item/commandExecution/outputDelta",
            commandDelta,
        )
        assertEquals(MAX_COMMAND_OUTPUT_CHARS, state.timeline.single().output.length)
        assertTrue(state.timeline.single().output.endsWith(OUTPUT_TRUNCATION_MARKER))

        val completed = buildJsonObject {
            put("id", "agent-completed")
            put("type", "agentMessage")
            put("text", "z".repeat(MAX_TIMELINE_TEXT_CHARS + 1))
        }
        val parsed = requireNotNull(CodexPayloadParser.parseItem(completed, "turn-1"))
        assertEquals(MAX_TIMELINE_TEXT_CHARS, parsed.text.length)
        assertTrue(parsed.text.endsWith(TEXT_TRUNCATION_MARKER))
    }

    @Test
    fun parsesCommandApprovalRequest() {
        val request = json.parseToJsonElement(
            """
            {
              "id": 42,
              "method": "item/commandExecution/requestApproval",
              "params": {
                "threadId":"thr-1",
                "turnId":"turn-1",
                "itemId":"cmd-1",
                "command":"npm test",
                "cwd":"/srv/app",
                "startedAtMs":1
              }
            }
            """.trimIndent(),
        ).jsonObject
        val approval = requireNotNull(CodexPayloadParser.parseServerRequest(request))
        assertEquals("42", approval.requestId)
        assertEquals("npm test", approval.command)
        assertEquals("/srv/app", approval.cwd)
    }

    @Test
    fun extractsActiveTurnIdAndAllUserInputQuestions() {
        val payload = json.parseToJsonElement(
            """
            {
              "thread": {
                "id": "thr-1",
                "cwd": "/srv/app",
                "status": {"type":"active","activeFlags":[]},
                "turns": [
                  {"id":"old","status":"completed","items":[]},
                  {"id":"live","status":"inProgress","items":[]}
                ]
              }
            }
            """.trimIndent(),
        ).jsonObject
        val (thread, _) = CodexPayloadParser.parseThreadPayload(payload)
        assertEquals("live", thread.activeTurnId)

        val request = json.parseToJsonElement(
            """
            {
              "id":"input-1",
              "method":"item/tool/requestUserInput",
              "params":{
                "threadId":"thr-1","turnId":"live","itemId":"item-1",
                "questions":[
                  {"id":"one","header":"模式","question":"选择模式","options":[{"label":"快速","description":"快"}]},
                  {"id":"two","header":"密钥","question":"输入密钥","isSecret":true}
                ]
              }
            }
            """.trimIndent(),
        ).jsonObject
        val approval = requireNotNull(CodexPayloadParser.parseServerRequest(request))
        assertEquals(2, approval.questions.size)
        assertEquals("快速", approval.questions.first().options.single().label)
        assertEquals("快", approval.questions.first().options.single().description)
        assertTrue(approval.questions[1].isSecret)
    }

    @Test
    fun ignoresUnsupportedServerRequestsAndTracksThreadStatus() {
        val unknown = json.parseToJsonElement(
            """{"id":9,"method":"mcpServer/elicitation/request","params":{}}""",
        ).jsonObject
        assertEquals(null, CodexPayloadParser.parseServerRequest(unknown))

        val activeThread = top.asdb.codexremote.data.CodexThread(
            id = "thr-1", title = "任务", preview = "", cwd = "/srv/app", source = "appServer",
            status = "active", createdAt = 0, updatedAt = 0, cliVersion = "0.144.6",
        )
        val state = AppUiState(activeThread = activeThread, activeTurnId = "turn-1", running = true)
        val idle = json.parseToJsonElement(
            """{"threadId":"thr-1","status":{"type":"idle"}}""",
        ).jsonObject
        val reduced = CodexEventReducer.reduce(state, "thread/status/changed", idle)
        assertEquals("idle", reduced.activeThread?.status)
        assertTrue(!reduced.running)
        assertEquals(null, reduced.activeTurnId)

        val error = json.parseToJsonElement(
            """{"threadId":"thr-1","turnId":"turn-1","error":{"message":"网络中断"},"willRetry":true}""",
        ).jsonObject
        val withError = CodexEventReducer.reduce(state, "error", error)
        assertEquals("网络中断", withError.timeline.single().text)
    }

    @Test
    fun keepsThreadListRuntimeStatusInSyncWithTurnNotifications() {
        val listed = top.asdb.codexremote.data.CodexThread(
            id = "thr-1", title = "任务", preview = "", cwd = "/srv/app", source = "appServer",
            status = "idle", createdAt = 0, updatedAt = 0, cliVersion = "0.144.6",
        )
        val base = AppUiState(threads = listOf(listed))
        val started = CodexEventReducer.reduce(
            base,
            "turn/started",
            json.parseToJsonElement(
                """{"threadId":"thr-1","turn":{"id":"turn-1"}}""",
            ).jsonObject,
        )
        assertEquals("active", started.threads.single().status)
        assertEquals("turn-1", started.threads.single().activeTurnId)

        val completed = CodexEventReducer.reduce(
            started,
            "turn/completed",
            json.parseToJsonElement(
                """{"threadId":"thr-1","turn":{"id":"turn-1"}}""",
            ).jsonObject,
        )
        assertEquals("idle", completed.threads.single().status)
        assertEquals(null, completed.threads.single().activeTurnId)
    }

    @Test
    fun backgroundStatusDoesNotInheritActiveTurnFromOpenThread() {
        val active = top.asdb.codexremote.data.CodexThread(
            id = "thr-active", title = "当前任务", preview = "", cwd = "/srv/app", source = "appServer",
            status = "active", createdAt = 0, updatedAt = 0, cliVersion = "0.144.6",
            activeTurnId = "turn-active",
        )
        val background = top.asdb.codexremote.data.CodexThread(
            id = "thr-background", title = "后台任务", preview = "", cwd = "/srv/app", source = "appServer",
            status = "idle", createdAt = 0, updatedAt = 0, cliVersion = "0.144.6",
        )
        val state = AppUiState(
            activeThread = active,
            activeTurnId = "turn-active",
            running = true,
            threads = listOf(active, background),
        )

        // The protocol status notification has no activeTurnId field. It must not reuse the
        // turn belonging to the currently open thread when updating a background row.
        val reduced = CodexEventReducer.reduce(
            state,
            "thread/status/changed",
            json.parseToJsonElement(
                """{"threadId":"thr-background","status":{"type":"active"}}""",
            ).jsonObject,
        )

        val listedBackground = reduced.threads.first { it.id == "thr-background" }
        assertEquals("active", listedBackground.status)
        assertEquals(null, listedBackground.activeTurnId)
        assertEquals("turn-active", reduced.activeTurnId)
        assertEquals("thr-active", reduced.activeThread?.id)
    }

    @Test
    fun backgroundStatusKeepsPreviouslyKnownTurnWhenAvailable() {
        val background = top.asdb.codexremote.data.CodexThread(
            id = "thr-background", title = "后台任务", preview = "", cwd = "/srv/app", source = "appServer",
            status = "active", createdAt = 0, updatedAt = 0, cliVersion = "0.144.6",
            activeTurnId = "turn-background",
        )
        val state = AppUiState(
            activeThread = top.asdb.codexremote.data.CodexThread(
                id = "thr-active", title = "当前任务", preview = "", cwd = "/srv/app", source = "appServer",
                status = "idle", createdAt = 0, updatedAt = 0, cliVersion = "0.144.6",
            ),
            activeTurnId = null,
            threads = listOf(background),
        )

        val reduced = CodexEventReducer.reduce(
            state,
            "thread/status/changed",
            json.parseToJsonElement(
                """{"threadId":"thr-background","status":{"type":"active"}}""",
            ).jsonObject,
        )

        assertEquals("turn-background", reduced.threads.single().activeTurnId)
    }

    @Test
    fun backgroundTurnStartWithoutIdDoesNotInheritOpenThreadTurn() {
        val active = top.asdb.codexremote.data.CodexThread(
            id = "thr-active", title = "当前任务", preview = "", cwd = "/srv/app", source = "appServer",
            status = "active", createdAt = 0, updatedAt = 0, cliVersion = "0.144.6",
            activeTurnId = "turn-active",
        )
        val background = top.asdb.codexremote.data.CodexThread(
            id = "thr-background", title = "后台任务", preview = "", cwd = "/srv/app", source = "appServer",
            status = "idle", createdAt = 0, updatedAt = 0, cliVersion = "0.144.6",
        )
        val state = AppUiState(
            activeThread = active,
            activeTurnId = "turn-active",
            running = true,
            threads = listOf(active, background),
        )

        val reduced = CodexEventReducer.reduce(
            state,
            "turn/started",
            json.parseToJsonElement(
                """{"threadId":"thr-background","turn":{}}""",
            ).jsonObject,
        )

        val listedBackground = reduced.threads.first { it.id == "thr-background" }
        assertEquals("active", listedBackground.status)
        assertEquals(null, listedBackground.activeTurnId)
        assertEquals("turn-active", reduced.activeTurnId)
        assertEquals("thr-active", reduced.activeThread?.id)
    }
}
