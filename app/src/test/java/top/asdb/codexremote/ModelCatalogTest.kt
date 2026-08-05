package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.CodexModel
import top.asdb.codexremote.data.CustomModelDefinition
import top.asdb.codexremote.data.ModelApiProtocol

class ModelCatalogTest {
    private val remoteModels = listOf(
        model("gpt-visible", "Visible"),
        model("gpt-hidden", "Hidden"),
    )

    @Test
    fun `hides only matching remote models`() {
        val catalog = buildModelCatalog(
            remoteModels = remoteModels,
            customModels = emptyList(),
            hiddenModelIds = listOf("gpt-hidden"),
        )

        assertEquals(listOf("gpt-visible"), catalog.map { it.model })
    }

    @Test
    fun `custom model remains selectable when matching remote model is hidden`() {
        val catalog = buildModelCatalog(
            remoteModels = remoteModels,
            customModels = listOf(
                CustomModelDefinition(
                    modelId = "gpt-hidden",
                    displayName = "My hidden override",
                    contextWindowTokens = 128_000,
                    maxOutputTokens = 16_000,
                ),
            ),
            hiddenModelIds = listOf("gpt-hidden"),
        )

        val custom = catalog.single { it.model == "gpt-hidden" }
        assertTrue(custom.isCustom)
        assertEquals("My hidden override", custom.displayName)
        assertEquals(128_000, custom.contextWindowTokens)
        assertEquals(16_000, custom.maxOutputTokens)
    }

    @Test
    fun `custom model metadata overrides the advertised remote metadata`() {
        val catalog = buildModelCatalog(
            remoteModels = listOf(
                model(
                    id = "gpt-visible",
                    displayName = "Provider name",
                    contextWindowTokens = 32_000,
                    maxOutputTokens = 4_000,
                ),
            ),
            customModels = listOf(
                CustomModelDefinition(
                    modelId = "gpt-visible",
                    displayName = "Preferred name",
                    contextWindowTokens = 64_000,
                    maxOutputTokens = 8_000,
                    apiProtocol = ModelApiProtocol.Responses,
                ),
            ),
            hiddenModelIds = emptyList(),
        )

        val model = catalog.single()
        assertTrue(model.isCustom)
        assertEquals("Preferred name", model.displayName)
        assertEquals(64_000, model.contextWindowTokens)
        assertEquals(8_000, model.maxOutputTokens)
        assertEquals(ModelApiProtocol.Responses, model.apiProtocol)
        assertFalse(model.isDefault)
    }

    private fun model(
        id: String,
        displayName: String,
        contextWindowTokens: Long = 0,
        maxOutputTokens: Long = 0,
    ) = CodexModel(
        id = id,
        model = id,
        displayName = displayName,
        description = "",
        isDefault = false,
        defaultEffort = "",
        efforts = emptyList(),
        contextWindowTokens = contextWindowTokens,
        maxOutputTokens = maxOutputTokens,
    )
}
