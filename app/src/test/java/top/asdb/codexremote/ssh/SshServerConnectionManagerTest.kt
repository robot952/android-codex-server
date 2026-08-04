package top.asdb.codexremote.ssh

import java.io.InputStream
import java.io.OutputStream
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.RemoteDirectoryListing
import top.asdb.codexremote.data.RemoteFileListing
import top.asdb.codexremote.data.RemoteFileTransferMode
import top.asdb.codexremote.data.ServerMetrics
import top.asdb.codexremote.data.ServerProfile

class SshServerConnectionManagerTest {
    @Test
    fun `host connection becomes available without an agent client`() = runTest {
        val clients = mutableListOf<FakeRemoteServerClient>()
        val manager = SshServerConnectionManager(this) {
            FakeRemoteServerClient().also(clients::add)
        }
        val profile = ServerProfile(id = "server", host = "host", hostFingerprint = "SHA256:test")

        manager.registerProfile(profile)
        manager.connect(profile)

        assertEquals(ConnectionPhase.Connected, manager.states.value[profile.id]?.phase)
        assertTrue(manager.client(profile.id)?.isConnected() == true)
        assertEquals(1, clients.size)

        manager.disconnect(profile.id)
        assertEquals(ConnectionPhase.Disconnected, manager.states.value[profile.id]?.phase)
        assertFalse(clients.single().isConnected())
        manager.close()
    }

    @Test
    fun `host identity change replaces only that server client`() = runTest {
        val manager = SshServerConnectionManager(this) { FakeRemoteServerClient() }
        val first = ServerProfile(id = "first", host = "host-a")
        val second = ServerProfile(id = "second", host = "host-b")
        val firstClient = manager.registerProfile(first)
        val secondClient = manager.registerProfile(second)

        assertSame(firstClient, manager.registerProfile(first.copy(workspace = "/project")))
        val replacement = manager.registerProfile(first.copy(host = "host-a-new"))

        assertNotSame(firstClient, replacement)
        assertSame(secondClient, manager.client(second.id))
        manager.close()
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `dropped host session updates the host state`() = runTest {
        lateinit var client: FakeRemoteServerClient
        val manager = SshServerConnectionManager(this) {
            FakeRemoteServerClient().also { client = it }
        }
        val profile = ServerProfile(id = "server", host = "host", hostFingerprint = "SHA256:test")

        manager.registerProfile(profile)
        manager.connect(profile)
        client.dropConnection()
        advanceUntilIdle()

        assertEquals(ConnectionPhase.Disconnected, manager.states.value[profile.id]?.phase)
        manager.close()
    }
}

private class FakeRemoteServerClient : RemoteServerClient {
    private var connected = false
    private var generation = 0L

    override suspend fun probeFingerprint(profile: ServerProfile): String = "SHA256:test"

    override suspend fun connect(profile: ServerProfile): String {
        connected = true
        generation += 1
        return "SSH"
    }

    override suspend fun disconnect() {
        connected = false
    }

    override fun close() {
        connected = false
    }

    override fun isConnected(): Boolean = connected

    fun dropConnection() {
        connected = false
    }

    override fun currentGeneration(): Long? = generation.takeIf { connected }

    override suspend fun listDirectories(path: String?): RemoteDirectoryListing =
        RemoteDirectoryListing(path ?: "/", null, emptyList())

    override suspend fun listFiles(path: String?): RemoteFileListing =
        RemoteFileListing(path ?: "/", null, emptyList())

    override suspend fun readServerMetrics(profile: ServerProfile): ServerMetrics = ServerMetrics()

    override suspend fun upload(name: String, bytes: ByteArray): String = "/tmp/$name"

    override suspend fun uploadFile(directory: String, name: String, input: InputStream) = Unit

    override suspend fun downloadFile(path: String, output: OutputStream) = Unit

    override suspend fun renameFile(path: String, newName: String) = Unit

    override suspend fun deleteFiles(paths: List<String>) = Unit

    override suspend fun transferFiles(
        paths: List<String>,
        destinationDirectory: String,
        mode: RemoteFileTransferMode,
    ) = Unit

    override suspend fun downloadImage(path: String): ByteArray = byteArrayOf()
}
