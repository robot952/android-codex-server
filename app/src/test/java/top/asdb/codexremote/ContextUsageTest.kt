package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import top.asdb.codexremote.data.TokenUsage
import top.asdb.codexremote.data.TokenUsageBreakdown
import top.asdb.codexremote.ui.contextUsageFraction

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
}
