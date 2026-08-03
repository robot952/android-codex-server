package top.asdb.codexremote.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class MarkdownTextTest {
    @Test
    fun `labeled markdown HTTP links retain a selectable destination`() {
        assertEquals(
            "- [内网 APK](http://192.168.8.109/codex.apk)\nhttp://192.168.8.109/codex.apk",
            markdownWithVisibleLinkDestinations("- [内网 APK](http://192.168.8.109/codex.apk)"),
        )
    }

    @Test
    fun `labeled HTTPS links retain a selectable destination`() {
        assertEquals(
            "[下载](https://frp.asdb.top:18080/codex.apk)\nhttps://frp.asdb.top:18080/codex.apk",
            markdownWithVisibleLinkDestinations("[下载](https://frp.asdb.top:18080/codex.apk)"),
        )
    }

    @Test
    fun `URL labels and non HTTP links are not duplicated`() {
        assertEquals(
            "[https://example.com](https://example.com) [邮件](mailto:test@example.com)",
            markdownWithVisibleLinkDestinations(
                "[https://example.com](https://example.com) [邮件](mailto:test@example.com)",
            ),
        )
    }

    @Test
    fun `absolute remote file links become internal clickable links`() {
        val rendered = markdownWithVisibleLinkDestinations(
            "[下载 CodexRemote](/home/ygy/android-codex-server/dist/CodexRemote-1.7.80.apk)",
        )

        assertEquals(
            "[下载 CodexRemote](https://codex-remote.local/remote-file/"
                + "L2hvbWUveWd5L2FuZHJvaWQtY29kZXgtc2VydmVyL2Rpc3QvQ29kZXhSZW1vdGUtMS43LjgwLmFwaw)",
            rendered,
        )
        assertEquals(
            "/home/ygy/android-codex-server/dist/CodexRemote-1.7.80.apk",
            remoteFilePathFromLink(rendered.substringAfter('(').substringBefore(')')),
        )
    }

    @Test
    fun `invalid internal remote file links are rejected`() {
        assertEquals(null, remoteFilePathFromLink("https://codex-remote.local/remote-file/not+base64"))
        assertEquals(null, remoteFilePathFromLink("https://codex-remote.local/remote-file/aGVsbG8"))
        assertEquals(null, remoteFilePathFromLink("https://example.com/remote-file/L2hvbWUveWd5"))
    }
}
