package top.asdb.codexremote.ssh

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale

/**
 * RFC 6455 framing for a WebSocket exposed over a bidirectional SSH exec stream.
 *
 * The Codex `app-server proxy` command only forwards bytes to its private Unix socket. It does
 * not translate JSONL, so this class carries one JSON-RPC object in each WebSocket text message.
 */
internal class WebSocketJsonTunnel(
    private val input: InputStream,
    private val output: OutputStream,
    private val fillRandomBytes: (ByteArray) -> Unit = { SecureRandom().nextBytes(it) },
) {
    sealed interface Event {
        data class Text(val value: String) : Event

        data class Close(
            val code: Int?,
            val reason: String,
        ) : Event
    }

    private data class Frame(
        val fin: Boolean,
        val opcode: Int,
        val payload: ByteArray,
    )

    private val handshakeLock = Any()
    private val writeLock = Any()

    @Volatile
    private var handshaken = false

    @Volatile
    private var closeReceived = false

    /** Guarded by [writeLock]. */
    private var closeSent = false
    private var fragmentedText: ByteArrayOutputStream? = null

    /**
     * Sends an HTTP Upgrade request and validates the server response before any JSON-RPC traffic
     * is sent. The proxy is local to the remote host, so `localhost` is the appropriate Host value.
     */
    fun performHandshake(
        host: String = DEFAULT_HOST,
        path: String = DEFAULT_PATH,
    ) {
        require(host.isNotBlank() && host.none { it == '\r' || it == '\n' }) {
            "WebSocket Host 不能为空且不能包含换行"
        }
        require(path.startsWith('/') && path.none { it == '\r' || it == '\n' }) {
            "WebSocket 路径必须以 / 开头且不能包含换行"
        }

        synchronized(handshakeLock) {
            check(!handshaken) { "WebSocket 已完成握手" }

            val keyBytes = ByteArray(WEBSOCKET_KEY_BYTES).also(fillRandomBytes)
            val clientKey = Base64.getEncoder().encodeToString(keyBytes)
            val request = buildString {
                append("GET ").append(path).append(" HTTP/1.1\r\n")
                append("Host: ").append(host).append("\r\n")
                append("Upgrade: websocket\r\n")
                append("Connection: Upgrade\r\n")
                append("Sec-WebSocket-Key: ").append(clientKey).append("\r\n")
                append("Sec-WebSocket-Version: 13\r\n")
                append("\r\n")
            }

            synchronized(writeLock) {
                output.write(request.toByteArray(Charsets.ISO_8859_1))
                output.flush()
            }

            validateHandshakeResponse(readHttpHeaderBlock(), clientKey)
            handshaken = true
        }
    }

    /** Sends one JSON-RPC payload as a masked, final WebSocket text frame. */
    fun sendText(value: String) {
        val payload = value.toByteArray(Charsets.UTF_8)
        require(payload.size <= MAX_MESSAGE_BYTES) {
            "WebSocket 文本消息超过 $MAX_MESSAGE_BYTES 字节"
        }
        requireHandshake()
        check(!closeReceived) { "WebSocket 已收到关闭帧" }
        synchronized(writeLock) {
            check(!closeReceived) { "WebSocket 已收到关闭帧" }
            check(!closeSent) { "WebSocket 已发送关闭帧" }
            writeFrameLocked(OPCODE_TEXT, fin = true, payload = payload)
        }
    }

    /**
     * Reads frames until a complete text message or a close frame arrives. Ping and Pong frames are
     * handled internally; each Ping receives a masked Pong while holding the same write lock as
     * normal requests.
     */
    fun readNextEvent(): Event {
        requireHandshake()
        check(!closeReceived) { "WebSocket 已收到关闭帧" }
        while (true) {
            val frame = readFrame()
            when (frame.opcode) {
                OPCODE_TEXT -> {
                    if (fragmentedText != null) {
                        throw WebSocketProtocolException(
                            "WebSocket 收到新的文本帧，但前一条分片消息尚未结束",
                        )
                    }
                    if (frame.fin) {
                        return Event.Text(decodeUtf8(frame.payload, "文本帧"))
                    }
                    fragmentedText = ByteArrayOutputStream(frame.payload.size).also {
                        it.write(frame.payload)
                    }
                }

                OPCODE_CONTINUATION -> {
                    val fragments = fragmentedText
                        ?: throw WebSocketProtocolException("WebSocket 收到没有起始帧的续帧")
                    appendFragment(fragments, frame.payload)
                    if (frame.fin) {
                        fragmentedText = null
                        return Event.Text(decodeUtf8(fragments.toByteArray(), "分片文本帧"))
                    }
                }

                OPCODE_BINARY -> throw WebSocketProtocolException("WebSocket 不支持二进制消息")

                OPCODE_PING -> sendPong(frame.payload)

                OPCODE_PONG -> Unit

                OPCODE_CLOSE -> {
                    val close = parseClose(frame.payload)
                    fragmentedText = null
                    closeReceived = true
                    synchronized(writeLock) {
                        if (!closeSent) {
                            writeFrameLocked(OPCODE_CLOSE, fin = true, payload = frame.payload)
                            closeSent = true
                        }
                    }
                    return close
                }

                else -> throw WebSocketProtocolException("WebSocket 收到不支持的操作码: ${frame.opcode}")
            }
        }
    }

    /**
     * Reads text messages until the peer closes the socket. This method intentionally does not
     * switch dispatchers: callers should invoke it from their existing Dispatchers.IO coroutine.
     * Closing the SSH exec channel closes [input], causing its blocking read to exit with EOF or
     * an I/O exception.
     */
    suspend fun readMessages(onText: suspend (String) -> Unit): Event.Close {
        while (true) {
            when (val event = readNextEvent()) {
                is Event.Text -> onText(event.value)
                is Event.Close -> return event
            }
        }
    }

    /** Sends a masked close frame. Repeated calls after the first close are ignored. */
    fun sendClose(
        code: Int = NORMAL_CLOSE_CODE,
        reason: String = "",
    ) {
        requireHandshake()
        require(isValidCloseCode(code)) { "无效的 WebSocket 关闭码: $code" }
        val reasonBytes = reason.toByteArray(Charsets.UTF_8)
        require(reasonBytes.size <= MAX_CONTROL_PAYLOAD_BYTES - CLOSE_CODE_BYTES) {
            "WebSocket 关闭原因超过 ${MAX_CONTROL_PAYLOAD_BYTES - CLOSE_CODE_BYTES} 字节"
        }
        val payload = ByteArray(CLOSE_CODE_BYTES + reasonBytes.size)
        payload[0] = (code ushr 8).toByte()
        payload[1] = code.toByte()
        reasonBytes.copyInto(payload, destinationOffset = CLOSE_CODE_BYTES)
        synchronized(writeLock) {
            if (closeSent) return
            writeFrameLocked(OPCODE_CLOSE, fin = true, payload = payload)
            closeSent = true
        }
    }

    private fun requireHandshake() {
        check(handshaken) { "WebSocket 尚未完成握手" }
    }

    private fun readHttpHeaderBlock(): ByteArray {
        val headers = ByteArrayOutputStream()
        val terminator = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte(), '\r'.code.toByte(), '\n'.code.toByte())
        var matchedTerminatorBytes = 0
        while (true) {
            if (headers.size() >= MAX_HTTP_HEADER_BYTES) {
                throw WebSocketProtocolException("WebSocket 握手响应头超过 $MAX_HTTP_HEADER_BYTES 字节")
            }
            val byte = input.read()
            if (byte < 0) throw EOFException("读取 WebSocket 握手响应时连接已关闭")
            headers.write(byte)
            matchedTerminatorBytes = when {
                byte.toByte() == terminator[matchedTerminatorBytes] -> matchedTerminatorBytes + 1
                byte.toByte() == terminator[0] -> 1
                else -> 0
            }
            if (matchedTerminatorBytes == terminator.size) return headers.toByteArray()
        }
    }

    private fun validateHandshakeResponse(response: ByteArray, clientKey: String) {
        val value = response.toString(Charsets.ISO_8859_1)
        if (!value.endsWith("\r\n\r\n")) {
            throw WebSocketProtocolException("WebSocket 握手响应头格式不完整")
        }
        val lines = value.removeSuffix("\r\n\r\n").split("\r\n")
        val statusLine = lines.firstOrNull()
            ?: throw WebSocketProtocolException("WebSocket 握手响应缺少状态行")
        val statusParts = statusLine.trim().split(Regex("\\s+"), limit = 3)
        if (
            statusParts.size < 2 ||
            !HTTP_VERSION_PATTERN.matches(statusParts[0]) ||
            statusParts[1] != "101"
        ) {
            throw WebSocketProtocolException("WebSocket 握手未返回 HTTP 101: $statusLine")
        }

        val headers = linkedMapOf<String, MutableList<String>>()
        lines.drop(1).forEach { line ->
            val separator = line.indexOf(':')
            if (separator <= 0) {
                throw WebSocketProtocolException("WebSocket 握手响应包含无效请求头")
            }
            val name = line.substring(0, separator)
            if (name != name.trim()) {
                throw WebSocketProtocolException("WebSocket 握手响应包含无效请求头名称")
            }
            headers.getOrPut(name.lowercase(Locale.US)) { mutableListOf() }
                .add(line.substring(separator + 1).trim())
        }

        if (!headerContainsToken(headers, "upgrade", "websocket")) {
            throw WebSocketProtocolException("WebSocket 握手响应缺少 Upgrade: websocket")
        }
        if (!headerContainsToken(headers, "connection", "upgrade")) {
            throw WebSocketProtocolException("WebSocket 握手响应缺少 Connection: Upgrade")
        }
        val acceptedKey = headers["sec-websocket-accept"]?.singleOrNull()?.trim()
        val expectedKey = websocketAccept(clientKey)
        if (acceptedKey != expectedKey) {
            throw WebSocketProtocolException("WebSocket 握手响应的 Sec-WebSocket-Accept 无效")
        }
    }

    private fun headerContainsToken(
        headers: Map<String, List<String>>,
        name: String,
        expectedToken: String,
    ): Boolean = headers[name]
        ?.flatMap { it.split(',') }
        ?.any { it.trim().equals(expectedToken, ignoreCase = true) }
        ?: false

    private fun readFrame(): Frame {
        val first = readRequiredByte("WebSocket 帧头")
        val second = readRequiredByte("WebSocket 帧头")
        if (first and RSV_MASK != 0) {
            throw WebSocketProtocolException("WebSocket 帧使用了未协商的 RSV 位")
        }
        val opcode = first and OPCODE_MASK
        if (opcode !in SUPPORTED_OPCODES) {
            throw WebSocketProtocolException("WebSocket 收到不支持的操作码: $opcode")
        }
        if (second and MASK_BIT != 0) {
            throw WebSocketProtocolException("WebSocket 服务端帧不应使用掩码")
        }

        val payloadLength = when (val compactLength = second and PAYLOAD_LENGTH_MASK) {
            in 0..SMALL_PAYLOAD_MAX -> compactLength.toLong()
            EXTENDED_SHORT_PAYLOAD -> readUnsignedShort().toLong()
            EXTENDED_LONG_PAYLOAD -> readUnsignedLong()
            else -> throw WebSocketProtocolException("WebSocket 帧长度无效")
        }
        val isControlFrame = opcode and CONTROL_OPCODE_BIT != 0
        if (isControlFrame && (first and FIN_BIT == 0 || payloadLength > MAX_CONTROL_PAYLOAD_BYTES)) {
            throw WebSocketProtocolException("WebSocket 控制帧不能分片且最多 $MAX_CONTROL_PAYLOAD_BYTES 字节")
        }
        if (payloadLength > MAX_MESSAGE_BYTES) {
            throw WebSocketProtocolException("WebSocket 帧超过 $MAX_MESSAGE_BYTES 字节")
        }
        return Frame(
            fin = first and FIN_BIT != 0,
            opcode = opcode,
            payload = ByteArray(payloadLength.toInt()).also(::readFully),
        )
    }

    private fun readUnsignedShort(): Int {
        val high = readRequiredByte("WebSocket 扩展帧长度")
        val low = readRequiredByte("WebSocket 扩展帧长度")
        return (high shl 8) or low
    }

    private fun readUnsignedLong(): Long {
        val first = readRequiredByte("WebSocket 扩展帧长度")
        if (first and MASK_BIT != 0) {
            throw WebSocketProtocolException("WebSocket 帧长度不能为负数")
        }
        var value = first.toLong()
        repeat(7) {
            value = (value shl 8) or readRequiredByte("WebSocket 扩展帧长度").toLong()
        }
        return value
    }

    private fun readRequiredByte(what: String): Int {
        val value = input.read()
        if (value < 0) throw EOFException("读取 $what 时连接已关闭")
        return value
    }

    private fun readFully(destination: ByteArray) {
        var offset = 0
        while (offset < destination.size) {
            val count = input.read(destination, offset, destination.size - offset)
            if (count < 0) throw EOFException("读取 WebSocket 帧负载时连接已关闭")
            if (count == 0) continue
            offset += count
        }
    }

    private fun appendFragment(fragments: ByteArrayOutputStream, payload: ByteArray) {
        if (payload.size > MAX_MESSAGE_BYTES - fragments.size()) {
            throw WebSocketProtocolException("WebSocket 分片消息超过 $MAX_MESSAGE_BYTES 字节")
        }
        fragments.write(payload)
    }

    private fun sendPong(payload: ByteArray) {
        synchronized(writeLock) {
            if (!closeSent) writeFrameLocked(OPCODE_PONG, fin = true, payload = payload)
        }
    }

    private fun parseClose(payload: ByteArray): Event.Close {
        if (payload.isEmpty()) return Event.Close(code = null, reason = "")
        if (payload.size == 1) {
            throw WebSocketProtocolException("WebSocket 关闭帧缺少完整关闭码")
        }
        val code = ((payload[0].toInt() and BYTE_MASK) shl 8) or (payload[1].toInt() and BYTE_MASK)
        if (!isValidCloseCode(code)) {
            throw WebSocketProtocolException("WebSocket 关闭帧包含无效关闭码: $code")
        }
        val reason = decodeUtf8(payload.copyOfRange(CLOSE_CODE_BYTES, payload.size), "关闭原因")
        return Event.Close(code, reason)
    }

    private fun writeFrameLocked(
        opcode: Int,
        fin: Boolean,
        payload: ByteArray,
    ) {
        check(opcode in SUPPORTED_OPCODES) { "不支持的 WebSocket 操作码: $opcode" }
        check(payload.size <= MAX_MESSAGE_BYTES) { "WebSocket 帧超过 $MAX_MESSAGE_BYTES 字节" }
        if (opcode and CONTROL_OPCODE_BIT != 0) {
            check(fin && payload.size <= MAX_CONTROL_PAYLOAD_BYTES) { "无效的 WebSocket 控制帧" }
        }

        val first = opcode or if (fin) FIN_BIT else 0
        output.write(first)
        when (payload.size) {
            in 0..SMALL_PAYLOAD_MAX -> output.write(MASK_BIT or payload.size)
            in (SMALL_PAYLOAD_MAX + 1)..MAX_UNSIGNED_SHORT -> {
                output.write(MASK_BIT or EXTENDED_SHORT_PAYLOAD)
                output.write(payload.size ushr 8)
                output.write(payload.size)
            }

            else -> {
                output.write(MASK_BIT or EXTENDED_LONG_PAYLOAD)
                var shift = 56
                while (shift >= 0) {
                    output.write((payload.size.toLong() ushr shift).toInt())
                    shift -= 8
                }
            }
        }

        val mask = ByteArray(MASK_BYTES).also(fillRandomBytes)
        output.write(mask)
        val maskedPayload = payload.copyOf()
        maskedPayload.indices.forEach { index ->
            maskedPayload[index] = (maskedPayload[index].toInt() xor mask[index % MASK_BYTES].toInt()).toByte()
        }
        output.write(maskedPayload)
        output.flush()
    }

    private fun decodeUtf8(bytes: ByteArray, context: String): String = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: CharacterCodingException) {
        throw WebSocketProtocolException("WebSocket $context 包含无效 UTF-8")
    }

    companion object {
        internal const val MAX_HTTP_HEADER_BYTES = 16 * 1024
        internal const val MAX_MESSAGE_BYTES = 8 * 1024 * 1024

        private const val DEFAULT_HOST = "localhost"
        private const val DEFAULT_PATH = "/"
        private const val WEBSOCKET_KEY_BYTES = 16
        private const val MASK_BYTES = 4
        private const val CLOSE_CODE_BYTES = 2
        private const val NORMAL_CLOSE_CODE = 1000
        private const val MAX_CONTROL_PAYLOAD_BYTES = 125
        private const val SMALL_PAYLOAD_MAX = 125
        private const val MAX_UNSIGNED_SHORT = 0xffff
        private const val EXTENDED_SHORT_PAYLOAD = 126
        private const val EXTENDED_LONG_PAYLOAD = 127
        private const val FIN_BIT = 0x80
        private const val RSV_MASK = 0x70
        private const val MASK_BIT = 0x80
        private const val OPCODE_MASK = 0x0f
        private const val PAYLOAD_LENGTH_MASK = 0x7f
        private const val CONTROL_OPCODE_BIT = 0x08
        private const val BYTE_MASK = 0xff
        private const val OPCODE_CONTINUATION = 0x00
        private const val OPCODE_TEXT = 0x01
        private const val OPCODE_BINARY = 0x02
        private const val OPCODE_CLOSE = 0x08
        private const val OPCODE_PING = 0x09
        private const val OPCODE_PONG = 0x0a
        private val SUPPORTED_OPCODES = setOf(
            OPCODE_CONTINUATION,
            OPCODE_TEXT,
            OPCODE_BINARY,
            OPCODE_CLOSE,
            OPCODE_PING,
            OPCODE_PONG,
        )
        private val HTTP_VERSION_PATTERN = Regex("HTTP/[0-9]+\\.[0-9]+")

        private fun websocketAccept(clientKey: String): String {
            val source = (clientKey + WEBSOCKET_GUID).toByteArray(Charsets.ISO_8859_1)
            return Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest(source))
        }

        private fun isValidCloseCode(code: Int): Boolean =
            code in 1000..1014 && code !in setOf(1004, 1005, 1006) || code in 3000..4999

        private const val WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    }
}

internal class WebSocketProtocolException(message: String) : IOException(message)
