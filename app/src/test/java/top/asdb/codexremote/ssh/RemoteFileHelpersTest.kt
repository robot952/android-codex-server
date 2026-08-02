package top.asdb.codexremote.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import top.asdb.codexremote.data.RemoteFileKind

class RemoteFileHelpersTest {
    @Test
    fun `remote paths require an absolute normalized path`() {
        assertEquals("/var/log/app.log", validateRemoteFilePath(" /var/log/app.log ", "下载文件"))
        assertThrows(IllegalArgumentException::class.java) {
            validateRemoteFilePath("relative/file", "下载文件")
        }
        assertThrows(IllegalArgumentException::class.java) {
            validateRemoteFilePath("/var/../etc/passwd", "下载文件")
        }
        assertThrows(IllegalArgumentException::class.java) {
            validateRemoteFilePath("/tmp/file\nname", "下载文件")
        }
    }

    @Test
    fun `file names are leaves only`() {
        assertEquals("release.apk", validateRemoteFileName(" release.apk "))
        assertThrows(IllegalArgumentException::class.java) { validateRemoteFileName("../release.apk") }
        assertThrows(IllegalArgumentException::class.java) { validateRemoteFileName("dir/file") }
        assertThrows(IllegalArgumentException::class.java) { validateRemoteFileName("\u0000") }
    }

    @Test
    fun `child paths keep root and nested directories correct`() {
        assertEquals("/archive.zip", remoteFileChildPath("/", "archive.zip"))
        assertEquals("/srv/releases/archive.zip", remoteFileChildPath("/srv/releases/", "archive.zip"))
    }

    @Test
    fun `permissions preserve the remote file kind`() {
        assertEquals("-rw-r--r--", formatRemoteFilePermissions(RemoteFileKind.File, 0x1a4))
        assertEquals("drwxr-xr-x", formatRemoteFilePermissions(RemoteFileKind.Directory, 0x1ed))
        assertEquals("lrwxrwxrwx", formatRemoteFilePermissions(RemoteFileKind.SymbolicLink, 0x1ff))
    }
}
