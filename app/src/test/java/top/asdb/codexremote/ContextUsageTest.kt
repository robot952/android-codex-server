package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.data.TokenUsageBreakdown
import top.asdb.codexremote.ui.contextUsageFraction
import top.asdb.codexremote.ui.contextUsageSummary
import top.asdb.codexremote.ui.formatContextTokenCount

class ContextUsageTest {
    @Test
    fun `uses latest request instead of cumulative thread total`() {
        val usage = TokenUsage(
            last = TokenUsageBreakdown(totalTokens = 25),
            total = TokenUsageBreakdown(totalTokens = 9_999),
            modelContextWindow = 100,
        )

        assertEquals(0.25f, contextUsageFraction(usage)!!, 0.0001f)
    }

    @Test
    fun `clamps over-limit usage and rejects invalid server values`() {
        assertEquals(
            1f,
            contextUsageFraction(
                TokenUsage(
                    last = TokenUsageBreakdown(totalTokens = 101),
                    modelContextWindow = 100,
                ),
            )!!,
            0f,
        )
        assertNull(
            contextUsageFraction(
                TokenUsage(
                    last = TokenUsageBreakdown(totalTokens = -1),
                    modelContextWindow = 100,
                ),
            ),
        )
        assertNull(
            contextUsageFraction(
                TokenUsage(last = TokenUsageBreakdown(totalTokens = 1), modelContextWindow = 0),
            ),
        )
    }

    @Test
    fun `reports current context values instead of cumulative thread totals`() {
        val summary = contextUsageSummary(
            TokenUsage(
                last = TokenUsageBreakdown(totalTokens = 129_000),
                total = TokenUsageBreakdown(totalTokens = 999_999),
                modelContextWindow = 353_000,
            ),
        )!!

        assertEquals(129_000, summary.usedTokens)
        assertEquals(224_000, summary.remainingTokens)
        assertEquals(353_000, summary.windowTokens)
        assertEquals(36, summary.usedPercent)
        assertEquals(64, summary.remainingPercent)
    }

    @Test
    fun `formats context token counts for the compact detail popover`() {
        assertEquals("999", formatContextTokenCount(999))
        assertEquals("1.2k", formatContextTokenCount(1_299))
        assertEquals("129k", formatContextTokenCount(129_000))
        assertEquals("1.2m", formatContextTokenCount(1_200_000))
    }
}
