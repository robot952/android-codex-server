package top.asdb.codexremote.ssh

import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.UserInfo
import java.security.MessageDigest
import java.util.Base64

object SshFingerprint {
    fun sha256(key: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(key)
        return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest)
    }

    fun normalize(value: String): String = value.trim().removePrefix("SHA256:").trimEnd('=')
}

class FingerprintCaptureHostKeyRepository : HostKeyRepository {
    @Volatile
    private var capturedKey: ByteArray? = null

    override fun check(host: String?, key: ByteArray?): Int {
        if (key != null) capturedKey = key.copyOf()
        return HostKeyRepository.NOT_INCLUDED
    }

    fun fingerprint(): String? = capturedKey?.let(SshFingerprint::sha256)

    override fun add(hostkey: HostKey?, ui: UserInfo?) = Unit
    override fun remove(host: String?, type: String?) = Unit
    override fun remove(host: String?, type: String?, key: ByteArray?) = Unit
    override fun getKnownHostsRepositoryID(): String = "Codex Remote fingerprint probe"
    override fun getHostKey(): Array<HostKey> = emptyArray()
    override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
}

class PinnedHostKeyRepository(private val expectedFingerprint: String) : HostKeyRepository {
    override fun check(host: String?, key: ByteArray?): Int {
        if (key == null || expectedFingerprint.isBlank()) return HostKeyRepository.NOT_INCLUDED
        val actual = SshFingerprint.normalize(SshFingerprint.sha256(key))
        return if (actual == SshFingerprint.normalize(expectedFingerprint)) {
            HostKeyRepository.OK
        } else {
            HostKeyRepository.CHANGED
        }
    }

    override fun add(hostkey: HostKey?, ui: UserInfo?) = Unit
    override fun remove(host: String?, type: String?) = Unit
    override fun remove(host: String?, type: String?, key: ByteArray?) = Unit
    override fun getKnownHostsRepositoryID(): String = "Codex Remote pinned host key"
    override fun getHostKey(): Array<HostKey> = emptyArray()
    override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
}
