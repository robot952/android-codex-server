package top.asdb.codexremote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import top.asdb.codexremote.data.FileChange
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.ui.theme.CodexRed

@Composable
fun DiffViewer(change: FileChange, onDismiss: () -> Unit) {
    val lines = remember(change.diff) { change.diff.lines() }
    val horizontal = rememberScrollState()
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Code, contentDescription = null, modifier = Modifier.size(19.dp))
                    Spacer(Modifier.width(9.dp))
                    Column(Modifier.weight(1f)) {
                        Text(change.path, style = MaterialTheme.typography.bodyMedium,
                            fontFamily = FontFamily.Monospace, maxLines = 2)
                        Row {
                            Text("+${change.additions}", color = CodexGreen,
                                style = MaterialTheme.typography.bodySmall)
                            Spacer(Modifier.width(7.dp))
                            Text("-${change.deletions}", color = CodexRed,
                                style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, contentDescription = "关闭")
                    }
                }
                HorizontalDivider(color = CodexBorder)
                val vertical = rememberScrollState()
                Column(
                    Modifier.fillMaxSize()
                        .verticalScroll(vertical)
                        .horizontalScroll(horizontal),
                ) {
                    lines.forEachIndexed { index, line ->
                        val background = when {
                            line.startsWith("+++") || line.startsWith("---") -> Color(0xFF252525)
                            line.startsWith("+") -> Color(0xFF17351E)
                            line.startsWith("-") -> Color(0xFF3B1D20)
                            line.startsWith("@@") -> Color(0xFF1D3047)
                            else -> Color.Transparent
                        }
                        val foreground = when {
                            line.startsWith("+") && !line.startsWith("+++") -> Color(0xFFB3E6BC)
                            line.startsWith("-") && !line.startsWith("---") -> Color(0xFFF4B1B5)
                            line.startsWith("@@") -> Color(0xFFAFCBF1)
                            else -> MaterialTheme.colorScheme.onSurface
                        }
                        Row(
                            modifier = Modifier.background(background).padding(vertical = 1.dp),
                        ) {
                            Text(
                                (index + 1).toString().padStart(4),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.sp,
                                modifier = Modifier.width(42.dp).padding(start = 4.dp),
                            )
                            Text(
                                line.ifEmpty { " " },
                                color = foreground,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 12.sp,
                                softWrap = false,
                                modifier = Modifier.padding(horizontal = 7.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}
