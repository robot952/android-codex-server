package top.asdb.codexremote.ui.components

import android.graphics.Typeface
import android.widget.TextView
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
fun MarkdownText(text: String, modifier: Modifier = Modifier, selectable: Boolean = true) {
    val context = LocalContext.current
    val color = LocalContentColor.current.toArgb()
    val markwon = remember(context) {
        Markwon.builder(context)
            .usePlugin(TablePlugin.create(context))
            .build()
    }
    val latestText = rememberUpdatedState(text)
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
            }
        },
        update = { view ->
            view.setTextColor(color)
            if (view.tag != renderedText) {
                markwon.setMarkdown(view, renderedText)
                view.tag = renderedText
            }
        },
    )
}

private const val MARKDOWN_FRAME_MS = 40L
