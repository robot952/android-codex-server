package top.asdb.codexremote.codex

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import top.asdb.codexremote.data.PendingAttachment

class CodexAttachmentInputTest {
    @Test
    fun `text attachment is included as text input`() {
        val input = buildUserInput(
            text = "",
            attachments = listOf(
                PendingAttachment(
                    name = "notes.txt",
                    remotePath = "/home/user/.codex-mobile/uploads/notes.txt",
                    mimeType = "text/plain",
                    textContent = "first line\nsecond line",
                ),
            ),
        )

        val value = input.single().jsonObject
        assertEquals("text", value["type"]?.jsonPrimitive?.content)
        assertEquals("文本附件 notes.txt:\nfirst line\nsecond line", value["text"]?.jsonPrimitive?.content)
    }

    @Test
    fun `image attachment remains a local image input`() {
        val input = buildUserInput(
            text = "",
            attachments = listOf(
                PendingAttachment(
                    name = "diagram.png",
                    remotePath = "/home/user/.codex-mobile/uploads/diagram.png",
                    mimeType = "image/png",
                ),
            ),
        )

        val value = input.single().jsonObject
        assertEquals("localImage", value["type"]?.jsonPrimitive?.content)
        assertEquals("/home/user/.codex-mobile/uploads/diagram.png", value["path"]?.jsonPrimitive?.content)
    }
}
