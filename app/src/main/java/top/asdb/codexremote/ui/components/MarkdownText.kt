package top.asdb.codexremote.ui.components

import android.graphics.Color
import android.graphics.Typeface
import android.text.Spannable
import android.text.style.URLSpan
import android.text.util.Linkify
import android.view.View
import android.widget.TextView
import androidx.core.text.util.LinkifyCompat
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.conflate

@Composable
fun MarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    selectable: Boolean = true,
    onOpenLink: (String) -> Unit,
) {
    val context = LocalContext.current
    val color = LocalContentColor.current.toArgb()
    val markwon = remember(context) {
        Markwon.builder(context)
            .usePlugin(TablePlugin.create(context))
            .build()
    }
    val latestText = rememberUpdatedState(text)
    val latestOpenLink = rememberUpdatedState(onOpenLink)
    var renderedText by remember { mutableStateOf(text) }
    LaunchedEffect(Unit) {
        snapshotFlow { latestText.value }.conflate().collect { value ->
            renderedText = value
            delay(MARKDOWN_FRAME_MS)
        }
    }
    AndroidView(
        modifier = modifier,
        factory = {
            TextView(it).apply {
                setTextColor(color)
                textSize = 15f
                setLineSpacing(0f, 1.2f)
                setTextIsSelectable(selectable)
                typeface = Typeface.create("sans", Typeface.NORMAL)
                linksClickable = true
                setLinkTextColor(LINK_COLOR)
            }
        },
        update = { view ->
            view.setTextColor(color)
            view.setLinkTextColor(LINK_COLOR)
            if (view.tag != renderedText) {
                markwon.setMarkdown(view, renderedText)
                // Markwon handles Markdown links, while Linkify adds clickable spans for bare URLs.
                LinkifyCompat.addLinks(view, Linkify.WEB_URLS)
                replaceUrlSpans(view) { url -> latestOpenLink.value(url) }
                view.tag = renderedText
            }
        },
    )
}

private const val MARKDOWN_FRAME_MS = 40L
private val LINK_COLOR = Color.rgb(100, 181, 246)

private fun replaceUrlSpans(view: TextView, onOpenLink: (String) -> Unit) {
    val text = view.text as? Spannable ?: return
    text.getSpans(0, text.length, URLSpan::class.java).forEach { span ->
        if (span is ConfirmUrlSpan) return@forEach
        val start = text.getSpanStart(span)
        val end = text.getSpanEnd(span)
        if (start < 0 || end <= start) return@forEach
        val flags = text.getSpanFlags(span)
        text.removeSpan(span)
        text.setSpan(ConfirmUrlSpan(span.url, onOpenLink), start, end, flags)
    }
}

private class ConfirmUrlSpan(
    url: String,
    private val onOpenLink: (String) -> Unit,
) : URLSpan(url) {
    override fun onClick(widget: View) = onOpenLink(url)
}
