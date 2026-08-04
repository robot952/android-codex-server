package top.asdb.codexremote.data

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class StoredProfilesTest {
    @Test
    fun `completed turn timings survive encrypted-profile payload serialization`() {
        val timing = TurnTiming(
            threadId = "thread-1",
            turnId = "turn-1",
            startedAtMillis = 1_000L,
            completedAtMillis = 4_500L,
            stopped = true,
        )
        val stored = StoredProfiles(
            completedTurnTimings = mapOf("profile-1\u0000thread-1" to timing),
        )

        val restored = Json.decodeFromString<StoredProfiles>(Json.encodeToString(stored))

        assertEquals(stored.completedTurnTimings, restored.completedTurnTimings)
    }

    @Test
    fun `legacy Codex model settings migrate without changing profile mode`() {
        val restored = Json.decodeFromString<StoredProfiles>(
            """
            {
              "profiles": [{
                "id": "legacy",
                "preferredModel": "gpt-5.2-codex",
                "preferredEffort": "high",
                "testModel": "gpt-5.2-codex",
                "customModels": [{"modelId":"custom-codex","contextWindowTokens":128000}],
                "hiddenModelIds": ["hidden-codex"]
              }],
              "selectedProfileId": "legacy"
            }
            """.trimIndent(),
        )

        val profile = restored.profiles.single()
        assertEquals(AgentMode.Codex, profile.agentMode)
        assertEquals(AgentKind.Codex, profile.activeAgent)
        assertEquals("gpt-5.2-codex", profile.modelSettings(AgentKind.Codex).preferredModel)
        assertEquals("high", profile.modelSettings(AgentKind.Codex).preferredEffort)
        assertEquals("custom-codex", profile.modelSettings(AgentKind.Codex).customModels.single().modelId)
        assertEquals(emptyList<CustomModelDefinition>(), profile.modelSettings(AgentKind.OpenCode).customModels)
    }

    @Test
    fun `agent model settings survive profile serialization independently`() {
        val profile = ServerProfile(
            id = "both",
            agentMode = AgentMode.Both,
            activeAgent = AgentKind.OpenCode,
            agentModelSettings = mapOf(
                AgentKind.Codex to AgentModelSettings(preferredModel = "gpt-5.2-codex"),
                AgentKind.OpenCode to AgentModelSettings(
                    preferredModel = "anthropic/claude-sonnet-4",
                    hiddenModelIds = listOf("openai/gpt-4"),
                ),
            ),
        )

        val restored = Json.decodeFromString<StoredProfiles>(
            Json.encodeToString(StoredProfiles(profiles = listOf(profile))),
        ).profiles.single()

        assertEquals(AgentMode.Both, restored.agentMode)
        assertEquals(AgentKind.OpenCode, restored.activeAgent)
        assertEquals("gpt-5.2-codex", restored.modelSettings(AgentKind.Codex).preferredModel)
        assertEquals("anthropic/claude-sonnet-4", restored.modelSettings(AgentKind.OpenCode).preferredModel)
        assertEquals(listOf("openai/gpt-4"), restored.modelSettings(AgentKind.OpenCode).hiddenModelIds)
    }
}
