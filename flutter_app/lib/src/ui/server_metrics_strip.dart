import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'theme.dart';

class ServerMetricsStrip extends StatelessWidget {
  const ServerMetricsStrip({
    super.key,
    required this.metrics,
    this.showResourceDetails = false,
    this.compactForServerList = false,
  });

  final ServerMetrics? metrics;
  final bool showResourceDetails;
  final bool compactForServerList;

  @override
  Widget build(BuildContext context) {
    final download = metrics?.networkDownloadBytesPerSecond;
    final upload = metrics?.networkUploadBytesPerSecond;
    final totalNetworkRate = download == null && upload == null
        ? null
        : (download ?? 0) + (upload ?? 0);
    final detail = _resourceDetails(metrics);

    const itemFlex = 3;
    final networkFlex = compactForServerList ? 4 : 7;

    return Semantics(
      container: true,
      label:
          'CPU ${_formatMetric(metrics?.cpuPercent)}，'
          '内存 ${_formatMetric(metrics?.memoryPercent)}，'
          '磁盘 ${_formatMetric(metrics?.diskPercent)}，'
          '网络下载 ${_formatNetworkRate(download, compact: false)}，'
          '上传 ${_formatNetworkRate(upload, compact: false)}',
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: itemFlex,
            child: _metric(
              context,
              icon: Icons.speed,
              label: 'CPU',
              value: metrics?.cpuPercent,
              displayValue: _formatMetric(metrics?.cpuPercent),
              detail: detail,
            ),
          ),
          SizedBox(width: compactForServerList ? 4 : 11),
          Expanded(
            flex: itemFlex,
            child: _metric(
              context,
              icon: Icons.memory,
              label: '内存',
              value: metrics?.memoryPercent,
              displayValue: _formatMetric(metrics?.memoryPercent),
              detail: detail,
            ),
          ),
          SizedBox(width: compactForServerList ? 4 : 11),
          Expanded(
            flex: itemFlex,
            child: _metric(
              context,
              icon: Icons.storage,
              label: '磁盘',
              value: metrics?.diskPercent,
              displayValue: _formatMetric(metrics?.diskPercent),
              detail: detail,
            ),
          ),
          SizedBox(width: compactForServerList ? 4 : 11),
          Expanded(
            flex: networkFlex,
            child: _metric(
              context,
              icon: Icons.network_check,
              label: compactForServerList ? '网络总速率' : '网络',
              displayValue: compactForServerList
                  ? _formatNetworkTotalRate(totalNetworkRate)
                  : '↓${_formatNetworkRate(download, compact: true)} '
                        '↑${_formatNetworkRate(upload, compact: true)}',
              detail: detail,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String displayValue,
    required String detail,
    int? value,
  }) {
    final color = _metricColor(value);
    final content = Semantics(
      button: showResourceDetails,
      label: showResourceDetails ? '$label，查看服务器资源详情' : label,
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: color),
            Text(
              displayValue,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: TextStyle(
                color: color,
                fontSize: 11,
                letterSpacing: 0,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
    if (!showResourceDetails) return content;

    return Tooltip(
      richMessage: _detailSpan(detail),
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(days: 1),
      enableTapToDismiss: true,
      excludeFromSemantics: true,
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 300),
      textStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: codexText,
        letterSpacing: 0,
        height: 1.35,
      ),
      child: content,
    );
  }
}

InlineSpan _detailSpan(String detail) {
  final lines = detail.split('\n');
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                line,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
            ),
        ],
      ),
    ),
  );
}

String _formatMetric(int? value) => value == null ? '--' : '$value%';

String _resourceDetails(ServerMetrics? metrics) => [
  'CPU ${metrics?.cpuCoreCount == null ? '-- 核' : '${metrics!.cpuCoreCount} 核'} · ${_formatMetric(metrics?.cpuPercent)}',
  '内存 ${_usageText(metrics?.memoryPercent, metrics?.memoryTotalKiB, metrics?.memoryUsedKiB)}',
  '硬盘 ${_usageText(metrics?.diskPercent, metrics?.diskTotalKiB, metrics?.diskUsedKiB)}',
  '网络 ↓${_formatNetworkRate(metrics?.networkDownloadBytesPerSecond, compact: false)} · ↑${_formatNetworkRate(metrics?.networkUploadBytesPerSecond, compact: false)}',
].join('\n');

String _usageText(int? percent, int? totalKiB, int? usedKiB) {
  if (totalKiB == null || usedKiB == null) {
    return '--/-- · ${_formatMetric(percent)}';
  }
  return '${_formatSize(usedKiB)}/${_formatSize(totalKiB)} · '
      '${_formatMetric(percent)}';
}

String _formatSize(int kib) {
  final gib = kib / 1024 / 1024;
  if (gib >= 1024) return '${(gib / 1024).toStringAsFixed(1)} TB';
  if (gib >= 1) return '${gib.toStringAsFixed(1)} GB';
  return '${(kib / 1024).toStringAsFixed(0)} MB';
}

String _formatNetworkRate(int? bytesPerSecond, {required bool compact}) {
  if (bytesPerSecond == null) return '--';
  if (bytesPerSecond >= 1024 * 1024) {
    final unit = compact ? 'M' : ' MB/s';
    return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)}$unit';
  }
  if (bytesPerSecond >= 1024) {
    final unit = compact ? 'K' : ' KB/s';
    return '${(bytesPerSecond / 1024).toStringAsFixed(0)}$unit';
  }
  return compact ? '${bytesPerSecond}B' : '$bytesPerSecond B/s';
}

String _formatNetworkTotalRate(int? bytesPerSecond) {
  if (bytesPerSecond == null) return '--';
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)}MB';
  }
  if (bytesPerSecond >= 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(0)}KB';
  }
  return '${bytesPerSecond}B';
}

Color _metricColor(int? value) {
  if (value == null) return codexMuted;
  if (value >= 90) return codexRed;
  if (value >= 70) return codexAmber;
  return codexMuted;
}
