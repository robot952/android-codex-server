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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

data class CodexNotification(val method: String, val params: JsonObject)

class CodexRpcException(message: String) : RuntimeException(message)

class CodexAppServerClient(
    private val scope: CoroutineScope,
    private val transport: SshCodexTransport = SshCodexTransport(),
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val nextId = AtomicLong(1)
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonElement>>()
    private val serverRequests = ConcurrentHashMap<String, Pair<String, JsonObject>>()

    private val _notifications = MutableSharedFlow<CodexNotification>(extraBufferCapacity = 256)
    val notifications: SharedFlow<CodexNotification> = _notifications.asSharedFlow()

    private val _approvals = MutableSharedFlow<ApprovalPrompt>(extraBufferCapacity = 8)
    val approvals: SharedFlow<ApprovalPrompt> = _approvals.asSharedFlow()

    private val _diagnostics = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val diagnostics: SharedFlow<String> = _diagnostics.asSharedFlow()

    private val _closed = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val closed: SharedFlow<String> = _closed.asSharedFlow()

    init {
        scope.launch(Dispatchers.Default) {
            transport.lines.collect(::handleLine)
        }
        scope.launch { transport.diagnostics.collect { _diagnostics.emit(it) } }
        scope.launch {
            transport.closed.collect { message ->
                val error = CodexRpcException(message)
                pending.values.forEach { deferred -> deferred.completeExceptionally(error) }
                pending.clear()
                serverRequests.clear()
                _diagnostics.emit(message)
                _closed.emit(message)
            }
        }
    }

    suspend fun probeFingerprint(profile: ServerProfile): String = transport.probeFingerprint(profile)

    suspend fun connect(profile: ServerProfile): String {
        transport.connect(profile)
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
            transport.disconnect()
            throw error
        }
    }

    suspend fun disconnect() {
        pending.values.forEach { it.completeExceptionally(CodexRpcException("连接已关闭")) }
        pending.clear()
        serverRequests.clear()
        transport.disconnect()
    }

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
        val result = request("thread/resume", buildJsonObject {
            put("threadId", threadId)
            put("approvalPolicy", approvalMode.approvalPolicy)
        }).jsonObject
        return CodexPayloadParser.parseThreadPayload(result)
    }

    suspend fun readThread(threadId: String): Pair<CodexThread, List<TimelineEntry>> {
        val result = request("thread/read", buildJsonObject {
            put("threadId", threadId)
            put("includeTurns", true)
        }).jsonObject
        return CodexPayloadParser.parseThreadPayload(result)
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
        }).jsonObject
        return CodexPayloadParser.parseThreadPayload(result)
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
    }

    suspend fun rollbackThread(threadId: String, turns: Int = 1): Pair<CodexThread, List<TimelineEntry>> {
        val result = request("thread/rollback", buildJsonObject {
            put("threadId", threadId)
            put("numTurns", turns)
        }).jsonObject
        return CodexPayloadParser.parseThreadPayload(result)
    }

    suspend fun setThreadName(threadId: String, name: String) {
        request("thread/name/set", buildJsonObject {
            put("threadId", threadId)
            put("name", name)
        })
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
        val method = stored.first
        val params = stored.second
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
            sendResponse(prompt.requestId, prompt.requestIdIsString, result)
        } catch (error: Throwable) {
            // Keep the request answerable if the write failed transiently; the caller can retry.
            serverRequests[prompt.requestId] = stored
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

    private suspend fun request(method: String, params: JsonObject): JsonElement {
        val id = nextId.getAndIncrement().toString()
        val deferred = CompletableDeferred<JsonElement>()
        pending[id] = deferred
        try {
            transport.sendLine(json.encodeToString(JsonObject.serializer(), buildJsonObject {
                put("method", method)
                put("id", id.toLong())
                put("params", params)
            }))
        } catch (error: Throwable) {
            pending.remove(id)
            deferred.completeExceptionally(error)
        }
        return try {
            withTimeout(REQUEST_TIMEOUT_MS) { deferred.await() }
        } catch (error: TimeoutCancellationException) {
            pending.remove(id)
            throw CodexRpcException("Codex 请求超时: $method")
        }
    }

    private suspend fun notify(method: String, params: JsonObject) {
        transport.sendLine(json.encodeToString(JsonObject.serializer(), buildJsonObject {
            put("method", method)
            put("params", params)
        }))
    }

    private suspend fun sendResponse(id: String, idIsString: Boolean, result: JsonObject) {
        transport.sendLine(json.encodeToString(JsonObject.serializer(), buildJsonObject {
            if (idIsString) {
                put("id", id)
            } else {
                id.toLongOrNull()?.let { put("id", it) } ?: put("id", id)
            }
            put("result", result)
        }))
    }

    private suspend fun sendErrorResponse(id: String, idIsString: Boolean, code: Int, message: String) {
        transport.sendLine(json.encodeToString(JsonObject.serializer(), buildJsonObject {
            if (idIsString) {
                put("id", id)
            } else {
                id.toLongOrNull()?.let { put("id", it) } ?: put("id", id)
            }
            put("error", buildJsonObject {
                put("code", code)
                put("message", message)
            })
        }))
    }

    private suspend fun handleLine(line: String) {
        val message = runCatching { json.parseToJsonElement(line).jsonObject }.getOrElse {
            _diagnostics.emit("无法解析 Codex 输出: ${line.take(240)}")
            return
        }
        val idElement = message["id"] as? JsonPrimitive
        val method = message.string("method")
        if (method.isNotBlank()) {
            if (idElement != null) {
                val key = idElement.content
                val params = message.obj("params") ?: JsonObject(emptyMap())
                val approval = CodexPayloadParser.parseServerRequest(message)
                if (approval != null) {
                    serverRequests[key] = method to params
                    _approvals.emit(approval)
                } else {
                    // Never leave an unknown server request pending: the active turn would wait
                    // forever for a response that this client cannot render.
                    runCatching {
                        sendErrorResponse(key, idElement.isString, -32601, "Unsupported server request: $method")
                    }.onFailure { error ->
                        _diagnostics.emit("无法回复未支持的服务端请求: ${error.message.orEmpty()}")
                    }
                    _diagnostics.emit("未支持的 Codex 服务端请求，已拒绝: $method")
                }
            } else {
                _notifications.emit(CodexNotification(method, message.obj("params") ?: JsonObject(emptyMap())))
            }
            return
        }
        if (idElement == null) return
        val deferred = pending.remove(idElement.content) ?: return
        val error = message.obj("error")
        if (error != null) {
            deferred.completeExceptionally(CodexRpcException(error.string("message").ifBlank { error.toString() }))
        } else {
            deferred.complete(message["result"] ?: JsonNull)
        }
    }

    companion object {
        private const val REQUEST_TIMEOUT_MS = 30_000L
    }
}
