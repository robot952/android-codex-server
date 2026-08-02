package top.asdb.codexremote.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AppUpdateManagerTest {
    @Test
    fun parsesVersionAndChineseGitChanges() {
        val update = parseAppUpdateManifest(
            """
            {
              "versionCode": 76,
              "versionName": "1.7.54",
              "changes": [
                {
                  "versionName": "1.7.54",
                  "gitCommit": "abcdef1",
                  "message": "新增应用内更新检测"
                },
                {
                  "versionName": "1.7.53",
                  "gitCommit": "fdb6bee",
                  "message": "支持诊断日志多选与多文件上传"
                }
              ]
            }
            """.trimIndent(),
        )

        assertEquals(76, update.versionCode)
        assertEquals("1.7.54", update.versionName)
        assertEquals(2, update.changes.size)
        assertEquals("fdb6bee", update.changes[1].gitCommit)
        assertEquals("支持诊断日志多选与多文件上传", update.changes[1].message)
    }

    @Test
    fun ignoresIncompleteChangeEntries() {
        val update = parseAppUpdateManifest(
            """
            {
              "versionCode": 76,
              "versionName": "1.7.54",
              "changes": [
                {"versionName": "1.7.54", "gitCommit": "abcdef1", "message": "有效记录"},
                {"versionName": "1.7.53", "message": "缺少提交"}
              ]
            }
            """.trimIndent(),
        )

        assertEquals(1, update.changes.size)
        assertEquals("有效记录", update.changes.single().message)
    }

    @Test
    fun rejectsManifestWithoutVersionCode() {
        assertThrows(IllegalArgumentException::class.java) {
            parseAppUpdateManifest("""{"versionName":"1.7.54"}""")
        }
    }
}
