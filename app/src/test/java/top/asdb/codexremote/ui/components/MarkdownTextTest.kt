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
}
