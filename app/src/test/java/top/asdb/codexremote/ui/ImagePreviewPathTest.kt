package top.asdb.codexremote.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind

class ImagePreviewPathTest {
    @Test
    fun `recognizes imageView local png path`() {
        val path = imagePreviewPath(
            TimelineEntry(
                id = "image",
                kind = TimelineKind.Tool,
                title = "imageView",
                text = "/tmp/codex-preview.png",
            ),
        )

        assertEquals("/tmp/codex-preview.png", path)
    }

    @Test
    fun `recognizes view_image output path`() {
        val path = imagePreviewPath(
            TimelineEntry(
                id = "image",
                kind = TimelineKind.Tool,
                title = "view_image",
                output = "file:///tmp/screenshot.webp",
            ),
        )

        assertEquals("/tmp/screenshot.webp", path)
    }

    @Test
    fun `recognizes localized image viewer title`() {
        val path = imagePreviewPath(
            TimelineEntry(
                id = "image",
                kind = TimelineKind.Tool,
                title = "查看了图片",
                text = "/tmp/screenshot.jpg",
            ),
        )

        assertEquals("/tmp/screenshot.jpg", path)
    }

    @Test
    fun `uses image mime type based on extension`() {
        assertEquals("image/jpeg", imageMimeType("/tmp/screenshot.JPG"))
        assertEquals("image/webp", imageMimeType("/tmp/screenshot.webp"))
        assertEquals("image/png", imageMimeType("/tmp/screenshot.png"))
    }

    @Test
    fun `rejects non-image tool output`() {
        val path = imagePreviewPath(
            TimelineEntry(
                id = "command",
                kind = TimelineKind.Tool,
                title = "exec_command",
                text = "/tmp/result.txt",
            ),
        )

        assertNull(path)
    }
}
