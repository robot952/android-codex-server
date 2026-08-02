package top.asdb.codexremote.codex

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import top.asdb.codexremote.data.MessageAttachment
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

    @Test
    fun `user message restores image and file attachment metadata`() {
        val item = Json.parseToJsonElement(
            """
            {
              "id": "message-1",
              "type": "userMessage",
              "content": [
                {"type": "text", "text": "请检查这些附件"},
                {"type": "localImage", "path": "/tmp/diagram.png"},
                {"type": "text", "text": "附件 report.pdf: /tmp/report.pdf"},
                {"type": "text", "text": "文本附件 notes.md:\nfirst line"}
              ]
            }
            """.trimIndent(),
        ).jsonObject

        val entry = requireNotNull(CodexPayloadParser.parseItem(item, "turn-1"))

        assertEquals("请检查这些附件", entry.text)
        assertEquals(
            listOf(
                MessageAttachment("diagram.png", "/tmp/diagram.png", "image/*"),
                MessageAttachment("report.pdf", "/tmp/report.pdf"),
                MessageAttachment("notes.md", mimeType = "text/plain"),
            ),
            entry.attachments,
        )
    }
}
