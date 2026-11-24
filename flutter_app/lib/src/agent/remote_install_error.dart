import 'dart:convert';

import '../platform/diagnostic_logger.dart';
import '../ssh/ssh_server_client.dart';

/// Installer stdout contains progress frames. Prefer the actual stderr cause
/// and use ordinary stdout diagnostics only when stderr is empty.
RemoteExitErrorFormatter remoteInstallErrorFormatter(String proxyUrl) =>
    (stdout, stderr, exitCode) {
      for (final stream in [stderr, stdout]) {
        final messages = <String>[];
        for (final line in LineSplitter.split(stream)) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('::progress::')) continue;
          if (messages.length == 4) messages.removeAt(0);
          messages.add(trimmed);
        }
        if (messages.isNotEmpty) {
          final detail = sanitizeInstallDetail(messages.join('\n'), proxyUrl);
          if (detail.isEmpty) continue;
          return detail.length <= 1024
              ? detail
              : '…${detail.substring(detail.length - 1023)}';
        }
      }
      return '远程安装失败（退出码 $exitCode），请重试。';
    };

String sanitizeInstallDetail(String detail, String proxyUrl) {
  final proxy = proxyUrl.trim();
  final masked = proxy.isEmpty ? detail : detail.replaceAll(proxy, '[代理地址]');
  return sanitizeDiagnosticText(
    masked.replaceAll(
      RegExp(r'proxy-authorization\s*:[^\r\n]*', caseSensitive: false),
      'Proxy-Authorization: [REDACTED]',
    ),
  ).trim();
}
