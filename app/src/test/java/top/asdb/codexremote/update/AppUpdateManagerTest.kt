package top.asdb.codexremote.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdateManagerTest {
    @Test
    fun selectsNewestStableReleaseAndParsesChineseGitChanges() {
        val update = requireNotNull(
            parseGiteeReleases(
                """
                [
                  {
                    "tag_name": "v1.7.56",
                    "prerelease": false,
                    "body": "## 更新日志\n\n- `61ca475` 发布 1.7.56\n- `9580a21` 避免在流水线日志暴露发布令牌",
                    "assets": [{"name": "CodexRemote-1.7.56.apk"}]
                  },
                  {
                    "tag_name": "v1.7.57",
                    "prerelease": false,
                    "body": "## 更新日志\n\n- `abcdef1` 完善应用内自动更新\n- `fdb6bee` 支持诊断日志多选与多文件上传",
                    "assets": [{"name": "CodexRemote-1.7.57.apk"}]
                  }
                ]
                """.trimIndent(),
            ),
        )

        assertEquals("1.7.57", update.versionName)
        assertEquals(2, update.changes.size)
        assertEquals("abcdef1", update.changes[0].gitCommit)
        assertEquals("完善应用内自动更新", update.changes[0].message)
        assertEquals("1.7.57", update.changes[1].versionName)
    }

    @Test
    fun skipsPrereleaseAndReleaseWithoutExpectedApk() {
        val update = requireNotNull(
            parseGiteeReleases(
                """
                [
                  {
                    "tag_name": "v1.7.58",
                    "prerelease": true,
                    "assets": [{"name": "CodexRemote-1.7.58.apk"}]
                  },
                  {
                    "tag_name": "v1.7.57",
                    "prerelease": false,
                    "assets": [{"name": "wrong-name.apk"}]
                  },
                  {
                    "tag_name": "v1.7.56",
                    "prerelease": false,
                    "assets": [{"name": "CodexRemote-1.7.56.apk"}]
                  }
                ]
                """.trimIndent(),
            ),
        )

        assertEquals("1.7.56", update.versionName)
        assertTrue(update.changes.isEmpty())
    }

    @Test
    fun returnsNoUpdateForInvalidReleasePayload() {
        assertNull(
            parseGiteeReleases(
                """
                [{"tag_name": "not-a-version", "assets": [{"name": "CodexRemote.apk"}]}]
                """.trimIndent(),
            ),
        )
    }

    @Test
    fun comparesSemanticVersionsIncludingPrereleases() {
        assertTrue(isVersionNewer("1.7.57", "1.7.56"))
        assertTrue(isVersionNewer("1.8.0", "1.7.99"))
        assertFalse(isVersionNewer("1.7.57-beta.1", "1.7.57"))
        assertTrue(isVersionNewer("1.7.57", "1.7.57-beta.4"))
        assertFalse(isVersionNewer("invalid", "1.7.56"))
    }
}
