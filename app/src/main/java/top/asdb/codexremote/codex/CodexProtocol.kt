package top.asdb.codexremote.codex

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.ApprovalKind
import top.asdb.codexremote.data.ApprovalPrompt
import top.asdb.codexremote.data.CodexModel
import top.asdb.codexremote.data.CodexThread
import top.asdb.codexremote.data.FileChange
import top.asdb.codexremote.data.InputOption
import top.asdb.codexremote.data.InputQuestion
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.data.TokenUsageBreakdown

internal const val MAX_TIMELINE_TEXT_CHARS = 256 * 1024
internal const val MAX_COMMAND_OUTPUT_CHARS = 512 * 1024
internal const val MAX_AGGREGATE_DIFF_CHARS = 512 * 1024
internal const val MAX_TIMELINE_METADATA_CHARS = 16 * 1024
internal const val TEXT_TRUNCATION_MARKER = "\n\n[内容过长，后续已截断]"
internal const val OUTPUT_TRUNCATION_MARKER = "\n\n[命令输出过长，后续已截断]"
internal const val DIFF_TRUNCATION_MARKER = "\n\n[差异内容过长，后续已截断]"

internal fun JsonObject.string(name: String): String =
    (this[name] as? JsonPrimitive)?.contentOrNull.orEmpty()

internal fun JsonObject.long(name: String): Long =
    (this[name] as? JsonPrimitive)?.longOrNull ?: 0L

internal fun JsonObject.obj(name: String): JsonObject? = this[name] as? JsonObject
internal fun JsonObject.array(name: String): JsonArray? = this[name] as? JsonArray

internal fun JsonElement?.wireType(): String = when (this) {
    is JsonPrimitive -> contentOrNull.orEmpty()
    is JsonObject -> string("type")
    else -> ""
}

object CodexPayloadParser {
    fun parseThreads(result: JsonObject): List<CodexThread> =
        result.array("data").orEmpty().mapNotNull { (it as? JsonObject)?.let(::parseThread) }

    fun parseModels(result: JsonObject): List<CodexModel> =
        result.array("data").orEmpty().mapNotNull { element ->
            val value = element as? JsonObject ?: return@mapNotNull null
            CodexModel(
                id = value.string("id").ifBlank { value.string("model") },
                model = value.string("model").ifBlank { value.string("id") },
                displayName = value.string("displayName").ifBlank { value.string("model") },
                description = value.string("description"),
                isDefault = (value["isDefault"] as? JsonPrimitive)?.booleanOrNull == true,
                defaultEffort = value.string("defaultReasoningEffort"),
                efforts = value.array("supportedReasoningEfforts").orEmpty().mapNotNull { effort ->
                    when (effort) {
                        is JsonPrimitive -> effort.contentOrNull
                        is JsonObject -> effort.string("reasoningEffort")
                            .ifBlank { effort.string("effort") }
                            .ifBlank { null }
                        else -> null
                    }
                },
            )
        }

    fun parseTokenUsage(params: JsonObject): TokenUsage {
        fun breakdown(value: JsonObject?): TokenUsageBreakdown = TokenUsageBreakdown(
            cachedInputTokens = value?.long("cachedInputTokens") ?: 0,
            inputTokens = value?.long("inputTokens") ?: 0,
            outputTokens = value?.long("outputTokens") ?: 0,
            reasoningOutputTokens = value?.long("reasoningOutputTokens") ?: 0,
            totalTokens = value?.long("totalTokens") ?: 0,
        )

        val usage = params.obj("tokenUsage") ?: JsonObject(emptyMap())
        return TokenUsage(
            last = breakdown(usage.obj("last")),
            total = breakdown(usage.obj("total")),
            modelContextWindow = usage.long("modelContextWindow"),
        )
    }

    fun parseThreadPayload(result: JsonObject): Pair<CodexThread, List<TimelineEntry>> {
        val thread = result.obj("thread") ?: result
        return parseThread(thread) to parseTimeline(thread)
    }

    fun parseThread(value: JsonObject): CodexThread {
        val preview = value.string("preview").trim()
            .bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER)
        val cwd = value.string("cwd").bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER)
        val name = value.string("name").trim().bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER)
        val activeTurnId = value.array("turns").orEmpty()
            .asReversed()
            .mapNotNull { it as? JsonObject }
            .firstOrNull { it.string("status") == "inProgress" }
            ?.string("id")
        return CodexThread(
            id = value.string("id"),
            title = name.ifBlank {
                preview.lineSequence().firstOrNull()?.trim()?.take(64).orEmpty().ifBlank {
                    cwd.substringAfterLast('/').ifBlank { "未命名任务" }
                }
            },
            preview = preview,
            cwd = cwd,
            source = sourceLabel(value["source"]),
            status = value["status"].wireType().ifBlank { "idle" },
            createdAt = value.long("createdAt"),
            updatedAt = value.long("updatedAt"),
            cliVersion = value.string("cliVersion"),
            activeTurnId = activeTurnId,
        )
    }

    fun parseTimeline(thread: JsonObject): List<TimelineEntry> {
        val entries = ArrayList<TimelineEntry>()
        val historicalTurnIds = HashSet<String>()
        thread.array("turns").orEmpty().forEach turnLoop@{ turnElement ->
            val turn = turnElement as? JsonObject ?: return@turnLoop
            val turnId = turn.string("id")
            val turnStatus = turn["status"].wireType()
            if (turnStatus.isNotBlank() && turnStatus != "inProgress") historicalTurnIds += turnId
            turn.array("items").orEmpty().forEach itemLoop@{ itemElement ->
                val item = itemElement as? JsonObject ?: return@itemLoop
                parseItem(item, turnId)?.let { entries += it }
                if (item.string("type") == "collabAgentToolCall") {
                    val updated = applySubAgentStates(entries, item)
                    entries.clear()
                    entries += updated
                }
            }
        }
        return entries.map { entry ->
            if (entry.kind == TimelineKind.SubAgent && entry.turnId in historicalTurnIds &&
                entry.status in ACTIVE_SUB_AGENT_STATES
            ) {
                entry.copy(status = "completed")
            } else {
                entry
            }
        }
    }

    fun parseItem(item: JsonObject, turnId: String): TimelineEntry? {
        val id = item.string("id").ifBlank { "item-${item.hashCode()}" }
        return when (val type = item.string("type")) {
            "userMessage" -> TimelineEntry(
                id = id,
                kind = TimelineKind.UserMessage,
                text = item.array("content").orEmpty().mapNotNull { content ->
                    val value = content as? JsonObject
                    value?.takeIf { it.string("type") == "text" }?.string("text")
                }.joinToString("\n").bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                turnId = turnId,
            )

            "agentMessage" -> TimelineEntry(
                id = id,
                kind = TimelineKind.AgentMessage,
                text = item.string("text").bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                status = item.string("phase"),
                turnId = turnId,
            )

            "reasoning" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Reasoning,
                title = "思考过程",
                reasoningSummary = parseReasoningParts(item.array("summary")),
                reasoningContent = parseReasoningParts(item.array("content")),
                turnId = turnId,
            ).withReasoningText()

            "plan" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Plan,
                title = "计划",
                text = item.string("text").bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                turnId = turnId,
            )

            "commandExecution" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Command,
                title = "终端",
                command = item.string("command").bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                cwd = item.string("cwd").bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                status = item.string("status"),
                output = item.string("aggregatedOutput")
                    .bounded(MAX_COMMAND_OUTPUT_CHARS, OUTPUT_TRUNCATION_MARKER),
                turnId = turnId,
            )

            "fileChange" -> TimelineEntry(
                id = id,
                kind = TimelineKind.FileChange,
                title = "已编辑文件",
                status = item.string("status"),
                changes = parseChanges(item.array("changes")),
                turnId = turnId,
            )

            "mcpToolCall", "dynamicToolCall", "collabAgentToolCall" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Tool,
                title = item.string("tool").ifBlank { "工具调用" }
                    .bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                text = item["result"].boundedJsonPreview(MAX_TIMELINE_TEXT_CHARS),
                status = item.string("status"),
                turnId = turnId,
            )

            "webSearch" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Tool,
                title = "网页搜索",
                text = item.string("query").bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                status = "completed",
                turnId = turnId,
            )

            "enteredReviewMode", "exitedReviewMode" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Review,
                title = if (type == "enteredReviewMode") "开始审核" else "审核完成",
                text = item.string("review").bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                turnId = turnId,
            )

            "contextCompaction" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Notice,
                text = "上下文已压缩",
                turnId = turnId,
            )

            "subAgentActivity" -> parseSubAgentActivity(item, id, turnId)

            "imageView", "imageGeneration", "sleep" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Tool,
                title = type,
                text = item.string("path").ifBlank { item.string("result") }
                    .bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                status = item.string("status"),
                turnId = turnId,
            )

            else -> if (type.isNotBlank()) {
                TimelineEntry(
                    id = id,
                    kind = TimelineKind.Notice,
                    title = type,
                    text = item.boundedJsonPreview(2_000),
                    turnId = turnId,
                )
            } else null
        }
    }

    private fun parseSubAgentActivity(item: JsonObject, id: String, turnId: String): TimelineEntry {
        val activity = item.string("kind")
        val path = item.string("agentPath")
            .bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER)
        val threadId = item.string("agentThreadId")
            .bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER)
        val explicitText = sequenceOf("message", "summary", "description")
            .map { item.string(it) }
            .firstOrNull { it.isNotBlank() }
        val text = explicitText
            ?.bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER)
            ?: item["result"].boundedJsonPreview(MAX_TIMELINE_TEXT_CHARS).ifBlank { "" }
        return TimelineEntry(
            id = id,
            kind = TimelineKind.SubAgent,
            title = "",
            text = text,
            status = subAgentStatusForActivity(activity),
            turnId = turnId,
            subAgentPath = path,
            subAgentThreadId = threadId,
            subAgentActivity = activity,
        )
    }

    fun parseServerRequest(message: JsonObject): ApprovalPrompt? {
        val id = message["id"] as? JsonPrimitive ?: return null
        val method = message.string("method")
        val params = message.obj("params") ?: JsonObject(emptyMap())
        val requestId = id.content
        val base = ApprovalPrompt(
            requestId = requestId,
            requestIdIsString = id.isString,
            kind = ApprovalKind.Command,
            threadId = params.string("threadId"),
            turnId = params.string("turnId"),
            itemId = params.string("itemId"),
            title = "需要批准",
            detail = params.string("reason"),
        )
        return when (method) {
            "item/commandExecution/requestApproval", "execCommandApproval" -> base.copy(
                kind = ApprovalKind.Command,
                title = "批准执行命令",
                    command = params.string("command")
                        .bounded(MAX_APPROVAL_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                    cwd = params.string("cwd")
                        .bounded(MAX_APPROVAL_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                    detail = params.string("reason").ifBlank { "Codex 请求执行以下命令" }
                        .bounded(MAX_APPROVAL_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
            )

            "item/fileChange/requestApproval", "applyPatchApproval" -> base.copy(
                kind = ApprovalKind.FileChange,
                title = "批准文件修改",
                detail = params.string("reason").ifBlank { "Codex 请求写入工作区文件" }
                    .bounded(MAX_APPROVAL_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
            )

            "item/permissions/requestApproval", "permissions/requestApproval" -> base.copy(
                kind = ApprovalKind.Permission,
                title = "批准额外权限",
                cwd = params.string("cwd").bounded(MAX_APPROVAL_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                detail = params.string("reason").ifBlank {
                    params["permissions"].boundedJsonPreview(MAX_APPROVAL_TEXT_CHARS)
                }.bounded(MAX_APPROVAL_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
            )

            "item/tool/requestUserInput", "tool/requestUserInput" -> {
                val question = params.array("questions")?.firstOrNull() as? JsonObject
                base.copy(
                    kind = ApprovalKind.UserInput,
                    title = question?.string("header").orEmpty().ifBlank { "Codex 需要信息" }
                        .bounded(MAX_APPROVAL_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                    detail = question?.string("question").orEmpty()
                        .bounded(MAX_APPROVAL_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                    questions = params.array("questions").orEmpty().take(MAX_APPROVAL_QUESTIONS)
                        .mapNotNull { element ->
                        val value = element as? JsonObject ?: return@mapNotNull null
                        InputQuestion(
                            id = value.string("id").bounded(MAX_APPROVAL_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                            header = value.string("header")
                                .bounded(MAX_APPROVAL_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                            question = value.string("question")
                                .bounded(MAX_APPROVAL_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                            options = value.array("options").orEmpty().take(MAX_APPROVAL_OPTIONS)
                                .mapNotNull { option ->
                                when (option) {
                                    is JsonObject -> option.string("label").takeIf { it.isNotBlank() }?.let {
                                        InputOption(
                                            it.bounded(MAX_APPROVAL_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                                            option.string("description")
                                                .bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                                        )
                                    }
                                    is JsonPrimitive -> option.contentOrNull?.takeIf { it.isNotBlank() }
                                        ?.let {
                                            InputOption(
                                                it.bounded(MAX_APPROVAL_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                                            )
                                        }
                                    else -> null
                                }
                            },
                            isSecret = (value["isSecret"] as? JsonPrimitive)?.booleanOrNull == true,
                        )
                    },
                )
            }

            else -> null
        }
    }

    private fun parseChanges(value: JsonArray?): List<FileChange> {
        val result = ArrayList<FileChange>()
        var remainingDiffChars = MAX_AGGREGATE_DIFF_CHARS
        for (element in value.orEmpty().take(MAX_FILE_CHANGES)) {
            val change = element as? JsonObject ?: continue
            val diff = if (remainingDiffChars > 0) {
                change.string("diff").bounded(remainingDiffChars, DIFF_TRUNCATION_MARKER)
            } else {
                ""
            }
            remainingDiffChars = (remainingDiffChars - diff.length).coerceAtLeast(0)
            result += FileChange(
                path = change.string("path").bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                kind = change["kind"].wireType()
                    .bounded(MAX_TIMELINE_METADATA_CHARS, TEXT_TRUNCATION_MARKER),
                diff = diff,
            )
        }
        return result
    }

    private fun parseReasoningParts(value: JsonArray?): List<String> = boundedReasoningParts(
        value.orEmpty().mapNotNull { element ->
            when (element) {
                is JsonPrimitive -> element.contentOrNull
                is JsonObject -> element.string("text")
                else -> null
            }
        },
    )

    private fun sourceLabel(value: JsonElement?): String = when (value) {
        is JsonPrimitive -> value.contentOrNull.orEmpty()
        is JsonObject -> value.string("custom").ifBlank {
            if ("subAgent" in value) "subAgent" else value.boundedJsonPreview(MAX_TIMELINE_METADATA_CHARS)
        }
        else -> ""
    }
}

private val ACTIVE_SUB_AGENT_STATES = setOf("pendingInit", "running", "inProgress", "started", "interacted")

private fun subAgentStatusForActivity(activity: String): String = when (activity) {
    "started", "interacted" -> "running"
    "interrupted" -> "interrupted"
    else -> "unknown"
}

private fun JsonObject.agentStates(): Map<String, String> {
    val states = obj("agentsStates") ?: obj("agents_states") ?: return emptyMap()
    return states.mapNotNull { (threadId, value) ->
        val status = (value as? JsonObject)?.string("status").orEmpty()
        threadId.takeIf { it.isNotBlank() }?.let { it to status }
    }.toMap()
}

private fun applySubAgentStates(
    entries: List<TimelineEntry>,
    collabItem: JsonObject,
): List<TimelineEntry> {
    val states = collabItem.agentStates()
    if (states.isEmpty()) return entries
    return entries.map { entry ->
        if (entry.kind != TimelineKind.SubAgent) {
            entry
        } else {
            states[entry.subAgentThreadId]?.takeIf { it.isNotBlank() }
                ?.let { entry.copy(status = it) }
                ?: entry
        }
    }
}

private fun completeSubAgentsForTurn(
    entries: List<TimelineEntry>,
    turnId: String,
): List<TimelineEntry> = entries.map { entry ->
    if (entry.kind == TimelineKind.SubAgent &&
        (turnId.isBlank() || entry.turnId.isBlank() || entry.turnId == turnId) &&
        entry.status in ACTIVE_SUB_AGENT_STATES
    ) {
        entry.copy(status = "completed")
    } else {
        entry
    }
}

object CodexEventReducer {
    fun reduce(state: AppUiState, method: String, params: JsonObject): AppUiState =
        if (!state.acceptsThreadEvent(method, params)) state else when (method) {
        "turn/started" -> {
            val turn = params.obj("turn")
            val threadId = params.string("threadId")
            val appliesToActiveThread = threadId.isBlank() || state.activeThread?.id == threadId
            val listedTurnId = state.threads.firstOrNull { it.id == threadId }?.activeTurnId
            val turnId = turn?.string("id").orEmpty().takeIf { it.isNotBlank() }
                ?: when {
                    appliesToActiveThread -> state.activeTurnId ?: listedTurnId
                    else -> listedTurnId
                }
            val base = if (appliesToActiveThread) {
                state.copy(
                    activeTurnId = turnId,
                    running = true,
                    activeThread = state.activeThread?.copy(status = "active"),
                )
            } else state
            base.updateThreadRuntime(threadId.ifBlank { state.activeThread?.id.orEmpty() }, "active", turnId)
        }

        "turn/completed" -> {
            val turn = params.obj("turn")
            val completedTurnId = turn?.string("id").orEmpty()
            val threadId = params.string("threadId")
            val appliesToActiveThread = threadId.isBlank() || state.activeThread?.id == threadId
            if (!appliesToActiveThread && threadId.isNotBlank()) {
                state.updateThreadRuntime(threadId, "idle", null)
            } else if (completedTurnId.isNotBlank() && state.activeTurnId != null &&
                completedTurnId != state.activeTurnId
            ) {
                state
            } else {
                val error = turn?.obj("error")?.string("message")
                state.copy(
                    activeTurnId = null,
                    running = false,
                    activeThread = state.activeThread?.copy(status = "idle"),
                    error = error?.takeIf { it.isNotBlank() } ?: state.error,
                    timeline = completeSubAgentsForTurn(state.timeline, completedTurnId),
                ).updateThreadRuntime(threadId.ifBlank { state.activeThread?.id.orEmpty() }, "idle", null)
            }
        }

        "thread/status/changed" -> {
            val threadId = params.string("threadId")
            if (threadId.isBlank()) {
                state
            } else {
                val status = params["status"].wireType().ifBlank { state.activeThread?.status.orEmpty() }
                val appliesToActiveThread = state.activeThread?.id == threadId
                // ThreadStatusChangedNotification does not carry an active turn id in the
                // current app-server schema. Never borrow the active turn from another thread:
                // doing so makes a background thread look steerable with the wrong turn id.
                val listedTurnId = state.threads.firstOrNull { it.id == threadId }?.activeTurnId
                val activeTurn = params.string("activeTurnId").takeIf { it.isNotBlank() }
                    ?: when {
                        status != "active" -> null
                        appliesToActiveThread -> state.activeTurnId ?: listedTurnId
                        else -> listedTurnId
                    }
                val base = if (appliesToActiveThread) {
                    state.copy(
                        activeThread = state.activeThread?.copy(status = status),
                        running = status == "active",
                        activeTurnId = if (status == "active") activeTurn else null,
                    )
                } else state
                base.updateThreadRuntime(threadId, status, activeTurn)
            }
        }

        "thread/tokenUsage/updated" -> state.copy(
            tokenUsage = CodexPayloadParser.parseTokenUsage(params),
        )

        "item/started", "item/completed" -> {
            val item = params.obj("item")
            val parsed = item?.let { CodexPayloadParser.parseItem(it, params.string("turnId")) }
            val entry = if (item?.string("type") == "contextCompaction") {
                if (method == "item/started") {
                    parsed?.copy(text = "正在压缩上下文", status = "inProgress")
                } else {
                    parsed?.copy(text = "上下文已压缩", status = "completed")
                }
            } else {
                parsed
            }
            if (entry == null) state else {
                var timeline = upsert(state.timeline, entry)
                if (item?.string("type") == "collabAgentToolCall") {
                    timeline = applySubAgentStates(timeline, item)
                }
                state.copy(timeline = timeline)
            }
        }

        "item/agentMessage/delta" -> state.updateEntry(
            params.string("itemId"), TimelineKind.AgentMessage, params.string("turnId"),
        ) {
            val delta = params.string("delta")
            (it ?: TimelineEntry(params.string("itemId"), TimelineKind.AgentMessage, turnId = params.string("turnId")))
                .copy(
                    text = appendBounded(
                        current = it?.text.orEmpty(),
                        delta = delta,
                        limit = MAX_TIMELINE_TEXT_CHARS,
                        marker = TEXT_TRUNCATION_MARKER,
                    ),
                )
        }

        "item/reasoning/summaryPartAdded" -> state.updateEntry(
            params.string("itemId"), TimelineKind.Reasoning, params.string("turnId"),
        ) { current ->
            val entry = current ?: TimelineEntry(
                params.string("itemId"),
                TimelineKind.Reasoning,
                title = "思考过程",
                turnId = params.string("turnId"),
            )
            entry.copy(
                reasoningSummary = ensureReasoningPart(entry.reasoningSummary, params.long("summaryIndex")),
            ).withReasoningText()
        }

        "item/reasoning/summaryTextDelta" -> state.updateEntry(
            params.string("itemId"), TimelineKind.Reasoning, params.string("turnId"),
        ) { current ->
            val entry = current ?: TimelineEntry(
                params.string("itemId"),
                TimelineKind.Reasoning,
                title = "思考过程",
                turnId = params.string("turnId"),
            )
            entry.copy(
                reasoningSummary = appendReasoningPart(
                    entry.reasoningSummary,
                    params.long("summaryIndex"),
                    params.string("delta"),
                ),
            ).withReasoningText()
        }

        "item/reasoning/textDelta" -> state.updateEntry(
            params.string("itemId"), TimelineKind.Reasoning, params.string("turnId"),
        ) { current ->
            val entry = current ?: TimelineEntry(
                params.string("itemId"),
                TimelineKind.Reasoning,
                title = "思考过程",
                turnId = params.string("turnId"),
            )
            entry.copy(
                reasoningContent = appendReasoningPart(
                    entry.reasoningContent,
                    params.long("contentIndex"),
                    params.string("delta"),
                ),
            ).withReasoningText()
        }

        "item/plan/delta" -> state.updateEntry(
            params.string("itemId"), TimelineKind.Plan, params.string("turnId"),
        ) {
            val delta = params.string("delta")
            (it ?: TimelineEntry(
                params.string("itemId"), TimelineKind.Plan, title = "计划",
                turnId = params.string("turnId"),
            )).copy(
                text = appendBounded(
                    current = it?.text.orEmpty(),
                    delta = delta,
                    limit = MAX_TIMELINE_TEXT_CHARS,
                    marker = TEXT_TRUNCATION_MARKER,
                ),
            )
        }

        "item/commandExecution/outputDelta" -> state.updateEntry(
            params.string("itemId"), TimelineKind.Command, params.string("turnId"),
        ) {
            val delta = params.string("delta")
            (it ?: TimelineEntry(
                params.string("itemId"), TimelineKind.Command, title = "终端",
                status = "inProgress", turnId = params.string("turnId"),
            )).copy(
                output = appendBounded(
                    current = it?.output.orEmpty(),
                    delta = delta,
                    limit = MAX_COMMAND_OUTPUT_CHARS,
                    marker = OUTPUT_TRUNCATION_MARKER,
                ),
            )
        }

        "item/fileChange/patchUpdated" -> state.updateEntry(
            params.string("itemId"), TimelineKind.FileChange, params.string("turnId"),
        ) {
            val item = JsonObject(
                mapOf(
                    "id" to JsonPrimitive(params.string("itemId")),
                    "type" to JsonPrimitive("fileChange"),
                    "status" to JsonPrimitive("inProgress"),
                    "changes" to (params.array("changes") ?: JsonArray(emptyList())),
                ),
            )
            val parsed = CodexPayloadParser.parseItem(item, params.string("turnId"))
            val current = it
            when {
                parsed == null && current != null -> current
                parsed == null -> TimelineEntry(params.string("itemId"), TimelineKind.FileChange)
                current == null -> parsed
                else -> parsed.copy(
                    status = parsed.status.ifBlank { current.status },
                    changes = parsed.changes.ifEmpty { current.changes },
                    turnId = parsed.turnId.ifBlank { current.turnId },
                )
            }
        }

        "turn/diff/updated" -> state.copy(
            aggregateDiff = params.string("diff")
                .bounded(MAX_AGGREGATE_DIFF_CHARS, DIFF_TRUNCATION_MARKER),
        )
        "thread/name/updated" -> state.copy(
            activeThread = state.activeThread?.copy(title = params.string("name")),
        )

        "error", "warning", "deprecationNotice", "guardianWarning" -> {
            val message = params.string("message")
                .ifBlank { params.obj("error")?.string("message").orEmpty() }
                .ifBlank { params.string("error") }
            if (message.isBlank()) state else state.copy(
                timeline = state.timeline + TimelineEntry(
                    id = "notice-${System.nanoTime()}",
                    kind = TimelineKind.Notice,
                    text = message.bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                ),
            )
        }

        else -> state
        }

    private fun AppUiState.acceptsThreadEvent(method: String, params: JsonObject): Boolean {
        if (method == "turn/started" || method == "turn/completed" || method == "thread/status/changed") {
            return true
        }
        val eventThreadId = params.string("threadId")
        val activeId = activeThread?.id.orEmpty()
        return eventThreadId.isBlank() || activeId.isBlank() || eventThreadId == activeId
    }

    private fun upsert(
        entries: List<TimelineEntry>,
        value: TimelineEntry,
    ): List<TimelineEntry> {
        val index = entries.indexOfFirst { it.sameTimelineIdentity(value) }
        if (index < 0) return entries + value
        val old = entries[index]
        // Completion payloads can race with the final delta, and a duplicate started event can
        // arrive after streaming has begun. Preserve fields that the newer payload omitted.
        val merged = value.copy(
            title = value.title.ifBlank { old.title },
            text = value.text.ifBlank { old.text },
            status = value.status.ifBlank { old.status },
            command = value.command.ifBlank { old.command },
            cwd = value.cwd.ifBlank { old.cwd },
            output = value.output.ifBlank { old.output },
            changes = value.changes.ifEmpty { old.changes },
            turnId = value.turnId.ifBlank { old.turnId },
            subAgentPath = value.subAgentPath.ifBlank { old.subAgentPath },
            subAgentThreadId = value.subAgentThreadId.ifBlank { old.subAgentThreadId },
            subAgentActivity = value.subAgentActivity.ifBlank { old.subAgentActivity },
            reasoningSummary = value.reasoningSummary.ifEmpty { old.reasoningSummary },
            reasoningContent = value.reasoningContent.ifEmpty { old.reasoningContent },
        )
        return entries.toMutableList().also {
            it[index] = if (merged.kind == TimelineKind.Reasoning) merged.withReasoningText() else merged
        }
    }

    private fun AppUiState.updateEntry(
        id: String,
        kind: TimelineKind,
        turnId: String,
        transform: (TimelineEntry?) -> TimelineEntry,
    ): AppUiState {
        if (id.isBlank()) return this
        val index = timeline.indexOfFirst { entry ->
            entry.id == id && entry.kind == kind &&
                (turnId.isBlank() || entry.turnId.isBlank() || entry.turnId == turnId)
        }
        val current = timeline.getOrNull(index)
        val next = transform(current)
        return copy(timeline = if (index < 0) timeline + next else timeline.toMutableList().also { it[index] = next })
    }

    private fun AppUiState.updateThreadRuntime(
        threadId: String,
        status: String,
        activeTurnId: String?,
    ): AppUiState {
        if (threadId.isBlank()) return this
        return copy(
            threads = threads.map { thread ->
                if (thread.id == threadId) {
                    thread.copy(status = status, activeTurnId = activeTurnId)
                } else {
                    thread
                }
            },
        )
    }
}

private fun TimelineEntry.sameTimelineIdentity(other: TimelineEntry): Boolean =
    id == other.id && kind == other.kind &&
        (turnId.isBlank() || other.turnId.isBlank() || turnId == other.turnId)

private const val MAX_REASONING_PARTS = 64
private const val MAX_FILE_CHANGES = 256
private const val MAX_APPROVAL_QUESTIONS = 3
private const val MAX_APPROVAL_OPTIONS = 8
private const val MAX_APPROVAL_TEXT_CHARS = 64 * 1024
private const val MAX_APPROVAL_METADATA_CHARS = 4 * 1024

private fun JsonElement?.boundedJsonPreview(limit: Int): String {
    if (this == null || this is JsonNull || limit <= 0) return ""
    val result = StringBuilder(minOf(limit, 4 * 1024))
    fun append(text: String) {
        if (result.length >= limit) return
        result.append(text, 0, minOf(text.length, limit - result.length))
    }
    fun appendElement(element: JsonElement, depth: Int) {
        if (result.length >= limit) return
        when (element) {
            is JsonPrimitive -> append(element.contentOrNull.orEmpty())
            is JsonArray -> {
                append("[")
                element.take(32).forEachIndexed { index, child ->
                    if (index > 0) append(", ")
                    appendElement(child, depth + 1)
                }
                if (element.size > 32) append(", ...")
                append("]")
            }
            is JsonObject -> {
                if (depth >= 6) {
                    append("{...}")
                } else {
                    append("{")
                    element.entries.take(32).forEachIndexed { index, (key, child) ->
                        if (index > 0) append(", ")
                        append(key)
                        append(": ")
                        appendElement(child, depth + 1)
                    }
                    if (element.size > 32) append(", ...")
                    append("}")
                }
            }
        }
    }

    appendElement(this, 0)
    if (result.length >= limit && limit >= TEXT_TRUNCATION_MARKER.length) {
        result.replace(limit - TEXT_TRUNCATION_MARKER.length, limit, TEXT_TRUNCATION_MARKER)
    }
    return result.toString()
}

private fun TimelineEntry.withReasoningText(): TimelineEntry {
    val visible = reasoningSummary.takeIf { parts -> parts.any(String::isNotBlank) } ?: reasoningContent
    return copy(
        text = visible.filter(String::isNotBlank).joinToString("\n\n")
            .bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
    )
}

private fun ensureReasoningPart(parts: List<String>, rawIndex: Long): List<String> {
    val index = rawIndex.takeIf { it >= 0L && it < MAX_REASONING_PARTS.toLong() }?.toInt() ?: return parts
    if (index < parts.size) return parts
    return parts + List(index + 1 - parts.size) { "" }
}

private fun appendReasoningPart(parts: List<String>, rawIndex: Long, delta: String): List<String> {
    val expanded = ensureReasoningPart(parts, rawIndex)
    val index = rawIndex.takeIf { it >= 0L && it < MAX_REASONING_PARTS.toLong() }?.toInt() ?: return parts
    if (delta.isEmpty()) return expanded
    val mutable = expanded.toMutableList()
    mutable[index] = appendBounded(
        current = mutable[index],
        delta = delta,
        limit = MAX_TIMELINE_TEXT_CHARS,
        marker = TEXT_TRUNCATION_MARKER,
    )
    return boundedReasoningParts(mutable)
}

private fun boundedReasoningParts(parts: List<String>): List<String> {
    var remaining = MAX_TIMELINE_TEXT_CHARS
    val result = ArrayList<String>(minOf(parts.size, MAX_REASONING_PARTS))
    for (part in parts.take(MAX_REASONING_PARTS)) {
        if (remaining <= 0) break
        if (part.length <= remaining) {
            result += part
            remaining -= part.length
        } else {
            result += part.bounded(remaining, TEXT_TRUNCATION_MARKER)
            remaining = 0
        }
    }
    return result
}

private fun String.bounded(limit: Int, marker: String): String {
    if (length <= limit) return this
    val markerPart = marker.take(limit)
    val contentLength = limit - markerPart.length
    return buildString(limit) {
        append(this@bounded, 0, contentLength)
        append(markerPart)
    }
}

private fun appendBounded(
    current: String,
    delta: String,
    limit: Int,
    marker: String,
): String {
    val normalized = current.bounded(limit, marker)
    if (delta.isEmpty() || normalized.endsWith(marker)) return normalized
    if (normalized.length.toLong() + delta.length <= limit.toLong()) {
        return buildString(normalized.length + delta.length) {
            append(normalized)
            append(delta)
        }
    }

    val markerPart = marker.take(limit)
    val contentLimit = limit - markerPart.length
    return buildString(limit) {
        val currentLength = minOf(normalized.length, contentLimit)
        append(normalized, 0, currentLength)
        val remaining = contentLimit - currentLength
        if (remaining > 0) append(delta, 0, minOf(delta.length, remaining))
        append(markerPart)
    }
}
