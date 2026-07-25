package top.asdb.codexremote.ui.components

private val MARKDOWN_HTTP_LINK = Regex("""\[([^\]\r\n]+)]\((https?://[^\s)]+)\)""")

/**
 * Markdown normally replaces a URL with its label, leaving nothing useful to select and copy.
 * Keep the label link, then expose its destination as a bare URL on the next line.
 */
internal fun markdownWithVisibleLinkDestinations(markdown: String): String =
    MARKDOWN_HTTP_LINK.replace(markdown) { match ->
        val label = match.groupValues[1].trim()
        val url = match.groupValues[2]
        if (label == url) match.value else "${match.value}\n$url"
    }
