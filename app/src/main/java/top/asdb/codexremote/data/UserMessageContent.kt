package top.asdb.codexremote.data

internal data class ParsedUserMessageText(
    val visibleText: String,
    val attachments: List<MessageAttachment>,
)

/**
 * Separates attachment transport text from the message the user actually typed. Some Agent
 * backends preserve each input part while others merge adjacent text parts into one block.
 */
internal fun parseUserMessageText(text: String): ParsedUserMessageText {
    val markers = TRANSPORT_ATTACHMENT_MARKER.findAll(text).toList()
    if (markers.isEmpty()) return ParsedUserMessageText(text, emptyList())

    val visibleText = StringBuilder()
    val attachments = ArrayList<MessageAttachment>(markers.size)
    var cursor = 0
    markers.forEachIndexed { index, marker ->
        val markerStart = marker.range.first
        if (markerStart > cursor) visibleText.append(text, cursor, markerStart)

        val inlineText = marker.groupValues[1].isNotBlank()
        val name = marker.groupValues[if (inlineText) 2 else 4].trim()
        if (inlineText) {
            if (name.isNotBlank()) {
                attachments += MessageAttachment(name = name, mimeType = "text/plain")
            }
            cursor = markers.getOrNull(index + 1)?.range?.first ?: text.length
        } else {
            val remotePath = marker.groupValues[5].trim()
            if (name.isNotBlank() && remotePath.isNotBlank()) {
                attachments += MessageAttachment(name = name, remotePath = remotePath)
            }
            cursor = marker.range.last + 1
        }
    }
    if (cursor < text.length) visibleText.append(text, cursor, text.length)

    return ParsedUserMessageText(
        visibleText = visibleText.toString().trim(),
        attachments = attachments,
    )
}

/** Also compacts old in-memory timeline entries created before merged text parts were recognized. */
internal fun TimelineEntry.withCompactAttachmentDisplay(): TimelineEntry {
    if (kind != TimelineKind.UserMessage || text.isBlank()) return this
    val parsed = parseUserMessageText(text)
    if (parsed.attachments.isEmpty()) return this
    return copy(
        text = parsed.visibleText,
        attachments = (attachments + parsed.attachments).distinct(),
    )
}

private const val INLINE_TEXT_ATTACHMENT_PREFIX = "文本附件"
private val TRANSPORT_ATTACHMENT_MARKER = Regex(
    pattern = "^[\\t ]*(?:($INLINE_TEXT_ATTACHMENT_PREFIX) ([^\\r\\n:]+):\\r?\\n|" +
        "(附件) ([^\\r\\n:]+):[\\t ]+([^\\r\\n]+))",
    option = RegexOption.MULTILINE,
)
