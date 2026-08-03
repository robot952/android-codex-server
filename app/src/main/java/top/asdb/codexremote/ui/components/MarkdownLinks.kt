package top.asdb.codexremote.ui.components

import java.util.Base64

private val MARKDOWN_HTTP_LINK = Regex("""\[([^\]\r\n]+)]\((https?://[^\s)]+)\)""")
private val MARKDOWN_REMOTE_FILE_LINK = Regex("""\[([^\]\r\n]+)]\((/[^\s)]+)\)""")
private val REMOTE_FILE_TOKEN = Regex("""[A-Za-z0-9_-]+""")

private const val REMOTE_FILE_LINK_PREFIX = "https://codex-remote.local/remote-file/"
private const val MAX_REMOTE_FILE_PATH_LENGTH = 4_096
private const val MAX_REMOTE_FILE_TOKEN_LENGTH = 6_000

/**
 * Markdown normally replaces a URL with its label, leaving nothing useful to select and copy.
 * Keep the label link, then expose its destination as a bare URL on the next line.
 */
internal fun markdownWithVisibleLinkDestinations(markdown: String): String =
    MARKDOWN_REMOTE_FILE_LINK.replace(markdown) { match ->
        val link = remoteFileLinkForPath(match.groupValues[2]) ?: return@replace match.value
        "[${match.groupValues[1]}]($link)"
    }.let { rendered ->
        MARKDOWN_HTTP_LINK.replace(rendered) { match ->
            val label = match.groupValues[1].trim()
            val url = match.groupValues[2]
            when {
                remoteFilePathFromLink(url) != null -> match.value
                label == url -> match.value
                else -> "${match.value}\n$url"
            }
        }
    }

/**
 * Maps an internal Markdown URL back to a server path after validating its encoded payload.
 * The HTTPS-looking URL lets Markwon generate a clickable span without leaking a fake URL into
 * the transcript or sending it to a browser.
 */
internal fun remoteFilePathFromLink(link: String): String? {
    if (!link.startsWith(REMOTE_FILE_LINK_PREFIX)) return null
    val token = link.removePrefix(REMOTE_FILE_LINK_PREFIX)
    if (token.isEmpty() || token.length > MAX_REMOTE_FILE_TOKEN_LENGTH || !REMOTE_FILE_TOKEN.matches(token)) {
        return null
    }
    val bytes = runCatching { Base64.getUrlDecoder().decode(token) }.getOrNull() ?: return null
    val path = String(bytes, Charsets.UTF_8)
    if (!bytes.contentEquals(path.toByteArray(Charsets.UTF_8))) return null
    return path.takeIf(::isDownloadableRemoteFilePath)
}

private fun remoteFileLinkForPath(path: String): String? {
    if (!isDownloadableRemoteFilePath(path)) return null
    val token = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(path.toByteArray(Charsets.UTF_8))
    return "$REMOTE_FILE_LINK_PREFIX$token"
}

private fun isDownloadableRemoteFilePath(path: String): Boolean =
    path.length in 2..MAX_REMOTE_FILE_PATH_LENGTH &&
        path.startsWith('/') &&
        path.none { it < ' ' || it == '\u007f' }
