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
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.ssh.SshCodexTransport
import top.asdb.codexremote.ssh.RemoteEnvironment
import top.asdb.codexremote.ssh.SshTransportEvent
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

data class CodexNotification(val generation: Long, val method: String, val params: JsonObject)

data class CodexApproval(val generation: Long, val prompt: ApprovalPrompt)

data class CodexConnectionEvent(val generation: Long, val message: String)

private data class ServerRequest(
    val generation: Long,
    val method: String,
    val params: JsonObject,
)

open class CodexRpcException(message: String) : RuntimeException(message)

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
    private val activeGeneration = AtomicLong(NO_GENERATION)
    private val closedGeneration = AtomicLong(NO_GENERATION)
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonElement>>()
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
            transport.closed.collect { event ->
                if (!activeGeneration.compareAndSet(event.generation, NO_GENERATION)) return@collect
                closedGeneration.set(event.generation)
                val error = CodexRpcException(event.value)
                pending.values.forEach { deferred -> deferred.completeExceptionally(error) }
                pending.clear()
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
    ): Pair<CodexThread, List<TimelineEntry>> {
        val result = request(
            "thread/resume",
            buildJsonObject {
                put("threadId", threadId)
                put("approvalPolicy", approvalMode.approvalPolicy)
            },
            timeoutMs = threadRequestTimeoutMs,
        ).jsonObject
        val snapshot = CodexPayloadParser.parseThreadPayload(result)
        activeThreadCache.put(snapshot.first, snapshot.second)
        return snapshot
    }

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
    fun cachedThread(threadId: String): Pair<CodexThread, List<TimelineEntry>>? =
        activeThreadCache.get(threadId)?.let { it.thread to it.timeline }

    /** Returns an expired snapshot for a UI fast path while a remote refresh is running. */
    fun cachedThreadStale(threadId: String): Pair<CodexThread, List<TimelineEntry>>? =
        activeThreadCache.getStale(threadId)?.let { it.thread to it.timeline }

    fun cacheThread(thread: CodexThread, timeline: List<TimelineEntry>) {
        activeThreadCache.put(thread, timeline)
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

    suspend fun listDirectories(path: String?): RemoteDirectoryListing = transport.listDirectories(path)

    suspend fun archiveThread(threadId: String) {
        request("thread/archive", buildJsonObject { put("threadId", threadId) })
        activeThreadCache.remove(threadId)
    }

    suspend fun rollbackThread(threadId: String, turns: Int = 1): Pair<CodexThread, List<TimelineEntry>> {
        val result = request("thread/rollback", buildJsonObject {
            put("threadId", threadId)
            put("numTurns", turns)
        }, timeoutMs = threadRequestTimeoutMs).jsonObject
        val snapshot = CodexPayloadParser.parseThreadPayload(result)
        activeThreadCache.put(snapshot.first, snapshot.second)
        return snapshot
    }

    suspend fun setThreadName(threadId: String, name: String) {
        request("thread/name/set", buildJsonObject {
            put("threadId", threadId)
            put("name", name)
        })
        activeThreadCache.getStale(threadId)?.let { cached ->
            activeThreadCache.put(cached.thread.copy(title = name), cached.timeline)
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
    ): JsonElement {
        val generation = requireActiveGeneration()
        val id = nextId.getAndIncrement().toString()
        val deferred = CompletableDeferred<JsonElement>()
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
            pending.remove(id)
            throw CodexRequestTimeoutException(method, timeoutMs)
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
        pending.values.forEach { it.completeExceptionally(error) }
        pending.clear()
        serverRequests.clear()
    }

    private suspend fun handleLine(event: SshTransportEvent) {
        val generation = event.generation
        if (!isGenerationActive(generation)) return
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
                    CodexNotification(generation, method, message.obj("params") ?: JsonObject(emptyMap())),
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
            deferred.complete(message["result"] ?: JsonNull)
        }
    }

    companion object {
        private const val NO_GENERATION = -1L
        const val DEFAULT_REQUEST_TIMEOUT_MS = 120_000L
        const val DEFAULT_THREAD_REQUEST_TIMEOUT_MS = 180_000L
    }
}

class CodexRequestTimeoutException(
    val method: String,
    val timeoutMs: Long,
) : CodexRpcException("Codex 请求超时（${timeoutMs / 1000} 秒）: $method")
