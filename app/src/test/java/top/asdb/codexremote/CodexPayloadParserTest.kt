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
import top.asdb.codexremote.data.TimelineKind

class CodexPayloadParserTest {
    private val json = Json { ignoreUnknownKeys = true }

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
}
