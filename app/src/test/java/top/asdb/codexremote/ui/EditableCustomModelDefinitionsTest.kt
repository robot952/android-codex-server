package top.asdb.codexremote.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import top.asdb.codexremote.data.CodexModel
import top.asdb.codexremote.data.CustomModelDefinition
import top.asdb.codexremote.data.ModelApiProtocol

class EditableCustomModelDefinitionsTest {
    @Test
    fun `discovers editable model when local definition is missing`() {
        val result = editableCustomModelDefinitions(
            models = listOf(
                model(
                    id = "custom-api/gpt-5.6-terra",
                    displayName = "GPT 5.6 Terra",
                    isCustom = true,
                    apiProtocol = ModelApiProtocol.Responses,
                ),
                model(id = "opencode/big-pickle", displayName = "Big Pickle"),
            ),
            storedDefinitions = emptyList(),
        )

        assertEquals(1, result.size)
        assertEquals("custom-api/gpt-5.6-terra", result.single().modelId)
        assertEquals("GPT 5.6 Terra", result.single().displayName)
        assertEquals(ModelApiProtocol.Responses, result.single().apiProtocol)
    }

    @Test
    fun `merges remote metadata into stored definition without duplicating it`() {
        val stored = CustomModelDefinition(
            modelId = "custom-api/gpt-5.6-terra",
            displayName = "Old name",
            apiProtocol = ModelApiProtocol.ChatCompletions,
        )
        val result = editableCustomModelDefinitions(
            models = listOf(
                model(
                    id = stored.modelId,
                    displayName = "Current name",
                    isCustom = true,
                    apiProtocol = ModelApiProtocol.Responses,
                ),
            ),
            storedDefinitions = listOf(stored),
        )

        assertEquals(1, result.size)
        assertEquals("Current name", result.single().displayName)
        assertEquals(ModelApiProtocol.Responses, result.single().apiProtocol)
    }

    private fun model(
        id: String,
        displayName: String,
        isCustom: Boolean = false,
        apiProtocol: ModelApiProtocol? = null,
    ) = CodexModel(
        id = id,
        model = id,
        displayName = displayName,
        description = "",
        isDefault = false,
        defaultEffort = "",
        efforts = emptyList(),
        contextWindowTokens = 200_000,
        maxOutputTokens = 32_000,
        isCustom = isCustom,
        apiProtocol = apiProtocol,
    )
}
