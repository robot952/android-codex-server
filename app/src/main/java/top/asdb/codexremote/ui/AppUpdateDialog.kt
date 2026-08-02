package top.asdb.codexremote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.update.AppUpdateInfo

@Composable
fun AppUpdateDialog(
    update: AppUpdateInfo,
    onDownload: () -> Unit,
    onLater: () -> Unit,
    onIgnore: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onLater,
        title = {
            Column {
                Text("发现新版本", fontWeight = FontWeight.SemiBold)
                Text(
                    "v${update.versionName}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = CodexGreen,
                )
            }
        },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().heightIn(max = 340.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("更新日志", style = MaterialTheme.typography.labelLarge)
                if (update.changes.isEmpty()) {
                    Text(
                        "此版本包含改进与问题修复。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    update.changes.forEach { change ->
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                change.versionName,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                            )
                            Text(
                                "Git ${change.gitCommit}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Text(
                                change.message,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                Text(
                    "将在浏览器中下载，完成后请按系统提示安装。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            Button(onClick = onDownload) {
                Icon(Icons.Default.Download, contentDescription = null)
                Spacer(Modifier.width(7.dp))
                Text("下载更新")
            }
        },
        dismissButton = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onIgnore) {
                    Text("忽略此版本")
                }
                TextButton(onClick = onLater) {
                    Text("下次提醒")
                }
            }
        },
    )
}
