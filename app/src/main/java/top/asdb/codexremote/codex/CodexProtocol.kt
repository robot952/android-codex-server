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
        val cwd = value.string("cwd")
        val name = value.string("name").trim()
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

    fun parseTimeline(thread: JsonObject): List<TimelineEntry> =
        thread.array("turns").orEmpty().flatMap { turnElement ->
            val turn = turnElement as? JsonObject ?: return@flatMap emptyList()
            val turnId = turn.string("id")
            turn.array("items").orEmpty().mapNotNull { item ->
                (item as? JsonObject)?.let { parseItem(it, turnId) }
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
                }.joinToString("\n"),
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
                text = (item.array("summary").orEmpty() + item.array("content").orEmpty())
                    .mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                    .joinToString("\n")
                    .bounded(MAX_TIMELINE_TEXT_CHARS, TEXT_TRUNCATION_MARKER),
                turnId = turnId,
            )

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
                command = item.string("command"),
                cwd = item.string("cwd"),
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
                title = item.string("tool").ifBlank { "工具调用" },
                text = item["result"]?.toString().orEmpty(),
                status = item.string("status"),
                turnId = turnId,
            )

            "webSearch" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Tool,
                title = "网页搜索",
                text = item.string("query"),
                status = "completed",
                turnId = turnId,
            )

            "enteredReviewMode", "exitedReviewMode" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Review,
                title = if (type == "enteredReviewMode") "开始审核" else "审核完成",
                text = item.string("review"),
                turnId = turnId,
            )

            "contextCompaction" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Notice,
                text = "上下文已压缩",
                turnId = turnId,
            )

            "imageView", "imageGeneration", "sleep", "subAgentActivity" -> TimelineEntry(
                id = id,
                kind = TimelineKind.Tool,
                title = type,
                text = item.string("path").ifBlank { item.string("result") },
                status = item.string("status"),
                turnId = turnId,
            )

            else -> if (type.isNotBlank()) {
                TimelineEntry(
                    id = id,
                    kind = TimelineKind.Notice,
                    title = type,
                    text = item.toString().take(2_000),
                    turnId = turnId,
                )
            } else null
        }
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
                command = params.string("command"),
                cwd = params.string("cwd"),
                detail = params.string("reason").ifBlank { "Codex 请求执行以下命令" },
            )

            "item/fileChange/requestApproval", "applyPatchApproval" -> base.copy(
                kind = ApprovalKind.FileChange,
                title = "批准文件修改",
                detail = params.string("reason").ifBlank { "Codex 请求写入工作区文件" },
            )

            "item/permissions/requestApproval", "permissions/requestApproval" -> base.copy(
                kind = ApprovalKind.Permission,
                title = "批准额外权限",
                cwd = params.string("cwd"),
                detail = params.string("reason").ifBlank {
                    params["permissions"]?.toString().orEmpty()
                },
            )

            "item/tool/requestUserInput", "tool/requestUserInput" -> {
                val question = params.array("questions")?.firstOrNull() as? JsonObject
                base.copy(
                    kind = ApprovalKind.UserInput,
                    title = question?.string("header").orEmpty().ifBlank { "Codex 需要信息" },
                    detail = question?.string("question").orEmpty(),
                    questions = params.array("questions").orEmpty().mapNotNull { element ->
                        val value = element as? JsonObject ?: return@mapNotNull null
                        InputQuestion(
                            id = value.string("id"),
                            header = value.string("header"),
                            question = value.string("question"),
                            options = value.array("options").orEmpty().mapNotNull { option ->
                                when (option) {
                                    is JsonObject -> option.string("label").takeIf { it.isNotBlank() }?.let {
                                        InputOption(it, option.string("description"))
                                    }
                                    is JsonPrimitive -> option.contentOrNull?.takeIf { it.isNotBlank() }
                                        ?.let { InputOption(it) }
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

    private fun parseChanges(value: JsonArray?): List<FileChange> = value.orEmpty().mapNotNull { element ->
        val change = element as? JsonObject ?: return@mapNotNull null
        FileChange(
            path = change.string("path"),
            kind = change["kind"].wireType(),
            diff = change.string("diff").bounded(MAX_AGGREGATE_DIFF_CHARS, DIFF_TRUNCATION_MARKER),
        )
    }

    private fun sourceLabel(value: JsonElement?): String = when (value) {
        is JsonPrimitive -> value.contentOrNull.orEmpty()
        is JsonObject -> value.string("custom").ifBlank {
            if ("subAgent" in value) "subAgent" else value.toString()
        }
        else -> ""
    }
}

object CodexEventReducer {
    fun reduce(state: AppUiState, method: String, params: JsonObject): AppUiState =
        if (!state.acceptsThreadEvent(params)) state else when (method) {
        "turn/started" -> {
            val turn = params.obj("turn")
            state.copy(
                activeTurnId = turn?.string("id").orEmpty().ifBlank { state.activeTurnId },
                running = true,
                activeThread = state.activeThread?.copy(status = "active"),
            )
        }

        "turn/completed" -> {
            val turn = params.obj("turn")
            val completedTurnId = turn?.string("id").orEmpty()
            if (completedTurnId.isNotBlank() && state.activeTurnId != null &&
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
                )
            }
        }

        "thread/status/changed" -> {
            val threadId = params.string("threadId")
            if (threadId.isBlank() || state.activeThread?.id != threadId) {
                state
            } else {
                val status = params["status"].wireType().ifBlank { state.activeThread.status }
                state.copy(
                    activeThread = state.activeThread.copy(status = status),
                    running = status == "active",
                    activeTurnId = if (status == "active") state.activeTurnId else null,
                )
            }
        }

        "thread/tokenUsage/updated" -> state.copy(
            tokenUsage = CodexPayloadParser.parseTokenUsage(params),
        )

        "item/started", "item/completed" -> {
            val item = params.obj("item")
            val entry = item?.let { CodexPayloadParser.parseItem(it, params.string("turnId")) }
            if (entry == null) state else state.copy(
                timeline = upsert(state.timeline, entry),
            )
        }

        "item/agentMessage/delta" -> state.updateEntry(params.string("itemId")) {
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

        "item/reasoning/summaryTextDelta", "item/reasoning/textDelta" ->
            state.updateEntry(params.string("itemId")) {
                val delta = params.string("delta")
                (it ?: TimelineEntry(
                    params.string("itemId"),
                    TimelineKind.Reasoning,
                    title = "思考过程",
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

        "item/plan/delta" -> state.updateEntry(params.string("itemId")) {
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

        "item/commandExecution/outputDelta" -> state.updateEntry(params.string("itemId")) {
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

        "item/fileChange/patchUpdated" -> state.updateEntry(params.string("itemId")) {
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
                    text = message,
                ),
            )
        }

        else -> state
        }

    private fun AppUiState.acceptsThreadEvent(params: JsonObject): Boolean {
        val eventThreadId = params.string("threadId")
        val activeId = activeThread?.id.orEmpty()
        return eventThreadId.isBlank() || activeId.isBlank() || eventThreadId == activeId
    }

    private fun upsert(
        entries: List<TimelineEntry>,
        value: TimelineEntry,
    ): List<TimelineEntry> {
        val index = entries.indexOfFirst { it.id == value.id }
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
        )
        return entries.toMutableList().also { it[index] = merged }
    }

    private fun AppUiState.updateEntry(
        id: String,
        transform: (TimelineEntry?) -> TimelineEntry,
    ): AppUiState {
        if (id.isBlank()) return this
        val index = timeline.indexOfFirst { it.id == id }
        val current = timeline.getOrNull(index)
        val next = transform(current)
        return copy(timeline = if (index < 0) timeline + next else timeline.toMutableList().also { it[index] = next })
    }
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
