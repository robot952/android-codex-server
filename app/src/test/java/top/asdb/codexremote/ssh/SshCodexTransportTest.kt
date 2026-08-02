package top.asdb.codexremote.ssh

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.StringReader
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class SshCodexTransportTest {
    @Test
    fun `server metrics parser clamps percentages and keeps the sample time`() {
        val metrics = parseServerMetrics(
            listOf("noise", "CODEX_METRICS|18|42|101|16777216|7046430|16|104857600|31457280|2097152|524288"),
            sampledAtEpochMillis = 1234L,
        )

        assertEquals(18, metrics.cpuPercent)
        assertEquals(16, metrics.cpuCoreCount)
        assertEquals(42, metrics.memoryPercent)
        assertEquals(100, metrics.diskPercent)
        assertEquals(16777216L, metrics.memoryTotalKiB)
        assertEquals(7046430L, metrics.memoryUsedKiB)
        assertEquals(104857600L, metrics.diskTotalKiB)
        assertEquals(31457280L, metrics.diskUsedKiB)
        assertEquals(2097152L, metrics.networkDownloadBytesPerSecond)
        assertEquals(524288L, metrics.networkUploadBytesPerSecond)
        assertEquals(1234L, metrics.sampledAtEpochMillis)
        assertNull(metrics.error)
    }

    @Test
    fun `server metrics parser ignores invalid memory size details`() {
        val metrics = parseServerMetrics(listOf("CODEX_METRICS|18|42|30|1024|2048|0|4096|8192|-1|oops"))

        assertEquals(42, metrics.memoryPercent)
        assertEquals(1024L, metrics.memoryTotalKiB)
        assertNull(metrics.memoryUsedKiB)
        assertNull(metrics.cpuCoreCount)
        assertEquals(4096L, metrics.diskTotalKiB)
        assertNull(metrics.diskUsedKiB)
        assertNull(metrics.networkDownloadBytesPerSecond)
        assertNull(metrics.networkUploadBytesPerSecond)
    }

    @Test
    fun `server metrics parser treats unavailable values as unknown`() {
        val metrics = parseServerMetrics(listOf("CODEX_METRICS|-1|--|oops"))

        assertNull(metrics.cpuPercent)
        assertNull(metrics.memoryPercent)
        assertNull(metrics.diskPercent)
        assertEquals(null, metrics.error)
    }

    @Test
    fun `server metrics parser reports missing output`() {
        val metrics = parseServerMetrics(listOf("连接失败"), sampledAtEpochMillis = 9L)

        assertNull(metrics.cpuPercent)
        assertEquals("远端未返回资源数据", metrics.error)
        assertEquals(9L, metrics.sampledAtEpochMillis)
    }

    @Test
    fun `structured installer progress is parsed and clamped`() {
        assertEquals(RemoteInstallProgress(65, "下载并安装 Codex CLI"), parseInstallProgress("65|下载并安装 Codex CLI"))
        assertEquals(RemoteInstallProgress(100, "完成"), parseInstallProgress("150|完成"))
        assertEquals(RemoteInstallProgress(0, "旧格式进度"), parseInstallProgress("旧格式进度"))
        assertEquals(
            RemoteInstallProgress(
                percent = 72,
                message = "下载并安装 Codex CLI",
                detail = "已处理 24 / 36 个组件 · 18.4 MB",
                downloadPercent = 67,
            ),
            parseInstallProgress("72|67|下载并安装 Codex CLI|已处理 24 / 36 个组件 · 18.4 MB"),
        )
        assertEquals(
            RemoteInstallProgress(72, "下载 Node.js", "已下载 2.4 MB", null),
            parseInstallProgress("72||下载 Node.js|已下载 2.4 MB"),
        )
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

    @Test
    fun `oversized envelope targets only a response id`() {
        assertEquals(
            JsonRpcEnvelopeHint("42", false, false),
            inspectJsonRpcEnvelopePrefix("{\"id\":42,\"result\":{\"large\":\"payload"),
        )
        assertEquals(
            JsonRpcEnvelopeHint("9", false, true),
            inspectJsonRpcEnvelopePrefix("{\"id\":9,\"method\":\"item/completed\",\"params\":{"),
        )
        assertEquals(
            JsonRpcEnvelopeHint(null, false, true),
            inspectJsonRpcEnvelopePrefix("{\"method\":\"item/delta\",\"params\":{\"id\":42,"),
        )
    }
}
