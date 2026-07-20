package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.CodexModel

class PersistedUiPreferenceTest {
    private val models = listOf(
        model("gpt-default", isDefault = true, defaultEffort = "medium"),
        model("gpt-chosen", defaultEffort = "high"),
    )

    @Test
    fun `restores valid per-server model and effort`() {
        assertEquals(
            ResolvedModelSelection("gpt-chosen", "xhigh"),
            resolveModelSelection(models, "gpt-chosen", "xhigh"),
        )
    }

    @Test
    fun `falls back safely when persisted model or effort is unavailable`() {
        assertEquals(
            ResolvedModelSelection("gpt-default", "medium"),
            resolveModelSelection(models, "removed-model", "removed-effort"),
        )
        assertEquals(
            ResolvedModelSelection("gpt-chosen", "high"),
            resolveModelSelection(models, "gpt-chosen", "removed-effort"),
        )
    }

    @Test
    fun `suppresses bubblewrap startup warning but keeps useful diagnostics`() {
        val warning = "\u001B[31mERROR\u001B[0m Codex could not find bubblewrap on PATH"
        val cleaned = sanitizeCodexDiagnostic(warning)
        assertEquals("ERROR Codex could not find bubblewrap on PATH", cleaned)
        assertFalse(shouldSurfaceCodexDiagnostic(cleaned))
        assertTrue(shouldSurfaceCodexDiagnostic("会话记录加载失败"))
    }

    private fun model(
        id: String,
        isDefault: Boolean = false,
        defaultEffort: String,
    ) = CodexModel(
        id = id,
        model = id,
        displayName = id,
        description = "",
        isDefault = isDefault,
        defaultEffort = defaultEffort,
        efforts = listOf("low", "medium", "high", "xhigh"),
    )
}
