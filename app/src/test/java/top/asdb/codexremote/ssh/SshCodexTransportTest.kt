package top.asdb.codexremote.ssh

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.StringReader
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class SshCodexTransportTest {
    @Test
    fun `structured installer progress is parsed and clamped`() {
        assertEquals(RemoteInstallProgress(65, "下载并安装 Codex CLI"), parseInstallProgress("65|下载并安装 Codex CLI"))
        assertEquals(RemoteInstallProgress(100, "完成"), parseInstallProgress("150|完成"))
        assertEquals(RemoteInstallProgress(0, "旧格式进度"), parseInstallProgress("旧格式进度"))
    }

    @Test
    fun `installer shell is isolated and receives the SSH parent pid`() {
        assertEquals(
            "CODEX_REMOTE_SSH_PID=\$PPID setsid --wait sh -s",
            SshCodexTransport.INSTALL_SHELL_COMMAND,
        )
    }

    @Test(timeout = 5_000)
    fun `cancelling a blocking connect disconnects its resource`() = runBlocking {
        val started = CountDownLatch(1)
        val releaseConnect = CountDownLatch(1)
        val disconnected = AtomicBoolean(false)
        val job = launch(Dispatchers.IO) {
            runCancellableConnect(
                connect = {
                    started.countDown()
                    releaseConnect.await()
                },
                disconnect = {
                    disconnected.set(true)
                    releaseConnect.countDown()
                },
            )
        }

        assertTrue(started.await(1, TimeUnit.SECONDS))
        job.cancelAndJoin()

        assertTrue(disconnected.get())
    }

    @Test
    fun `oversized JSONL is dropped without losing the next message`() = runBlocking {
        val lines = mutableListOf<String>()
        var oversizedLines = 0

        readBoundedJsonLines(
            reader = StringReader("123456789\n{\"ok\":1}\r\n"),
            maxLineChars = 8,
            onLine = lines::add,
            onOversizedLine = { oversizedLines += 1 },
        )

        assertEquals(listOf("{\"ok\":1}"), lines)
        assertEquals(1, oversizedLines)
    }
}
