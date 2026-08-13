String formatInstallBytes(int? bytes) {
  if (bytes == null || bytes < 0) return '未知大小';
  if (bytes < 1024) return '$bytes B';
  final kibibytes = bytes / 1024;
  if (kibibytes < 1024) return '${kibibytes.toStringAsFixed(1)} KB';
  final mebibytes = kibibytes / 1024;
  if (mebibytes < 1024) return '${mebibytes.toStringAsFixed(1)} MB';
  return '${(mebibytes / 1024).toStringAsFixed(1)} GB';
}

String formatInstallRate(int? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) return '速度 --';
  return '${formatInstallBytes(bytesPerSecond)}/s';
}

String formatInstallDuration(int? seconds) {
  if (seconds == null || seconds < 0) return '用时 --';
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  if (minutes == 0) return '用时 ${remainder}s';
  return '用时 ${minutes}m ${remainder}s';
}

String formatInstallTransfer({
  required int? downloadedBytes,
  required int? totalBytes,
  required int? bytesPerSecond,
  required int? elapsedSeconds,
  String action = '已下载',
}) {
  if (downloadedBytes == null && totalBytes == null && bytesPerSecond == null) {
    return formatInstallDuration(elapsedSeconds);
  }
  final total = totalBytes == null ? '总大小未知' : formatInstallBytes(totalBytes);
  return '$action ${formatInstallBytes(downloadedBytes)} / $total · '
      '${formatInstallRate(bytesPerSecond)} · '
      '${formatInstallDuration(elapsedSeconds)}';
}
