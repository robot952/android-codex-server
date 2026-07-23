package top.asdb.codexremote.ssh

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.runBlocking
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64

class WebSocketJsonTunnelTest {
    @Test
    fun `handshake sends upgrade request and accepts a valid response`() {
        val keyBytes = ByteArray(16) { it.toByte() }
        val key = Base64.getEncoder().encodeToString(keyBytes)
        val output = ByteArrayOutputStream()
        val tunnel = WebSocketJsonTunnel(
            input = ByteArrayInputStream(handshakeResponse(key).toByteArray()),
            output = output,
            fillRandomBytes = deterministicBytes(keyBytes, byteArrayOf(1, 2, 3, 4)),
        )

        tunnel.performHandshake(host = "codex.local", path = "/app-server")

        val request = output.toString(Charsets.ISO_8859_1.name())
        assertTrue(request.startsWith("GET /app-server HTTP/1.1\r\n"))
        assertTrue(request.contains("Host: codex.local\r\n"))
        assertTrue(request.contains("Sec-WebSocket-Key: $key\r\n"))
        assertTrue(request.endsWith("Sec-WebSocket-Version: 13\r\n\r\n"))
    }

    @Test
    fun `handshake rejects an invalid accept key`() {
        val output = ByteArrayOutputStream()
        val tunnel = WebSocketJsonTunnel(
            input = ByteArrayInputStream(
                (
                    "HTTP/1.1 101 Switching Protocols\r\n" +
                        "Upgrade: websocket\r\n" +
                        "Connection: Upgrade\r\n" +
                        "Sec-WebSocket-Accept: invalid\r\n\r\n"
                    ).toByteArray(),
            ),
            output = output,
            fillRandomBytes = deterministicBytes(ByteArray(16), byteArrayOf(1, 2, 3, 4)),
        )

        val error = expectThrows<WebSocketProtocolException> { tunnel.performHandshake() }

        assertTrue(error.message.orEmpty().contains("Sec-WebSocket-Accept"))
    }

    @Test
    fun `handshake rejects headers larger than sixteen kibibytes`() {
        val output = ByteArrayOutputStream()
        val oversized = "HTTP/1.1 101 Switching Protocols\r\nX: " +
            "a".repeat(WebSocketJsonTunnel.MAX_HTTP_HEADER_BYTES) + "\r\n\r\n"
        val tunnel = WebSocketJsonTunnel(
            input = ByteArrayInputStream(oversized.toByteArray()),
            output = output,
            fillRandomBytes = deterministicBytes(ByteArray(16), byteArrayOf(1, 2, 3, 4)),
        )

        val error = expectThrows<WebSocketProtocolException> { tunnel.performHandshake() }

        assertTrue(error.message.orEmpty().contains("超过"))
    }

    @Test
    fun `outbound text is a masked UTF8 frame`() {
        val keyBytes = ByteArray(16) { (it + 1).toByte() }
        val output = ByteArrayOutputStream()
        val tunnel = WebSocketJsonTunnel(
            input = ByteArrayInputStream(handshakeResponse(Base64.getEncoder().encodeToString(keyBytes)).toByteArray()),
            output = output,
            fillRandomBytes = deterministicBytes(keyBytes, byteArrayOf(1, 2, 3, 4)),
        )
        tunnel.performHandshake()
        output.reset()

        tunnel.sendText("{\"ok\":true}")

        val bytes = output.toByteArray()
        assertEquals(0x81, bytes[0].toInt() and 0xff)
        assertEquals(0x80 or "{\"ok\":true}".toByteArray().size, bytes[1].toInt() and 0xff)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), bytes.copyOfRange(2, 6))
        val decoded = bytes.copyOfRange(6, bytes.size).mapIndexed { index, byte ->
            (byte.toInt() xor bytes[2 + index % 4].toInt()).toByte()
        }.toByteArray()
        assertEquals("{\"ok\":true}", decoded.toString(Charsets.UTF_8))
    }

    @Test
    fun `fragmented text is reassembled and ping receives a masked pong`() {
        val keyBytes = ByteArray(16) { (it + 2).toByte() }
        val output = ByteArrayOutputStream()
        val input = ByteArrayInputStream(
            handshakeResponse(Base64.getEncoder().encodeToString(keyBytes)).toByteArray() +
                serverFrame(opcode = 0x01, fin = false, payload = "{\"hel".toByteArray()) +
                serverFrame(opcode = 0x09, fin = true, payload = byteArrayOf(9, 8)) +
                serverFrame(opcode = 0x00, fin = true, payload = "lo\":1}".toByteArray()),
        )
        val tunnel = WebSocketJsonTunnel(
            input = input,
            output = output,
            fillRandomBytes = deterministicBytes(keyBytes, byteArrayOf(4, 3, 2, 1)),
        )
        tunnel.performHandshake()
        output.reset()

        val event = tunnel.readNextEvent()

        assertEquals(WebSocketJsonTunnel.Event.Text("{\"hello\":1}"), event)
        val pong = output.toByteArray()
        assertEquals(0x8a, pong[0].toInt() and 0xff)
        assertEquals(0x82, pong[1].toInt() and 0xff)
        assertArrayEquals(byteArrayOf(4, 3, 2, 1), pong.copyOfRange(2, 6))
        val pongPayload = pong.copyOfRange(6, 8).mapIndexed { index, byte ->
            (byte.toInt() xor pong[2 + index % 4].toInt()).toByte()
        }.toByteArray()
        assertArrayEquals(byteArrayOf(9, 8), pongPayload)
    }

    @Test
    fun `close is surfaced and acknowledged`() {
        val keyBytes = ByteArray(16) { (it + 3).toByte() }
        val output = ByteArrayOutputStream()
        val closePayload = byteArrayOf(0x03, 0xe8.toByte()) + "done".toByteArray()
        val tunnel = WebSocketJsonTunnel(
            input = ByteArrayInputStream(
                handshakeResponse(Base64.getEncoder().encodeToString(keyBytes)).toByteArray() +
                    serverFrame(opcode = 0x08, fin = true, payload = closePayload),
            ),
            output = output,
            fillRandomBytes = deterministicBytes(keyBytes, byteArrayOf(5, 6, 7, 8)),
        )
        tunnel.performHandshake()
        output.reset()

        val event = runBlocking { tunnel.readMessages { } }

        assertEquals(WebSocketJsonTunnel.Event.Close(1000, "done"), event)
        val close = output.toByteArray()
        assertEquals(0x88, close[0].toInt() and 0xff)
        assertEquals(0x80 or closePayload.size, close[1].toInt() and 0xff)
        assertFalse(close.copyOfRange(6, close.size).contentEquals(closePayload))
        val decoded = close.copyOfRange(6, close.size).mapIndexed { index, byte ->
            (byte.toInt() xor close[2 + index % 4].toInt()).toByte()
        }.toByteArray()
        assertArrayEquals(closePayload, decoded)
    }

    @Test
    fun `binary invalid rsv fragmented control and oversized frames are rejected`() {
        val cases = listOf(
            serverFrame(opcode = 0x02, fin = true, payload = byteArrayOf(1)),
            serverFrame(opcode = 0x01, fin = true, payload = byteArrayOf(1), rsv1 = true),
            serverFrame(opcode = 0x09, fin = false, payload = byteArrayOf(1)),
            byteArrayOf(0x81.toByte(), 127.toByte(), 0x80.toByte(), 0, 0, 0, 0, 0, 0, 0),
        )

        cases.forEach { frame ->
            val keyBytes = ByteArray(16) { (it + 4).toByte() }
            val tunnel = WebSocketJsonTunnel(
                input = ByteArrayInputStream(
                    handshakeResponse(Base64.getEncoder().encodeToString(keyBytes)).toByteArray() + frame,
                ),
                output = ByteArrayOutputStream(),
                fillRandomBytes = deterministicBytes(keyBytes, byteArrayOf(1, 2, 3, 4)),
            )
            tunnel.performHandshake()

            expectThrows<WebSocketProtocolException> { tunnel.readNextEvent() }
        }
    }

    @Test
    fun `oversized fragmented message is rejected before allocation`() {
        val keyBytes = ByteArray(16) { (it + 5).toByte() }
        val output = ByteArrayOutputStream()
        val tooLarge = WebSocketJsonTunnel.MAX_MESSAGE_BYTES + 1
        val header = byteArrayOf(
            0x81.toByte(),
            127.toByte(),
            0,
            0,
            0,
            0,
            ((tooLarge ushr 24) and 0xff).toByte(),
            ((tooLarge ushr 16) and 0xff).toByte(),
            ((tooLarge ushr 8) and 0xff).toByte(),
            (tooLarge and 0xff).toByte(),
        )
        val tunnel = WebSocketJsonTunnel(
            input = ByteArrayInputStream(
                handshakeResponse(Base64.getEncoder().encodeToString(keyBytes)).toByteArray() + header,
            ),
            output = output,
            fillRandomBytes = deterministicBytes(keyBytes, byteArrayOf(1, 2, 3, 4)),
        )
        tunnel.performHandshake()

        val error = expectThrows<WebSocketProtocolException> { tunnel.readNextEvent() }

        assertTrue(error.message.orEmpty().contains("超过"))
    }

    private fun handshakeResponse(key: String): String =
        "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: WebSocket\r\n" +
            "Connection: keep-alive, Upgrade\r\n" +
            "Sec-WebSocket-Accept: ${websocketAccept(key)}\r\n\r\n"

    private fun websocketAccept(key: String): String = Base64.getEncoder().encodeToString(
        MessageDigest.getInstance("SHA-1")
            .digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray(Charsets.ISO_8859_1)),
    )

    private fun serverFrame(
        opcode: Int,
        fin: Boolean,
        payload: ByteArray,
        rsv1: Boolean = false,
    ): ByteArray {
        require(payload.size <= 125)
        val first = opcode or (if (fin) 0x80 else 0) or (if (rsv1) 0x40 else 0)
        return byteArrayOf(
            first.toByte(),
            payload.size.toByte(),
        ) + payload
    }

    private fun deterministicBytes(vararg values: ByteArray): (ByteArray) -> Unit {
        val queue = ArrayDeque(values.toList())
        return { destination ->
            val source = queue.removeFirstOrNull() ?: error("未提供足够的测试随机字节")
            require(source.size == destination.size)
            source.copyInto(destination)
        }
    }

    private inline fun <reified T : Throwable> expectThrows(block: () -> Unit): T {
        try {
            block()
        } catch (error: Throwable) {
            if (error is T) return error
            throw AssertionError("期望 ${T::class.java.name}，实际为 ${error::class.java.name}", error)
        }
        throw AssertionError("期望抛出 ${T::class.java.name}")
    }
}
