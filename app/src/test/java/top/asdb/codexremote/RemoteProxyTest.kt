package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.ssh.RemoteBootstrap
import java.util.concurrent.TimeUnit

class RemoteProxyTest {
    @Test
    fun proxyIsScopedToGeneratedInstallProcess() {
        val script = RemoteBootstrap.installScript("0.146.0", "22.17.0", "http://127.0.0.1:7890")

        assertTrue(script.contains("DOWNLOAD_PROXY='http://127.0.0.1:7890'"))
        assertTrue(script.contains("export HTTP_PROXY HTTPS_PROXY ALL_PROXY"))
        assertTrue(script.contains("npm_config_https_proxy"))
        assertTrue(!script.contains("~/.profile"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun proxyRejectsShellWhitespace() {
        RemoteBootstrap.installScript("0.146.0", "22.17.0", "http://127.0.0.1:7890\nevil")
    }

    @Test(expected = IllegalArgumentException::class)
    fun proxyRequiresSupportedScheme() {
        RemoteBootstrap.installScript("0.146.0", "22.17.0", "file:///tmp/proxy")
    }

    @Test
    fun quotedProxyStillProducesValidShell() {
        val script = RemoteBootstrap.installScript(
            "0.146.0",
            "22.17.0",
            "http://user:p'ass@127.0.0.1:7890",
        )
        val process = ProcessBuilder("sh", "-n").start()
        process.outputStream.bufferedWriter().use { it.write(script) }

        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
    }
}
