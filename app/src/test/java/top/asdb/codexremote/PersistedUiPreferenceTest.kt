package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.CodexModel
import top.asdb.codexremote.data.ThreadModelPreference

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
    fun `each thread resolves its own independent model preference`() {
        val first = resolveThreadModelSelection(
            models,
            ThreadModelPreference("gpt-default", "low"),
            fallbackModel = "gpt-default",
            fallbackEffort = "medium",
        )
        val second = resolveThreadModelSelection(
            models,
            ThreadModelPreference("gpt-chosen", "xhigh"),
            fallbackModel = "gpt-default",
            fallbackEffort = "medium",
        )

        assertEquals(ResolvedModelSelection("gpt-default", "low"), first)
        assertEquals(ResolvedModelSelection("gpt-chosen", "xhigh"), second)
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
