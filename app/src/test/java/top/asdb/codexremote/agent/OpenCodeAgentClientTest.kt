package top.asdb.codexremote.agent

import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.AgentCapabilities
import top.asdb.codexremote.data.CustomModelDefinition
import top.asdb.codexremote.data.ModelApiProtocol

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
        assertEquals(
            listOf(ModelApiProtocol.ChatCompletions, ModelApiProtocol.Responses),
            AgentCapabilities.OpenCode.modelApiProtocols,
        )
    }

    @Test
    fun `custom model payload includes the selected API protocol`() {
        val params = openCodeCustomModelParams(
            CustomModelDefinition(
                modelId = "custom-api/gpt-5.6-sol",
                apiProtocol = ModelApiProtocol.Responses,
            ),
        )

        assertEquals("responses", params.getValue("apiProtocol").jsonPrimitive.content)
    }

    @Test
    fun `custom model cache key changes with the API protocol`() {
        val definition = CustomModelDefinition(modelId = "custom-api/gpt-5.6-sol")

        assertNotEquals(
            openCodeCustomModelCacheKey(definition),
            openCodeCustomModelCacheKey(definition.copy(apiProtocol = ModelApiProtocol.Responses)),
        )
    }

    @Test
    fun `connection test uses the configured model protocol`() {
        val definitions = listOf(
            CustomModelDefinition(
                modelId = "custom-api/gpt-responses",
                apiProtocol = ModelApiProtocol.Responses,
            ),
        )

        assertEquals(
            ModelApiProtocol.Responses,
            resolveOpenCodeModelApiProtocol("gpt-responses", definitions),
        )
        assertEquals(
            ModelApiProtocol.ChatCompletions,
            resolveOpenCodeModelApiProtocol("unconfigured-model", definitions),
        )
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
