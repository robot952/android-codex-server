package top.asdb.codexremote.ssh

/** Runs a bounded shell script through an SSH host connection that is already authenticated. */
interface RemoteShellExecutor {
    suspend fun executeShellScript(
        script: String,
        timeoutMs: Long,
        operationName: String,
    ): List<String>
}
