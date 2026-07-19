package top.asdb.codexremote

import com.jcraft.jsch.HostKeyRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.ssh.FingerprintCaptureHostKeyRepository
import top.asdb.codexremote.ssh.PinnedHostKeyRepository
import top.asdb.codexremote.ssh.SshFingerprint

class SshFingerprintTest {
    @Test
    fun fingerprintIsStableAndPinIsEnforced() {
        val key = "test-host-key".toByteArray()
        val fingerprint = SshFingerprint.sha256(key)
        assertTrue(fingerprint.startsWith("SHA256:"))

        val repository = PinnedHostKeyRepository(fingerprint)
        assertEquals(HostKeyRepository.OK, repository.check("host", key))
        assertEquals(HostKeyRepository.CHANGED, repository.check("host", "other".toByteArray()))
    }

    @Test
    fun normalizationAcceptsPaddingAndPrefixVariants() {
        assertEquals("abc", SshFingerprint.normalize(" SHA256:abc== "))
    }

    @Test
    fun probeRepositoryCapturesRawHostKey() {
        val repository = FingerprintCaptureHostKeyRepository()
        assertNull(repository.fingerprint())

        val key = "probe-host-key".toByteArray()
        val expected = SshFingerprint.sha256(key)
        assertEquals(HostKeyRepository.NOT_INCLUDED, repository.check("host", key))
        key.fill(0)
        assertEquals(expected, repository.fingerprint())
    }
}
