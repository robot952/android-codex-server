package top.asdb.codexremote.ui.components

import android.graphics.Typeface
import android.widget.TextView
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.Markwon

@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier, selectable: Boolean = true) {
    val context = LocalContext.current
    val color = LocalContentColor.current.toArgb()
    val markwon = remember(context) { Markwon.create(context) }
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
            markwon.setMarkdown(view, text)
        },
    )
}
