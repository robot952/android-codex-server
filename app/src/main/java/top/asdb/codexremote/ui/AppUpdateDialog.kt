package top.asdb.codexremote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.update.AppUpdateDownloadState
import top.asdb.codexremote.update.AppUpdateDownloadStatus
import top.asdb.codexremote.update.AppUpdateInfo
import top.asdb.codexremote.update.formatUpdateByteSize
import top.asdb.codexremote.update.updateDownloadProgressFraction
import kotlin.math.roundToInt

@Composable
fun AppUpdateDialog(
    update: AppUpdateInfo,
    download: AppUpdateDownloadState,
    onDownload: () -> Unit,
    onInstall: () -> Unit,
    onLater: () -> Unit,
    onIgnore: () -> Unit,
) {
    val updateDownload = download.takeIf { it.versionName == update.versionName }
        ?: AppUpdateDownloadState(versionName = update.versionName)
    val progress = updateDownloadProgressFraction(
        downloadedBytes = updateDownload.downloadedBytes,
        totalBytes = updateDownload.totalBytes,
    )

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
                when (updateDownload.status) {
                    AppUpdateDownloadStatus.Idle -> {
                        Text(
                            "安装包将下载到本机，下载完成后可直接安装。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }

                    AppUpdateDownloadStatus.Downloading -> {
                        Text("下载进度", style = MaterialTheme.typography.labelLarge)
                        if (progress == null) {
                            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                        } else {
                            LinearProgressIndicator(
                                progress = progress,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        Text(
                            buildString {
                                append("已下载 ")
                                append(formatUpdateByteSize(updateDownload.downloadedBytes))
                                append(" / ")
                                append(
                                    updateDownload.totalBytes?.let(::formatUpdateByteSize)
                                        ?: "正在获取总大小",
                                )
                                progress?.let { append("（${(it * 100).roundToInt()}%）") }
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }

                    AppUpdateDownloadStatus.Downloaded -> {
                        Text("下载完成", style = MaterialTheme.typography.labelLarge)
                        LinearProgressIndicator(progress = 1f, modifier = Modifier.fillMaxWidth())
                        Text(
                            "已下载 ${formatUpdateByteSize(updateDownload.downloadedBytes)} / " +
                                formatUpdateByteSize(
                                    updateDownload.totalBytes ?: updateDownload.downloadedBytes,
                                ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }

                    AppUpdateDownloadStatus.AwaitingInstallPermission -> Text(
                        "请在系统设置中允许本应用安装未知来源应用，然后返回此处继续安装。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )

                    AppUpdateDownloadStatus.Installing -> Text(
                        "系统安装界面已打开，请按系统提示完成升级。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )

                    AppUpdateDownloadStatus.Failed -> Text(
                        updateDownload.errorMessage ?: "下载失败，请重试。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                Text("更新日志", style = MaterialTheme.typography.labelLarge)
                if (update.changes.isEmpty()) {
                    Text(
                        "此版本包含改进与问题修复。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    update.changes.forEachIndexed { index, change ->
                        Text(
                            "${index + 1}. ${change.message}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        },
        confirmButton = {
            when (updateDownload.status) {
                AppUpdateDownloadStatus.Downloading -> Button(enabled = false, onClick = {}) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                    )
                    Spacer(Modifier.width(7.dp))
                    Text("下载中")
                }

                AppUpdateDownloadStatus.Downloaded -> Button(onClick = onInstall) {
                    Text("安装更新")
                }

                AppUpdateDownloadStatus.AwaitingInstallPermission -> Button(onClick = onInstall) {
                    Text("继续安装")
                }

                AppUpdateDownloadStatus.Installing -> Button(enabled = false, onClick = {}) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                    )
                    Spacer(Modifier.width(7.dp))
                    Text("等待安装")
                }

                AppUpdateDownloadStatus.Failed -> Button(onClick = onDownload) {
                    Icon(Icons.Default.Download, contentDescription = null)
                    Spacer(Modifier.width(7.dp))
                    Text("重新下载")
                }

                AppUpdateDownloadStatus.Idle -> Button(onClick = onDownload) {
                    Icon(Icons.Default.Download, contentDescription = null)
                    Spacer(Modifier.width(7.dp))
                    Text("下载更新")
                }
            }
        },
        dismissButton = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (updateDownload.status in setOf(
                        AppUpdateDownloadStatus.Idle,
                        AppUpdateDownloadStatus.Failed,
                    )
                ) {
                    TextButton(onClick = onIgnore) {
                        Text("忽略此版本")
                    }
                }
                TextButton(onClick = onLater) {
                    Text(
                        if (updateDownload.status in setOf(
                                AppUpdateDownloadStatus.Downloading,
                                AppUpdateDownloadStatus.Downloaded,
                                AppUpdateDownloadStatus.AwaitingInstallPermission,
                                AppUpdateDownloadStatus.Installing,
                            )
                        ) {
                            "后台继续"
                        } else {
                            "下次提醒"
                        },
                    )
                }
            }
        },
    )
}
