package top.asdb.codexremote.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.AgentCapabilities

class OpenCodeAgentClientTest {
    @Test
    fun `raw API model IDs use the managed OpenCode provider`() {
        assertEquals(
            "custom-api/gpt-new",
            normalizeOpenCodeModelId("gpt-new"),
        )
    }

    @Test
    fun `legacy managed provider model IDs migrate to the neutral provider`() {
        assertEquals(
            "custom-api/gpt-5.6-sol",
            normalizeOpenCodeModelId("codex-remote/gpt-5.6-sol"),
        )
    }

    @Test
    fun `existing provider model IDs remain unchanged`() {
        assertEquals(
            "anthropic/claude-sonnet-4-5",
            normalizeOpenCodeModelId("anthropic/claude-sonnet-4-5"),
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unsafe model IDs are rejected`() {
        normalizeOpenCodeModelId("gpt-new; rm -rf")
    }

    @Test
    fun `OpenCode exposes global provider settings`() {
        assertTrue(AgentCapabilities.OpenCode.globalSettings)
        assertTrue(AgentCapabilities.OpenCode.reasoningEffort)
    }

    @Test
    fun `OpenCode reasoning models expose native variants`() {
        assertEquals(
            listOf("minimal", "low", "medium", "high", "xhigh"),
            openCodeReasoningEfforts("custom-api/gpt-5.6-sol"),
        )
        assertTrue(openCodeReasoningEfforts("custom-api/gpt-4.1").isEmpty())
    }
}
