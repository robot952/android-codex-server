package top.asdb.codexremote.codex

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import top.asdb.codexremote.BuildConfig
import top.asdb.codexremote.data.ApprovalKind
import top.asdb.codexremote.data.ApprovalMode
import top.asdb.codexremote.data.ApprovalPrompt
import top.asdb.codexremote.data.CodexModel
import top.asdb.codexremote.data.CodexThread
import top.asdb.codexremote.data.PendingAttachment
import top.asdb.codexremote.data.RemoteDirectoryListing
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.data.ThreadGoal
import top.asdb.codexremote.data.ThreadGoalStatus
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.ssh.SshCodexTransport
import top.asdb.codexremote.ssh.RemoteEnvironment
import top.asdb.codexremote.ssh.SshTransportEvent
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

private const val INITIAL_TURNS_PAGE_LIMIT = 4
private const val OLDER_TURNS_PAGE_LIMIT = 4
private const val OVERSIZED_RETRY_PAGE_LIMIT = 1

internal fun buildThreadResumeParams(
    threadId: String,
    approvalMode: ApprovalMode,
    itemsView: String = "full",
    limit: Int = INITIAL_TURNS_PAGE_LIMIT,
): JsonObject {
    require(limit > 0)
    return buildJsonObject {
        put("threadId", threadId)
        put("approvalPolicy", approvalMode.approvalPolicy)
        put("excludeTurns", true)
        put("initialTurnsPage", buildJsonObject {
            put("limit", limit)
            put("sortDirection", "desc")
            put("itemsView", itemsView)
        })
    }
}

internal fun buildThreadTurnsListParams(
    threadId: String,
    cursor: String,
    itemsView: String = "full",
    limit: Int = OLDER_TURNS_PAGE_LIMIT,
): JsonObject {
    require(limit > 0)
    return buildJsonObject {
        put("threadId", threadId)
        put("cursor", cursor)
        put("limit", limit)
        put("sortDirection", "desc")
        put("itemsView", itemsView)
    }
}

data class CodexNotification(
    val generation: Long,
    val method: String,
    val params: JsonObject,
    val sequence: Long = 0,
)

data class ResumedThread(
    val thread: CodexThread,
    val timeline: List<TimelineEntry>,
    /** Last wire message included in the thread/resume response snapshot. */
    val responseSequence: Long,
    val nextTurnsCursor: String? = null,
    val turnIds: List<String> = emptyList(),
    val itemsView: String = "full",
)

data class ThreadTurnsPage(
    val timeline: List<TimelineEntry>,
    val nextCursor: String?,
    val turnIds: List<String> = emptyList(),
    val itemsView: String = "full",
)

data class CodexApproval(val generation: Long, val prompt: ApprovalPrompt)

data class CodexConnectionEvent(val generation: Long, val message: String)

private data class ServerRequest(
    val generation: Long,
    val method: String,
    val params: JsonObject,
)

private data class RpcResponse(val result: JsonElement, val sequence: Long)

open class CodexRpcException(message: String) : RuntimeException(message)

class CodexResponseTooLargeException(message: String) : CodexRpcException(message)

class CodexAppServerClient(
    private val scope: CoroutineScope,
    private val transport: SshCodexTransport = SshCodexTransport(),
    private val requestTimeoutMs: Long = DEFAULT_REQUEST_TIMEOUT_MS,
    private val threadRequestTimeoutMs: Long = DEFAULT_THREAD_REQUEST_TIMEOUT_MS,
    private val threadCache: ThreadSessionCache = ThreadSessionCache(),
) {
    init {
        require(requestTimeoutMs > 0) { "requestTimeoutMs must be positive" }
        require(threadRequestTimeoutMs > 0) { "threadRequestTimeoutMs must be positive" }
    }

    @Volatile
    private var connectedProfileId: String? = null
    private val threadCacheLock = Any()
    private val threadCaches = ConcurrentHashMap<String, ThreadSessionCache>()
    @Volatile
    private var activeThreadCache: ThreadSessionCache = threadCache
    private val json = Json { ignoreUnknownKeys = true }
    private val nextId = AtomicLong(1)
    private val nextWireSequence = AtomicLong(0)
    private val activeGeneration = AtomicLong(NO_GENERATION)
    private val closedGeneration = AtomicLong(NO_GENERATION)
    private val pending = ConcurrentHashMap<String, CompletableDeferred<RpcResponse>>()
    private val serverRequests = ConcurrentHashMap<String, ServerRequest>()

    private val _notifications = MutableSharedFlow<CodexNotification>()
    val notifications: SharedFlow<CodexNotification> = _notifications.asSharedFlow()

    private val _approvals = MutableSharedFlow<CodexApproval>()
    val approvals: SharedFlow<CodexApproval> = _approvals.asSharedFlow()

    private val _diagnostics = MutableSharedFlow<CodexConnectionEvent>()
    val diagnostics: SharedFlow<CodexConnectionEvent> = _diagnostics.asSharedFlow()

    private val _closed = MutableSharedFlow<CodexConnectionEvent>()
    val closed: SharedFlow<CodexConnectionEvent> = _closed.asSharedFlow()

    init {
        scope.launch(Dispatchers.Default) {
            transport.lines.collect { event ->
                if (isGenerationActive(event.generation)) handleLine(event)
            }
        }
        scope.launch {
            transport.diagnostics.collect { event ->
                if (isGenerationActive(event.generation)) {
                    _diagnostics.emit(CodexConnectionEvent(event.generation, event.value))
                }
            }
        }
        scope.launch {
            transport.oversizedLines.collect { event ->
                if (!isGenerationActive(event.generation)) return@collect
                val id = event.id ?: return@collect
                val error = CodexResponseTooLargeException(event.value)
                if (event.hasMethod) {
                    runCatching {
                        sendErrorResponse(
                            event.generation,
                            id,
                            event.idIsString,
                            -32600,
                            "Codex server request exceeded the mobile response limit",
                        )
                    }
                } else {
                    pending.remove(id)?.completeExceptionally(error)
                }
            }
        }
        scope.launch {
            transport.closed.collect { event ->
                if (!activeGeneration.compareAndSet(event.generation, NO_GENERATION)) return@collect
                closedGeneration.set(event.generation)
                val error = CodexRpcException(event.value)
                failPending(error)
                serverRequests.clear()
                val closed = CodexConnectionEvent(event.generation, event.value)
                _diagnostics.emit(closed)
                _closed.emit(closed)
            }
        }
    }

    suspend fun probeFingerprint(profile: ServerProfile): String = transport.probeFingerprint(profile)

    suspend fun inspectRemote(profile: ServerProfile): RemoteEnvironment = transport.inspectRemote(profile)

    suspend fun installRemote(
        profile: ServerProfile,
        onProgress: (String) -> Unit,
    ) = transport.installRemote(
        profile = profile,
        codexVersion = BuildConfig.PINNED_CODEX_VERSION,
        nodeVersion = BuildConfig.PINNED_NODE_VERSION,
        onProgress = onProgress,
    )

    suspend fun installRemoteDetailed(
        profile: ServerProfile,
        onProgress: (top.asdb.codexremote.ssh.RemoteInstallProgress) -> Unit,
    ) = transport.installRemoteDetailed(
        profile = profile,
        codexVersion = BuildConfig.PINNED_CODEX_VERSION,
        nodeVersion = BuildConfig.PINNED_NODE_VERSION,
        onProgress = onProgress,
    )

    /** Disconnects this client and removes only the runtime managed by Codex Remote. */
    suspend fun uninstallRemote(profile: ServerProfile) {
        disconnect()
        transport.uninstallRemote(profile)
    }

    suspend fun connect(profile: ServerProfile): String {
        if (connectedProfileId != profile.id) {
            connectedProfileId = profile.id
            activeThreadCache = cacheForProfile(profile.id)
        }
        invalidateGeneration("连接已替换")
        val generation = transport.connect(profile)
        activeGeneration.set(generation)
        return try {
            val initialize = request(
                "initialize",
                buildJsonObject {
                    put("clientInfo", buildJsonObject {
                        put("name", "codex_remote_android")
                        put("title", "Codex Remote Android")
                        put("version", BuildConfig.VERSION_NAME)
                    })
                    put("capabilities", buildJsonObject {
                        put("optOutNotificationMethods", JsonArray(emptyList()))
                        put("experimentalApi", true)
                    })
                },
            ).jsonObject
            notify("initialized", JsonObject(emptyMap()))
            initialize.string("userAgent").ifBlank { "codex-cli ${BuildConfig.PINNED_CODEX_VERSION}" }
        } catch (error: Throwable) {
            activeGeneration.compareAndSet(generation, NO_GENERATION)
            transport.disconnect()
            throw error
        }
    }

    suspend fun disconnect() {
        invalidateGeneration("连接已关闭")
        transport.disconnect()
    }

    fun close() {
        invalidateGeneration("连接已关闭")
        transport.close()
    }

    fun isGenerationActive(generation: Long): Boolean = activeGeneration.get() == generation

    /** Captures the app-server generation so UI callbacks cannot publish after reconnect. */
    fun currentGeneration(): Long? = activeGeneration.get().takeUnless { it == NO_GENERATION }

    fun isClosedGenerationCurrent(generation: Long): Boolean =
        activeGeneration.get() == NO_GENERATION && closedGeneration.get() == generation

    suspend fun listThreads(search: String = "", archived: Boolean = false): List<CodexThread> {
        val result = request("thread/list", buildJsonObject {
            put("limit", 100)
            put("archived", archived)
            put("sortKey", "recency_at")
            put("sortDirection", "desc")
            if (search.isNotBlank()) put("searchTerm", search.trim())
        }).jsonObject
        return CodexPayloadParser.parseThreads(result)
    }

    suspend fun listModels(): List<CodexModel> {
        val result = request("model/list", buildJsonObject { put("limit", 100) }).jsonObject
        return CodexPayloadParser.parseModels(result).filterNot { it.id.isBlank() }
    }

    suspend fun openThread(
        threadId: String,
        approvalMode: ApprovalMode,
    ): ResumedThread {
        val (response, itemsView) = try {
            requestThreadResume(threadId, approvalMode, itemsView = "full") to "full"
        } catch (_: CodexResponseTooLargeException) {
            try {
                requestThreadResume(
                    threadId,
                    approvalMode,
                    itemsView = "full",
                    limit = OVERSIZED_RETRY_PAGE_LIMIT,
                ) to "full"
            } catch (_: CodexResponseTooLargeException) {
                try {
                    requestThreadResume(
                        threadId,
                        approvalMode,
                        itemsView = "summary",
                        limit = OVERSIZED_RETRY_PAGE_LIMIT,
                    ) to "summary"
                } catch (_: CodexResponseTooLargeException) {
                    requestThreadResume(
                        threadId,
                        approvalMode,
                        itemsView = "notLoaded",
                        limit = OVERSIZED_RETRY_PAGE_LIMIT,
                    ) to "notLoaded"
                }
            }
        }
        return parseResumedThreadPayload(response.result.jsonObject, response.sequence).copy(itemsView = itemsView)
    }

    suspend fun listThreadTurnsPage(threadId: String, cursor: String): ThreadTurnsPage {
        val (result, itemsView) = try {
            requestThreadTurnsPage(threadId, cursor, itemsView = "full") to "full"
        } catch (_: CodexResponseTooLargeException) {
            try {
                requestThreadTurnsPage(
                    threadId,
                    cursor,
                    itemsView = "full",
                    limit = OVERSIZED_RETRY_PAGE_LIMIT,
                ) to "full"
            } catch (_: CodexResponseTooLargeException) {
                try {
                    requestThreadTurnsPage(
                        threadId,
                        cursor,
                        itemsView = "summary",
                        limit = OVERSIZED_RETRY_PAGE_LIMIT,
                    ) to "summary"
                } catch (_: CodexResponseTooLargeException) {
                    requestThreadTurnsPage(
                        threadId,
                        cursor,
                        itemsView = "notLoaded",
                        limit = OVERSIZED_RETRY_PAGE_LIMIT,
                    ) to "notLoaded"
                }
            }
        }
        return parseThreadTurnsPagePayload(result.jsonObject).copy(itemsView = itemsView)
    }

    private suspend fun requestThreadResume(
        threadId: String,
        approvalMode: ApprovalMode,
        itemsView: String,
        limit: Int = INITIAL_TURNS_PAGE_LIMIT,
    ): RpcResponse = requestSequenced(
        "thread/resume",
        buildThreadResumeParams(threadId, approvalMode, itemsView, limit),
        timeoutMs = threadRequestTimeoutMs,
    )

    private suspend fun requestThreadTurnsPage(
        threadId: String,
        cursor: String,
        itemsView: String,
        limit: Int = OLDER_TURNS_PAGE_LIMIT,
    ): JsonElement = request(
        "thread/turns/list",
        buildThreadTurnsListParams(threadId, cursor, itemsView, limit),
        timeoutMs = threadRequestTimeoutMs,
    )

    suspend fun readThread(threadId: String): Pair<CodexThread, List<TimelineEntry>> {
        val result = request(
            "thread/read",
            buildJsonObject {
                put("threadId", threadId)
                put("includeTurns", true)
            },
            timeoutMs = threadRequestTimeoutMs,
        ).jsonObject
        val snapshot = CodexPayloadParser.parseThreadPayload(result)
        activeThreadCache.put(snapshot.first, snapshot.second)
        return snapshot
    }

    /** Returns a recent snapshot without doing network I/O. */
    fun cachedThread(threadId: String): ThreadSessionCache.Snapshot? = activeThreadCache.get(threadId)

    /** Returns an expired snapshot for a UI fast path while a remote refresh is running. */
    fun cachedThreadStale(threadId: String): ThreadSessionCache.Snapshot? = activeThreadCache.getStale(threadId)

    fun cacheThread(
        thread: CodexThread,
        timeline: List<TimelineEntry>,
        nextTurnsCursor: String? = null,
        tokenUsage: TokenUsage? = null,
    ) {
        activeThreadCache.put(thread, timeline, nextTurnsCursor, tokenUsage)
    }

    suspend fun startThread(
        profile: ServerProfile,
        model: String?,
        approvalMode: ApprovalMode,
    ): Pair<CodexThread, List<TimelineEntry>> {
        val result = request("thread/start", buildJsonObject {
            profile.workspace.takeIf { it.isNotBlank() }?.let { put("cwd", it) }
            model?.takeIf { it.isNotBlank() }?.let { put("model", it) }
            put("approvalPolicy", approvalMode.approvalPolicy)
            put("sandbox", approvalMode.sandbox.wireValue)
            put("ephemeral", false)
        }, timeoutMs = threadRequestTimeoutMs).jsonObject
        val snapshot = CodexPayloadParser.parseThreadPayload(result)
        activeThreadCache.put(snapshot.first, snapshot.second)
        return snapshot
    }

    suspend fun startTurn(
        threadId: String,
        text: String,
        attachments: List<PendingAttachment>,
        model: String?,
        effort: String?,
        approvalMode: ApprovalMode,
        cwd: String?,
    ): String {
        val input = buildUserInput(text, attachments)
        val result = request("turn/start", buildJsonObject {
            put("threadId", threadId)
            put("input", input)
            put("approvalPolicy", approvalMode.approvalPolicy)
            put("sandboxPolicy", buildJsonObject { put("type", approvalMode.sandbox.policyType) })
            model?.takeIf { it.isNotBlank() }?.let { put("model", it) }
            effort?.takeIf { it.isNotBlank() }?.let { put("effort", it) }
            cwd?.takeIf { it.isNotBlank() }?.let { put("cwd", it) }
        }).jsonObject
        return result.obj("turn")?.string("id")?.takeIf { it.isNotBlank() }
            ?: throw CodexRpcException("Codex turn/start 响应缺少 turn.id")
    }

    suspend fun steerTurn(
        threadId: String,
        turnId: String,
        text: String,
        attachments: List<PendingAttachment>,
    ) {
        request("turn/steer", buildJsonObject {
            put("threadId", threadId)
            put("expectedTurnId", turnId)
            put("input", buildUserInput(text, attachments))
        })
    }

    suspend fun interruptTurn(threadId: String, turnId: String) {
        request("turn/interrupt", buildJsonObject {
            put("threadId", threadId)
            put("turnId", turnId)
        })
    }

    /** Starts the app-server's native manual context compaction flow. */
    suspend fun compactThread(threadId: String) {
        request(
            "thread/compact/start",
            buildJsonObject { put("threadId", threadId) },
            timeoutMs = threadRequestTimeoutMs,
        )
    }

    /** Reads the app-server's durable, thread-scoped goal state. */
    suspend fun getThreadGoal(threadId: String): ThreadGoal? {
        val result = request(
            "thread/goal/get",
            buildJsonObject { put("threadId", threadId) },
            // Goal hydration is optional UI enrichment. It must not keep a resumed thread in a
            // loading state behind the long timeout used for large thread-history requests.
            timeoutMs = DEFAULT_GOAL_READ_TIMEOUT_MS,
        ).jsonObject
        return result.obj("goal")?.let(CodexPayloadParser::parseThreadGoal)
    }

    /** Creates or updates the app-server's durable, thread-scoped goal. */
    suspend fun setThreadGoal(
        threadId: String,
        objective: String? = null,
        status: ThreadGoalStatus? = null,
        tokenBudget: Long? = null,
    ): ThreadGoal {
        val result = request(
            "thread/goal/set",
            buildJsonObject {
                put("threadId", threadId)
                objective?.let { put("objective", it) }
                status?.let { put("status", it.wireValue) }
                tokenBudget?.let { put("tokenBudget", it) }
            },
            timeoutMs = threadRequestTimeoutMs,
        ).jsonObject
        return result.obj("goal")?.let(CodexPayloadParser::parseThreadGoal)
            ?: throw CodexRpcException("Codex thread/goal/set 响应缺少 goal")
    }

    suspend fun clearThreadGoal(threadId: String) {
        request(
            "thread/goal/clear",
            buildJsonObject { put("threadId", threadId) },
            timeoutMs = threadRequestTimeoutMs,
        )
    }

    suspend fun listDirectories(path: String?): RemoteDirectoryListing = transport.listDirectories(path)

    suspend fun archiveThread(threadId: String) {
        request("thread/archive", buildJsonObject { put("threadId", threadId) })
        activeThreadCache.remove(threadId)
    }

    suspend fun rollbackThread(
        threadId: String,
        approvalMode: ApprovalMode,
        turns: Int = 1,
    ): ResumedThread {
        return try {
            val response = requestSequenced(
                "thread/rollback",
                buildJsonObject {
                    put("threadId", threadId)
                    put("numTurns", turns)
                },
                timeoutMs = threadRequestTimeoutMs,
            )
            parseResumedThreadPayload(response.result.jsonObject, response.sequence)
        } catch (_: CodexResponseTooLargeException) {
            // The rollback mutation already succeeded on the server; resume the resulting thread
            // with bounded paging instead of issuing rollback a second time.
            openThread(threadId, approvalMode)
        }
    }

    suspend fun setThreadName(threadId: String, name: String) {
        request("thread/name/set", buildJsonObject {
            put("threadId", threadId)
            put("name", name)
        })
        activeThreadCache.getStale(threadId)?.let { cached ->
            activeThreadCache.put(
                cached.thread.copy(title = name),
                cached.timeline,
                cached.nextTurnsCursor,
                cached.tokenUsage,
            )
        }
    }

    suspend fun startReview(threadId: String) {
        request("review/start", buildJsonObject {
            put("threadId", threadId)
            put("target", buildJsonObject { put("type", "uncommittedChanges") })
            put("delivery", "inline")
        })
    }

    suspend fun upload(name: String, bytes: ByteArray): String = transport.upload(name, bytes)

    suspend fun answerApproval(
        prompt: ApprovalPrompt,
        accept: Boolean,
        answers: Map<String, String> = emptyMap(),
    ) {
        val stored = serverRequests.remove(prompt.requestId)
            ?: throw IllegalStateException("审批请求已经失效")
        check(isGenerationActive(stored.generation)) { "审批请求已经失效" }
        val method = stored.method
        val params = stored.params
        val result = when (method) {
            "item/commandExecution/requestApproval", "item/fileChange/requestApproval" ->
                buildJsonObject { put("decision", if (accept) "accept" else "decline") }

            "execCommandApproval", "applyPatchApproval" ->
                buildJsonObject { put("decision", if (accept) "approved" else "denied") }

            "item/permissions/requestApproval", "permissions/requestApproval" -> buildJsonObject {
                put("permissions", if (accept) params["permissions"] ?: JsonObject(emptyMap()) else JsonObject(emptyMap()))
                put("scope", "turn")
            }

            "item/tool/requestUserInput", "tool/requestUserInput" -> buildJsonObject {
                put("answers", buildJsonObject {
                    prompt.questions.forEach { question ->
                        put(question.id, buildJsonObject {
                            put("answers", buildJsonArray {
                                add(JsonPrimitive(answers[question.id].orEmpty()))
                            })
                        })
                    }
                })
            }

            else -> throw IllegalStateException("不支持的审批类型: $method")
        }
        try {
            sendResponse(stored.generation, prompt.requestId, prompt.requestIdIsString, result)
        } catch (error: Throwable) {
            // Keep the request answerable if the write failed transiently; the caller can retry.
            if (isGenerationActive(stored.generation)) serverRequests[prompt.requestId] = stored
            throw error
        }
    }

    fun isConnected(): Boolean = transport.isConnected()

    private fun buildUserInput(
        text: String,
        attachments: List<PendingAttachment>,
    ): JsonArray = buildJsonArray {
        if (text.isNotBlank()) add(buildJsonObject {
            put("type", "text")
            put("text", text)
        })
        attachments.forEach { attachment ->
            if (attachment.mimeType.startsWith("image/")) {
                add(buildJsonObject {
                    put("type", "localImage")
                    put("path", attachment.remotePath)
                })
            } else {
                add(buildJsonObject {
                    put("type", "text")
                    put("text", "附件 ${attachment.name}: ${attachment.remotePath}")
                })
            }
        }
    }

    private suspend fun request(
        method: String,
        params: JsonObject,
        timeoutMs: Long = requestTimeoutMs,
    ): JsonElement = requestSequenced(method, params, timeoutMs).result

    private suspend fun requestSequenced(
        method: String,
        params: JsonObject,
        timeoutMs: Long = requestTimeoutMs,
    ): RpcResponse {
        val generation = requireActiveGeneration()
        val id = nextId.getAndIncrement().toString()
        val deferred = CompletableDeferred<RpcResponse>()
        pending[id] = deferred
        try {
            transport.sendLine(
                json.encodeToString(JsonObject.serializer(), buildJsonObject {
                    put("method", method)
                    put("id", id.toLong())
                    put("params", params)
                }),
                generation,
            )
        } catch (error: Throwable) {
            pending.remove(id)
            deferred.completeExceptionally(error)
        }
        return try {
            withTimeout(timeoutMs) { deferred.await() }
        } catch (error: TimeoutCancellationException) {
            throw CodexRequestTimeoutException(method, timeoutMs)
        } finally {
            pending.remove(id, deferred)
        }
    }

    private suspend fun notify(method: String, params: JsonObject) {
        val generation = requireActiveGeneration()
        transport.sendLine(
            json.encodeToString(JsonObject.serializer(), buildJsonObject {
                put("method", method)
                put("params", params)
            }),
            generation,
        )
    }

    private suspend fun sendResponse(generation: Long, id: String, idIsString: Boolean, result: JsonObject) {
        transport.sendLine(
            json.encodeToString(JsonObject.serializer(), buildJsonObject {
                if (idIsString) {
                    put("id", id)
                } else {
                    id.toLongOrNull()?.let { put("id", it) } ?: put("id", id)
                }
                put("result", result)
            }),
            generation,
        )
    }

    private suspend fun sendErrorResponse(
        generation: Long,
        id: String,
        idIsString: Boolean,
        code: Int,
        message: String,
    ) {
        transport.sendLine(
            json.encodeToString(JsonObject.serializer(), buildJsonObject {
                if (idIsString) {
                    put("id", id)
                } else {
                    id.toLongOrNull()?.let { put("id", it) } ?: put("id", id)
                }
                put("error", buildJsonObject {
                    put("code", code)
                    put("message", message)
                })
            }),
            generation,
        )
    }

    private fun requireActiveGeneration(): Long = activeGeneration.get().also { generation ->
        check(generation != NO_GENERATION) { "SSH 通道尚未连接" }
    }

    private fun cacheForProfile(profileId: String): ThreadSessionCache = synchronized(threadCacheLock) {
        threadCaches[profileId] ?: (if (threadCaches.isEmpty()) threadCache else ThreadSessionCache()).also {
            threadCaches[profileId] = it
        }
    }

    private fun invalidateGeneration(message: String) {
        activeGeneration.set(NO_GENERATION)
        closedGeneration.set(NO_GENERATION)
        val error = CodexRpcException(message)
        failPending(error)
        serverRequests.clear()
    }

    /** Removes the current snapshot before resuming callers, so immediate retries cannot be erased. */
    private fun failPending(error: Throwable) {
        val snapshot = pending.entries.map { it.key to it.value }
        val removed = snapshot.mapNotNull { (id, deferred) ->
            deferred.takeIf { pending.remove(id, deferred) }
        }
        removed.forEach { it.completeExceptionally(error) }
    }

    private suspend fun handleLine(event: SshTransportEvent) {
        val generation = event.generation
        if (!isGenerationActive(generation)) return
        val sequence = nextWireSequence.incrementAndGet()
        val message = runCatching { json.parseToJsonElement(event.value).jsonObject }.getOrElse {
            if (isGenerationActive(generation)) {
                _diagnostics.emit(
                    CodexConnectionEvent(generation, "无法解析 Codex 输出: ${event.value.take(240)}"),
                )
            }
            return
        }
        if (!isGenerationActive(generation)) return
        val idElement = message["id"] as? JsonPrimitive
        val method = message.string("method")
        if (method.isNotBlank()) {
            if (idElement != null) {
                val key = idElement.content
                val params = message.obj("params") ?: JsonObject(emptyMap())
                val approval = CodexPayloadParser.parseServerRequest(message)
                if (approval != null) {
                    if (!isGenerationActive(generation)) return
                    val request = ServerRequest(generation, method, params)
                    serverRequests[key] = request
                    if (!isGenerationActive(generation)) {
                        serverRequests.remove(key, request)
                        return
                    }
                    _approvals.emit(CodexApproval(generation, approval))
                } else {
                    // Never leave an unknown server request pending: the active turn would wait
                    // forever for a response that this client cannot render.
                    runCatching {
                        sendErrorResponse(
                            generation,
                            key,
                            idElement.isString,
                            -32601,
                            "Unsupported server request: $method",
                        )
                    }.onFailure { error ->
                        if (isGenerationActive(generation)) {
                            _diagnostics.emit(
                                CodexConnectionEvent(
                                    generation,
                                    "无法回复未支持的服务端请求: ${error.message.orEmpty()}",
                                ),
                            )
                        }
                    }
                    if (isGenerationActive(generation)) {
                        _diagnostics.emit(
                            CodexConnectionEvent(generation, "未支持的 Codex 服务端请求，已拒绝: $method"),
                        )
                    }
                }
            } else {
                if (!isGenerationActive(generation)) return
                _notifications.emit(
                    CodexNotification(
                        generation,
                        method,
                        message.obj("params") ?: JsonObject(emptyMap()),
                        sequence,
                    ),
                )
            }
            return
        }
        if (idElement == null) return
        if (!isGenerationActive(generation)) return
        val deferred = pending.remove(idElement.content) ?: return
        val error = message.obj("error")
        if (error != null) {
            deferred.completeExceptionally(CodexRpcException(error.string("message").ifBlank { error.toString() }))
        } else {
            deferred.complete(RpcResponse(message["result"] ?: JsonNull, sequence))
        }
    }

    companion object {
        private const val NO_GENERATION = -1L
        const val DEFAULT_REQUEST_TIMEOUT_MS = 120_000L
        const val DEFAULT_THREAD_REQUEST_TIMEOUT_MS = 180_000L
        private const val DEFAULT_GOAL_READ_TIMEOUT_MS = 6_000L
    }
}

internal fun parseThreadTurnsPagePayload(result: JsonObject): ThreadTurnsPage {
    val turns = result.array("data").orEmpty().mapNotNull { it as? JsonObject }.asReversed()
    val timeline = CodexPayloadParser.parseTimeline(
        JsonObject(mapOf("turns" to JsonArray(turns))),
    )
    return ThreadTurnsPage(
        timeline = timeline,
        nextCursor = result.string("nextCursor").takeIf { it.isNotBlank() },
        turnIds = turns.mapNotNull { it.string("id").takeIf(String::isNotBlank) },
    )
}

internal fun parseResumedThreadPayload(result: JsonObject, responseSequence: Long): ResumedThread {
    val thread = result.obj("thread") ?: result
    val initialPage = result.obj("initialTurnsPage")
    // Paged data is requested newest-first and must be reversed. A legacy thread.turns payload is
    // already chronological, so reversing it would scramble the entire restored conversation.
    val chronologicalTurns = if (initialPage != null) {
        initialPage.array("data").orEmpty().mapNotNull { it as? JsonObject }.asReversed()
    } else {
        thread.array("turns").orEmpty().mapNotNull { it as? JsonObject }
    }
    val hydratedThread = JsonObject(thread + ("turns" to JsonArray(chronologicalTurns)))
    val snapshot = CodexPayloadParser.parseThreadPayload(hydratedThread)
    return ResumedThread(
        thread = snapshot.first,
        timeline = snapshot.second,
        responseSequence = responseSequence,
        nextTurnsCursor = initialPage?.string("nextCursor")?.takeIf { it.isNotBlank() },
        turnIds = chronologicalTurns.mapNotNull { it.string("id").takeIf(String::isNotBlank) },
    )
}

class CodexRequestTimeoutException(
    val method: String,
    val timeoutMs: Long,
) : CodexRpcException("Codex 请求超时（${timeoutMs / 1000} 秒）: $method")
