package top.asdb.codexremote.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.asdb.codexremote.diagnostics.DiagnosticLogEntry
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * A multi-select dialog for retained diagnostic log sessions.
 *
 * Call this conditionally while it is visible. [onConfirm] receives only stable log ids, which can
 * be passed to [DiagnosticLogger.createShareIntent] or [DiagnosticLogger.attachmentText].
 */
@Composable
fun DiagnosticLogPickerDialog(
    confirmLabel: String,
    onDismissRequest: () -> Unit,
    onConfirm: (List<String>) -> Unit,
    modifier: Modifier = Modifier,
    title: String = "选择诊断日志",
) {
    var entries by remember { mutableStateOf<List<DiagnosticLogEntry>>(emptyList()) }
    var selectedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var isLoading by remember { mutableStateOf(true) }
    var loadError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        isLoading = true
        loadError = null
        try {
            entries = withContext(Dispatchers.IO) { DiagnosticLogger.listLogs() }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            loadError = "无法读取诊断日志"
        } finally {
            isLoading = false
        }
    }

    AlertDialog(
        modifier = modifier,
        onDismissRequest = onDismissRequest,
        title = { Text(title) },
        text = {
            when {
                isLoading -> {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 28.dp),
                        horizontalArrangement = Arrangement.Center,
                    ) {
                        CircularProgressIndicator()
                    }
                }

                loadError != null -> {
                    Text(
                        loadError.orEmpty(),
                        color = MaterialTheme.colorScheme.error,
                    )
                }

                entries.isEmpty() -> {
                    Text(
                        "暂无可分享的诊断日志",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                    ) {
                        items(entries, key = DiagnosticLogEntry::id) { entry ->
                            DiagnosticLogPickerRow(
                                entry = entry,
                                selected = entry.id in selectedIds,
                                onCheckedChange = { checked ->
                                    selectedIds = if (checked) {
                                        selectedIds + entry.id
                                    } else {
                                        selectedIds - entry.id
                                    }
                                },
                            )
                            HorizontalDivider(color = CodexBorder)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(entries.filter { it.id in selectedIds }.map { it.id }) },
                enabled = !isLoading && selectedIds.isNotEmpty(),
            ) {
                Text(confirmLabel)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismissRequest) {
                Text("取消")
            }
        },
    )
}

@Composable
private fun DiagnosticLogPickerRow(
    entry: DiagnosticLogEntry,
    selected: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth()
            .clickable { onCheckedChange(!selected) }
            .padding(vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = selected,
            onCheckedChange = onCheckedChange,
        )
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(
                formatDiagnosticLogTime(entry.createdAtMillis),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    formatDiagnosticLogSize(entry.sizeBytes),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (entry.isActive) {
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "当前记录中",
                        style = MaterialTheme.typography.labelSmall,
                        color = CodexGreen,
                    )
                }
            }
        }
    }
}

private fun formatDiagnosticLogTime(createdAtMillis: Long): String =
    Instant.ofEpochMilli(createdAtMillis)
        .atZone(CHINA_STANDARD_TIME)
        .format(DIAGNOSTIC_LOG_TIME_FORMATTER)

private fun formatDiagnosticLogSize(bytes: Long): String = when {
    bytes >= 1024L * 1024L -> "%.1f MB".format(bytes / (1024f * 1024f))
    bytes >= 1024L -> "%.1f KB".format(bytes / 1024f)
    else -> "$bytes B"
}

private val CHINA_STANDARD_TIME: ZoneId = ZoneId.of("Asia/Shanghai")
private val DIAGNOSTIC_LOG_TIME_FORMATTER: DateTimeFormatter =
    DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
