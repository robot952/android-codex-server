package top.asdb.codexremote.diagnostics

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticLoggerTest {
    @Test
    fun `diagnostic timestamps use China standard time`() {
        val formatted = DiagnosticLogger.formatTimestamp(Instant.parse("2026-08-02T06:33:17.267Z"))

        assertEquals("2026-08-02 14:33:17.267 +08:00", formatted)
    }

    @Test
    fun `utf8 log tail keeps complete characters within byte budget`() {
        val tail = takeLastUtf8Bytes("prefix-你好😀", 7)

        assertEquals("好😀", tail)
        assertTrue(tail.toByteArray(Charsets.UTF_8).size <= 7)
    }

    @Test
    fun `sanitizer removes common credentials and private keys`() {
        val input = """
            [31mERROR[0m
            password=super-secret
            passphrase="two word secret"
            Authorization: Bearer token-value.123
            sk-abcdefghijklmnopqrstuvwxyz123456
            https://user:pass@example.com/path
            -----BEGIN OPENSSH PRIVATE KEY-----
            private-material
            -----END OPENSSH PRIVATE KEY-----
        """.trimIndent()

        val sanitized = sanitizeDiagnosticText(input)

        assertFalse(sanitized.contains("super-secret"))
        assertFalse(sanitized.contains("two word secret"))
        assertFalse(sanitized.contains("token-value"))
        assertFalse(sanitized.contains("abcdefghijklmnopqrstuvwxyz"))
        assertFalse(sanitized.contains("user:pass"))
        assertFalse(sanitized.contains("private-material"))
        assertTrue(sanitized.contains("[REDACTED]"))
        assertTrue(sanitized.contains("[REDACTED_PRIVATE_KEY]"))
        assertFalse(sanitized.contains("\u001B"))
    }

    @Test
    fun `debug mode activates on tenth continuous tap`() {
        val counter = DebugTapCounter(requiredTaps = 10, maximumGapMillis = 1_500)

        repeat(9) { index ->
            assertFalse(counter.registerTap(index * 100L))
        }
        assertTrue(counter.registerTap(900L))
        assertFalse(counter.registerTap(1_000L))
    }

    @Test
    fun `tap sequence resets after a long gap`() {
        val counter = DebugTapCounter(requiredTaps = 3, maximumGapMillis = 1_000)

        assertFalse(counter.registerTap(0L))
        assertFalse(counter.registerTap(500L))
        assertFalse(counter.registerTap(2_000L))
        assertFalse(counter.registerTap(2_500L))
        assertTrue(counter.registerTap(3_000L))
    }

    @Test
    fun `connection timing uses stable fields and a single line`() {
        val message = formatConnectionTiming(
            profileId = "1234567890",
            agent = "OpenCode",
            stage = "thread_list",
            elapsedMs = 245L,
            status = "failed",
            detail = "request\n timed out",
        )

        assertEquals(
            "profile=12345678 agent=OpenCode stage=thread_list elapsed_ms=245 " +
                "status=failed detail=request timed out",
            message,
        )
    }
}
