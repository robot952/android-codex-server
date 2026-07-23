package top.asdb.codexremote

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import top.asdb.codexremote.data.AppServerTransportMode
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.data.StoredProfiles

class ServerProfileSerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `app server transport is runtime only and decodes to json lines`() {
        val profiles = StoredProfiles(
            profiles = listOf(
                ServerProfile(
                    id = "server",
                    host = "host-a",
                    appServerTransport = AppServerTransportMode.WebSocketOverProxy,
                ),
            ),
        )

        val encoded = json.encodeToString(profiles)
        val decoded = json.decodeFromString<StoredProfiles>(encoded)

        assertFalse(encoded.contains("appServerTransport"))
        assertFalse(encoded.contains("WebSocketOverProxy"))
        assertEquals(AppServerTransportMode.JsonLines, decoded.profiles.single().appServerTransport)
    }
}
