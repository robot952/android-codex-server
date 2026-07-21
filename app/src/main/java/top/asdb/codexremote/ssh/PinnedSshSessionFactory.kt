package top.asdb.codexremote.ssh

import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import top.asdb.codexremote.data.AuthMode
import top.asdb.codexremote.data.ServerProfile

internal const val SSH_CONNECT_TIMEOUT_MS = 15_000
internal const val SSH_CHANNEL_TIMEOUT_MS = 10_000

internal fun createPinnedSshSession(profile: ServerProfile): Session {
    require(profile.host.isNotBlank()) { "服务器地址不能为空" }
    require(profile.username.isNotBlank()) { "用户名不能为空" }
    require(profile.hostFingerprint.isNotBlank()) { "请先核对并保存 SSH 主机指纹" }

    val jsch = JSch().apply {
        hostKeyRepository = PinnedHostKeyRepository(profile.hostFingerprint)
        when (profile.authMode) {
            AuthMode.Password -> Unit
            AuthMode.PrivateKey -> {
                require(profile.privateKeyPem.isNotBlank()) { "请选择 SSH 私钥" }
                addIdentity(
                    profile.name,
                    profile.privateKeyPem.toByteArray(),
                    null,
                    profile.privateKeyPassphrase.takeIf { it.isNotEmpty() }?.toByteArray(),
                )
            }
        }
    }
    return jsch.getSession(profile.username, profile.host, profile.port).apply {
        setConfig("StrictHostKeyChecking", "yes")
        setConfig(
            "PreferredAuthentications",
            if (profile.authMode == AuthMode.Password) {
                "password,keyboard-interactive"
            } else {
                "publickey"
            },
        )
        if (profile.authMode == AuthMode.Password) {
            require(profile.password.isNotEmpty()) { "密码不能为空" }
            setPassword(profile.password)
        }
        serverAliveInterval = SSH_KEEPALIVE_INTERVAL_MS
        serverAliveCountMax = SSH_KEEPALIVE_MISSES_BEFORE_CLOSE
        timeout = SSH_CONNECT_TIMEOUT_MS
    }
}

private const val SSH_KEEPALIVE_INTERVAL_MS = 15_000
private const val SSH_KEEPALIVE_MISSES_BEFORE_CLOSE = 12
