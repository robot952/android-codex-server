package top.asdb.codexremote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp
import top.asdb.codexremote.data.ServerMetrics
import top.asdb.codexremote.ui.theme.CodexAmber

@Composable
internal fun ServerMetricsText(
    metrics: ServerMetrics?,
    modifier: Modifier = Modifier,
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
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MetricValue(Icons.Default.Speed, "CPU", cpu, Modifier.weight(1f))
        MetricValue(Icons.Default.Memory, "内存", memory, Modifier.weight(1f))
        MetricValue(Icons.Default.Storage, "磁盘", disk, Modifier.weight(1f))
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

@Composable
private fun metricColor(value: Int?) = when {
    value == null -> MaterialTheme.colorScheme.onSurfaceVariant
    value >= 90 -> MaterialTheme.colorScheme.error
    value >= 70 -> CodexAmber
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
