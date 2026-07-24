package top.asdb.codexremote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp
import androidx.compose.material3.rememberTooltipState
import top.asdb.codexremote.data.ServerMetrics
import top.asdb.codexremote.ui.theme.CodexAmber

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ServerMetricsText(
    metrics: ServerMetrics?,
    modifier: Modifier = Modifier,
    showResourceDetails: Boolean = false,
) {
    val cpu = metrics?.cpuPercent
    val memory = metrics?.memoryPercent
    val disk = metrics?.diskPercent
    var selectedDetail by remember { mutableStateOf<ResourceMetric?>(null) }
    val details = resourceDetails(metrics)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .semantics {
                contentDescription = "CPU ${formatMetric(cpu)}，内存 ${formatMetric(memory)}，磁盘 ${formatMetric(disk)}"
            },
        horizontalArrangement = Arrangement.spacedBy(11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MetricValue(
            icon = Icons.Default.Speed,
            label = "CPU",
            value = cpu,
            detail = if (showResourceDetails) details else null,
            selected = selectedDetail == ResourceMetric.Cpu,
            onDetailClick = { selectedDetail = selectedDetail.toggle(ResourceMetric.Cpu) },
        )
        MetricValue(
            icon = Icons.Default.Memory,
            label = "内存",
            value = memory,
            detail = if (showResourceDetails) details else null,
            selected = selectedDetail == ResourceMetric.Memory,
            onDetailClick = { selectedDetail = selectedDetail.toggle(ResourceMetric.Memory) },
        )
        MetricValue(
            icon = Icons.Default.Storage,
            label = "磁盘",
            value = disk,
            detail = if (showResourceDetails) details else null,
            selected = selectedDetail == ResourceMetric.Disk,
            onDetailClick = { selectedDetail = selectedDetail.toggle(ResourceMetric.Disk) },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MetricValue(
    icon: ImageVector,
    label: String,
    value: Int?,
    detail: ResourceDetails?,
    selected: Boolean,
    onDetailClick: () -> Unit,
) {
    if (detail == null) {
        MetricValueContent(icon, label, value, Modifier)
        return
    }

    val tooltipState = rememberTooltipState(isPersistent = true)
    LaunchedEffect(selected) {
        if (selected) tooltipState.show() else tooltipState.dismiss()
    }
    TooltipBox(
        positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = {
            PlainTooltip {
                Column {
                    Text(
                        detail.cpu,
                        style = MaterialTheme.typography.labelSmall,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Clip,
                    )
                    Text(
                        detail.memory,
                        style = MaterialTheme.typography.labelSmall,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Clip,
                    )
                    Text(
                        detail.disk,
                        style = MaterialTheme.typography.labelSmall,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Clip,
                    )
                }
            }
        },
        state = tooltipState,
        focusable = false,
        enableUserInput = false,
    ) {
        MetricValueContent(
            icon = icon,
            label = "$label，查看服务器资源详情",
            value = value,
            modifier = Modifier.clickable(onClick = onDetailClick),
        )
    }
}

@Composable
private fun MetricValueContent(
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

private enum class ResourceMetric { Cpu, Memory, Disk }

private data class ResourceDetails(
    val cpu: String,
    val memory: String,
    val disk: String,
)

private fun ResourceMetric?.toggle(metric: ResourceMetric): ResourceMetric? =
    if (this == metric) null else metric

private fun resourceDetails(metrics: ServerMetrics?): ResourceDetails = ResourceDetails(
    cpu = "CPU ${formatMetric(metrics?.cpuPercent)} · ${metrics?.cpuCoreCount?.let { "$it 核" } ?: "-- 核"}",
    memory = "内存 ${usageText(metrics?.memoryPercent, metrics?.memoryTotalKiB, metrics?.memoryUsedKiB)}",
    disk = "硬盘 ${usageText(metrics?.diskPercent, metrics?.diskTotalKiB, metrics?.diskUsedKiB)}",
)

private fun usageText(percent: Int?, totalKiB: Long?, usedKiB: Long?): String = when {
    totalKiB != null && usedKiB != null -> "${formatSize(usedKiB)}/${formatSize(totalKiB)} · ${formatMetric(percent)}"
    else -> "--/-- · ${formatMetric(percent)}"
}

private fun formatSize(kib: Long): String {
    val gib = kib.toDouble() / 1024.0 / 1024.0
    return when {
        gib >= 1024.0 -> "%.1f TB".format(gib / 1024.0)
        gib >= 1.0 -> "%.1f GB".format(gib)
        else -> "%.0f MB".format(kib / 1024.0)
    }
}

@Composable
private fun metricColor(value: Int?) = when {
    value == null -> MaterialTheme.colorScheme.onSurfaceVariant
    value >= 90 -> MaterialTheme.colorScheme.error
    value >= 70 -> CodexAmber
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
