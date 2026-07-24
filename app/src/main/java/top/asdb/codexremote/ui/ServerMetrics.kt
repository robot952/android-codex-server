package top.asdb.codexremote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.foundation.clickable
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp
import androidx.compose.material3.rememberTooltipState
import kotlinx.coroutines.launch
import top.asdb.codexremote.data.ServerMetrics
import top.asdb.codexremote.ui.theme.CodexAmber

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ServerMetricsText(
    metrics: ServerMetrics?,
    modifier: Modifier = Modifier,
    showMemoryDetails: Boolean = false,
) {
    val cpu = metrics?.cpuPercent
    val memory = metrics?.memoryPercent
    val disk = metrics?.diskPercent
    Row(
        modifier = modifier
            .fillMaxWidth()
            .semantics {
                contentDescription = "CPU ${formatMetric(cpu)}，内存 ${formatMetric(memory)}，磁盘 ${formatMetric(disk)}"
            },
        horizontalArrangement = Arrangement.spacedBy(11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MetricValue(Icons.Default.Speed, "CPU", cpu, Modifier)
        MemoryMetricValue(
            value = memory,
            totalKiB = metrics?.memoryTotalKiB,
            usedKiB = metrics?.memoryUsedKiB,
            showDetails = showMemoryDetails,
        )
        MetricValue(Icons.Default.Storage, "磁盘", disk, Modifier)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MemoryMetricValue(
    value: Int?,
    totalKiB: Long?,
    usedKiB: Long?,
    showDetails: Boolean,
) {
    if (!showDetails) {
        MetricValue(Icons.Default.Memory, "内存", value, Modifier)
        return
    }

    val tooltipState = rememberTooltipState(isPersistent = true)
    val coroutineScope = rememberCoroutineScope()
    TooltipBox(
        positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = {
            PlainTooltip {
                Column {
                    Text("内存占用", style = MaterialTheme.typography.labelLarge)
                    Text(
                        memoryUsageText(value, totalKiB, usedKiB),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        },
        state = tooltipState,
    ) {
        MetricValue(
            icon = Icons.Default.Memory,
            label = "内存，查看用量",
            value = value,
            modifier = Modifier.clickable {
                if (tooltipState.isVisible) {
                    tooltipState.dismiss()
                } else {
                    coroutineScope.launch { tooltipState.show() }
                }
            },
        )
    }
}

@Composable
private fun MetricValue(
    icon: ImageVector,
    label: String,
    value: Int?,
    modifier: Modifier,
) {
    val color = metricColor(value)
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            modifier = Modifier.size(15.dp),
            tint = color,
        )
        Text(
            text = formatMetric(value),
            modifier = Modifier,
            style = MaterialTheme.typography.labelSmall,
            color = color,
            maxLines = 1,
        )
    }
}

private fun formatMetric(value: Int?): String = value?.let { "$it%" } ?: "--"

private fun memoryUsageText(value: Int?, totalKiB: Long?, usedKiB: Long?): String = when {
    totalKiB != null && usedKiB != null -> "已用 ${formatMemorySize(usedKiB)} / ${formatMemorySize(totalKiB)} (${formatMetric(value)})"
    else -> "等待服务器返回内存容量 (${formatMetric(value)})"
}

private fun formatMemorySize(kib: Long): String {
    val gib = kib.toDouble() / 1024.0 / 1024.0
    return if (gib >= 1.0) "%.1f GB".format(gib) else "%.0f MB".format(kib / 1024.0)
}

@Composable
private fun metricColor(value: Int?) = when {
    value == null -> MaterialTheme.colorScheme.onSurfaceVariant
    value >= 90 -> MaterialTheme.colorScheme.error
    value >= 70 -> CodexAmber
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
